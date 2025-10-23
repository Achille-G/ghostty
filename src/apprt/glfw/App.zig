/// GLFW Application Runtime for Windows
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const CoreApp = @import("../../App.zig");
const CoreConfig = @import("../../config.zig").Config;
const Surface = @import("Surface.zig");
const glfw = @import("glfw");

const log = std.log.scoped(.glfw);

/// GLFW drawing must happen on app thread
pub const must_draw_from_app_thread = true;

/// Core app reference
core_app: *CoreApp,

/// Configuration (owned, must be deinitialized)
config: CoreConfig,

/// Whether the event loop is running
running: bool,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    log.info("Initializing GLFW runtime...", .{});

    // Load configuration
    var config = CoreConfig.load(core_app.alloc) catch |err| config: {
        // If we fail to load configuration, use default
        log.warn("Failed to load config, using default: {}", .{err});
        break :config try CoreConfig.default(core_app.alloc);
    };
    errdefer config.deinit();

    try config.finalize();

    // Initialize GLFW
    try glfw.init();
    errdefer glfw.terminate();

    // Set OpenGL version hints - Ghostty requires OpenGL 4.3
    glfw.windowHint(glfw.CONTEXT_VERSION_MAJOR, 4);
    glfw.windowHint(glfw.CONTEXT_VERSION_MINOR, 3);
    glfw.windowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE);

    // macOS requires forward compatibility
    if (builtin.os.tag.isDarwin()) {
        glfw.windowHint(glfw.OPENGL_FORWARD_COMPAT, glfw.TRUE);
    }

    self.* = .{
        .core_app = core_app,
        .config = config,
        .running = false,
    };

    // Queue creation of the first window (like GTK does in activate())
    _ = core_app.mailbox.push(.{
        .new_window = .{},
    }, .{ .forever = {} });

    log.info("GLFW initialized successfully", .{});
}

pub fn run(self: *App) !void {
    log.info("Starting GLFW event loop...", .{});

    self.running = true;
    defer self.running = false;

    // Main event loop
    while (self.running) {
        // Process pending messages from the mailbox (creates windows, etc.)
        try self.core_app.tick(self);

        // Check for windows that should be closed and clean them up
        self.cleanupClosedWindows();

        // If no windows remain, quit the application
        if (self.core_app.surfaces.items.len == 0 and self.core_app.first == false) {
            log.info("No windows remaining, quitting...", .{});
            self.running = false;
            break;
        }

        // Wait for events with a timeout to avoid busy-waiting
        glfw.waitEventsTimeout(0.016); // ~60fps
    }

    log.info("GLFW event loop ended", .{});
}

pub fn terminate(self: *App) void {
    log.info("Terminating GLFW runtime...", .{});

    self.running = false;
    glfw.terminate();
    self.config.deinit();

    log.info("GLFW terminated", .{});
}

pub fn wakeup(self: *App) void {
    _ = self;

    // Wake up the event loop by posting an empty event
    glfw.postEmptyEvent();
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    _ = value;

    switch (action) {
        .new_window => {
            log.info("Creating new GLFW window...", .{});

            // Create an apprt Surface for this window
            const surface = try self.core_app.alloc.create(Surface);
            errdefer self.core_app.alloc.destroy(surface);

            // Initialize the surface (this creates GLFW window, CoreSurface, renderer, terminal, etc.)
            try surface.init(self, .{});
            errdefer surface.deinit();

            log.info("GLFW surface initialized successfully", .{});

            // Mark that we're no longer creating the first surface
            self.core_app.first = false;

            return true;
        },

        .render => {
            // Render action - swap buffers to display the rendered content
            switch (target) {
                .app => {
                    // Render all surfaces - not commonly used
                    log.debug("render action for all surfaces not yet implemented", .{});
                },
                .surface => |core| {
                    // Render the specific surface
                    const surface: *Surface = @ptrCast(@alignCast(core.rt_surface));
                    surface.redraw();
                },
            }
            return true;
        },

        .quit => {
            log.info("Quit action received", .{});
            self.running = false;
            return true;
        },

        else => {
            log.debug("performAction not implemented for: {s}", .{@tagName(action)});
            return false;
        },
    }
}

pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    _ = alloc;
    _ = target;
    _ = value;

    // TODO: Implement IPC when needed
    log.debug("performIpc not implemented for: {s}", .{@tagName(action)});
    return false;
}

pub fn redrawInspector(_: *App, surface: *Surface) void {
    _ = surface;
    // TODO: Implement inspector redraw when needed
}

/// Clean up windows that have been marked for closing
fn cleanupClosedWindows(self: *App) void {
    // We need to iterate backwards to safely remove items
    var i: usize = self.core_app.surfaces.items.len;
    while (i > 0) {
        i -= 1;
        // Get the GLFW surface (surfaces list contains *apprt.Surface which is our GLFW Surface)
        const surface: *Surface = self.core_app.surfaces.items[i];

        // Check if the window should close
        if (glfw.windowShouldClose(surface.glfw_window)) {
            log.info("Cleaning up closed window at index {}", .{i});

            // Deinitialize the surface (this will also call deleteSurface)
            surface.deinit();

            // Free the surface memory
            self.core_app.alloc.destroy(surface);
        }
    }
}
