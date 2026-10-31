    .set noreorder
    .set noat
    .set mips32r2
    .set fp=32

    # Layout is checked by task_context.zig. k0/k1 are reserved by O32.
    .equ context_bytes, 0x110
    .equ fpr_offset, 0x84
    .equ fcsr_offset, 0x104
    .equ status_offset, 0x7c
    .equ epc_offset, 0x80
    .equ ost_counter, 0xb2000020

    .text
    .global gain_x1000_interrupt
    .extern gain_x1000_dispatch
    .extern _irq_stack_top
gain_x1000_interrupt:
    li $k0, ost_counter
    lw $k1, 0($k0)
    la $k0, _irq_stack_top
    addiu $k0, $k0, -context_bytes
    sw $1, 0($k0)
    sw $2, 4($k0)
    sw $3, 8($k0)
    sw $4, 12($k0)
    sw $5, 16($k0)
    sw $6, 20($k0)
    sw $7, 24($k0)
    sw $8, 28($k0)
    sw $9, 32($k0)
    sw $10, 36($k0)
    sw $11, 40($k0)
    sw $12, 44($k0)
    sw $13, 48($k0)
    sw $14, 52($k0)
    sw $15, 56($k0)
    sw $16, 60($k0)
    sw $17, 64($k0)
    sw $18, 68($k0)
    sw $19, 72($k0)
    sw $20, 76($k0)
    sw $21, 80($k0)
    sw $22, 84($k0)
    sw $23, 88($k0)
    sw $24, 92($k0)
    sw $25, 96($k0)
    sw $gp, 100($k0)
    sw $sp, 104($k0)
    sw $fp, 108($k0)
    sw $ra, 112($k0)
    mflo $t0
    sw $t0, 0x74($k0)
    mfhi $t0
    sw $t0, 0x78($k0)
    mfc0 $t0, $12
    sw $t0, status_offset($k0)
    # Permit FPU access even for an exception before task startup. Restore the
    # interrupted CU1 state only after loading the incoming floating registers.
    lui $t1, 0x2000
    or $t1, $t0, $t1
    mtc0 $t1, $12
    ehb
    mfc0 $t0, $14
    sw $t0, epc_offset($k0)
    swc1 $f0, fpr_offset+0($k0)
    swc1 $f1, fpr_offset+4($k0)
    swc1 $f2, fpr_offset+8($k0)
    swc1 $f3, fpr_offset+12($k0)
    swc1 $f4, fpr_offset+16($k0)
    swc1 $f5, fpr_offset+20($k0)
    swc1 $f6, fpr_offset+24($k0)
    swc1 $f7, fpr_offset+28($k0)
    swc1 $f8, fpr_offset+32($k0)
    swc1 $f9, fpr_offset+36($k0)
    swc1 $f10, fpr_offset+40($k0)
    swc1 $f11, fpr_offset+44($k0)
    swc1 $f12, fpr_offset+48($k0)
    swc1 $f13, fpr_offset+52($k0)
    swc1 $f14, fpr_offset+56($k0)
    swc1 $f15, fpr_offset+60($k0)
    swc1 $f16, fpr_offset+64($k0)
    swc1 $f17, fpr_offset+68($k0)
    swc1 $f18, fpr_offset+72($k0)
    swc1 $f19, fpr_offset+76($k0)
    swc1 $f20, fpr_offset+80($k0)
    swc1 $f21, fpr_offset+84($k0)
    swc1 $f22, fpr_offset+88($k0)
    swc1 $f23, fpr_offset+92($k0)
    swc1 $f24, fpr_offset+96($k0)
    swc1 $f25, fpr_offset+100($k0)
    swc1 $f26, fpr_offset+104($k0)
    swc1 $f27, fpr_offset+108($k0)
    swc1 $f28, fpr_offset+112($k0)
    swc1 $f29, fpr_offset+116($k0)
    swc1 $f30, fpr_offset+120($k0)
    swc1 $f31, fpr_offset+124($k0)
    cfc1 $t0, $31
    sw $t0, fcsr_offset($k0)
    ctc1 $zero, $31
    move $sp, $k0
    move $a0, $k0
    move $a1, $k1
    mfc0 $a2, $13
    # O32 callees own a 16-byte argument home area below the saved context.
    addiu $sp, $sp, -16
    jal gain_x1000_dispatch
    nop
    move $k0, $v0
    lwc1 $f0, fpr_offset+0($k0)
    lwc1 $f1, fpr_offset+4($k0)
    lwc1 $f2, fpr_offset+8($k0)
    lwc1 $f3, fpr_offset+12($k0)
    lwc1 $f4, fpr_offset+16($k0)
    lwc1 $f5, fpr_offset+20($k0)
    lwc1 $f6, fpr_offset+24($k0)
    lwc1 $f7, fpr_offset+28($k0)
    lwc1 $f8, fpr_offset+32($k0)
    lwc1 $f9, fpr_offset+36($k0)
    lwc1 $f10, fpr_offset+40($k0)
    lwc1 $f11, fpr_offset+44($k0)
    lwc1 $f12, fpr_offset+48($k0)
    lwc1 $f13, fpr_offset+52($k0)
    lwc1 $f14, fpr_offset+56($k0)
    lwc1 $f15, fpr_offset+60($k0)
    lwc1 $f16, fpr_offset+64($k0)
    lwc1 $f17, fpr_offset+68($k0)
    lwc1 $f18, fpr_offset+72($k0)
    lwc1 $f19, fpr_offset+76($k0)
    lwc1 $f20, fpr_offset+80($k0)
    lwc1 $f21, fpr_offset+84($k0)
    lwc1 $f22, fpr_offset+88($k0)
    lwc1 $f23, fpr_offset+92($k0)
    lwc1 $f24, fpr_offset+96($k0)
    lwc1 $f25, fpr_offset+100($k0)
    lwc1 $f26, fpr_offset+104($k0)
    lwc1 $f27, fpr_offset+108($k0)
    lwc1 $f28, fpr_offset+112($k0)
    lwc1 $f29, fpr_offset+116($k0)
    lwc1 $f30, fpr_offset+120($k0)
    lwc1 $f31, fpr_offset+124($k0)
    lw $t0, fcsr_offset($k0)
    ctc1 $t0, $31
    lw $t0, 0x74($k0)
    mtlo $t0
    lw $t0, 0x78($k0)
    mthi $t0
    lw $t0, status_offset($k0)
    mtc0 $t0, $12
    ehb
    lw $t0, epc_offset($k0)
    mtc0 $t0, $14
    ehb
    lw $1, 0($k0)
    lw $2, 4($k0)
    lw $3, 8($k0)
    lw $4, 12($k0)
    lw $5, 16($k0)
    lw $6, 20($k0)
    lw $7, 24($k0)
    lw $8, 28($k0)
    lw $9, 32($k0)
    lw $10, 36($k0)
    lw $11, 40($k0)
    lw $12, 44($k0)
    lw $13, 48($k0)
    lw $14, 52($k0)
    lw $15, 56($k0)
    lw $16, 60($k0)
    lw $17, 64($k0)
    lw $18, 68($k0)
    lw $19, 72($k0)
    lw $20, 76($k0)
    lw $21, 80($k0)
    lw $22, 84($k0)
    lw $23, 88($k0)
    lw $24, 92($k0)
    lw $25, 96($k0)
    lw $gp, 100($k0)
    lw $fp, 108($k0)
    lw $ra, 112($k0)
    lw $sp, 104($k0)
    eret
    ssnop

    .global gain_task_trap
gain_task_trap:
    syscall
    jr $ra
    nop
