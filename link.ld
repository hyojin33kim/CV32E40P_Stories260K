ENTRY(_start)
MEMORY { INST (rx) : ORIGIN = 0x01000080, LENGTH = 16K-128
 CTRL (rw) : ORIGIN = 0x001b4000, LENGTH = 304K }
SECTIONS {
 .text : { *(.text.start) *(.text*) } > INST
 .rodata : { *(.rodata*) *(.srodata*) } > CTRL
 .data : { *(.data*) *(.sdata*) } > CTRL
 .bss (NOLOAD) : { . = ALIGN(4); __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > CTRL
 __stack_top = ORIGIN(CTRL)+LENGTH(CTRL);
 ASSERT(__bss_end <= __stack_top-4096, "control SRAM overflow")
}
