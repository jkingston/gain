ENTRY(_start)
MEMORY { DRAM : ORIGIN = 0x80004000, LENGTH = 0x100000 }
SECTIONS {
    .startup : { KEEP(*(.startup)) } > DRAM
    .text : { *(.text*) } > DRAM
    .rodata : { *(.rodata*) } > DRAM
    .data : {
        _data_start = .;
        *(.data*) *(.sdata*)
        _data_end = .;
    } > DRAM
    _gp = ALIGN(16) + 0x7ff0;
    .bss (NOLOAD) : {
        _bss_start = .;
        *(.sbss*) *(.bss*) *(COMMON) *(.scommon*)
        . = ALIGN(4);
        _bss_end = .;
    } > DRAM
    /DISCARD/ : { *(.MIPS.abiflags) *(.reginfo*) *(.note.*) *(.eh_frame) *(.rel.dyn) }
}
