    .set noreorder
    .set noat
    .section .startup, "ax", @progbits
    .global _start
    .extern spl_main
    .extern _gp
_start:
    mtc0  $zero, $18
    mtc0  $zero, $19
    li    $v0, 0x40fc04
    mtc0  $v0, $12
    li    $v0, 0x00800000
    mtc0  $v0, $13
    lui   $v0, 0xb000
    lw    $v1, 0x24($v0)
    ori   $v1, $v1, 0x22
    sw    $v1, 0x24($v0)
    li    $v0, 3
    mtc0  $v0, $16
    nop
    li    $v0, 0x20000000
    mtc0  $v0, $26
    li    $v0, 0x80000000
    ori   $v1, $v0, 0x4000
    mtc0  $zero, $28
    mtc0  $zero, $29
1:
    cache 8, 0($v0)
    cache 9, 0($v0)
    addiu $v0, $v0, 32
    bne   $v0, $v1, 1b
    nop
    mfc0  $v0, $16, 7
    nop
    ori   $v0, $v0, 2
    mtc0  $v0, $16, 7
    nop
    # Zig may address the declarative DDR profiles through the small-data
    # region, so initialize the ABI global pointer before entering Zig code.
    la    $gp, _gp
    j     spl_main
    nop

    .section .handoff, "ax", @progbits
    .global stage2_handoff
stage2_handoff:
    sync
    li    $v0, 0x80004000
    jr    $v0
    nop
