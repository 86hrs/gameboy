const std = @import("std");
const print = std.debug.print;
const process = std.process;

const CPU = @import("cpu.zig");

const c = @cImport(@cInclude("SDL2/SDL.h"));

var window: ?*c.SDL_Window = null;
var renderer: ?*c.SDL_Renderer = null;
var texture: ?*c.SDL_Texture = null;
var open: bool = true;

var cpu: *CPU = undefined;

pub fn println(msg: []const u8) void {
    print("{s}\n", .{msg});
}
pub fn create_window() void {
    window = c.SDL_CreateWindow("DMG: Game Boy", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, 800, 600, 0);
    if (window == null) {
        @panic("SDL Window failed to create");
    }
}
pub fn init() !void {
    println("Gameboy Started!");
    println("Initializing SDL!");

    if (c.SDL_Init(c.SDL_INIT_EVERYTHING) < 0) {
        @panic("SDL Initialization Failed!");
    }

    create_window();
    renderer = c.SDL_CreateRenderer(window, -1, 0);

    if (renderer == null) {
        const err = c.SDL_GetError();
        print("{s}\n", .{err});
        @panic("SDL Renderer Initializaiton Failed!");
    }
    texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_STREAMING, 160, 144);

    if (texture == null) {
        const err = c.SDL_GetError();
        print("{s}\n", .{err});
        @panic("SDL Texture Initializaiton Failed!");
    }
}
pub fn deinit() void {
    println("Quitting Gameboy!");
    c.SDL_DestroyWindow(window);
    window = null;

    c.SDL_DestroyRenderer(renderer);
    renderer = null;

    c.SDL_DestroyTexture(texture);
    texture = null;
    println("Quitting SDL!");
    c.SDL_Quit();
}
pub fn buildTexture(system: *CPU) void {
    var pixels: [160 * 144]u32 = undefined;

    for (0..144) |y| {
        for (0..160) |x| {
            const pixel_val = system.getPixel(@as(u8, @intCast(x)), @as(u8, @intCast(y)));
            // Convert RGB to ARGB (SDL expects bytes in order: A R G B)
            pixels[y * 160 + x] = 0xFF000000 | // Alpha (fully opaque)
                ((pixel_val & 0xFF0000) >> 16) | // Red
                ((pixel_val & 0x00FF00)) | // Green
                ((pixel_val & 0x0000FF) << 16); // Blue
        }
    }

    _ = c.SDL_UpdateTexture(texture, null, &pixels, 160 * @sizeOf(u32));
}
pub fn handle_events(system: *CPU) void {
    var e: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&e) > 0) {
        switch (e.type) {
            c.SDL_QUIT => open = false,
            c.SDL_KEYDOWN => {
                if (e.key.keysym.scancode == c.SDL_SCANCODE_ESCAPE)
                    open = false;
            },
            else => {},
        }
    }
    buildTexture(system);

    _ = c.SDL_RenderClear(renderer);
    var dest = c.SDL_Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    _ = c.SDL_RenderCopy(renderer, texture, null, &dest);
    _ = c.SDL_RenderPresent(renderer);
}
pub fn main() !void {
    const allocator = std.heap.raw_c_allocator;

    var arg_it = try process.argsWithAllocator(allocator);
    _ = arg_it.skip(); // executable name

    const filename = arg_it.next() orelse {
        println("No ROM file given!\n");
        return error.InvalidROM;
    };

    try @call(.auto, init, .{});
    defer deinit();

    cpu = try allocator.create(CPU);
    defer allocator.destroy(cpu);

    cpu.init();
    try cpu.loadROM(filename);

    while (open) {
        cpu.cycle();
        handle_events(cpu);
    }
}
