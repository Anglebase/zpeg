const std = @import("std");
const zpeg = @import("zpeg");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // var file = try std.fs.cwd().openFile("peg.peg", .{});
    // defer file.close();

    // const src = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    // defer allocator.free(src);
    const src = @embedFile("peg.peg");

    var parser = zpeg.Parser.init(allocator, src);
    defer parser.deinit();
    const root = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Out of memmory.", .{});
            return;
        },
        else => {
            std.debug.print("{s}", .{parser.err_msg.?});
            return err;
        },
    };

    std.debug.print("{any}\n", .{root});
}
