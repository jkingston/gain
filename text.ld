ENTRY(gain_text_api)
/* Independently loaded component; these bytes never expand the boot image. */
MEMORY { TEXT : ORIGIN = 0x81010000, LENGTH = 0x100000
WORK : ORIGIN = 0x80d78000, LENGTH = 0x88000 }
SECTIONS {
    .startup : { KEEP(*(.startup)) } > TEXT
    .text : { *(.text*) } > TEXT
    .rodata : { *(.rodata*) } > TEXT
    .data : { *(.data*) *(.sdata*) *(.got*) } > TEXT
    _gp = ALIGN(16) + 0x7ff0;
    _text_code_end = .;
    .bss (NOLOAD) : { *(.sbss*) *(.bss*) *(COMMON) *(.scommon*) . = ALIGN(16); _text_end = .; } > WORK
    /DISCARD/ : { *(.MIPS.abiflags) *(.reginfo*) *(.note.*) *(.eh_frame*) *(.rel.dyn) }
}
ASSERT(_text_code_end <= ORIGIN(TEXT) + LENGTH(TEXT), "text engine code exceeds RAM reservation")
ASSERT(_text_end <= ORIGIN(WORK) + LENGTH(WORK), "text engine workspace exceeds RAM reservation")
