//! Exclusive filesystem ownership for an automatically connected USB disk.
//! A bus reset or suspend never gives the card back to the player.
const std = @import("std");

pub const sector_bytes = 512;

/// CPU-visible memory also accessible to this device's DMA engine. Buffers
/// outside this reservation retain the ordinary bounce-buffer path.
pub const SharedMemory = struct {
    start: usize,
    bytes: usize,

    pub fn contains(self: SharedMemory, address: usize, bytes: usize) bool {
        return self.bytes <= std.math.maxInt(usize) - self.start and address >= self.start and address - self.start <= self.bytes and
            bytes <= self.bytes - (address - self.start);
    }

    fn accepts(self: SharedMemory, address: usize, offset: u32, bytes: usize) bool {
        return offset == 0 and bytes != 0 and bytes % sector_bytes == 0 and
            address & 3 == 0 and self.contains(address, bytes);
    }
};

pub const State = enum { player, quiescing, host, ejecting, ejected, remounting };

pub const Session = struct {
    state: State = .player,
    connected: bool = false,
    configured: bool = false,
    prevent_removal: bool = false,
    generation: u32 = 0,

    pub fn connectedToHost(self: *Session) void {
        self.connected = true;
        self.configured = true;
        if (self.state == .player) self.state = .quiescing;
    }

    pub fn busReset(self: *Session) void {
        self.configured = false;
        self.prevent_removal = false;
    }

    /// Call only after playback, decoder, storage and display have relinquished
    /// the card. The caller must discard every old filesystem reader/cache.
    pub fn grantHost(self: *Session) !void {
        if (self.state != .quiescing or !self.configured or !self.connected) return error.Busy;
        self.state = .host;
    }

    pub fn requestEject(self: *Session) !void {
        if (self.state != .host or self.prevent_removal) return error.Busy;
        self.state = .ejecting;
    }

    /// Invoked after the successful SCSI status wrapper has reached the host.
    pub fn ejectAcknowledged(self: *Session) void {
        if (self.state != .ejecting) return;
        self.state = .remounting;
        self.generation +%= 1;
    }

    pub fn unplug(self: *Session) void {
        self.connected = false;
        self.configured = false;
        self.prevent_removal = false;
        if (self.state == .host or self.state == .ejecting) {
            self.state = .remounting;
            self.generation +%= 1;
        } else if (self.state == .ejected or self.state == .quiescing) self.state = .player;
    }

    pub fn remounted(self: *Session) !void {
        if (self.state != .remounting) return error.Busy;
        self.state = if (self.connected) .ejected else .player;
    }

    pub fn reconnect(self: *Session) !void {
        if (self.state != .ejected or !self.connected) return error.Busy;
        self.state = .quiescing;
        self.configured = false;
    }

    pub fn playerAllowed(self: Session) bool {
        return self.state == .player or self.state == .ejected;
    }
};

/// A synchronous sector device; successful writes/sync promise card completion,
/// not merely that a DMA descriptor has consumed the source bytes.
pub const Device = struct {
    context: *anyopaque,
    capacity: *const fn (*anyopaque) u64,
    present: *const fn (*anyopaque) bool,
    read: *const fn (*anyopaque, u32, []u8) anyerror!void,
    write: *const fn (*anyopaque, u32, []const u8) anyerror!void,
    sync: *const fn (*anyopaque) anyerror!void,
    shared: ?SharedMemory = null,
};

