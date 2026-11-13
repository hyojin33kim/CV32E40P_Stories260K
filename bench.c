#include <math.h>
static inline unsigned cyc(void){unsigned v;__asm__ volatile("csrr %0,mcycle":"=r"(v)::"memory");return v;}
static inline void consume(float x){unsigned v;__asm__ volatile("fmv.x.w %0,%1":"=r"(v):"f"(x):"memory");}
volatile float inputs[8]={-8,-2,0,2,8,0.1f,1,100};
volatile float sink;
void boot(void){volatile unsigned*out=(unsigned*)0x1aff00;
 for(unsigned mode=0;mode<4;mode++){
 unsigned total=0;
 for(unsigned i=0;i<256;i++){
 float x=inputs[mode==2?5+(i%3):i%5];unsigned a,b;
 if(mode==0){a=cyc();consume(x);b=cyc();}
 else if(mode==1){a=cyc();float y=expf(x);consume(y);b=cyc();sink=y;}
 else if(mode==2){a=cyc();float y=sqrtf(x);consume(y);b=cyc();sink=y;}
 else{a=cyc();b=cyc();}
 total+=b-a;}
 out[mode]=total;}
 *(volatile unsigned*)0x20000000=1;for(;;);}
