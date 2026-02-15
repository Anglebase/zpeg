const std = @import("std");
const zpeg = @import("zpeg");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var file = try std.fs.cwd().createFile("Parser2.zig", .{});
    defer file.close();
    var log = try std.fs.cwd().createFile("ast.txt", .{});
    defer log.close();

    const src = @embedFile("peg.peg");

    var parser = try zpeg.Parser.init(allocator, src);
    defer parser.deinit();
    const root = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Out of memmory.", .{});
            return;
        },
        else => {
            return err;
        },
    };

    var analyzer = zpeg.Analyzer.init(allocator, &root.childs.items[0]);
    defer analyzer.deinit();

    var buffer: [16]u8 = undefined;
    var writer = file.writer(&buffer);
    try analyzer.generator(&writer.interface);
    try writer.interface.flush();

    var logwriter = log.writer(&buffer);
    try zpeg.utils.printNode(root.childs.items[0], &logwriter.interface, 0);
    try logwriter.interface.flush();
}
