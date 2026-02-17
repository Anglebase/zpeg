const std = @import("std");
const zpeg = @import("zpeg");

pub fn main() !void {
    // Global
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Except 1 argument.", .{});
        return;
    }
    // input
    var input = try std.fs.cwd().openFile(args[1], .{});
    defer input.close();

    const src = try input.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(src);

    // parse
    var parser = try zpeg.Parser.init(allocator, src);
    defer parser.deinit();
    const root = parser.parse() catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Out of memmory.", .{});
            return;
        },
        else => {
            parser.filterError();
            for (parser.err_stack.items) |errinfo| {
                std.debug.print("pos: {d}, error: {s}\n", .{ errinfo.pos, errinfo.msg });
                for (errinfo.stack, 1..) |f, i| {
                    std.debug.print("    {d} | {s}\n", .{ i, f });
                }
            }
            return;
        },
    };

    // checker
    var checker = try zpeg.Checker.init(allocator, &root.childs.items[0]);
    defer checker.deinit();

    checker.checkRoot() catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Out of memmory.", .{});
            return;
        },
        else => {
            for (checker.err_stack.items) |errinfo| {
                std.debug.print(
                    "start: {d}, end: {d}:\n  error: {s}\n",
                    .{ errinfo.ref.start(), errinfo.ref.end(), errinfo.msg },
                );
            }
        },
    };

    // analyzer
    var analyzer = zpeg.Analyzer.init(allocator, &root.childs.items[0]);
    defer analyzer.deinit();

    // output
    var output = try std.fs.cwd().createFile("Parser.zig", .{});
    defer output.close();

    var buffer: [16]u8 = undefined;
    var writer = output.writer(&buffer);
    try analyzer.generator(&writer.interface);
    try writer.interface.flush();
}