pub const Store = struct {
    session: Session = .{},
    device: Device,
    bounce: []u8,
    failed: bool = false,
    reads: u64 = 0,
    writes: u64 = 0,
    direct_reads: u64 = 0,
    direct_writes: u64 = 0,

    pub fn init(device: Device, bounce: []u8) !Store {
        if (bounce.len < sector_bytes or bounce.len % sector_bytes != 0 or @intFromPtr(bounce.ptr) & 3 != 0) return error.InvalidBuffer;
        return .{ .device = device, .bounce = bounce };
    }

    pub fn capacity(self: *const Store) u32 {
        return @intCast(@min(self.device.capacity(self.device.context), std.math.maxInt(u32)));
    }

    pub fn ready(self: *const Store) bool {
        return self.session.state == .host and !self.failed and self.device.present(self.device.context) and self.capacity() != 0;
    }

    fn checkedAddress(self: *const Store, lba: u32, offset: u32, length: usize) !u64 {
        if (!self.ready()) return error.NotReady;
        const address = @as(u64, lba) * sector_bytes + offset;
        const limit = @as(u64, self.capacity()) * sector_bytes;
        if (offset >= sector_bytes or address > limit or length > limit - address) return error.OutOfRange;
        return address;
    }

    pub fn read(self: *Store, lba: u32, offset: u32, output: []u8) !void {
        var address = try self.checkedAddress(lba, offset, output.len);
        if (self.device.shared) |shared| if (shared.accepts(@intFromPtr(output.ptr), offset, output.len)) {
            self.device.read(self.device.context, lba, output) catch |err| {
                self.failed = true;
                return err;
            };
            self.reads += output.len;
            self.direct_reads += output.len;
            return;
        };

        var written: usize = 0;
        while (written < output.len) {
            const within: usize = @intCast(address % sector_bytes);
            const remaining = output.len - written;
            const blocks = if (within == 0 and remaining >= sector_bytes) @min(remaining / sector_bytes, self.bounce.len / sector_bytes) else 1;
            const bytes = blocks * sector_bytes;
            self.device.read(self.device.context, @intCast(address / sector_bytes), self.bounce[0..bytes]) catch |err| {
                self.failed = true;
                return err;
            };

            const count = @min(remaining, bytes - within);
            @memcpy(output[written..][0..count], self.bounce[within..][0..count]);
            written += count;
            address += count;
        }
        self.reads += output.len;
    }

    pub fn write(self: *Store, lba: u32, offset: u32, input: []const u8) !void {
        var address = try self.checkedAddress(lba, offset, input.len);
        if (self.device.shared) |shared| if (shared.accepts(@intFromPtr(input.ptr), offset, input.len)) {
            self.device.write(self.device.context, lba, input) catch |err| {
                self.failed = true;
                return err;
            };
            self.writes += input.len;
            self.direct_writes += input.len;
            return;
        };

        var consumed: usize = 0;
        while (consumed < input.len) {
            const within: usize = @intCast(address % sector_bytes);
            const remaining = input.len - consumed;
            const blocks = if (within == 0 and remaining >= sector_bytes) @min(remaining / sector_bytes, self.bounce.len / sector_bytes) else 1;
            const bytes = blocks * sector_bytes;
            const count = @min(remaining, bytes - within);
            if (within != 0 or count != bytes) self.device.read(self.device.context, @intCast(address / sector_bytes), self.bounce[0..bytes]) catch |err| {
                self.failed = true;
                return err;
            };
            @memcpy(self.bounce[within..][0..count], input[consumed..][0..count]);
            self.device.write(self.device.context, @intCast(address / sector_bytes), self.bounce[0..bytes]) catch |err| {
                self.failed = true;
                return err;
            };
            consumed += count;
            address += count;
        }
        self.writes += input.len;
    }

    pub fn sync(self: *Store) !void {
        if (!self.ready()) return error.NotReady;
        self.device.sync(self.device.context) catch |err| {
            self.failed = true;
            return err;
        };
    }

    pub fn eject(self: *Store) !void {
        if (self.session.prevent_removal) return error.Busy;
        try self.sync();
        try self.session.requestEject();
    }
};

test "eject waits for card completion and host acknowledgement; reset cannot remount it" {
    var session: Session = .{};
    session.connectedToHost();
    try std.testing.expect(!session.playerAllowed());
    session.busReset();
    try std.testing.expectError(error.Busy, session.grantHost());
    session.connectedToHost();
    try session.grantHost();
    session.prevent_removal = true;
    try std.testing.expectError(error.Busy, session.requestEject());
    session.prevent_removal = false;
    try session.requestEject();
    try std.testing.expect(!session.playerAllowed());
    session.ejectAcknowledged();
    try session.remounted();
    for (0..1024) |_| {
        session.busReset();
        session.connectedToHost();
        try std.testing.expectEqual(State.ejected, session.state);
    }
    try session.reconnect();
    session.connectedToHost();
    try session.grantHost();
    session.unplug();
    try std.testing.expectEqual(State.remounting, session.state);
    try session.remounted();
    try std.testing.expectEqual(State.player, session.state);
}

