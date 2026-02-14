const std = @import("std");
const zpeg = @import("zpeg");

fn printNode(node: zpeg.Parser.Node, prefix: usize) void {
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
        => {
            for (0..prefix) |_| {
                std.debug.print(" ", .{});
            }
            std.debug.print("{s}\n", .{@tagName(node)});
            unreachable;
        },
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
                std.debug.print(" ", .{});
            }
            std.debug.print("{s} ref[{d}..{d}] [[ {s} ]]\n", .{
                @tagName(node),
                leaf.start,
                leaf.end,
                leaf.str(),
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
                std.debug.print(" ", .{});
            }
            std.debug.print("{s} ref[{d}..{d}] [[ {s} ]]:\n", .{
                @tagName(node),
                value.start,
                value.end,
                value.str(),
            });
            for (value.childs.items) |child| {
                printNode(child, prefix + 2);
            }
        },
    }
}

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

    printNode(root, 0);
}
