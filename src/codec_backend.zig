//! Packet decoder engines. Containers own timing and I/O; engines own only
//! numerical decoder state allocated from their caller's bounded pool.
const std = @import("std");
const Pool = @import("codec_pool.zig").Pool;
const Alac = @import("alac_bridge.zig").Decoder;
const faad = @import("c_faad");
const vorbis = @import("c_vorbis");
const opus = @import("c_opus");

pub const Kind = enum(c_int) { aac, alac, vorbis, opus };
pub const Error = error{ InvalidFormat, DecoderInit, OutOfMemory, InvalidHeader, DecodeFailed, InvalidOutput };

const Vorbis = struct {
    information: vorbis.vorbis_info = std.mem.zeroes(vorbis.vorbis_info),
    comments: vorbis.vorbis_comment = std.mem.zeroes(vorbis.vorbis_comment),
    synthesis: vorbis.vorbis_dsp_state = std.mem.zeroes(vorbis.vorbis_dsp_state),
    block: vorbis.vorbis_block = std.mem.zeroes(vorbis.vorbis_block),
    headers: u8 = 0,
    packet: i64 = 3,
    synthesis_ready: bool = false,
    block_ready: bool = false,

    fn deinit(self: *Vorbis) void {
        if (self.block_ready) _ = vorbis.vorbis_block_clear(&self.block);
        if (self.synthesis_ready) vorbis.vorbis_dsp_clear(&self.synthesis);
        vorbis.vorbis_comment_clear(&self.comments);
        vorbis.vorbis_info_clear(&self.information);
    }
};

const State = union(Kind) {
    aac: *anyopaque,
    alac: *Alac,
    vorbis: Vorbis,
    opus: *opus.OpusDecoder,
};