test "deterministic event permutations preserve ownership, generation and I/O exclusion" {
    for (0..128) |seed| {
        var random = std.Random.DefaultPrng.init(seed);
        var device: TestDevice = .{};
        var bounce: [512]u8 align(4) = undefined;
        var store = try Store.init(device.device(), &bounce);
        var bytes: [512]u8 = undefined;
        const session = &store.session;
        for (0..1024) |_| {
            const before = session.*;
            const event = random.random().uintLessThan(u8, 8);
            switch (event) {
                0 => session.connectedToHost(),
                1 => session.busReset(),
                2 => session.grantHost() catch {},
                3 => session.requestEject() catch {},
                4 => session.ejectAcknowledged(),
                5 => session.unplug(),
                6 => session.remounted() catch {},
                else => session.reconnect() catch {},
            }
            const released = (event == 4 and before.state == .ejecting) or
                (event == 5 and (before.state == .host or before.state == .ejecting));
            try std.testing.expectEqual(before.generation +% @as(u32, @intFromBool(released)), session.generation);
            if (event == 1) try std.testing.expectEqual(before.state, session.state);
            if (before.state == .ejected and event == 0) try std.testing.expectEqual(State.ejected, session.state);
            const operations = device.operations;
            if (session.state == .host) {
                try store.read(0, 0, &bytes);
                try std.testing.expectEqual(operations + 1, device.operations);
            } else {
                try std.testing.expectError(error.NotReady, store.read(0, 0, &bytes));
                try std.testing.expectError(error.NotReady, store.write(0, 0, &bytes));
                try std.testing.expectEqual(operations, device.operations);
            }
        }
    }
}

/// Bounded block-device double. Faults occur at the same synchronous boundary
/// as the native controller, including failure after a partial write.
pub const TestDevice = struct {
    bytes: [16 * sector_bytes]u8 = @splat(0),
    inserted: bool = true,
    fail_read: bool = false,
    fail_write: bool = false,
    fail_sync: bool = false,
    operations: usize = 0,
    syncs: usize = 0,
    last_buffer: usize = 0,

    fn cast(context: *anyopaque) *TestDevice {
        return @ptrCast(@alignCast(context));
    }

    fn blocks(_: *anyopaque) u64 {
        return 16;
    }

    fn present(context: *anyopaque) bool {
        return cast(context).inserted;
    }

    fn read(context: *anyopaque, lba: u32, output: []u8) !void {
        const self = cast(context);
        self.operations += 1;
        self.last_buffer = @intFromPtr(output.ptr);
        if (self.fail_read) return error.InjectedRead;
        const start = @as(usize, lba) * sector_bytes;
        @memcpy(output, self.bytes[start..][0..output.len]);
    }

    fn write(context: *anyopaque, lba: u32, input: []const u8) !void {
        const self = cast(context);
        self.operations += 1;
        self.last_buffer = @intFromPtr(input.ptr);
        if (self.fail_write) return error.InjectedWrite;
        const start = @as(usize, lba) * sector_bytes;
        @memcpy(self.bytes[start..][0..input.len], input);
    }

    fn sync(context: *anyopaque) !void {
        const self = cast(context);
        self.syncs += 1;
        if (self.fail_sync) return error.InjectedSync;
    }

    pub fn device(self: *TestDevice) Device {
        return .{ .context = self, .capacity = blocks, .present = present, .read = read, .write = write, .sync = sync };
    }
};

test "unaligned USB fragments preserve every surrounding byte across sector boundaries" {
    var device: TestDevice = .{};
    var bounce: [1024]u8 align(4) = undefined;
    var store = try Store.init(device.device(), &bounce);
    store.session.connectedToHost();
    try store.session.grantHost();
    var random = std.Random.DefaultPrng.init(0x554253);
    random.random().bytes(&device.bytes);
    var expected = device.bytes;
    for (0..4096) |_| {
        const start = random.random().uintLessThan(usize, expected.len);
        const count = random.random().uintLessThan(usize, @min(1537, expected.len - start) + 1);
        var input: [1537]u8 = undefined;
        random.random().bytes(input[0..count]);
        try store.write(@intCast(start / sector_bytes), @intCast(start % sector_bytes), input[0..count]);
        @memcpy(expected[start..][0..count], input[0..count]);
        try std.testing.expectEqualSlices(u8, &expected, &device.bytes);
        var output: [1537]u8 = undefined;
        try store.read(@intCast(start / sector_bytes), @intCast(start % sector_bytes), output[0..count]);
        try std.testing.expectEqualSlices(u8, input[0..count], output[0..count]);
    }
}

