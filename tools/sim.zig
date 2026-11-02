//! Generic native F20 simulator: pixel presentation, input and app lifecycle only.
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl");
const api = @import("gain_simulator");
const core = @import("sim_core.zig");

const Allocator = std.mem.Allocator;
const frame_interval_ms = 1000 / 60;

const Loaded = struct {
    handle: *sdl.SDL_SharedObject,
    interface: *const api.Api,
    source: [:0]u8,
    temporary: [:0]u8,
    allocator: Allocator,

    fn load(allocator: Allocator, directory: []const u8, source: []const u8) !Loaded {
        if (source.len == 0 or std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidAppPath;
        const path = try allocator.dupeSentinel(u8, source, 0);
        errdefer allocator.free(path);
        const filename = try std.fmt.allocPrint(allocator, "module-{d}{s}", .{ sdl.SDL_GetTicksNS(), dynamicExtension() });
        defer allocator.free(filename);
        const temporary = try std.fs.path.joinZ(allocator, &.{ directory, filename });
        errdefer allocator.free(temporary);
        if (!sdl.SDL_CopyFile(path, temporary)) return error.AppCopyFailed;
        errdefer _ = sdl.SDL_RemovePath(temporary);
        const handle = sdl.SDL_LoadObject(temporary) orelse return error.AppLoadFailed;
        errdefer sdl.SDL_UnloadObject(handle);
        const entry = sdl.SDL_LoadFunction(handle, "gain_app_api") orelse return error.MissingAppEntry;
        const get: *const fn () callconv(.c) ?*const api.Api = @ptrCast(entry);
        const interface = get() orelse return error.MissingAppInterface;
        try interface.validate();
        interface.init.?(now());
        return .{ .handle = handle, .interface = interface, .source = path, .temporary = temporary, .allocator = allocator };
    }

    fn close(self: *Loaded) void {
        if (self.interface.deinit) |deinit| deinit();
        sdl.SDL_UnloadObject(self.handle);
        _ = sdl.SDL_RemovePath(self.temporary);
        self.allocator.free(self.source);
        self.allocator.free(self.temporary);
    }

    fn replace(self: *Loaded, directory: []const u8, source: ?[]const u8) !void {
        var state: [api.snapshot_capacity]u8 = undefined;
        const preserving_state = source == null and self.interface.save != null;
        const length = if (preserving_state) self.interface.save.?(&state, state.len) else 0;
        if (length > state.len) return error.AppSnapshotTooLarge;
        var candidate = try Loaded.load(self.allocator, directory, source orelse self.source);
        errdefer candidate.close();
        if (preserving_state) {
            const restore = candidate.interface.restore orelse return error.AppCannotRestore;
            if (!restore(&state, length, now())) return error.AppRestoreRejected;
        }
        self.close();
        self.* = candidate;
    }
};

const Options = struct {
    app: ?[]const u8 = null,
    directory: ?[]const u8 = null,
    capture: ?[]const u8 = null,
    watch: bool = false,
    headless: bool = false,
};

const Geometry = struct { window_width: i32, window_height: i32, render_width: i32, render_height: i32, scale: i32, screen_x: i32, screen_y: i32 };

const Response = struct { id: u64, ok: bool = true, failure: ?[]const u8 = null, geometry: Geometry };

const Host = struct {
    init: std.process.Init,
    directory: [:0]u8,
    request_path: [:0]u8,
    response_path: [:0]u8,
    pending_path: [:0]u8,
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    texture: *sdl.SDL_Texture,
    app: Loaded,
    buttons: core.Buttons = .{},
    keys: core.KeySources = .{},
    wheel: core.Wheel = .{},
    last_id: ?u64 = null,
    last_response: ?[]u8 = null,
    dirty: bool = true,
    watch: core.Watch = .{},

    fn geometry(self: *Host) !Geometry {
        var w: c_int = 0;
        var h: c_int = 0;
        var rw: c_int = 0;
        var rh: c_int = 0;
        if (!sdl.SDL_GetWindowSize(self.window, &w, &h) or !sdl.SDL_GetRenderOutputSize(self.renderer, &rw, &rh)) return error.WindowGeometry;
        // Minimized or temporarily unavailable drawables must not terminate the app.
        const v = core.viewport(rw, rh) catch return .{
            .window_width = w,
            .window_height = h,
            .render_width = rw,
            .render_height = rh,
            .scale = 0,
            .screen_x = 0,
            .screen_y = 0,
        };
        return .{
            .window_width = w,
            .window_height = h,
            .render_width = rw,
            .render_height = rh,
            .scale = v.scale,
            .screen_x = v.rect.x,
            .screen_y = v.rect.y,
        };
    }

    fn deliver(self: *Host, input: api.Input, phase: api.Phase, at: u64) void {
        const event = api.Event{ .input = input, .phase = phase };
        if (self.buttons.apply(event)) self.app.interface.input.?(event, at);
    }

    fn tap(self: *Host, input: api.Input, at: u64) void {
        if (self.buttons.held & (@as(u16, 1) << @intCast(@backingInt(input))) != 0) return;
        self.deliver(input, .press, at);
        self.deliver(input, .release, at);
    }

    fn releaseAll(self: *Host, at: u64) void {
        for (std.enums.values(api.Input)) |input| self.deliver(input, .release, at);
        self.keys = .{};
    }

    fn replace(self: *Host, source: ?[]const u8) !void {
        // Failed replacement keeps both the old module and its held-input state.
        try self.app.replace(self.directory, source);
        self.releaseAll(now());
        self.watch = .{ .seen = stamp(self.app.source) };
        self.dirty = true;
    }

    fn apply(self: *Host, request: core.Request, pixels: *const api.Pixels) !bool {
        switch (request.op) {
            .input => switch (request.phase) {
                .tap => self.tap(request.button.?, now()),
                .press => self.deliver(request.button.?, .press, now()),
                .release => self.deliver(request.button.?, .release, now()),
                .repeat => self.deliver(request.button.?, .repeat, now()),
            },
            .resize => {
                const density = sdl.SDL_GetWindowPixelDensity(self.window);
                if (!std.math.isFinite(density) or density <= 0 or @as(f64, @floatFromInt(request.width.?)) * density > core.max_dimension or @as(f64, @floatFromInt(request.height.?)) * density > core.max_dimension) return error.InvalidWindowSize;
                if (!sdl.SDL_SetWindowSize(self.window, request.width.?, request.height.?)) return error.ResizeFailed;
                self.dirty = true;
            },
            .reload => try self.replace(null),
            .load => try self.replace(request.path.?),
            .capture => {
                const path = try self.init.gpa.dupeSentinel(u8, request.path.?, 0);
                defer self.init.gpa.free(path);
                if (request.native) try save(path, pixels) else {
                    try self.draw(pixels);
                    const shot = sdl.SDL_RenderReadPixels(self.renderer, null) orelse return error.CaptureFailed;
                    defer sdl.SDL_DestroySurface(shot);
                    if (!sdl.SDL_SaveBMP(shot, path)) return error.CaptureFailed;
                }
            },
            .state => {},
            .quit => return true,
        }
        return false;
    }

    fn respond(self: *Host, response: Response) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.init.gpa, response, .{});
        errdefer self.init.gpa.free(bytes);
        try std.Io.Dir.cwd().writeFile(self.init.io, .{ .sub_path = self.pending_path, .data = bytes });
        try std.Io.Dir.renameAbsolute(self.pending_path, self.response_path, self.init.io);
        if (self.last_response) |previous| self.init.gpa.free(previous);
        self.last_response = bytes;
        self.last_id = response.id;
    }

    fn command(self: *Host, pixels: *const api.Pixels) !bool {
        const stream = sdl.SDL_IOFromFile(self.request_path, "rb") orelse return false;
        var buffer: [core.max_request_bytes + 1]u8 = undefined;
        const length = sdl.SDL_ReadIO(stream, &buffer, buffer.len);
        _ = sdl.SDL_CloseIO(stream);
        _ = sdl.SDL_RemovePath(self.request_path);
        const parsed = core.parseRequest(self.init.gpa, buffer[0..length]) catch |err| {
            try self.respond(.{ .id = 0, .ok = false, .failure = @errorName(err), .geometry = try self.geometry() });
            return false;
        };
        defer parsed.deinit();
        const request = parsed.value;
        if (self.last_id != null and self.last_id.? == request.id) {
            try std.Io.Dir.cwd().writeFile(self.init.io, .{ .sub_path = self.pending_path, .data = self.last_response.? });
            try std.Io.Dir.renameAbsolute(self.pending_path, self.response_path, self.init.io);
            return false;
        }
        var failure: ?[]const u8 = null;
        const quit = self.apply(request, pixels) catch |err| failed: {
            failure = @errorName(err);
            break :failed false;
        };
        try self.respond(.{ .id = request.id, .ok = failure == null, .failure = failure, .geometry = try self.geometry() });
        return quit;
    }

    fn draw(self: *Host, pixels: *const api.Pixels) !void {
        const g = try self.geometry();
        if (g.scale == 0) return error.DisplayUnavailable;
        const v = try core.viewport(g.render_width, g.render_height);
        if (!sdl.SDL_UpdateTexture(self.texture, null, pixels, api.width * 2) or !sdl.SDL_SetRenderDrawColor(self.renderer, 10, 12, 14, 255) or !sdl.SDL_RenderClear(self.renderer)) return error.PresentFailed;
        const dst = sdl.SDL_FRect{ .x = @floatFromInt(v.rect.x), .y = @floatFromInt(v.rect.y), .w = @floatFromInt(v.rect.width), .h = @floatFromInt(v.rect.height) };
        if (!sdl.SDL_RenderTexture(self.renderer, self.texture, null, &dst)) return error.PresentFailed;
        // Capture commands read this fully composed back buffer before presentation.
    }
};

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        std.debug.print("gain-sim: {s}: {s}\n", .{ @errorName(err), std.mem.span(sdl.SDL_GetError()) });
        return err;
    };
}

fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var options = Options{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        }
        if (std.mem.eql(u8, arg, "--watch")) {
            options.watch = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
            continue;
        }
        const target: *?[]const u8 = if (std.mem.eql(u8, arg, "--app")) &options.app else if (std.mem.eql(u8, arg, "--control-dir")) &options.directory else if (std.mem.eql(u8, arg, "--capture")) &options.capture else return error.UnknownOption;
        if (target.* != null) return error.DuplicateOption;
        target.* = args.next() orelse return error.MissingOptionValue;
    }
    const source = options.app orelse {
        usage();
        return error.MissingApp;
    };
    if (options.headless and !sdl.SDL_SetHint(sdl.SDL_HINT_VIDEO_DRIVER, "dummy")) return error.HeadlessUnavailable;
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) return error.SdlInitialize;
    defer sdl.SDL_Quit();
    const cwd = try std.process.currentPathAlloc(init.io, arena);
    var random: u64 = undefined;
    init.io.random(std.mem.asBytes(&random));
    const directory = if (options.directory) |path| try std.fs.path.resolve(arena, &.{
        cwd,
        path,
    }) else try std.fs.path.join(arena, &.{ init.environ_map.get("TMPDIR") orelse "/tmp", try std.fmt.allocPrint(arena, "gain-sim-{x}", .{random}) });
    const directory_z = try arena.dupeSentinel(u8, directory, 0);
    // A new directory is an exclusive instance claim. Never share command files.
    try std.Io.Dir.cwd().createDir(init.io, directory, .default_dir);
    defer _ = sdl.SDL_RemovePath(directory_z);
    const request_path = try std.fs.path.joinZ(arena, &.{ directory, "request.json" });
    const response_path = try std.fs.path.joinZ(arena, &.{ directory, "response.json" });
    const pending_path = try std.fs.path.joinZ(arena, &.{ directory, "response.pending" });
    defer {
        _ = sdl.SDL_RemovePath(request_path);
        // Keep the final acknowledged response readable after a clean exit.
        _ = sdl.SDL_RemovePath(pending_path);
    }
    const window = sdl.SDL_CreateWindow("gain · F20 simulator", 960, 720, sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY | (if (options.headless) @as(u64, sdl.SDL_WINDOW_HIDDEN) else 0)) orelse return error.CreateWindow;
    defer sdl.SDL_DestroyWindow(window);
    if (!sdl.SDL_SetWindowMinimumSize(window, api.width, api.height)) return error.WindowMinimum;
    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.CreateRenderer;
    defer sdl.SDL_DestroyRenderer(renderer);
    _ = sdl.SDL_SetRenderVSync(renderer, 1);
    const texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGB565, sdl.SDL_TEXTUREACCESS_STREAMING, api.width, api.height) orelse return error.CreateTexture;
    defer sdl.SDL_DestroyTexture(texture);
    if (!sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST)) return error.TextureFilter;
    var host = Host{ .init = init, .directory = directory_z, .request_path = request_path, .response_path = response_path, .pending_path = pending_path, .window = window, .renderer = renderer, .texture = texture, .app = try Loaded.load(init.gpa, directory, source) };
    defer host.app.close();
    defer if (host.last_response) |bytes| init.gpa.free(bytes);
    var pixels: api.Pixels = @splat(0);
    host.watch = .{ .seen = stamp(host.app.source) };
    std.debug.print("gain-sim control directory: {s}\n", .{directory});
    while (true) {
        const at = now();
        if (options.watch and host.watch.observe(stamp(host.app.source), at)) host.replace(null) catch |err| std.debug.print("Reload kept current app: {s}\n", .{
            @errorName(err),
        });
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) switch (event.type) {
            sdl.SDL_EVENT_QUIT => return,
            sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => {
                if (event.key.key == sdl.SDLK_F5) {
                    if (event.type == sdl.SDL_EVENT_KEY_DOWN and !event.key.repeat) host.replace(null) catch |err| std.debug.print("Reload kept current app: {s}\n", .{
                        @errorName(err),
                    });
                    continue;
                }
                if (key(event.key.key)) |input| {
                    const scan: usize = @intCast(event.key.scancode);
                    if (scan >= host.keys.keys.len) continue;
                    if (event.type == sdl.SDL_EVENT_KEY_UP) {
                        if (host.keys.release(scan)) |released| host.deliver(released, .release, now());
                    } else if (event.key.repeat) {
                        if (host.keys.keys[scan] != null) host.deliver(input, .repeat, now());
                    } else if (host.keys.press(scan, input)) host.deliver(input, .press, now());
                }
            },
            sdl.SDL_EVENT_MOUSE_WHEEL => {
                const steps = host.wheel.add(@as(f64, event.wheel.y) * (if (event.wheel.direction == sdl.SDL_MOUSEWHEEL_FLIPPED) @as(f64, -1) else 1));
                for (0..@as(usize, @intCast(@abs(steps)))) |_| host.tap(if (steps > 0) .up else .down, now());
            },
            sdl.SDL_EVENT_WINDOW_FOCUS_LOST => host.releaseAll(now()),
            sdl.SDL_EVENT_WINDOW_EXPOSED, sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => host.dirty = true,
            else => {},
        };
        host.dirty = host.app.interface.frame.?(&pixels, now()) or host.dirty;
        if (options.capture) |path| {
            const z = try arena.dupeSentinel(u8, path, 0);
            try save(z, &pixels);
            return;
        }
        // Always compose before processing captures; only upload/present changed frames.
        const display_available = (try host.geometry()).scale > 0;
        if (host.dirty and display_available) try host.draw(&pixels);
        if (try host.command(&pixels)) return;
        if (host.dirty and display_available) {
            if (!sdl.SDL_RenderPresent(renderer)) return error.PresentFailed;
            host.dirty = false;
        }
        const elapsed = now() - at;
        if (elapsed < frame_interval_ms) sdl.SDL_Delay(@intCast(frame_interval_ms - elapsed));
    }
}

