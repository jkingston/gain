ENTRY(_start)
MEMORY { TCSM : ORIGIN = 0xf4001800, LENGTH = 0x2800 }
SECTIONS {
    .startup : { KEEP(*(.startup)) } > TCSM
    .handoff 0xf4001a00 : { KEEP(*(.handoff)) } > TCSM
    .text : { *(.text*) } > TCSM
    .rodata : { *(.rodata*) } > TCSM
    .data : { *(.data*) *(.sdata*) } > TCSM
    .bss (NOLOAD) : { *(.sbss*) *(.bss*) *(COMMON) *(.scommon*) } > TCSM
    /DISCARD/ : { *(.MIPS.abiflags) *(.reginfo*) *(.note.*) *(.eh_frame) *(.rel.dyn) }
}
ASSERT(SIZEOF(.startup) <= 0x200, "SPL startup overlaps handoff entry")
