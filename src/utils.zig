const Parser = @import("Parser.zig");
const std = @import("std");
const Writer = std.io.Writer;

pub fn printNode(node: Parser.Node, writer: *Writer, prefix: usize) !void {
    switch (node) {
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
