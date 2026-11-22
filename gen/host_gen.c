// Host golden for step ① (continuous generation). Uses the unmodified llama2.c run.c.
//   host_gen encode <model> <tok> "<text>" <prompt.u32>
//   host_gen tf     <model> <prompt.u32> <risc_toks.u32> <steps> <logits.f32> <kv.f32>
//        teacher-forced on the RISC-selected tokens: logits per step + final KV cache
//   host_gen free   <model> <prompt.u32> <steps> <toks.u32>   independent greedy run
//   host_gen decode <model> <tok> <prompt.u32> <toks.u32> <steps>
#define main original_main
#if defined(OPTA) && defined(W8)
#include "../w8/run_opta_w8.c"  // Option A + int8 weights with per-row scale (I1, w8/make_run_w8.py)
#elif defined(OPTA)
#include "../opta/run_opta.c"   // Option A numerics (S3): exp2q softmax/SiLU, deferred normalization
#elif defined(W8)
#include "../w8/run_w8.c"       // int8 weights with per-row scale (I1)
#elif defined(QUANT)
#include "../quant/run_quant.c"  // precision gate (P1): fake-quantized weights/activations/KV
#else
#include "../run.c"
#endif
#undef main

static int *read_u32(const char *path, int *n) {
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    int *v = malloc(sz); *n = (int)(sz / 4);
    if (fread(v, 4, *n, f) != (size_t)*n) { perror(path); exit(1); }
    fclose(f); return v;
}
static void write_bin(const char *path, const void *p, size_t sz, size_t n) {
    FILE *f = fopen(path, "wb"); if (!f) { perror(path); exit(1); }
    fwrite(p, sz, n, f); fclose(f);
}
static int argmax(const float *x, int n) { int b = 0; for (int i = 1; i < n; i++) if (x[i] > x[b]) b = i; return b; }

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: see header\n"); return 1; }
    Transformer t; build_transformer(&t, argv[2]);
    int V = t.config.vocab_size, kvn = t.config.n_layers * t.config.seq_len *
        (t.config.dim * t.config.n_kv_heads / t.config.n_heads);
    if (!strcmp(argv[1], "encode")) {
        Tokenizer tk; build_tokenizer(&tk, argv[3], V);
        int *toks = malloc((strlen(argv[4]) + 3) * sizeof(int)), n = 0;
        encode(&tk, argv[4], 1, 0, toks, &n);
        write_bin(argv[5], toks, 4, n);
        printf("%d\n", n);
    } else if (!strcmp(argv[1], "tf")) {
        int np, nr; int *prompt = read_u32(argv[3], &np), *risc = read_u32(argv[4], &nr);
        int steps = atoi(argv[5]); float *lg = malloc((size_t)steps * V * 4);
        int token = prompt[0];
        for (int pos = 0; pos < steps; pos++) {
            float *r = forward(&t, token, pos);
            memcpy(lg + (size_t)pos * V, r, V * 4);
            token = pos + 1 < np ? prompt[pos + 1] : risc[pos];
        }
        write_bin(argv[6], lg, 4, (size_t)steps * V);
        FILE *f = fopen(argv[7], "wb");
        fwrite(t.state.key_cache, 4, kvn, f); fwrite(t.state.value_cache, 4, kvn, f); fclose(f);
    } else if (!strcmp(argv[1], "free")) {
        int np; int *prompt = read_u32(argv[3], &np); int steps = atoi(argv[4]);
        int *out = malloc(steps * 4), token = prompt[0];
        for (int pos = 0; pos < steps; pos++) {
            int best = argmax(forward(&t, token, pos), V);
            out[pos] = best;
            token = pos + 1 < np ? prompt[pos + 1] : best;
        }
        write_bin(argv[5], out, 4, steps);
    } else if (!strcmp(argv[1], "decode")) {
        Tokenizer tk; build_tokenizer(&tk, argv[3], V);
        int np, nt; int *prompt = read_u32(argv[4], &np), *toks = read_u32(argv[5], &nt);
        int steps = atoi(argv[6]); if (steps > nt) steps = nt;
        int token = prompt[0];
        for (int pos = 0; pos < steps; pos++) {
            int next = pos + 1 < np ? prompt[pos + 1] : toks[pos];
            if (next == 1) { printf("<BOS>"); } else safe_printf(decode(&tk, token, next));
            token = next;
        }
        printf("\n");
    }
    return 0;
}
