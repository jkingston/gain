ENTRY(_start)
/* RAM ownership is documented and checked in src/f20_memory.zig. */
MEMORY { DRAM : ORIGIN = 0x80004000, LENGTH = 0x1fc000
USB_DMA : ORIGIN = 0x00240000, LENGTH = 0x20000 }
SECTIONS {
    .usb_dma (NOLOAD) : { *(.usb_dma) } > USB_DMA
    .startup : { KEEP(*(.startup)) } > DRAM
    .vectors 0x80004180 : { KEEP(*(.vectors)) } > DRAM
    .text : { *(.text*) } > DRAM
    .rodata : { *(.rodata*) } > DRAM
    .data : {
        _data_start = .;
        *(.data*) *(.sdata*) *(.got*)
        _data_end = .;
    } > DRAM
    _gp = ALIGN(16) + 0x7ff0;
    .bss (NOLOAD) : {
        _bss_start = .;
        *(.sbss*) *(.bss*) *(COMMON) *(.scommon*)
        . = ALIGN(4);
        _bss_end = .;
    } > DRAM
    /DISCARD/ : { *(.MIPS.abiflags) *(.reginfo*) *(.note.*) *(.eh_frame*) *(.rel.dyn) }
}
ASSERT(SIZEOF(.startup) <= 0x180, "startup overlaps exception vector")
ASSERT(_bss_end <= 0x80200000, "stage two overlaps LCD descriptors")

_irq_stack_top = 0x81fde000;

ASSERT(SIZEOF(.usb_dma) <= LENGTH(USB_DMA), "USB buffers exceed their uncached identity window")
