ENTRY(_start)
MEMORY { RAM : ORIGIN = 0x81e00000, LENGTH = 0x18000 }
SECTIONS {
 .startup : { KEEP(*(.startup)) } > RAM
 .vectors 0x81e00180 : { KEEP(*(.vectors)) } > RAM
 .text : { *(.text*) } > RAM
 .rodata : { *(.rodata*) } > RAM
 .data : { *(.data*) *(.sdata*) *(.got*) . = ALIGN(32); _image_end = .; } > RAM
 _gp = ALIGN(16) + 0x7ff0;
 .bss (NOLOAD) : { _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) *(.scommon*) . = ALIGN(4); _bss_end = .; } > RAM
 /DISCARD/ : { *(.MIPS.abiflags) *(.reginfo*) *(.note.*) *(.eh_frame*) *(.rel.dyn) }
}
ASSERT(SIZEOF(.startup) <= 0x180, "relocation trampoline overlaps vectors")
ASSERT(_image_end - _start <= 0x18000, "loader exceeds first erase block budget")
ASSERT(_bss_end < 0x81e18000, "relocated loader exceeds reservation")
