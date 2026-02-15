const std = @import("std");
const zpeg = @import("zpeg");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Except 1 argument.", .{});
        return;
    }
    var input = try std.fs.cwd().openFile(args[1], .{});
    defer input.close();

    var output = try std.fs.cwd().createFile("Parser.zig", .{});
    defer output.close();

    const src = try input.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(src);

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
    var writer = output.writer(&buffer);
    try analyzer.generator(&writer.interface);
    try writer.interface.flush();
}
