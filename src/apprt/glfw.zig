const internal_os = @import("../os/main.zig");

// The required comptime API for any apprt.
pub const App = @import("glfw/App.zig");
pub const Surface = @import("glfw/Surface.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
}