test "ownership and wide bounds reject requests before touching the card" {
    var device: TestDevice = .{};
    var bounce: [512]u8 align(4) = undefined;
    var store = try Store.init(device.device(), &bounce);
    var bytes: [513]u8 = @splat(42);
    try std.testing.expectError(error.NotReady, store.write(0, 0, &bytes));
    store.session.connectedToHost();
    try std.testing.expectError(error.NotReady, store.read(0, 0, &bytes));
    try store.session.grantHost();
    for ([_][3]u32{ .{ 0xffffffff, 0, 1 }, .{ 0, 0xffffffff, 1 }, .{ 15, 0, 513 }, .{ 16, 0, 1 } }) |request| {
        try std.testing.expectError(error.OutOfRange, store.read(request[0], request[1], bytes[0..request[2]]));
        try std.testing.expectError(error.OutOfRange, store.write(request[0], request[1], bytes[0..request[2]]));
    }
    try std.testing.expectEqual(0, device.operations);
    try store.eject();
    try std.testing.expectEqual(1, device.syncs);
    try std.testing.expect(!store.session.playerAllowed());
    try std.testing.expectError(error.NotReady, store.write(0, 0, &bytes));
    store.session.ejectAcknowledged();
    try store.session.remounted();
    try std.testing.expectError(error.NotReady, store.read(0, 0, &bytes));
    try std.testing.expectEqual(0, device.operations);
}

test "failed card operations latch failure and cannot acknowledge eject" {
    for (0..3) |fault| {
        var device: TestDevice = .{};
        var bounce: [512]u8 align(4) = undefined;
        var store = try Store.init(device.device(), &bounce);
        store.session.connectedToHost();
        try store.session.grantHost();
        var bytes: [512]u8 = @splat(0);
        switch (fault) {
            0 => {
                device.fail_read = true;
                try std.testing.expectError(error.InjectedRead, store.read(0, 0, &bytes));
            },
            1 => {
                device.fail_write = true;
                try std.testing.expectError(error.InjectedWrite, store.write(0, 0, &bytes));
            },
            else => {
                device.fail_sync = true;
                try std.testing.expectError(error.InjectedSync, store.eject());
            },
        }
        try std.testing.expect(store.failed and !store.ready());
        try std.testing.expectEqual(State.host, store.session.state);
        store.session.ejectAcknowledged();
        try std.testing.expectEqual(State.host, store.session.state);
        try std.testing.expectError(error.NotReady, store.write(0, 0, &bytes));
        store.session.unplug();
        try store.session.remounted();
        try std.testing.expect(store.session.playerAllowed());
    }
}

test "removed card and prevent removal never release ownership" {
    var device: TestDevice = .{};
    var bounce: [512]u8 align(4) = undefined;
    var store = try Store.init(device.device(), &bounce);
    store.session.connectedToHost();
    try store.session.grantHost();
    store.session.prevent_removal = true;
    try std.testing.expectError(error.Busy, store.eject());
    try std.testing.expectEqual(0, device.syncs);
    store.session.prevent_removal = false;
    device.inserted = false;
    try std.testing.expectError(error.NotReady, store.eject());
    try std.testing.expectEqual(State.host, store.session.state);
}

test "shared whole sectors use the original buffer; fragments and foreign buffers bounce" {
    var device: TestDevice = .{};
    var shared: [2048]u8 align(32) = undefined;
    var bounce: [512]u8 align(4) = undefined;
    var target = device.device();
    target.shared = .{ .start = @intFromPtr(&shared), .bytes = shared.len };
    var store = try Store.init(target, &bounce);
    store.session.connectedToHost();
    try store.session.grantHost();
    var random = std.Random.DefaultPrng.init(0x444d4142);
    random.random().bytes(&shared);
    try store.write(1, 0, &shared);
    try std.testing.expectEqual(@intFromPtr(&shared), device.last_buffer);
    try std.testing.expectEqualSlices(u8, &shared, device.bytes[512..2560]);
    @memset(&shared, 0);
    try store.read(1, 0, &shared);
    try std.testing.expectEqual(@intFromPtr(&shared), device.last_buffer);
    const original = device.bytes;
    try store.write(0, 1, shared[1..513]);
    try std.testing.expectEqual(@intFromPtr(&bounce), device.last_buffer);
    try std.testing.expectEqual(original[0], device.bytes[0]);
    try std.testing.expectEqual(original[513], device.bytes[513]);
    var foreign: [512]u8 align(4) = undefined;
    try store.read(0, 0, &foreign);
    try std.testing.expectEqual(@intFromPtr(&bounce), device.last_buffer);
    const operations = device.operations;
    try std.testing.expectError(error.OutOfRange, store.read(15, 0, &shared));
    try std.testing.expectEqual(operations, device.operations);
    try store.eject();
    try std.testing.expectError(error.NotReady, store.write(0, 0, &shared));
    try std.testing.expectEqual(operations, device.operations);
}

