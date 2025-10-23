const std = @import("std");
const uucode = @import("uucode");
const lut = @import("lut.zig");

/// Runnable binary to generate the lookup tables and output to stdout.
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const gen: lut.Generator(
        bool,
        struct {
            pub fn get(ctx: @This(), cp: u21) !bool {
                _ = ctx;
                return if (cp > uucode.config.max_code_point)
                    false
                else
                    uucode.get(.is_symbol, @intCast(cp));
            }

            pub fn eql(ctx: @This(), a: bool, b: bool) bool {
                _ = ctx;
                return a == b;
            }
        },
    ) = .{};

    const t = try gen.generate(alloc);
    defer alloc.free(t.stage1);
    defer alloc.free(t.stage2);
    defer alloc.free(t.stage3);

    // On Windows, use heap allocation to avoid stack overflow with large buffer
    // On other platforms, use 4KB stack buffer
    const is_windows = @import("builtin").os.tag == .windows;
    var stack_buf: [4096]u8 = undefined;
    const heap_buf = if (is_windows) try alloc.alloc(u8, 1024 * 1024) else &[_]u8{};
    defer if (is_windows) alloc.free(heap_buf);

    const buf = if (is_windows) heap_buf else &stack_buf;
    var stdout = std.fs.File.stdout().writer(buf);
    const writer_iface = &stdout.interface;
    try t.writeZig(writer_iface);
    // Flush buffered writer (ignore ftruncate error on Windows)
    stdout.end() catch |err| {
        if (is_windows and err == error.FileTooBig) {
            // On Windows, ftruncate() on stdout fails, but buffer is flushed
        } else return err;
    };

    // Uncomment when manually debugging to see our table sizes.
    // std.log.warn("stage1={} stage2={} stage3={}", .{
    //     t.stage1.len,
    //     t.stage2.len,
    //     t.stage3.len,
    // });
}

test "unicode symbols: tables match uucode" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const testing = std.testing;
    const table = @import("symbols_table.zig").table;

    for (0..std.math.maxInt(u21)) |cp| {
        const t = table.get(@intCast(cp));
        const uu = if (cp > uucode.config.max_code_point)
            false
        else
            uucode.get(.is_symbol, @intCast(cp));

        if (t != uu) {
            std.log.warn("mismatch cp=U+{x} t={} uu={}", .{ cp, t, uu });
            try testing.expect(false);
        }
    }
}
