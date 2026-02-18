const std = @import("std");
const buildin = @import("builtin");
const zpeg = @import("zpeg");
const Writer = std.io.Writer;

fn exit(stderr: *Writer) !void {
    if (buildin.mode != .Debug) {
        return error.ErrorTreminal;
    }
    try stderr.flush();
}

pub fn main() !void {
    if (buildin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    }
    // Global
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = if (buildin.mode == .Debug) gpa.allocator() else std.heap.smp_allocator;
    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;
    // args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try stderr.print("Except 1 argument.", .{});
        return exit(stderr);
    }
    // input
    var input = std.fs.cwd().openFile(args[1], .{}) catch |err| {
        try stderr.print(
            "Cannot open file '{s}': {s}",
            .{ args[1], @errorName(err) },
        );
        return exit(stderr);
    };
    defer input.close();

    const src = try input.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(src);

    // parse
    var parser = try zpeg.Parser.init(allocator, src);
    defer parser.deinit();
    const root = parser.parse() catch |err| {
        switch (err) {
            error.OutOfMemory => {
                try stderr.print("Out of memmory.", .{});
            },
            else => {
                parser.filterError();
                const pos = parser.err_stack.items[0].pos;
                try zpeg.utils.printContext(stderr, pos, pos, parser.ref);
                var has = std.StringHashMap(void).init(allocator);
                defer has.deinit();
                try stderr.writeAll("Info:\n");
                for (parser.err_stack.items) |errinfo| {
                    const str = zpeg.utils.exceptContent(errinfo.stack);
                    if (has.contains(str)) {
                        continue;
                    }
                    try has.put(str, {});
                    try stderr.print("    * Except {s}.\n", .{str});
                }
            },
        }
        return exit(stderr);
    };

    // checker
    var checker = try zpeg.Checker.init(allocator, &root.childs.items[0]);
    defer checker.deinit();

    checker.checkRoot() catch |err| {
        switch (err) {
            error.OutOfMemory => {
                try stderr.print("Out of memmory.", .{});
            },
            else => {
                for (checker.err_stack.items) |errinfo| {
                    const start = errinfo.ref.start();
                    const end = errinfo.ref.end();
                    try zpeg.utils.printContext(stderr, start, end, parser.ref);
                    try stderr.print("error: {s}\n", .{errinfo.msg});
                }
            },
        }
        return exit(stderr);
    };

    // analyzer
    var analyzer = zpeg.Analyzer.init(allocator, &root.childs.items[0]);
    defer analyzer.deinit();

    // output
    var output = try std.fs.cwd().createFile("Parser.zig", .{});
    defer output.close();

    var writer = output.writer(&buffer);
    try analyzer.generator(&writer.interface, &checker);
    try writer.interface.flush();
}
