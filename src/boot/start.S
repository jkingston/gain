    .set noreorder
    .set noat
    .set mips32r2
    .set fp=32
    .section .startup, "ax", @progbits
    .global _start
_start:
    li $k1, 0
    b entry_common
    nop
    .global ram_start
ram_start:
    li $k1, 1
    b entry_common
    nop
    .global standalone_probe
standalone_probe:
    li $k1, 2
entry_common:
    di
    ehb
    # The vendor SPL or bootm places the raw image at 0x80100000.
    # Evacuate it before loading the full player over low RAM.
    li $t0, 0x80100000
    li $t1, 0xa1e00000
    la $t2, _image_end
    li $t3, 0x81e00000
    subu $t2, $t2, $t3
    addu $t2, $t2, $t1
1:  lw $t3, 0($t0)
    sw $t3, 0($t1)
    addiu $t0, $t0, 4
    addiu $t1, $t1, 4
    bne $t1, $t2, 1b
    nop
    sync
    li $t0, 0x81e00000
    la $t1, _image_end
2:  cache 0x11, 0($t0)
    cache 0x10, 0($t0)
    addiu $t0, $t0, 32
    sltu $t2, $t0, $t1
    bne $t2, $zero, 2b
    nop
    sync
    la $t0, relocated_start
    jr $t0
    nop
    .text
relocated_start:
    li $sp, 0x81e1f000
    la $gp, _gp
    la $t0, _bss_start
    la $t1, _bss_end
3:  beq $t0, $t1, 4f
    nop
    sw $zero, 0($t0)
    addiu $t0, $t0, 4
    b 3b
    nop
4:  # Runtime vectors occupy a separate page; a TLB refill must never
    # execute the relocation trampoline at the image's initial entry.
    li $t0, 0xa1e18000
    la $t1, gain_x1000_interrupt
    srl $t1, $t1, 2
    li $t2, 0x03ffffff
    and $t1, $t1, $t2
    lui $t2, 0x0800
    or $t1, $t1, $t2
    sw $t1, 0x000($t0)
    sw $zero, 0x004($t0)
    sw $t1, 0x080($t0)
    sw $zero, 0x084($t0)
    sw $t1, 0x100($t0)
    sw $zero, 0x104($t0)
    sw $t1, 0x180($t0)
    sw $zero, 0x184($t0)
    sync
    li $t0, 0x81e18000
    cache 0x10, 0x000($t0)
    cache 0x10, 0x080($t0)
    cache 0x10, 0x100($t0)
    cache 0x10, 0x180($t0)
    sync
    mtc0 $t0, $15, 1
    mtc0 $zero, $13
    li $t0, 0x20000000
    mtc0 $t0, $12
    ehb
    ctc1 $zero, $31
    jal loader_main
    move $a0, $k1
    break
    nop
    .section .vectors, "ax", @progbits
    j gain_x1000_interrupt
    nop
    .text
    .global payload_enter
payload_enter:
    sync
    li $t0, 0x80004000
    li $t1, 0x80200000
5:  cache 0x15, 0($t0)
    cache 0x10, 0($t0)
    addiu $t0, $t0, 32
    bne $t0, $t1, 5b
    nop
    sync
    li $t9, 0x80004000
    jr $t9
    nop
    .global executing_pc
executing_pc:
    move $v0, $ra
    jr $ra
    nop