fn stamp(path: [*:0]const u8) ?core.Stamp {
    var info: sdl.SDL_PathInfo = undefined;
    if (!sdl.SDL_GetPathInfo(path, &info)) return null;
    return .{ .size = info.size, .modified = info.modify_time };
}

fn now() u64 {
    return sdl.SDL_GetTicksNS() / 1_000_000;
}

fn dynamicExtension() []const u8 {
    return switch (builtin.os.tag) {
        .macos => ".dylib",
        .windows => ".dll",
        else => ".so",
    };
}

fn key(code: sdl.SDL_Keycode) ?api.Input {
    return switch (code) {
        sdl.SDLK_UP, sdl.SDLK_K => .up,
        sdl.SDLK_DOWN, sdl.SDLK_J => .down,
        sdl.SDLK_RETURN, sdl.SDLK_SPACE => .select,
        sdl.SDLK_ESCAPE, sdl.SDLK_BACKSPACE => .back,
        sdl.SDLK_M => .menu,
        sdl.SDLK_LEFTBRACKET => .previous,
        sdl.SDLK_RIGHTBRACKET => .next,
        sdl.SDLK_PLUS, sdl.SDLK_EQUALS => .volume_up,
        sdl.SDLK_MINUS => .volume_down,
        sdl.SDLK_P => .power,
        else => null,
    };
}

fn save(path: [*:0]const u8, pixels: *const api.Pixels) !void {
    const surface = sdl.SDL_CreateSurfaceFrom(api.width, api.height, sdl.SDL_PIXELFORMAT_RGB565, @constCast(pixels), api.width * 2) orelse return error.CaptureFailed;
    defer sdl.SDL_DestroySurface(surface);
    if (!sdl.SDL_SaveBMP(surface, path)) return error.CaptureFailed;
}

fn usage() void {
    std.debug.print("gain-sim --app LIBRARY [--watch] [--control-dir NEW_DIRECTORY] [--headless] [--capture FILE.bmp]\nWheel/Up/Down, Enter/Space, Esc, M, [ ], +/-, P; F5 reloads.\n", .{});
}
