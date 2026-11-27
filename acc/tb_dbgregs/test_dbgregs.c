// Board-top observation registers (acc/chip_axi_top.sv 0x200_0040 ..): output channel, last fetch address, fetch counter, trap counter.
// Scenario in the control word at 0x1afff0: 0 = three output writes, then DONE; 1 = three output writes, then an illegal instruction (trap, never DONE).
#define OUT ((volatile unsigned*)0x20000010)
void boot(void) {
    unsigned sc = *(volatile unsigned*)0x1afff0;
    *OUT = 0x11111111u;
    *OUT = 0x22222222u;
    *OUT = 0xABCD0003u;
    if (sc == 1) {
        __asm__ volatile(".word 0xffffffff");   // illegal instruction: the core takes the exception and fetches the trap vector 0x0100_0000
        for (;;) ;
    }
    *(volatile unsigned*)0x20000000 = 1;
    for (;;) ;
}
