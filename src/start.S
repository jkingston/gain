    .set noreorder
    .set noat
    .set mips32r2
    .set fp=32
    .section .startup, "ax", @progbits
    .global _start
    .extern gain_main
    .extern _bss_start
    .extern _bss_end
    .extern _gp
_start:
    li    $sp, 0x81fff000
    la    $gp, _gp

    la    $t0, _bss_start
    la    $t1, _bss_end
1:
    beq   $t0, $t1, 2f
    nop
    sw    $zero, 0($t0)
    addiu $t0, $t0, 4
    b     1b
    nop
2:
    li    $t0, 0x80004000
    mtc0  $t0, $15, 1
    li    $t0, 0x2000fc00
    mtc0  $t0, $12
    ehb
    ctc1  $zero, $31
    jal   gain_main
    nop
3:
    b     3b
    nop

    .section .vectors, "ax", @progbits
    .global exception_vector
    .extern exception_panic
exception_vector:
    j     gain_x1000_interrupt
    nop
4:
    b     4b
    nop
