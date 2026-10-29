fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}
fn rd(address: usize) u32 {
    return reg(address).*;
}
fn wr(address: usize, value: u32) void {
    reg(address).* = value;
}

const CPM_CLKGR = 0xb0000020;
const CPM_MPCR = 0xb0000014;
const CPM_DDRCDR = 0xb000002c;
const CPM_PSWC0ST = 0xb0000090;
const CPM_PSWC1ST = 0xb0000094;
const CPM_PSWC2ST = 0xb0000098;
const CPM_PSWC3ST = 0xb000009c;
const CPM_DRCG = 0xb00000d0;
const CPM_CSR = 0xb00000d4;
const OST_CTRL = 0xb2000000;
const OST_CLEAR = 0xb2000008;
const OST_2CNTH = 0xb200001c;
const OST_2CNTL = 0xb2000020;
const OST_ENABLE_SET = 0xb2000034;
const DDRPHY = 0xb3011000;
const DDRC_APB_CLKSTP_CFG = 0xb3012068;
const DDRC_APB_PHYRST_CFG = 0xb3012080;
const DDRC = 0xb34f0000;

fn delay3ms() void {
    const start = rd(OST_2CNTL);
    while (rd(OST_2CNTL) -% start < 18_000) asm volatile ("nop");
}

fn initTimer() void {
    wr(CPM_CLKGR, rd(CPM_CLKGR) & ~@as(u32, 1 << 20));
    wr(OST_CTRL, (rd(OST_CTRL) & ~@as(u32, 3 << 2)) | (1 << 2));
    wr(OST_CLEAR, 1 << 1);
    wr(OST_2CNTH, 0);
    wr(OST_2CNTL, 0);
    wr(OST_ENABLE_SET, 1 << 1);
}

fn initClock() void {
    wr(CPM_MPCR, rd(CPM_MPCR) & ~@as(u32, 1 << 7));
    while ((rd(CPM_MPCR) & 1) != 0) asm volatile ("nop");
    wr(CPM_MPCR, (@as(u32, 1) << 31) | (@as(u32, 24) << 24) | (@as(u32, 1) << 7));
    while ((rd(CPM_MPCR) & 1) == 0) asm volatile ("nop");
    wr(CPM_DDRCDR, (rd(CPM_DDRCDR) & ~@as(u32, 0xc000000f)) |
        (@as(u32, 2) << 30) | (@as(u32, 1) << 29) | 2);
    while ((rd(CPM_CSR) & (@as(u32, 1) << 27)) == 0) asm volatile ("nop");
    while ((rd(CPM_DDRCDR) & (@as(u32, 1) << 28)) != 0) asm volatile ("nop");
    wr(CPM_DDRCDR, rd(CPM_DDRCDR) & ~@as(u32, 1 << 29));
}

fn waitPgsr(a: u32, b: u32, count: u32) bool {
    var left = count;
    while (left != 0) : (left -= 1) {
        const value = rd(DDRPHY + 0x0c);
        if (value == a or value == b) return true;
    }
    return false;
}

