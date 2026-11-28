// Lab 1: the smallest program. Writes two words to the output channel (0x2000_0010) and then DONE (0x2000_0000).
// Read prog.dis (the startup code start.S is linked in front of it) and find: where _start is, where boot() is, where the stack pointer is set.
#define OUT ((volatile unsigned*)0x20000010)
void boot(void) {
    *OUT = 0x12345678u;
    *OUT = 0xCAFEF00Du;
    *(volatile unsigned*)0x20000000 = 1;   // DONE
    for (;;) ;
}
