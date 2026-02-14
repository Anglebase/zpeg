const std = @import("std");
const zpeg = @import("zpeg");

const Writer = std.io.Writer;

fn printNode(node: zpeg.Parser.Node, writer: *Writer, prefix: usize) !void {
    switch (node) {
        .eof,
        .eol,
        .comment,
        .whitespace,
        .is,
        .final,
        .semicolon,
        .colon,
        .slash,
        .open,
        .close,
        .to,
        .openb,
        .closeb,
        .apostroph,
        .dapostroph,
        .peg,
        .hexdigit,
        => unreachable,
        .xdigit,
        .alnum,
        .alpha,
        .ascii,
        .control,
        .ddigit,
        .digit,
        .graph,
        .lower,
        .print,
        .punct,
        .space,
        .upper,
        .wordchar,
        .void,
        .leaf,
        .@"and",
        .not,
        .question,
        .star,
        .plus,
        .dot,
        .charunescaped,
        .charunicode,
        .ident,
        .charspecial,
        .charoctalfull,
        .charoctalpart,
        => |leaf| {
            for (0..prefix) |_| {
                try writer.print(" ", .{});
            }
            try writer.print("{s} ref[{d}..{d}]\n", .{
                @tagName(node),
                leaf.start,
                leaf.end,
            });
        },
        .grammar,
        .header,
        .definition,
        .attribute,
        .expression,
        .sequence,
        .prefix,
        .suffix,
        .primary,
        .literal,
        .class,
        .range,
        .startexpr,
        .identifier,
        .char,
        => |value| {
            for (0..prefix) |_| {
                try writer.print(" ", .{});
            }
            try writer.print("{s} ref[{d}..{d}]:\n", .{
                @tagName(node),
                value.start,
                value.end,
            });
            for (value.childs.items) |child| {
                try printNode(child, writer, prefix + 2);
            }
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var file = try std.fs.cwd().createFile("Parser.zig", .{});
    defer file.close();

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


    var analyzer = zpeg.Analyzer.init(allocator, root);
    defer analyzer.deinit();

    var buffer: [16]u8 = undefined;
    var writer = file.writer(&buffer);

    try analyzer.generator(&writer.interface);

    try writer.interface.flush();

}
