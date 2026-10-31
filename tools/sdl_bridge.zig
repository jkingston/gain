//! Desktop-only SDL adapter. UI policy and rendering remain in shared Zig code.
const sdl = @import("sdl");
pub const Event = enum {
    none,
    quit,
    play,
    back,
    menu,
    previous,
    next,
    volume_up,
    volume_down,
    power,
    wheel_up,
    wheel_down,
    theme,
    debug,
};
pub const Window = struct {
    window: *sdl.SDL_Window,
    renderer: *sdl.SDL_Renderer,
    texture: *sdl.SDL_Texture,

    pub fn init(title: [*:0]const u8, width: c_int, height: c_int, scale: c_int) !Window {
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) return error.Initialize;
        errdefer sdl.SDL_Quit();
        var window: ?*sdl.SDL_Window = null;
        var renderer: ?*sdl.SDL_Renderer = null;
        if (!sdl.SDL_CreateWindowAndRenderer(title, width * scale, height * scale, 0, &window, &renderer)) return error.Window;
        errdefer sdl.SDL_DestroyWindow(window);
        errdefer sdl.SDL_DestroyRenderer(renderer);
        const texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGB565, sdl.SDL_TEXTUREACCESS_STREAMING, width, height) orelse return error.Texture;
        errdefer sdl.SDL_DestroyTexture(texture);
        if (!sdl.SDL_SetTextureScaleMode(texture, sdl.SDL_SCALEMODE_NEAREST) or !sdl.SDL_SetRenderLogicalPresentation(renderer, width, height, sdl.SDL_LOGICAL_PRESENTATION_LETTERBOX)) return error.Presentation;
        return .{ .window = window.?, .renderer = renderer.?, .texture = texture };
    }

    pub fn deinit(self: *Window) void {
        sdl.SDL_DestroyTexture(self.texture);
        sdl.SDL_DestroyRenderer(self.renderer);
        sdl.SDL_DestroyWindow(self.window);
        sdl.SDL_Quit();
        self.* = undefined;
    }

    pub fn poll(_: *const Window) Event {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => return .quit,
                sdl.SDL_EVENT_KEY_DOWN => {
                    if (event.key.repeat and !repeatable(event.key.key)) continue;
                    const translated = key(event.key.key);
                    if (translated != .none) return translated;
                },
                sdl.SDL_EVENT_MOUSE_WHEEL => {
                    if (event.wheel.y > 0) return .wheel_up;
                    if (event.wheel.y < 0) return .wheel_down;
                },
                else => {},
            }
        }
        return .none;
    }

    pub fn present(self: *const Window, pixels: [*]const u16, pitch: c_int) !void {
        if (!sdl.SDL_UpdateTexture(self.texture, null, pixels, pitch) or
            !sdl.SDL_SetRenderDrawColor(self.renderer, 5, 8, 6, 255) or
            !sdl.SDL_RenderClear(self.renderer) or
            !sdl.SDL_RenderTexture(self.renderer, self.texture, null, null) or
            !sdl.SDL_RenderPresent(self.renderer)) return error.Present;
    }
};

fn repeatable(code: sdl.SDL_Keycode) bool {
    return switch (code) {
        sdl.SDLK_UP, sdl.SDLK_DOWN, sdl.SDLK_K, sdl.SDLK_J, sdl.SDLK_EQUALS, sdl.SDLK_PLUS, sdl.SDLK_MINUS => true,
        else => false,
    };
}
fn key(code: sdl.SDL_Keycode) Event {
    return switch (code) {
        sdl.SDLK_SPACE, sdl.SDLK_RETURN => .play,
        sdl.SDLK_ESCAPE, sdl.SDLK_BACKSPACE => .back,
        sdl.SDLK_M => .menu,
        sdl.SDLK_LEFTBRACKET => .previous,
        sdl.SDLK_RIGHTBRACKET => .next,
        sdl.SDLK_EQUALS, sdl.SDLK_PLUS => .volume_up,
        sdl.SDLK_MINUS => .volume_down,
        sdl.SDLK_P => .power,
        sdl.SDLK_UP, sdl.SDLK_K => .wheel_up,
        sdl.SDLK_DOWN, sdl.SDLK_J => .wheel_down,
        sdl.SDLK_T => .theme,
        sdl.SDLK_D => .debug,
        else => .none,
    };
}

pub fn saveBitmap(path: [*:0]const u8, pixels: [*]const u16, width: c_int, height: c_int, pitch: c_int) !void {
    const surface = sdl.SDL_CreateSurfaceFrom(width, height, sdl.SDL_PIXELFORMAT_RGB565, @constCast(pixels), pitch) orelse return error.Capture;
    defer sdl.SDL_DestroySurface(surface);
    if (!sdl.SDL_SaveBMP(surface, path)) return error.Capture;
}
pub fn nowMilliseconds() u64 {
    return sdl.SDL_GetTicksNS() / 1_000_000;
}
pub fn delayMilliseconds(milliseconds: u32) void {
    sdl.SDL_Delay(milliseconds);
}
