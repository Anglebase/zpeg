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

fn charCount(num: usize) usize {
    var n = num;
    var len: usize = 1;
    while (n > 10) : (n %= 10) len += 1;
    return len;
}

pub fn printContext(writer: *Writer, start: usize, end: usize, ref: []const u8) !void {
    var lines = std.mem.splitAny(u8, ref, "\n");
    var pos: usize = 0;
    var line_num: usize = 0;
    while (lines.next()) |line_| {
        line_num += 1;
        const line, const swap = blk: {
            if (line_[line_.len - 1] == '\r') {
                break :blk .{ line_[0..(line_.len - 1)], @as(usize, 2) };
            } else {
                break :blk .{ line_, @as(usize, 1) };
            }
        };
        if (pos + line.len < start) {
            pos += line.len + swap;
            continue;
        }
        try writer.print("{d} |{s}\n", .{ line_num, line });
        for (0..(charCount(line_num) + 2 + (start - pos))) |_|
            try writer.writeAll(" ");
        try writer.writeAll("^");
        if (end == start) break;
        for (0..(@min(pos + line.len, end) - start - 1)) |_|
            try writer.writeAll("~");
        break;
    }
    try writer.writeAll("\n");
}

pub fn exceptContent(stack: []const []const u8) []const u8 {
    return exceptContent2(stack, stack.len - 1);
}

fn exceptContent2(stack: []const []const u8, index: usize) []const u8 {
    const s = stack[index];
    if (std.mem.eql(u8, s, "Grammar") or std.mem.eql(u8, s, "Header")) {
        return "'PEG'";
    }
    if(std.mem.eql(u8, s, "Definition")) {
        return "'void', 'leaf'or identifier";
    }
    if(std.mem.eql(u8, s, "Expression")) {
        return "expression";
    }
    if(std.mem.eql(u8, s, "Identifier")) {
        return "identifier";
    }
    if(std.mem.eql(u8, s, "IS")) {
        return "'<-'";
    }
    if(std.mem.eql(u8, s, "COLON")) {
        return "':'";
    }

    if (index == 0) {
        return "'PEG'";
    }
    return exceptContent2(stack, index - 1);
}
