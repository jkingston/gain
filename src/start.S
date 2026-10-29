    .set noreorder
    .set noat
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
    li    $t0, 0x0000fc00
    mtc0  $t0, $12
    ehb
    jal   gain_main
    nop
3:
    b     3b
    nop

    .section .vectors, "ax", @progbits
    .global exception_vector
    .extern exception_panic
exception_vector:
    mfc0  $a0, $13
    mfc0  $a1, $14
    mfc0  $a2, $12
    jal   exception_panic
    nop
4:
    b     4b
    nop
