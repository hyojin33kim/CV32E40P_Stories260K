#include <stdint.h>
#include <math.h>
static inline unsigned cyc(void){unsigned v;__asm__ volatile("csrr %0, mcycle":"=r"(v)::"memory");return v;}
volatile unsigned ec,sc,en,sn;
#ifdef USE_ACC
// GEMV on gemv_acc (acc/gemv_acc.sv), bit-exact with the software loops:
//   y[i] = sum_j w[i*wstride + j*jstride] * x[j]   (strides in bytes)
// Step ③: FFN W1/W3/W2 (USE_ACC). Step ④: attention QK and AV (USE_ACC_ATTN).
// noinline: keeps the MMIO wait loop out of forward() so profiles charge it to the call line
static __attribute__((noinline)) void acc_gemv(float* y, float* x, float* w, int n, int d, int wstride, int jstride) {
    volatile unsigned *r = (volatile unsigned*)0x30000000;
    r[2] = (unsigned)x; r[3] = (unsigned)w; r[4] = (unsigned)y;
    r[5] = n; r[6] = d; r[7] = wstride; r[9] = jstride;
    r[0] = 1;
    while (r[1] & 1) ;
}
static void acc_matmul(float* xout, float* x, float* w, int n, int d) {
    acc_gemv(xout, x, w, n, d, n * 4, 4);
}
#ifdef USE_ACC_VFU
// Step ④-b: vector function unit (acc/vfu.sv), bit-exact with softmax(), the SwiGLU
// loop and the /sqrt(head_size) loop (picolibc expf). cmd: 1 softmax(a,n),
// 2 a[i]=(a[i]*(1/(1+expf(-a[i]))))*b[i], 3 a[i]/=s, 4 a[i]=expf(a[i])
static __attribute__((noinline)) void acc_vfu(unsigned cmd, float* a, float* b, int n, float s) {
    volatile unsigned *r = (volatile unsigned*)0x30000040;
    union { float f; unsigned u; } c = { s };
    r[2] = (unsigned)a; r[3] = (unsigned)b; r[4] = n; r[5] = c.u;
    r[0] = cmd;
    while (r[1] & 1) ;
}
#endif
#define FFN_MATMUL acc_matmul
#else
#define FFN_MATMUL matmul
#endif
#include <string.h>
typedef struct {
    int dim; // transformer dimension
    int hidden_dim; // for ffn layers
    int n_layers; // number of layers
    int n_heads; // number of query heads
    int n_kv_heads; // number of key/value heads (can be < query heads because of multiquery)
    int vocab_size; // vocabulary size, usually 256 (byte-level)
    int seq_len; // max sequence length
} Config;

typedef struct {
    // token embedding table
    float* token_embedding_table;    // (vocab_size, dim)
    // weights for rmsnorms
    float* rms_att_weight; // (layer, dim) rmsnorm weights
    float* rms_ffn_weight; // (layer, dim)
    // weights for matmuls. note dim == n_heads * head_size
    float* wq; // (layer, dim, n_heads * head_size)
    float* wk; // (layer, dim, n_kv_heads * head_size)
    float* wv; // (layer, dim, n_kv_heads * head_size)
    float* wo; // (layer, n_heads * head_size, dim)
    // weights for ffn
    float* w1; // (layer, hidden_dim, dim)
    float* w2; // (layer, dim, hidden_dim)
    float* w3; // (layer, hidden_dim, dim)
    // final rmsnorm
    float* rms_final_weight; // (dim,)
    // (optional) classifier weights for the logits, on the last layer
    float* wcls;
} TransformerWeights;

