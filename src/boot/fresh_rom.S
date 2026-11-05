    .set noreorder
    .set noat
    .set mips32r2
    .section .text, "ax", @progbits
    .global rom_fresh_enter
rom_fresh_enter:
    di
    ehb
    la $t0, rom_usb_blob
    la $t1, rom_usb_blob_end
    li $t2, 0xf4003f00
6:
    lw $t3, 0($t0)
    sw $t3, 0($t2)
    addiu $t0, $t0, 4
    addiu $t2, $t2, 4
    bne $t0, $t1, 6b
    nop
    sync
    li $t0, 0xf4003f00
    jr $t0
    nop
    .section .rodata, "a", @progbits
    .balign 4
rom_usb_blob:
    .word 0x41606000
    .word 0xc0
    .word 0x3c1df400
    .word 0x37bd1000
    .word 0x241c0000
    .word 0x3c080040
    .word 0x40886000
    .word 0xc0
    .word 0x3c08f400
    .word 0x350801e4
    .word 0xad000000
    .word 0x3c1df400
    .word 0x37bd1000
    .word 0x3c19bfc0
    .word 0x37392808
    .word 0x320f809
    .word 0x0
    .word 0x1000fff9
    .word 0x0
rom_usb_blob_end:
