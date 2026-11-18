// Built for cv32e40p_top (default), with -DSOC for acc/soc_top.sv (CPU + gemv_acc + vfu), or
// with -DCHIP -DSOC for acc/soc_chip.sv (S5: imem + 1 MB SRAM in RTL; this file then serves
// only the external ports: DDR weights < 0x100000 and the sim MMIO, and preloads / dumps the
// RTL memories through their public arrays).
#ifdef CHIP
#include "Vsoc_chip.h"
#include "Vsoc_chip___024root.h"
#define VTOP Vsoc_chip
#define CORE(x) rootp->soc_chip__DOT__soc_i__DOT__cpu_i__DOT__core_i__DOT__##x
#define SRAM(i) rootp->soc_chip__DOT__sram_i__DOT__mem[i]
#ifndef CHIP_SRAM_BASE   // build_sim.sh CHIP_WEIGHTS=onchip (default): 0x0, 131072 lines; ddr: 0x100000, 65536
#define CHIP_SRAM_BASE 0x0u
#define CHIP_SRAM_LINES 131072u
#endif
#define IMEM(i) rootp->soc_chip__DOT__imem[i]
#define IREQ t.dbg_instr_req_o
#define IADDR t.dbg_instr_addr_o
#define DREQ t.dbg_data_req_o
#define DWE t.dbg_data_we_o
#define DADDR t.dbg_data_addr_o
#elif defined(SOC)
#include "Vsoc_top.h"
#include "Vsoc_top___024root.h"
#define VTOP Vsoc_top
#define CORE(x) rootp->soc_top__DOT__cpu_i__DOT__core_i__DOT__##x
#else
#include "Vcv32e40p_top.h"
#include "Vcv32e40p_top___024root.h"
#define VTOP Vcv32e40p_top
#define CORE(x) rootp->cv32e40p_top__DOT__core_i__DOT__##x
#endif
#ifndef CHIP
#define IREQ t.instr_req_o
#define IADDR t.instr_addr_o
#define DREQ t.data_req_o
#define DWE t.data_we_o
#define DADDR t.data_addr_o
#endif
#include "verilated.h"
#ifdef VTRACE
#include "verilated_vcd_c.h"
#endif
#include <deque>
#include <vector>
#include <fstream>
#include <iostream>
#include <cstring>
#include <cstdlib>
#include <unordered_map>
#include <string>
std::vector<unsigned char> mem(0x1020000,0);
// Zero-overhead profiler (sim side only; firmware unchanged). Enabled by env:
//   SIM_PROF=<out.csv>  SIM_PROF_SITES=<lo-hi>[,<lo-hi>...] (hex, top-level functions)
// Each cycle is charged to (site, pc_id): site = last pc_id seen inside a site
// function, so callee cycles (matmul, expf, ...) land on the calling source line.
// Data requests are counted per memory class at the same key (pc_id is the
// instruction after the load/store in EX; the site is unaffected by that skew).
struct Prof{unsigned long long cyc=0,rd[6]={},wr[6]={};};
static int memclass(unsigned a){return a<0x100000?0:a<0x1a0000?1:a<0x1b0000?2:a<0x1b4000?3:a<0x200000?4:5;}
unsigned rd(unsigned a){if(a+4>mem.size()){std::cerr<<"bad read "<<std::hex<<a;exit(2);} unsigned x;memcpy(&x,&mem[a],4);return x;}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv); std::ifstream f(argv[1],std::ios::binary);f.read((char*)mem.data(),mem.size());VTOP t;
#ifdef CHIP
auto rootp=t.rootp;
for(unsigned i=0;i<4096;i++)memcpy(&IMEM(i),&mem[0x1000000+4*i],4);
for(unsigned i=0;i<CHIP_SRAM_LINES;i++)for(int k=0;k<4;k++)memcpy(&SRAM(i)[k],&mem[CHIP_SRAM_BASE+16*i+4*k],4);
auto sram_out=[&](unsigned a,unsigned n){for(unsigned i=a;i<a+n;i+=4){unsigned l=(i-CHIP_SRAM_BASE)/16,k=((i-CHIP_SRAM_BASE)/4)%4;unsigned v=SRAM(l)[k];memcpy(&mem[i],&v,4);}};
t.fetch_enable_i=1;t.rst_ni=0;t.ld_req_i=0;t.ld_we_i=0;t.ld_addr_i=0;t.ld_wdata_i=0;
#else
t.boot_addr_i=0x1000080;t.mtvec_addr_i=0x1000000;t.fetch_enable_i=1;t.pulp_clock_en_i=1;t.scan_cg_en_i=1;t.rst_ni=0;
#ifdef SOC
t.acc_wr_pend_i=0;
#endif
#endif
unsigned ir=0,dr=0;bool iv=0,dv=0;unsigned low=0x200000;
#ifdef VTRACE
// debug: -CFLAGS -DVTRACE --trace build; SIM_VCD=<file> SIM_VCD_FROM / SIM_VCD_TO = cycle window
Verilated::traceEverOn(true);VerilatedVcdC vcd;const unsigned long long vfrom=getenv("SIM_VCD_FROM")?strtoull(getenv("SIM_VCD_FROM"),0,0):0,vto=getenv("SIM_VCD_TO")?strtoull(getenv("SIM_VCD_TO"),0,0):0;
if(getenv("SIM_VCD")){t.trace(&vcd,99);vcd.open(getenv("SIM_VCD"));}
#endif
// optional: argv[3] max cycles (default 30M), argv[4] step log (MMIO 0x20000004: pos + 512 logits per write)
unsigned long long maxc=argc>3?strtoull(argv[3],0,0):30000000ULL;std::ofstream steplog;if(argc>4)steplog.open(argv[4],std::ios::binary);
const char*profpath=getenv("SIM_PROF");std::vector<std::pair<unsigned,unsigned>>sites;std::unordered_map<unsigned long long,Prof>prof;unsigned site=0;
if(profpath&&getenv("SIM_PROF_SITES")){std::string s=getenv("SIM_PROF_SITES");size_t i=0;while(i<s.size()){size_t j=s.find(',',i);if(j==std::string::npos)j=s.size();std::string r=s.substr(i,j-i);size_t d=r.find('-');sites.push_back({(unsigned)strtoul(r.substr(0,d).c_str(),0,16),(unsigned)strtoul(r.substr(d+1).c_str(),0,16)});i=j+1;}}
auto dumpprof=[&](){if(!profpath)return;std::ofstream o(profpath);o<<"site,pc,cycles,rd_w,rd_kv,rd_act,rd_rope,rd_ctrl,rd_other,wr_w,wr_kv,wr_act,wr_rope,wr_ctrl,wr_other\n";for(auto&kv:prof){o<<std::hex<<(unsigned)(kv.first>>32)<<','<<(unsigned)kv.first<<std::dec<<','<<kv.second.cyc;for(int k=0;k<6;k++)o<<','<<kv.second.rd[k];for(int k=0;k<6;k++)o<<','<<kv.second.wr[k];o<<'\n';}};
// Optional DDR/SRAM memory model (SIM_DDR=1; off = the ideal model used so far).
// Addresses < 0x100000 (model weights) are external DDR, everything else on-chip SRAM.
//   SIM_DDR_LAT   (40)  cycles from request to first data of a burst
//   SIM_DDR_OVH   (4)   extra cycles when a new burst starts
//   SIM_DDR_BURST (16)  max 16-byte beats per burst (consecutive line addresses coalesce)
//   SIM_DDR_BW    (12.8) sustained DDR bytes/cycle (e.g. 16 B/cycle x 80 %)
//   SIM_DDR_OUT   (8)   max outstanding accelerator DDR burst transactions (a request that
//                       would open a new burst is not granted at the limit)
//   SIM_CPU_DDR_LAT (= SIM_DDR_LAT) CPU load latency from DDR (no cache, one at a time)
// Accelerator responses stay in order (a fast SRAM line waits behind an earlier DDR line).
const bool ddr_on=getenv("SIM_DDR")&&atoi(getenv("SIM_DDR"));
auto envd=[](const char*n,double d){return getenv(n)?atof(getenv(n)):d;};
const unsigned ddr_lat=envd("SIM_DDR_LAT",40),ddr_ovh=envd("SIM_DDR_OVH",4),ddr_burst=envd("SIM_DDR_BURST",16),ddr_out_max=envd("SIM_DDR_OUT",8),cpu_ddr_lat=envd("SIM_CPU_DDR_LAT",ddr_lat);
const double ddr_bw=envd("SIM_DDR_BW",12.8);
unsigned long long cpu_wait=0;unsigned cpu_wdata=0;unsigned long long cpu_ddr_rd=0;
#ifdef SOC
// Accelerator memory port model: grant every SIM_ACC_GNT_EVERY cycles (bandwidth),
// read data (the 16-byte aligned line holding the address) returned SIM_ACC_LAT cycles
// after the earliest OBI response cycle, in order; writes are 32-bit words.
unsigned acc_lat=getenv("SIM_ACC_LAT")?atoi(getenv("SIM_ACC_LAT")):0,acc_gp=getenv("SIM_ACC_GNT_EVERY")?atoi(getenv("SIM_ACC_GNT_EVERY")):1;
struct Line{unsigned long long t;unsigned w[4];bool ddr;unsigned long long bid;};std::deque<Line>accq;unsigned long long acc_rd=0,acc_wr=0;
unsigned long long last_resp=0,ddr_rd=0,ddr_bursts=0,cur_bid=0;double chan_free=0;unsigned ddr_out=0,last_line=0xffffffff,beats=0;
std::unordered_map<unsigned long long,unsigned>bpend;  // lines of a burst not yet delivered
#endif
for(unsigned long long c=0;c<maxc;c++){
#ifdef CHIP
t.clk_i=0;t.rst_ni=c>=5;t.data_gnt_i=1;t.data_rvalid_i=dv;t.data_rdata_i=dr;(void)iv;(void)ir;
#else
t.clk_i=0;t.scan_cg_en_i=c<5;t.rst_ni=c>=5;t.instr_gnt_i=1;t.data_gnt_i=1;t.instr_rvalid_i=iv;t.instr_rdata_i=ir;t.data_rvalid_i=dv;t.data_rdata_i=dr;
#endif
if(ddr_on&&cpu_wait){t.data_gnt_i=0;if(c>=cpu_wait){t.data_rvalid_i=1;t.data_rdata_i=cpu_wdata;cpu_wait=0;}}
#ifdef SOC
t.acc_gnt_i=(c%acc_gp)==0;if(!accq.empty()&&accq.front().t<=c){t.acc_rvalid_i=1;for(int k=0;k<4;k++)t.acc_rdata_i[k]=accq.front().w[k];if(accq.front().ddr){unsigned long long id=accq.front().bid;if(--bpend[id]==0&&id!=cur_bid){bpend.erase(id);ddr_out--;}}accq.pop_front();}else t.acc_rvalid_i=0;
#endif
t.eval();
#ifdef SOC
if(ddr_on&&t.acc_req_o&&!t.acc_we_o&&t.acc_gnt_i){unsigned b0=t.acc_addr_o&~15u;bool nb0=!(b0==last_line+16&&beats<ddr_burst);
 if(b0<0x100000&&nb0&&ddr_out>=ddr_out_max){t.acc_gnt_i=0;t.eval();}}
if(t.acc_req_o&&t.acc_gnt_i&&t.rst_ni){unsigned a=t.acc_addr_o&~3u;if(t.acc_we_o){acc_wr++;memcpy(&mem[a],&t.acc_wdata_o,4);}else{acc_rd++;unsigned b=a&~15u;Line l{c+1+acc_lat,{},false};
 if(ddr_on){if(b<0x100000){bool nb=!(b==last_line+16&&beats<ddr_burst);if(nb){if(cur_bid&&bpend.count(cur_bid)&&bpend[cur_bid]==0){bpend.erase(cur_bid);ddr_out--;}cur_bid++;bpend[cur_bid]=0;ddr_out++;beats=0;ddr_bursts++;}beats++;bpend[cur_bid]++;l.bid=cur_bid;last_line=b;double td=c+1+ddr_lat+(nb?ddr_ovh:0);if(td<chan_free)td=chan_free;chan_free=td+16.0/ddr_bw;l.t=(unsigned long long)(td+0.999);l.ddr=true;ddr_rd++;}
  else l.t=c+1;if(l.t<=last_resp)l.t=last_resp+1;last_resp=l.t;}
 for(int k=0;k<4;k++)l.w[k]=rd(b+4*k);accq.push_back(l);}}
#endif
Prof*pp=nullptr;if(profpath){unsigned pc=t.CORE(pc_id);for(auto&r:sites)if(pc>=r.first&&pc<r.second){site=pc;break;}pp=&prof[((unsigned long long)site<<32)|pc];pp->cyc++;
 if(DREQ&&t.rst_ni){int k=memclass(DADDR);if(DWE)pp->wr[k]++;else pp->rd[k]++;}}
#ifdef CHIP
if(DREQ&&DWE&&t.rst_ni&&DADDR>=0x1ff000&&DADDR<low)low=DADDR&~3u;
#endif
if(c>10 && IREQ && IADDR>=0x1000000 && IADDR<0x1000080){std::cerr<<"TRAP mepc="<<std::hex<<t.CORE(cs_registers_i__DOT__mepc_q)<<" cause="<<(unsigned)t.CORE(cs_registers_i__DOT__mcause_q)<<"\n";return 3;}
#ifdef CHIP
bool ni=false,nd=t.data_req_o&&t.rst_ni&&t.data_gnt_i;unsigned nr=0,ndr=0;bool cpu_delay=false;
static const unsigned long long trc=getenv("SIM_TRACE_DATA")?strtoull(getenv("SIM_TRACE_DATA"),0,0):0;
if(c<trc&&(DREQ||t.data_req_o||t.data_rvalid_i))std::cerr<<std::dec<<c<<" cpu req="<<(int)DREQ<<" we="<<(int)DWE<<" a="<<std::hex<<DADDR<<" ext req="<<std::dec<<(int)t.data_req_o<<" rv="<<(int)t.data_rvalid_i<<"\n";
#else
bool ni=t.instr_req_o&&t.rst_ni,nd=t.data_req_o&&t.rst_ni&&t.data_gnt_i;unsigned nr=ni?rd(t.instr_addr_o):0,ndr=0;bool cpu_delay=false;
#endif
if(nd){unsigned a=t.data_addr_o&~3u;if(a==0x20000000&&t.data_we_o){std::cout<<"DONE cycles="<<c<<" min_stack_write=0x"<<std::hex<<low<<std::dec<<"\n";
#ifdef SOC
std::cout<<"ACC reads="<<acc_rd<<" writes="<<acc_wr<<" lat="<<acc_lat<<" gnt_every="<<acc_gp<<"\n";
if(ddr_on)std::cout<<"DDR acc_lines="<<ddr_rd<<" bursts="<<ddr_bursts<<" lat="<<ddr_lat<<" ovh="<<ddr_ovh<<" burst="<<ddr_burst<<" bw="<<ddr_bw<<" out="<<ddr_out_max<<"\n";
#endif
if(ddr_on)std::cout<<"DDR cpu_loads="<<cpu_ddr_rd<<" cpu_lat="<<cpu_ddr_lat<<"\n";

#ifdef CHIP
sram_out(CHIP_SRAM_BASE,16*CHIP_SRAM_LINES);
#endif
std::ofstream out(argv[2],std::ios::binary);out.write((char*)mem.data(),0x200000);dumpprof();return 0;}
if(a==0x20000004&&t.data_we_o){if(steplog.is_open()){
#ifdef CHIP
sram_out(0x1a4a00,2048);
#endif
unsigned v=t.data_wdata_o;steplog.write((char*)&v,4);steplog.write((char*)&mem[0x1a4a00],2048);}}
else{ndr=rd(a);if(ddr_on&&!t.data_we_o&&a<0x100000){cpu_wait=c+1+cpu_ddr_lat;cpu_wdata=ndr;cpu_delay=true;cpu_ddr_rd++;}if(t.data_we_o){if(a>=0x1ff000&&a<low)low=a;for(int j=0;j<4;j++)if(t.data_be_o&(1<<j))mem[a+j]=t.data_wdata_o>>(j*8);}}}
#ifdef VTRACE
if(vcd.isOpen()&&c>=vfrom&&c<vto)vcd.dump((uint64_t)(2*c));
#endif
t.clk_i=1;t.eval();iv=ni;dv=nd&&!cpu_delay;ir=nr;dr=ndr;
#ifdef VTRACE
if(vcd.isOpen()&&c>=vfrom&&c<vto)vcd.dump((uint64_t)(2*c+1));
if(vcd.isOpen()&&c==vto)vcd.close();
#endif
if(c%5000000==0)std::cerr<<c<<" pc_fetch="<<std::hex<<IADDR<<" id="<<t.CORE(pc_id)<<" mepc="<<t.CORE(cs_registers_i__DOT__mepc_q)<<" cause="<<(unsigned)t.CORE(cs_registers_i__DOT__mcause_q)<<std::dec<<"\n";
}std::cerr<<"TIMEOUT\n";return 1;}
