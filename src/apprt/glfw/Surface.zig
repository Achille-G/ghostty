/// GLFW Surface (Window) Implementation
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const ApprtApp = @import("App.zig");
const glfw = @import("glfw");
const gl = @import("opengl");
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.glfw_surface);

/// App reference
app: *ApprtApp,

/// GLFW window handle
glfw_window: *glfw.Window,

/// Core surface (the actual terminal)
core_surface: *CoreSurface,

/// Window title (owned)
title: ?[:0]u8 = null,

/// Content scale
content_scale: apprt.ContentScale,

/// Window size
size: apprt.SurfaceSize,

/// Cursor position
cursor_pos: apprt.CursorPos,

/// Surface initialization options
pub const Options = struct {
    /// The size of the window
    width: u32 = 800,
    height: u32 = 600,

    /// The title of the window
    title: [:0]const u8 = "Ghostty",

    /// Font size to use
    font_size: f32 = 0,

    /// Working directory
    working_directory: ?[:0]const u8 = null,
};

pub fn init(self: *Self, app: *ApprtApp, opts: Options) !void {
    // Create GLFW window
    const window = try glfw.createWindow(
        @intCast(opts.width),
        @intCast(opts.height),
        opts.title.ptr,
        null, // monitor
        null, // share
    );
    errdefer glfw.destroyWindow(window);

    // Make the OpenGL context current
    glfw.makeContextCurrent(window);

    // Initialize our structure (core_surface set later after allocation)
    self.app = app;
    self.glfw_window = window;
    self.content_scale = .{ .x = 1.0, .y = 1.0 };
    self.size = .{
        .width = opts.width,
        .height = opts.height,
    };
    self.cursor_pos = .{ .x = -1, .y = -1 };
    self.title = null;

    // Get actual content scale from GLFW
    const scale = glfw.getWindowContentScale(window);
    self.content_scale = .{ .x = scale.xscale, .y = scale.yscale };

    // Set window user pointer for callbacks
    glfw.setWindowUserPointer(window, self);

    // Setup GLFW callbacks
    _ = glfw.setWindowCloseCallback(window, windowCloseCallback);
    _ = glfw.setKeyCallback(window, keyCallback);
    _ = glfw.setCharCallback(window, charCallback);
    _ = glfw.setFramebufferSizeCallback(window, framebufferSizeCallback);
    _ = glfw.setScrollCallback(window, scrollCallback);

    // Add ourselves to the core app
    try app.core_app.addSurface(@ptrCast(self));
    errdefer app.core_app.deleteSurface(@ptrCast(self));

    // Prepare config
    var config = try apprt.surface.newConfig(app.core_app, &app.config);
    defer config.deinit();

    // Set working directory if provided
    if (opts.working_directory) |wd| {
        config.@"working-directory" = wd;
    }

    // Create the core surface
    const core_surface = try app.core_app.alloc.create(CoreSurface);
    errdefer app.core_app.alloc.destroy(core_surface);
    self.core_surface = core_surface;

    // Initialize the core surface (this spawns renderer and terminal threads)
    try core_surface.init(
        app.core_app.alloc,
        &config,
        app.core_app,
        app,
        @ptrCast(self),
    );
    errdefer core_surface.deinit();

    // Set font size if requested
    if (opts.font_size != 0) {
        var font_size = self.core_surface.font_size;
        font_size.points = opts.font_size;
        try self.core_surface.setFontSize(font_size);
    }

    log.info("GLFW surface initialized successfully", .{});
}

pub fn deinit(self: *Self) void {
    log.info("Deinitializing GLFW surface...", .{});

    // Free title if allocated
    if (self.title) |title| {
        self.app.core_app.alloc.free(title);
    }

    // Remove ourselves from the core app
    self.app.core_app.deleteSurface(@ptrCast(self));

    // Deinit the core surface (stops rendering and IO threads)
    self.core_surface.deinit();

    // Free the core surface
    self.app.core_app.alloc.destroy(self.core_surface);

    // Destroy GLFW window
    glfw.destroyWindow(self.glfw_window);

    log.info("GLFW surface deinitialized", .{});
}

pub fn core(self: *Self) *CoreSurface {
    return self.core_surface;
}

pub fn rtApp(self: *Self) *ApprtApp {
    return self.app;
}

pub fn close(self: *Self, process_active: bool) void {
    _ = process_active;

    log.info("Closing GLFW window...", .{});

    // Mark window for closing
    glfw.setWindowShouldClose(self.glfw_window, true);
}