test "shared buffer containment is overflow safe and direct errors remain latched" {
    const memory = SharedMemory{ .start = 0x240000, .bytes = 0x20000 };
    try std.testing.expect(memory.accepts(0x240000, 0, 512));
    try std.testing.expect(memory.accepts(0x258000, 0, 32768));
    for ([_]usize{ 0, 0x23fffc, 0x240001, 0x260000, std.math.maxInt(usize) }) |bad| try std.testing.expect(!memory.accepts(bad, 0, 512));
    try std.testing.expect(!memory.accepts(0x240000, 1, 512));
    try std.testing.expect(!memory.accepts(0x240000, 0, 511));
    try std.testing.expect(!memory.accepts(0x240000, 0, 0));
    try std.testing.expect(!memory.contains(0x240000, std.math.maxInt(usize)));
    for ([_]bool{ false, true }) |writing| {
        var device: TestDevice = .{};
        var shared: [512]u8 align(32) = @splat(0);
        var bounce: [512]u8 align(4) = undefined;
        var target = device.device();
        target.shared = .{ .start = @intFromPtr(&shared), .bytes = shared.len };
        var store = try Store.init(target, &bounce);
        store.session.connectedToHost();
        try store.session.grantHost();
        if (writing) {
            device.fail_write = true;
            try std.testing.expectError(error.InjectedWrite, store.write(0, 0, &shared));
        } else {
            device.fail_read = true;
            try std.testing.expectError(error.InjectedRead, store.read(0, 0, &shared));
        }
        try std.testing.expectEqual(@intFromPtr(&shared), device.last_buffer);
        try std.testing.expect(store.failed);
        try std.testing.expectError(error.NotReady, store.eject());
        try std.testing.expectEqual(0, store.reads + store.writes);
    }
}

test "deterministic shared and bounce transports match the same storage oracle" {
    for (0..32) |seed| {
        var random = std.Random.DefaultPrng.init(seed);
        var direct: TestDevice = .{};
        random.random().bytes(&direct.bytes);
        var bounced = direct;
        var shared: [2048]u8 align(32) = undefined;
        var direct_bounce: [512]u8 align(4) = undefined;
        var ordinary_bounce: [512]u8 align(4) = undefined;
        var target = direct.device();
        target.shared = .{ .start = @intFromPtr(&shared), .bytes = shared.len };
        var a = try Store.init(target, &direct_bounce);
        var b = try Store.init(bounced.device(), &ordinary_bounce);
        a.session.connectedToHost();
        b.session.connectedToHost();
        try a.session.grantHost();
        try b.session.grantHost();
        for (0..512) |step| {
            const start = random.random().uintLessThan(usize, direct.bytes.len - shared.len);
            const aligned = step % 2 == 0;
            const at = if (aligned) start / 512 * 512 else start;
            const count = if (aligned) (1 + random.random().uintLessThan(usize, 4)) * 512 else random.random().uintLessThan(usize, shared.len + 1);
            random.random().bytes(shared[0..count]);
            try a.write(@intCast(at / 512), @intCast(at % 512), shared[0..count]);
            try b.write(@intCast(at / 512), @intCast(at % 512), shared[0..count]);
            try std.testing.expectEqualSlices(u8, &direct.bytes, &bounced.bytes);
            var expected: [2048]u8 align(4) = undefined;
            try a.read(@intCast(at / 512), @intCast(at % 512), shared[0..count]);
            try b.read(@intCast(at / 512), @intCast(at % 512), expected[0..count]);
            try std.testing.expectEqualSlices(u8, expected[0..count], shared[0..count]);
            try std.testing.expectEqual(a.reads, b.reads);
            try std.testing.expectEqual(a.writes, b.writes);
        }
    }
}
