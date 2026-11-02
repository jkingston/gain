    .set noreorder
    .set noat
    .section .startup, "ax", @progbits
    .global _start
    .extern benchmark_main
    .extern _gp
    .extern _bss_start
    .extern _bss_end
    # Keep saved ROM state in the dedicated reservation below all stacks.
    .equ saved_context, 0xa0204000
    .equ benchmark_stack, 0x81fff000
_start:
    li    $k0, saved_context
    sw    $sp,  0($k0)
    sw    $ra,  4($k0)
    sw    $gp,  8($k0)
    sw    $s0, 12($k0)
    sw    $s1, 16($k0)
    sw    $s2, 20($k0)
    sw    $s3, 24($k0)
    sw    $s4, 28($k0)
    sw    $s5, 32($k0)
    sw    $s6, 36($k0)
    sw    $s7, 40($k0)
    sw    $fp, 44($k0)

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
    li    $sp, benchmark_stack
    jal   benchmark_main
    nop

    li    $k0, saved_context
    lw    $sp,  0($k0)
    lw    $ra,  4($k0)
    lw    $gp,  8($k0)
    lw    $s0, 12($k0)
    lw    $s1, 16($k0)
    lw    $s2, 20($k0)
    lw    $s3, 24($k0)
    lw    $s4, 28($k0)
    lw    $s5, 32($k0)
    lw    $s6, 36($k0)
    lw    $s7, 40($k0)
    lw    $fp, 44($k0)
    jr    $ra
    nop