pub fn cgroup(self: *Self) ?[]const u8 {
    _ = self;
    return null; // Windows doesn't use cgroups
}

pub fn getTitle(self: *Self) ?[:0]const u8 {
    return self.title;
}

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    return self.content_scale;
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    return self.size;
}

pub fn getCursorPos(self: *const Self) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn supportsClipboard(
    self: *const Self,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true, // Windows clipboard
        .selection => false, // X11 only
        .primary => false, // X11 only
    };
}

pub fn clipboardRequest(
    self: *Self,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !void {
    _ = clipboard_type;
    _ = state;
    _ = self;

    // TODO: Implement clipboard request via GLFW
    log.debug("clipboardRequest not yet implemented", .{});
}

pub fn setClipboardString(
    self: *Self,
    val: [:0]const u8,
    clipboard_type: apprt.Clipboard,
    confirm: bool,
) !void {
    _ = self;
    _ = confirm;

    if (clipboard_type != .standard) {
        return; // Only standard clipboard on Windows
    }

    // Set clipboard via GLFW
    glfw.setClipboardString(null, val.ptr);

    log.debug("Clipboard set: {s}", .{val});
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    const alloc = self.app.core_app.alloc;
    var env = try internal_os.getEnvMap(alloc);
    errdefer env.deinit();

    // Set TERM to ghostty
    try env.put("TERM", "ghostty");

    // Set COLORTERM for true color support
    try env.put("COLORTERM", "truecolor");

    return env;
}

pub fn redraw(self: *Self) void {
    // Make context current for this window
    glfw.makeContextCurrent(self.glfw_window);

    // Update OpenGL viewport to match window size
    gl.glad.context.Viewport.?(
        0,
        0,
        @intCast(self.size.width),
        @intCast(self.size.height),
    );

    // Call the renderer to draw the frame
    self.core_surface.renderer.drawFrame(false) catch |err| {
        log.warn("error drawing frame err={}", .{err});
    };

    // Swap buffers to display the rendered content
    glfw.swapBuffers(self.glfw_window);

    log.debug("frame drawn and swapped for window", .{});
}

pub fn redrawInspector(self: *Self) void {
    _ = self;
    // TODO: Implement inspector redraw when needed
}

pub fn newSurfaceOptions(self: *const Self) apprt.Surface.Options {
    _ = self;
    return .{};
}

// =========================================================================
// GLFW Callbacks
// =========================================================================

fn windowCloseCallback(window: ?*glfw.Window) callconv(.c) void {
    const self = getSurfaceFromWindow(window) orelse return;
    log.info("Window close requested", .{});

    // Close the surface gracefully
    self.core_surface.close();
}

fn keyCallback(
    window: ?*glfw.Window,
    key: c_int,
    scancode: c_int,
    action: c_int,
    mods: c_int,
) callconv(.c) void {
    _ = scancode;
    const self = getSurfaceFromWindow(window) orelse return;

    // Convert GLFW action to input.Action
    const input_action: @import("../../input.zig").Action = switch (action) {
        glfw.PRESS => .press,
        glfw.RELEASE => .release,
        glfw.REPEAT => .repeat,
        else => return,
    };

    // Convert GLFW mods to input.Mods
    const input_mods: @import("../../input.zig").Mods = .{
        .shift = (mods & glfw.MOD_SHIFT) != 0,
        .ctrl = (mods & glfw.MOD_CONTROL) != 0,
        .alt = (mods & glfw.MOD_ALT) != 0,
        .super = (mods & glfw.MOD_SUPER) != 0,
    };

    // Convert GLFW key to input.Key (simplified mapping)
    const input_key = glfwKeyToInputKey(key);

    // Create key event
    const event: @import("../../input.zig").KeyEvent = .{
        .action = input_action,
        .key = input_key,
        .mods = input_mods,
    };

    // Send to core surface
    _ = self.core_surface.keyCallback(event) catch |err| {
        log.warn("error in key callback err={}", .{err});
    };
}

fn charCallback(
    window: ?*glfw.Window,
    codepoint: c_uint,
) callconv(.c) void {
    const self = getSurfaceFromWindow(window) orelse return;

    // Convert codepoint to UTF-8
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return;

    // Create key event with UTF-8 text
    const event: @import("../../input.zig").KeyEvent = .{
        .action = .press,
        .utf8 = buf[0..len],
    };

    // Send to core surface
    _ = self.core_surface.keyCallback(event) catch |err| {
        log.warn("error in char callback err={}", .{err});
    };
}

fn framebufferSizeCallback(
    window: ?*glfw.Window,
    width: c_int,
    height: c_int,
) callconv(.c) void {
    const self = getSurfaceFromWindow(window) orelse return;

    log.debug("Framebuffer resized to {}x{}", .{ width, height });

    // Update our stored size
    self.size = .{
        .width = @intCast(width),
        .height = @intCast(height),
    };

    // Update content scale (it can change on resize, e.g., moving between monitors)
    const scale = glfw.getWindowContentScale(self.glfw_window);
    self.content_scale = .{ .x = scale.xscale, .y = scale.yscale };

    // Notify core surface of content scale change
    self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
        log.warn("error in content scale callback err={}", .{err});
    };

    // Notify core surface of size change
    self.core_surface.sizeCallback(self.size) catch |err| {
        log.warn("error in size callback err={}", .{err});
    };

    // Trigger a render via the renderer thread's normal mechanism
    // This is like GTK - we don't draw directly, we let the renderer handle it
    self.core_surface.renderer_thread.wakeup.notify() catch |err| {
        log.warn("error waking up renderer err={}", .{err});
    };
}