pub const Decoder = struct {
    state: *State,
    pool: *Pool,
    channels: u2,
    rate: u32,

    pub fn init(pool: *Pool, kind: Kind, configuration: []const u8, rate: u32, channels: u32) Error!Decoder {
        if (channels < 1 or channels > 2 or rate < 8000 or rate > 192000) return error.InvalidFormat;
        const binding = pool.bind();
        defer binding.end();
        const failures = pool.statistics.failures;
        return open(pool, kind, configuration, rate, @intCast(channels)) catch |err| {
            return if (pool.statistics.failures != failures) error.OutOfMemory else err;
        };
    }

    fn open(pool: *Pool, kind: Kind, configuration: []const u8, rate: u32, channels: u2) Error!Decoder {
        const state: *State = @ptrCast(@alignCast(pool.allocate(@sizeOf(State)) orelse return error.OutOfMemory));
        errdefer pool.release(state);
        switch (kind) {
            .aac => {
                const handle = faad.NeAACDecOpen() orelse return error.DecoderInit;
                errdefer faad.NeAACDecClose(handle);
                const config = faad.NeAACDecGetCurrentConfiguration(handle);
                if (config == null) return error.DecoderInit;
                config.*.outputFormat = faad.FAAD_FMT_FLOAT;
                config.*.dontUpSampleImplicitSBR = 1;
                if (faad.NeAACDecSetConfiguration(handle, config) == 0) return error.DecoderInit;
                var actual_rate: c_ulong = 0;
                var actual_channels: u8 = 0;
                if (faad.NeAACDecInit2(handle, @constCast(configuration.ptr), @intCast(configuration.len), &actual_rate, &actual_channels) != 0 or actual_rate != rate or actual_channels != channels) return error.DecoderInit;
                state.* = .{ .aac = handle };
            },
            .alac => {
                const decoder: *Alac = @ptrCast(@alignCast(pool.allocate(@sizeOf(Alac)) orelse return error.OutOfMemory));
                errdefer pool.release(decoder);
                decoder.* = try Alac.init(configuration);
                state.* = .{ .alac = decoder };
            },
            .vorbis => {
                state.* = .{ .vorbis = .{} };
                vorbis.vorbis_info_init(&state.vorbis.information);
                vorbis.vorbis_comment_init(&state.vorbis.comments);
            },
            .opus => {
                const size = opus.opus_decoder_get_size(channels);
                if (size <= 0) return error.DecoderInit;
                const handle: *opus.OpusDecoder = @ptrCast(@alignCast(pool.allocate(@intCast(size)) orelse return error.OutOfMemory));
                errdefer pool.release(handle);
                if (opus.opus_decoder_init(handle, 48000, channels) != opus.OPUS_OK) return error.DecoderInit;
                if (configuration.len >= 19) {
                    const gain = std.mem.readInt(i16, configuration[16..18], .little);
                    if (opus.opus_decoder_ctl(handle, opus.OPUS_SET_GAIN_REQUEST, @as(c_int, gain)) != opus.OPUS_OK) return error.DecoderInit;
                }
                state.* = .{ .opus = handle };
            },
        }
        return .{ .state = state, .pool = pool, .channels = channels, .rate = rate };
    }

    pub fn deinit(self: *Decoder) void {
        const binding = self.pool.bind();
        defer binding.end();
        switch (self.state.*) {
            .aac => |handle| faad.NeAACDecClose(handle),
            .alac => |decoder| {
                decoder.deinit();
                self.pool.release(decoder);
            },
            .vorbis => |*decoder| decoder.deinit(),
            .opus => |handle| self.pool.release(handle),
        }
        self.pool.release(self.state);
        self.* = undefined;
    }

    pub fn header(self: *Decoder, bytes: []const u8, bos: bool) Error!void {
        const binding = self.pool.bind();
        defer binding.end();
        if (self.state.* != .vorbis) return error.InvalidHeader;
        const decoder = &self.state.vorbis;
        if (decoder.headers >= 3) return error.InvalidHeader;
        var packet = std.mem.zeroes(vorbis.ogg_packet);
        packet.packet = @constCast(bytes.ptr);
        packet.bytes = @intCast(bytes.len);
        packet.b_o_s = @intFromBool(bos);
        packet.packetno = decoder.headers;
        if (vorbis.vorbis_synthesis_headerin(&decoder.information, &decoder.comments, &packet) != 0) return error.InvalidHeader;
        decoder.headers += 1;
        if (decoder.headers == 3) {
            if (decoder.information.rate != self.rate or decoder.information.channels != self.channels or vorbis.vorbis_synthesis_init(&decoder.synthesis, &decoder.information) != 0) return error.InvalidHeader;
            decoder.synthesis_ready = true;
            if (vorbis.vorbis_block_init(&decoder.synthesis, &decoder.block) != 0) return error.InvalidHeader;
            decoder.block_ready = true;
        }
    }

    /// Input has 64 readable zero-padding bytes supplied by the container.
    pub fn decode(self: *Decoder, bytes: []const u8, output: []f32, granule: ?u64, eos: bool) Error!usize {
        const binding = self.pool.bind();
        defer binding.end();
        const frames: usize = switch (self.state.*) {
            .aac => |handle| blk: {
                var info: faad.NeAACDecFrameInfo = undefined;
                const decoded = faad.NeAACDecDecode(handle, &info, @constCast(bytes.ptr), @intCast(bytes.len));
                if (info.@"error" != 0 or info.channels != self.channels or info.samples > output.len or info.samples % self.channels != 0 or (decoded == null and info.samples != 0)) return error.DecodeFailed;
                if (info.samples != 0) @memcpy(output[0..info.samples], @as([*]const f32, @ptrCast(@alignCast(decoded.?)))[0..info.samples]);
                break :blk info.samples / self.channels;
            },
            .alac => |decoder| try decoder.decode(bytes, output),
            .opus => |handle| blk: {
                const count = opus.opus_decode_float(handle, bytes.ptr, @intCast(bytes.len), output.ptr, @intCast(output.len / self.channels), 0);
                if (count < 0) return error.DecodeFailed;
                break :blk @intCast(count);
            },
            .vorbis => |*decoder| blk: {
                if (!decoder.block_ready) return error.DecodeFailed;
                var packet = std.mem.zeroes(vorbis.ogg_packet);
                packet.packet = @constCast(bytes.ptr);
                packet.bytes = @intCast(bytes.len);
                packet.packetno = decoder.packet;
                decoder.packet += 1;
                packet.granulepos = if (granule) |value| @intCast(value) else -1;
                packet.e_o_s = @intFromBool(eos);
                if (vorbis.vorbis_synthesis(&decoder.block, &packet) != 0 or vorbis.vorbis_synthesis_blockin(&decoder.synthesis, &decoder.block) != 0) return error.DecodeFailed;
                var planar: [*c][*c]f32 = null;
                const count = vorbis.vorbis_synthesis_pcmout(&decoder.synthesis, &planar);
                if (count < 0 or @as(usize, @intCast(count)) > output.len / self.channels) return error.InvalidOutput;
                const samples: usize = @intCast(count);
                for (0..samples) |frame| for (0..self.channels) |channel| {
                    output[frame * self.channels + channel] = planar[channel][frame];
                };
                if (vorbis.vorbis_synthesis_read(&decoder.synthesis, count) != 0) return error.DecodeFailed;
                break :blk samples;
            },
        };
        if (frames > output.len / self.channels) return error.InvalidOutput;
        for (output[0 .. frames * self.channels]) |value| if (!std.math.isFinite(value)) return error.InvalidOutput;
        return frames;
    }
};
