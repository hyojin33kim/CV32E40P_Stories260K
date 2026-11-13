#define main original_main
#include "run.c"
#undef main
int main(){Transformer t;build_transformer(&t,"stories260K.bin");for(int pos=0;pos<512;pos++){
 if(pos==0||pos==127||pos==511){char name[50];sprintf(name,"kv_%d.bin",pos+1);FILE*f=fopen(name,"wb");fwrite(t.state.key_cache,4,81920,f);fwrite(t.state.value_cache,4,81920,f);fclose(f);}
 float*r=forward(&t,1,pos);
 if(pos==0||pos==127||pos==511){char name[50];sprintf(name,"ref_%d.bin",pos+1);FILE*f=fopen(name,"wb");fwrite(r,4,512,f);fclose(f);sprintf(name,"after_kv_%d.bin",pos+1);f=fopen(name,"wb");fwrite(t.state.key_cache,4,81920,f);fwrite(t.state.value_cache,4,81920,f);fclose(f);}}
}