fn initDram() u32 {
    wr(CPM_CLKGR, rd(CPM_CLKGR) & ~@as(u32, 1 << 31));
    wr(CPM_DRCG, 0x73);
    delay3ms();
    wr(CPM_DRCG, 0x71);
    delay3ms();
    wr(DDRC_APB_PHYRST_CFG, 0x1a00001);
    delay3ms();
    wr(DDRC_APB_PHYRST_CFG, 0);
    delay3ms();
    wr(DDRC + 0x08, 0xf00000);
    delay3ms();
    wr(DDRC + 0x08, 0);
    delay3ms();

    wr(DDRC + 0x04, 0x0a46896c);
    wr(DDRC + 0x08, 2);
    wr(DDRPHY + 0x54, 0x150000);
    wr(DDRPHY + 0x30, 0);
    wr(DDRPHY + 0x40, 0x42);
    wr(DDRPHY + 0x48, 0x98);
    wr(DDRPHY + 0x18, 0x21000a);
    wr(DDRPHY + 0x1c, 0xa09c40);
    wr(DDRPHY + 0x20, 0x280014);
    wr(DDRPHY + 0x34, 0x1a69444a);
    wr(DDRPHY + 0x38, 0x180090);
    wr(DDRPHY + 0x3c, 0x1ff99428);
    wr(DDRPHY + 0x1c0, 0x90881);
    wr(DDRPHY + 0x200, 0x90881);
    wr(DDRPHY + 0x240, 0x90e80);
    wr(DDRPHY + 0x280, 0x90e80);
    wr(DDRPHY + 0x08, 0x1042e03);
    wr(DDRPHY + 0x24, 0x30c00813);
    wr(DDRPHY + 0x28, 0x4912);
    if (!waitPgsr(7, 0x1f, 10_000)) return 1;

    wr(DDRPHY + 0x14, 0x80000000);
    wr(DDRPHY + 0x2c, rd(DDRPHY + 0x2c) & ~@as(u32, 0x10));
    wr(DDRPHY + 0x10, rd(DDRPHY + 0x10) | 0x800000);
    wr(DDRPHY + 0x04, 0x20020041);
    if (!waitPgsr(0x0f, 0x1f, 10_000)) return 2;

    wr(DDRC_APB_PHYRST_CFG, 0x400000);
    delay3ms();
    wr(DDRC_APB_PHYRST_CFG, 0);
    delay3ms();
    wr(DDRC + 0x04, 0x0a4689ec);
    wr(DDRC + 0x08, 2);
    wr(DDRPHY + 0x04, 0x20020081);

    var left: u32 = 500_000;
    while (left != 0) : (left -= 1) {
        const value = rd(DDRPHY + 0x0c);
        if (value == 0x1f or (value & 0x70) != 0) break;
    }
    if (left == 0) return 3;
    const pgsr = rd(DDRPHY + 0x0c);
    if ((pgsr & 0x60) != 0 and pgsr != 0) return 4;

    wr(DDRC + 0x08, 0);
    wr(DDRC + 0x08, 10);
    wr(DDRC + 0x08, 0);
    wr(DDRC + 0x04, 0x0a46896c);
    wr(DDRC + 0x60, 0x02050501);
    wr(DDRC + 0x64, 0x04090404);
    wr(DDRC + 0x68, 0x2704030d);
    wr(DDRC + 0x6c, 0x0b7a0251);
    wr(DDRC + 0x70, 0xff090200);
    wr(DDRC + 0x74, 0x0a0a0202);
    wr(DDRC + 0x24, 0x20fe);
    wr(DDRC + 0x28, 0x2200);
    wr(DDRC + 0x08, 10);
    wr(DDRC + 0x18, 0x2f0003);
    wr(DDRC + 0x08, 0xc91e);
    wr(DDRC + 0x9c, 0x03020b0a);
    wr(DDRC + 0xa0, 0x07060504);
    wr(DDRC + 0xa4, 0x01000908);
    wr(DDRC + 0xa8, 0x0f0e0d0c);
    wr(DDRC + 0xac, 0x13121110);
    wr(DDRC + 0x00, rd(DDRC + 0x00) & ~@as(u32, 0x40));
    wr(CPM_DDRCDR, rd(CPM_DDRCDR) | (@as(u32, 1) << 26));
    wr(DDRC_APB_CLKSTP_CFG, 0x9000000f);
    wr(DDRC + 0x304, 1);

    const cell = reg(0xa0010000);
    const saved = cell.*;
    cell.* = 0x55aa33cc;
    if (cell.* != 0x55aa33cc) return 5;
    cell.* = 0xaa55cc33;
    if (cell.* != 0xaa55cc33) return 6;
    cell.* = saved;
    return 0;
}

export fn spl_main() callconv(.c) void {
    wr(CPM_PSWC0ST, 0x00);
    wr(CPM_PSWC1ST, 0x10);
    wr(CPM_PSWC2ST, 0x18);
    wr(CPM_PSWC3ST, 0x08);
    initClock();
    initTimer();
    if (initDram() != 0) while (true) asm volatile ("nop");
}