typedef struct {
    // current wave of activations
    float *x; // activation at current time stamp (dim,)
    float *xb; // same, but inside a residual branch (dim,)
    float *xb2; // an additional buffer just for convenience (dim,)
    float *hb; // buffer for hidden dimension in the ffn (hidden_dim,)
    float *hb2; // buffer for hidden dimension in the ffn (hidden_dim,)
    float *q; // query (dim,)
    float *k; // key (dim,)
    float *v; // value (dim,)
    float *att; // buffer for scores/attention values (n_heads, seq_len)
    float *logits; // output logits
    // kv cache
    float* key_cache;   // (layer, seq_len, dim)
    float* value_cache; // (layer, seq_len, dim)
} RunState;

typedef struct {
    Config config; // the hyperparameters of the architecture (the blueprint)
    TransformerWeights weights; // the weights of the model
    RunState state; // buffers for the "wave" of activations in the forward pass
    // some more state needed to properly clean up the memory mapping (sigh)
    int fd; // file descriptor for memory mapping
    float* data; // memory mapped data pointer
    long file_size; // size of the checkpoint file in bytes
} Transformer;

void rmsnorm(float* o, float* x, float* weight, int size) {
    // calculate sum of squares
    float ss = 0.0f;
    for (int j = 0; j < size; j++) {
        ss += x[j] * x[j];
    }
    ss /= size;
    ss += 1e-5f;
    ss = 1.0f / sqrtf(ss);
    // normalize and scale
    for (int j = 0; j < size; j++) {
        o[j] = weight[j] * (ss * x[j]);
    }
}

void softmax(float* x, int size) {
    // find max value (for numerical stability)
    float max_val = x[0];
    for (int i = 1; i < size; i++) {
        if (x[i] > max_val) {
            max_val = x[i];
        }
    }
    // exp and sum
    float sum = 0.0f;
    for (int i = 0; i < size; i++) {
        x[i] = expf(x[i] - max_val);
        sum += x[i];
    }
    // normalize
    for (int i = 0; i < size; i++) {
        x[i] /= sum;
    }
}

void matmul(float* xout, float* x, float* w, int n, int d) {
    // W (d,n) @ x (n,) -> xout (d,)
    // by far the most amount of time is spent inside this little function
    int i;
    #pragma omp parallel for private(i)
    for (i = 0; i < d; i++) {
        float val = 0.0f;
        for (int j = 0; j < n; j++) {
            val += w[i * n + j] * x[j];
        }
        xout[i] = val;
    }
}