fn scrollCallback(
    window: ?*glfw.Window,
    xoffset: f64,
    yoffset: f64,
) callconv(.c) void {
    const self = getSurfaceFromWindow(window) orelse return;

    log.debug("Scroll event: xoffset={d}, yoffset={d}", .{ xoffset, yoffset });

    // GLFW mouse wheel events are discrete (not precision/touchpad)
    const scroll_mods: @import("../../input.zig").ScrollMods = .{
        .precision = false,
    };

    // Send scroll event to core surface
    // GLFW already provides the correct scroll direction on Windows
    self.core_surface.scrollCallback(
        xoffset,
        yoffset,
        scroll_mods,
    ) catch |err| {
        log.warn("error in scroll callback err={}", .{err});
    };
}

fn getSurfaceFromWindow(window: ?*glfw.Window) ?*Self {
    const win = window orelse return null;
    const ptr = glfw.getWindowUserPointer(win) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn glfwKeyToInputKey(key: c_int) @import("../../input.zig").Key {
    const input = @import("../../input.zig");
    return switch (key) {
        glfw.KEY_A => input.Key.key_a,
        glfw.KEY_B => input.Key.key_b,
        glfw.KEY_C => input.Key.key_c,
        glfw.KEY_D => input.Key.key_d,
        glfw.KEY_E => input.Key.key_e,
        glfw.KEY_F => input.Key.key_f,
        glfw.KEY_G => input.Key.key_g,
        glfw.KEY_H => input.Key.key_h,
        glfw.KEY_I => input.Key.key_i,
        glfw.KEY_J => input.Key.key_j,
        glfw.KEY_K => input.Key.key_k,
        glfw.KEY_L => input.Key.key_l,
        glfw.KEY_M => input.Key.key_m,
        glfw.KEY_N => input.Key.key_n,
        glfw.KEY_O => input.Key.key_o,
        glfw.KEY_P => input.Key.key_p,
        glfw.KEY_Q => input.Key.key_q,
        glfw.KEY_R => input.Key.key_r,
        glfw.KEY_S => input.Key.key_s,
        glfw.KEY_T => input.Key.key_t,
        glfw.KEY_U => input.Key.key_u,
        glfw.KEY_V => input.Key.key_v,
        glfw.KEY_W => input.Key.key_w,
        glfw.KEY_X => input.Key.key_x,
        glfw.KEY_Y => input.Key.key_y,
        glfw.KEY_Z => input.Key.key_z,
        glfw.KEY_SPACE => input.Key.space,
        glfw.KEY_ENTER => input.Key.enter,
        glfw.KEY_TAB => input.Key.tab,
        glfw.KEY_BACKSPACE => input.Key.backspace,
        glfw.KEY_ESCAPE => input.Key.escape,
        glfw.KEY_UP => input.Key.arrow_up,
        glfw.KEY_DOWN => input.Key.arrow_down,
        glfw.KEY_LEFT => input.Key.arrow_left,
        glfw.KEY_RIGHT => input.Key.arrow_right,
        else => input.Key.unidentified,
    };
}
