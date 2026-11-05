    .set noreorder
    .set noat
    .set mips32r2
    .set fp=32
    .equ context, 0xa02e4000
    .section .startup, "ax", @progbits
    .global _start
_start:
    li $k0, context
    sw $sp, 0($k0)
    sw $ra, 4($k0)
    sw $gp, 8($k0)
    sw $s0, 12($k0)
    sw $s1, 16($k0)
    sw $s2, 20($k0)
    sw $s3, 24($k0)
    sw $s4, 28($k0)
    sw $s5, 32($k0)
    sw $s6, 36($k0)
    sw $s7, 40($k0)
    sw $fp, 44($k0)
    mfc0 $t0, $12
    sw $t0, 48($k0)
    mfc0 $t0, $15, 1
    sw $t0, 52($k0)
    mfc0 $t0, $13
    sw $t0, 56($k0)
    sw $zero, 60($k0)
    li $sp, 0x81fff000
    la $gp, _gp
    la $t0, _bss_start
    la $t1, _bss_end
1:  beq $t0, $t1, 2f
    nop
    sw $zero, 0($t0)
    addiu $t0, $t0, 4
    b 1b
    nop
2:  mtc0 $zero, $12
    li $t0, 0x80004000
    mtc0 $t0, $15, 1
    ehb
    jal save_fpu
    nop
    jal player_check_main
    nop
    j rom_return
    nop
    .section .vectors, "ax", @progbits
    j gain_x1000_interrupt
    nop
    .text
codec_exception:
    mfc0 $a0, $13
    mfc0 $a1, $14
    li $sp, 0x81fff000
    la $gp, _gp
    jal player_check_fault
    nop
    j rom_return
    nop
save_fpu:
    mfc0 $t0, $16, 1
    andi $t0, $t0, 1
    beq $t0, $zero, 4f
    nop
    li $k0, context
    lw $t0, 48($k0)
    li $t1, 0x04000000
    and $t0, $t0, $t1
    bne $t0, $zero, 4f
    nop
    li $t0, 0x20000000
    mtc0 $t0, $12
    ehb
    swc1 $f0, 256($k0)
    swc1 $f1, 260($k0)
    swc1 $f2, 264($k0)
    swc1 $f3, 268($k0)
    swc1 $f4, 272($k0)
    swc1 $f5, 276($k0)
    swc1 $f6, 280($k0)
    swc1 $f7, 284($k0)
    swc1 $f8, 288($k0)
    swc1 $f9, 292($k0)
    swc1 $f10, 296($k0)
    swc1 $f11, 300($k0)
    swc1 $f12, 304($k0)
    swc1 $f13, 308($k0)
    swc1 $f14, 312($k0)
    swc1 $f15, 316($k0)
    swc1 $f16, 320($k0)
    swc1 $f17, 324($k0)
    swc1 $f18, 328($k0)
    swc1 $f19, 332($k0)
    swc1 $f20, 336($k0)
    swc1 $f21, 340($k0)
    swc1 $f22, 344($k0)
    swc1 $f23, 348($k0)
    swc1 $f24, 352($k0)
    swc1 $f25, 356($k0)
    swc1 $f26, 360($k0)
    swc1 $f27, 364($k0)
    swc1 $f28, 368($k0)
    swc1 $f29, 372($k0)
    swc1 $f30, 376($k0)
    swc1 $f31, 380($k0)
    cfc1 $t0, $31
    sw $t0, 384($k0)
    ctc1 $zero, $31
    li $t0, 1
    sw $t0, 60($k0)
4:  jr $ra
    nop
    .global rom_return
rom_return:
    di
    ehb
    li $k0, context
    lw $t0, 60($k0)
    beq $t0, $zero, 5f
    nop
    li $t0, 0x20000000
    mtc0 $t0, $12
    ehb
    lwc1 $f0, 256($k0)
    lwc1 $f1, 260($k0)
    lwc1 $f2, 264($k0)
    lwc1 $f3, 268($k0)
    lwc1 $f4, 272($k0)
    lwc1 $f5, 276($k0)
    lwc1 $f6, 280($k0)
    lwc1 $f7, 284($k0)
    lwc1 $f8, 288($k0)
    lwc1 $f9, 292($k0)
    lwc1 $f10, 296($k0)
    lwc1 $f11, 300($k0)
    lwc1 $f12, 304($k0)
    lwc1 $f13, 308($k0)
    lwc1 $f14, 312($k0)
    lwc1 $f15, 316($k0)
    lwc1 $f16, 320($k0)
    lwc1 $f17, 324($k0)
    lwc1 $f18, 328($k0)
    lwc1 $f19, 332($k0)
    lwc1 $f20, 336($k0)
    lwc1 $f21, 340($k0)
    lwc1 $f22, 344($k0)
    lwc1 $f23, 348($k0)
    lwc1 $f24, 352($k0)
    lwc1 $f25, 356($k0)
    lwc1 $f26, 360($k0)
    lwc1 $f27, 364($k0)
    lwc1 $f28, 368($k0)
    lwc1 $f29, 372($k0)
    lwc1 $f30, 376($k0)
    lwc1 $f31, 380($k0)
    lw $t0, 384($k0)
    ctc1 $t0, $31
5:  lw $t0, 52($k0)
    mtc0 $t0, $15, 1
    lw $t0, 56($k0)
    mtc0 $t0, $13
    lw $t0, 48($k0)
    mtc0 $t0, $12
    ehb
    lw $sp, 0($k0)
    lw $ra, 4($k0)
    lw $gp, 8($k0)
    lw $s0, 12($k0)
    lw $s1, 16($k0)
    lw $s2, 20($k0)
    lw $s3, 24($k0)
    lw $s4, 28($k0)
    lw $s5, 32($k0)
    lw $s6, 36($k0)
    lw $s7, 40($k0)
    lw $fp, 44($k0)
    jr $ra
    nop
