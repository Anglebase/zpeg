const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const Analyzer = @This();
const Node = Parser.Node;
const Writer = std.io.Writer;

const HEADER = @embedFile("res/Header.txt");
const KEYWORDS = @embedFile("res/keywords.txt");
const NODE = @embedFile("res/Node.txt");

arena: std.heap.ArenaAllocator,
root: Node,

pub fn init(allocator: Allocator, root: Node) Analyzer {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = root,
    };
}

pub fn deinit(self: *Analyzer) void {
    self.arena.deinit();
}

pub fn generator(self: *Analyzer, writer: *Writer) !void {
    try writer.writeAll(HEADER);
    {
        try writer.writeAll(NODE);
        try self.genNode(writer);
        try writer.writeAll("};");
    }
    // TODO
}

fn isStandardName(name: []const u8) bool {
    if (std.mem.containsAtLeast(u8, name, 1, ":")) {
        return false;
    } else {
        var keywords = std.mem.splitAny(u8, KEYWORDS, ";");
        while (keywords.next()) |keyword| {
            if (std.mem.eql(u8, name, keyword)) {
                return false;
            }
        }
    }
    return true;
}

fn genNode(self: *Analyzer, writer: *Writer) !void {
    const allocator = self.arena.allocator();

    for (self.root.grammar.childs.items[1..]) |node| {
        const def = node.definition;
        switch (def.childs.items[0]) {
            .attribute => |attr| {
                switch (attr.childs.items[0]) {
                    .void => {},
                    .leaf => {
                        const raw_name = def.childs.items[1].identifier.childs.items[0].ident.str();
                        const name = try allocator.alloc(u8, raw_name.len);
                        defer allocator.free(name);
                        @memcpy(name, raw_name);
                        for (name) |*ch| {
                            ch.* = std.ascii.toLower(ch.*);
                        }

                        if (isStandardName(name)) {
                            try writer.print("    {s}: Leaf,\n", .{name});
                        } else {
                            try writer.print("    @\"{s}\": Leaf,\n", .{name});
                        }
                    },
                    else => unreachable,
                }
            },
            .identifier => |ident| {
                const raw_name = ident.childs.items[0].ident.str();
                const name = try allocator.alloc(u8, raw_name.len);
                defer allocator.free(name);
                @memcpy(name, raw_name);
                for (name) |*ch| {
                    ch.* = std.ascii.toLower(ch.*);
                }

                if (isStandardName(name)) {
                    try writer.print("    {s}: Value,\n", .{name});
                } else {
                    try writer.print("    @\"{s}\": Value,\n", .{name});
                }
            },
            else => unreachable,
        }
    }
}