float* forward(Transformer* transformer, int token, int pos) {

    // a few convenience variables
    Config* p = &transformer->config;
    TransformerWeights* w = &transformer->weights;
    RunState* s = &transformer->state;
    float *x = s->x;
    int dim = p->dim;
    int kv_dim = (p->dim * p->n_kv_heads) / p->n_heads;
    int kv_mul = p->n_heads / p->n_kv_heads; // integer multiplier of the kv sharing in multiquery
    int hidden_dim =  p->hidden_dim;
    int head_size = dim / p->n_heads;

    // copy the token embedding into x
    float* content_row = w->token_embedding_table + token * dim;
    memcpy(x, content_row, dim*sizeof(*x));

    // forward all the layers
    for(unsigned long long l = 0; l < p->n_layers; l++) {

        // attention rmsnorm
        rmsnorm(s->xb, x, w->rms_att_weight + l*dim, dim);

        // key and value point to the kv cache
        int loff = l * 2 * p->seq_len * kv_dim; // kv cache layer offset for convenience
        s->k = s->key_cache + loff + pos * kv_dim;
        s->v = s->value_cache + loff + pos * kv_dim;

        // qkv matmuls for this position
        matmul(s->q, s->xb, w->wq + l*dim*dim, dim, dim);
        matmul(s->k, s->xb, w->wk + l*dim*kv_dim, dim, kv_dim);
        matmul(s->v, s->xb, w->wv + l*dim*kv_dim, dim, kv_dim);

        // RoPE relative positional encoding: complex-valued rotate q and k in each head
        for (int i = 0; i < dim; i+=2) {
            int head_dim = i % head_size;
            const float *rope=(const float*)0x001b0000;
            float fcr=rope[pos*8+head_dim];
            float fci=rope[pos*8+head_dim+1];
            int rotn = i < kv_dim ? 2 : 1; // how many vectors? 2 = q & k, 1 = q only
            for (int v = 0; v < rotn; v++) {
                float* vec = v == 0 ? s->q : s->k; // the vector to rotate (query or key)
                float v0 = vec[i];
                float v1 = vec[i+1];
                vec[i]   = v0 * fcr - v1 * fci;
                vec[i+1] = v0 * fci + v1 * fcr;
            }
        }

        // multihead attention. iterate over all heads
        int h;
        #pragma omp parallel for private(h)
        for (h = 0; h < p->n_heads; h++) {
            // get the query vector for this head
            float* q = s->q + h * head_size;
            // attention scores for this head
            float* att = s->att + h * p->seq_len;
#ifdef USE_ACC_ATTN
            // step ④: q.K^T on the accelerator (rows = timesteps), then the /sqrt(head_size)
            // on the CPU after the full dot product, exactly as below
            acc_gemv(att, q, s->key_cache + loff + (h / kv_mul) * head_size, head_size, pos + 1,
                     kv_dim * 4, 4);
            // (the VFU divs command is not used here: the divider latency dominates and
            //  the CPU loop measured 6% faster at ctx512, see acc/P4B_VFU.md)
            for (int t = 0; t <= pos; t++) att[t] /= 0x1.6a09e6p+1f;
#else
            // iterate over all timesteps, including the current one
            for (int t = 0; t <= pos; t++) {
                // get the key vector for this head and at this timestep
                float* k = s->key_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
                // calculate the attention score as the dot product of q and k
                float score = 0.0f;
                for (int i = 0; i < head_size; i++) {
                    score += q[i] * k[i];
                }
                score /= 0x1.6a09e6p+1f;
                // save the score to the attention buffer
                att[t] = score;
            }
#endif

            // softmax the scores to get attention weights, from 0..pos inclusively
#ifdef USE_ACC_VFU
            acc_vfu(1, att, 0, pos + 1, 0);
#else
            softmax(att, pos + 1);
#endif

            // weighted sum of the values, store back into xb
            float* xb = s->xb + h * head_size;
#ifdef USE_ACC_ATTN
            // step ④: V^T.a on the accelerator (rows = head dims, columns = timesteps,
            // accumulated in t order from +0.0 like the memset + loop below)
            acc_gemv(xb, att, s->value_cache + loff + (h / kv_mul) * head_size, pos + 1, head_size,
                     4, kv_dim * 4);
#else
            memset(xb, 0, head_size * sizeof(float));
            for (int t = 0; t <= pos; t++) {
                // get the value vector for this head and at this timestep
                float* v = s->value_cache + loff + t * kv_dim + (h / kv_mul) * head_size;
                // get the attention weight for this timestep
                float a = att[t];
                // accumulate the weighted value into xb
                for (int i = 0; i < head_size; i++) {
                    xb[i] += a * v[i];
                }
            }
#endif
        }

        // final matmul to get the output of the attention
        matmul(s->xb2, s->xb, w->wo + l*dim*dim, dim, dim);

        // residual connection back into x
        for (int i = 0; i < dim; i++) {
            x[i] += s->xb2[i];
        }

        // ffn rmsnorm
        rmsnorm(s->xb, x, w->rms_ffn_weight + l*dim, dim);

        // Now for FFN in PyTorch we have: self.w2(F.silu(self.w1(x)) * self.w3(x))
        // first calculate self.w1(x) and self.w3(x)
        FFN_MATMUL(s->hb, s->xb, w->w1 + l*dim*hidden_dim, dim, hidden_dim);
        FFN_MATMUL(s->hb2, s->xb, w->w3 + l*dim*hidden_dim, dim, hidden_dim);

        // SwiGLU non-linearity
#ifdef USE_ACC_VFU
        acc_vfu(2, s->hb, s->hb2, hidden_dim, 0);
#else
        for (int i = 0; i < hidden_dim; i++) {
            float val = s->hb[i];
            // silu(x)=x*σ(x), where σ(x) is the logistic sigmoid
            val *= (1.0f / (1.0f + expf(-val)));
            // elementwise multiply with w3(x)
            val *= s->hb2[i];
            s->hb[i] = val;
        }
#endif

        // final matmul to get the output of the ffn
        FFN_MATMUL(s->xb, s->hb, w->w2 + l*dim*hidden_dim, hidden_dim, dim);

        // residual connection
        for (int i = 0; i < dim; i++) {
            x[i] += s->xb[i];
        }
    }

    // final rmsnorm
    rmsnorm(x, x, w->rms_final_weight, dim);

    // classifier into logits
    matmul(s->logits, x, w->wcls, p->dim, p->vocab_size);
    return s->logits;
}

