#include "Vcv32e40p_top.h"
#include "verilated.h"
#include "Vcv32e40p_top___024root.h"
#include <vector>
#include <fstream>
#include <iostream>
#include <cstring>
std::vector<unsigned char> mem(0x1020000,0);
unsigned rd(unsigned a){if(a+4>mem.size()){std::cerr<<"bad read "<<std::hex<<a;exit(2);} unsigned x;memcpy(&x,&mem[a],4);return x;}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv); std::ifstream f(argv[1],std::ios::binary);f.read((char*)mem.data(),mem.size());Vcv32e40p_top t; t.boot_addr_i=0x1000080;t.mtvec_addr_i=0x1000000;t.fetch_enable_i=1;t.pulp_clock_en_i=1;t.scan_cg_en_i=1;t.rst_ni=0;
unsigned ir=0,dr=0;bool iv=0,dv=0;unsigned low=0x200000;
for(unsigned long long c=0;c<30000000;c++){
t.clk_i=0;t.scan_cg_en_i=c<5;t.rst_ni=c>=5;t.instr_gnt_i=1;t.data_gnt_i=1;t.instr_rvalid_i=iv;t.instr_rdata_i=ir;t.data_rvalid_i=dv;t.data_rdata_i=dr;t.eval();
if(c>10 && t.instr_req_o && t.instr_addr_o>=0x1000000 && t.instr_addr_o<0x1000080){std::cerr<<"TRAP mepc="<<std::hex<<t.rootp->cv32e40p_top__DOT__core_i__DOT__cs_registers_i__DOT__mepc_q<<" cause="<<(unsigned)t.rootp->cv32e40p_top__DOT__core_i__DOT__cs_registers_i__DOT__mcause_q<<"\n";return 3;}
bool ni=t.instr_req_o&&t.rst_ni,nd=t.data_req_o&&t.rst_ni;unsigned nr=ni?rd(t.instr_addr_o):0,ndr=0;
if(nd){unsigned a=t.data_addr_o&~3u;if(a==0x20000000&&t.data_we_o){std::cout<<"DONE cycles="<<c<<" min_stack_write=0x"<<std::hex<<low<<std::dec<<"\n";std::ofstream out(argv[2],std::ios::binary);out.write((char*)mem.data(),0x200000);return 0;}
ndr=rd(a);if(t.data_we_o){if(a>=0x1ff000&&a<low)low=a;for(int j=0;j<4;j++)if(t.data_be_o&(1<<j))mem[a+j]=t.data_wdata_o>>(j*8);}}
t.clk_i=1;t.eval();iv=ni;dv=nd;ir=nr;dr=ndr;
if(c%5000000==0)std::cerr<<c<<" pc_fetch="<<std::hex<<t.instr_addr_o<<" id="<<t.rootp->cv32e40p_top__DOT__core_i__DOT__pc_id<<" mepc="<<t.rootp->cv32e40p_top__DOT__core_i__DOT__cs_registers_i__DOT__mepc_q<<" cause="<<(unsigned)t.rootp->cv32e40p_top__DOT__core_i__DOT__cs_registers_i__DOT__mcause_q<<std::dec<<"\n";
}std::cerr<<"TIMEOUT\n";return 1;}
