#include "Vcv32e40p_top.h"
#include "verilated.h"
#include "Vcv32e40p_top___024root.h"
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
int main(int argc,char**argv){Verilated::commandArgs(argc,argv); std::ifstream f(argv[1],std::ios::binary);f.read((char*)mem.data(),mem.size());Vcv32e40p_top t; t.boot_addr_i=0x1000080;t.mtvec_addr_i=0x1000000;t.fetch_enable_i=1;t.pulp_clock_en_i=1;t.scan_cg_en_i=1;t.rst_ni=0;
unsigned ir=0,dr=0;bool iv=0,dv=0;unsigned low=0x200000;
// optional: argv[3] max cycles (default 30M), argv[4] step log (MMIO 0x20000004: pos + 512 logits per write)
unsigned long long maxc=argc>3?strtoull(argv[3],0,0):30000000ULL;std::ofstream steplog;if(argc>4)steplog.open(argv[4],std::ios::binary);
const char*profpath=getenv("SIM_PROF");std::vector<std::pair<unsigned,unsigned>>sites;std::unordered_map<unsigned long long,Prof>prof;unsigned site=0;
if(profpath&&getenv("SIM_PROF_SITES")){std::string s=getenv("SIM_PROF_SITES");size_t i=0;while(i<s.size()){size_t j=s.find(',',i);if(j==std::string::npos)j=s.size();std::string r=s.substr(i,j-i);size_t d=r.find('-');sites.push_back({(unsigned)strtoul(r.substr(0,d).c_str(),0,16),(unsigned)strtoul(r.substr(d+1).c_str(),0,16)});i=j+1;}}
auto dumpprof=[&](){if(!profpath)return;std::ofstream o(profpath);o<<"site,pc,cycles,rd_w,rd_kv,rd_act,rd_rope,rd_ctrl,rd_other,wr_w,wr_kv,wr_act,wr_rope,wr_ctrl,wr_other\n";for(auto&kv:prof){o<<std::hex<<(unsigned)(kv.first>>32)<<','<<(unsigned)kv.first<<std::dec<<','<<kv.second.cyc;for(int k=0;k<6;k++)o<<','<<kv.second.rd[k];for(int k=0;k<6;k++)o<<','<<kv.second.wr[k];o<<'\n';}};
for(unsigned long long c=0;c<maxc;c++){
t.clk_i=0;t.scan_cg_en_i=c<5;t.rst_ni=c>=5;t.instr_gnt_i=1;t.data_gnt_i=1;t.instr_rvalid_i=iv;t.instr_rdata_i=ir;t.data_rvalid_i=dv;t.data_rdata_i=dr;t.eval();
Prof*pp=nullptr;if(profpath){unsigned pc=t.rootp->cv32e40p_top__DOT__core_i__DOT__pc_id;for(auto&r:sites)if(pc>=r.first&&pc<r.second){site=pc;break;}pp=&prof[((unsigned long long)site<<32)|pc];pp->cyc++;
 if(t.data_req_o&&t.rst_ni){int k=memclass(t.data_addr_o);if(t.data_we_o)pp->wr[k]++;else pp->rd[k]++;}}
if(c>10 && t.instr_req_o && t.instr_addr_o>=0x1000000 && t.instr_addr_o<0x1000080){std::cerr<<"TRAP mepc="<<std::hex<<t.rootp->cv32e40p_top__DOT__core_i__DOT__cs_registers_i__DOT__mepc_q<<" cause="<<(unsigned)t.rootp->cv32e40p_top__DOT__core_i__DOT__cs_registers_i__DOT__mcause_q<<"\n";return 3;}
bool ni=t.instr_req_o&&t.rst_ni,nd=t.data_req_o&&t.rst_ni;unsigned nr=ni?rd(t.instr_addr_o):0,ndr=0;
if(nd){unsigned a=t.data_addr_o&~3u;if(a==0x20000000&&t.data_we_o){std::cout<<"DONE cycles="<<c<<" min_stack_write=0x"<<std::hex<<low<<std::dec<<"\n";std::ofstream out(argv[2],std::ios::binary);out.write((char*)mem.data(),0x200000);dumpprof();return 0;}
if(a==0x20000004&&t.data_we_o){if(steplog.is_open()){unsigned v=t.data_wdata_o;steplog.write((char*)&v,4);steplog.write((char*)&mem[0x1a4a00],2048);}}
else{ndr=rd(a);if(t.data_we_o){if(a>=0x1ff000&&a<low)low=a;for(int j=0;j<4;j++)if(t.data_be_o&(1<<j))mem[a+j]=t.data_wdata_o>>(j*8);}}}
t.clk_i=1;t.eval();iv=ni;dv=nd;ir=nr;dr=ndr;
if(c%5000000==0)std::cerr<<c<<" pc_fetch="<<std::hex<<t.instr_addr_o<<" id="<<t.rootp->cv32e40p_top__DOT__core_i__DOT__pc_id<<" mepc="<<t.rootp->cv32e40p_top__DOT__core_i__DOT__cs_registers_i__DOT__mepc_q<<" cause="<<(unsigned)t.rootp->cv32e40p_top__DOT__core_i__DOT__cs_registers_i__DOT__mcause_q<<std::dec<<"\n";
}std::cerr<<"TIMEOUT\n";return 1;}