// ----------------------------------------------------------------------------

static Transformer tr;
volatile unsigned result_token;
void boot(void) {
 tr.config=(Config){64,172,5,8,4,512,512};
 TransformerWeights *w=&tr.weights;
 w->token_embedding_table=(float*)0x0;
 w->wcls=w->token_embedding_table;
 w->wq=(float*)0x20000; w->wk=(float*)0x34000; w->wv=(float*)0x3e000;
 w->wo=(float*)0x48000;
 w->w1=(float*)0x5c000; w->w2=w->w1+55040; w->w3=w->w2+55040;
 w->rms_att_weight=(float*)0xfd400; w->rms_ffn_weight=w->rms_att_weight+320;
 w->rms_final_weight=w->rms_ffn_weight+320;
 RunState *s=&tr.state;
 s->x=(float*)0x1a0000;s->xb=(float*)0x1a0100;s->xb2=(float*)0x1a0200;
 s->q=(float*)0x1a0300;s->hb=(float*)0x1a0400;s->hb2=(float*)0x1a0700;
 s->att=(float*)0x1a0a00;s->logits=(float*)0x1a4a00;
 s->key_cache=(float*)0x100000;s->value_cache=(float*)0x110000;
 // Autoregressive generation (llama2.c generate(), greedy, no BOS stop so the
 // whole KV cache can be exercised). Control block written by the host image:
 //   0x1afff0 n_prompt, 0x1afff4 n_steps, 0x1afff8 first pos, 0x1ae000 prompt tokens (u32)
 // Outputs: 0x1ae800 argmax per pos (u32), 0x1ad000 forward cycles per pos.
 // MMIO 0x20000004 <- pos after each step; the sim dumps logits there.
 volatile unsigned *ctrl=(unsigned*)0x1afff0;
 unsigned np=ctrl[0], steps=ctrl[1], pos0=ctrl[2]; // pos0: first pos (0 = normal generation; >0 = single-step profiling with host-injected KV)
 const unsigned *prompt=(const unsigned*)0x1ae000;
 volatile unsigned *toks=(unsigned*)0x1ae800, *cycles=(unsigned*)0x1ad000;
 unsigned token=prompt[0]; unsigned long long total=0;
 for(unsigned pos=pos0;pos<pos0+steps;pos++){
  unsigned start=cyc();
  float *r=forward(&tr,token,pos);
  unsigned elapsed=cyc()-start; unsigned best=0;
  for(unsigned i=1;i<512;i++) if(r[i]>r[best]) best=i;
  toks[pos]=best; cycles[pos]=elapsed; total+=elapsed;
  *(volatile unsigned*)0x20000004=pos;
  token = pos+1<np ? prompt[pos+1] : best;
 }
 result_token=token;
 volatile unsigned *out=(unsigned*)0x1aff00; out[0]=(unsigned)total;out[1]=ec;out[2]=sc;out[3]=en;out[4]=sn;out[5]=steps;out[6]=(unsigned)(total>>32);
 *(volatile unsigned*)0x20000000=1; for(;;);
}
