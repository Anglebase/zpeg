const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Parser = @import("Parser.zig");
const Analyzer = @This();
const Node = Parser.Node;
const Writer = std.io.Writer;
const Checker = @import("Checker.zig");

const HEADER = @embedFile("res/HeaderUnicode.txt");
const KEYWORDS = @embedFile("res/keywords.txt");
const NODE = @embedFile("res/Node.txt");

arena: std.heap.ArenaAllocator,
root: *const Node,

pub fn init(allocator: Allocator, root: *const Node) Analyzer {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = root,
    };
}

pub fn deinit(self: *Analyzer) void {
    self.arena.deinit();
}

pub fn generator(self: *Analyzer, writer: *Writer, checker: *const Checker) !void {
    try writer.writeAll(HEADER);

    try self.genNullableSet(writer, checker);

    try writer.writeAll(NODE);
    try self.genNode(writer);
    try writer.writeAll("};\n\n");

    try self.genParseFunc(writer);

    try self.genParse(writer);
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

fn toStandardName(self: *Analyzer, name: []const u8) ![]const u8 {
    const allocator = self.arena.allocator();
    const result = try allocator.alloc(u8, name.len + 3);
    for (name, result[2..(result.len - 1)]) |c, *ch| {
        ch.* = std.ascii.toLower(c);
    }
    if (isStandardName(result[2..(result.len - 1)])) return result[2..(result.len - 1)];
    result[0] = '@';
    result[1] = '"';
    result[result.len - 1] = '"';
    return result;
}

fn genNode(self: *Analyzer, writer: *Writer) !void {
    // start
    try writer.writeAll(
        \\    pub fn start(self: Node) Index {
        \\        switch(self) {
        \\
    );
    for (self.root.grammar.childs.items[1..]) |node| {
        if (node.definition.childs.items[0] != .identifier) continue;
        const name = node.definition.childs.items[0].identifier.childs.items[0].ident.str();
        try writer.print(
            \\            .{s},
            \\
        , .{try self.toStandardName(name)});
    }
    try writer.writeAll(
        \\            => |n| return n.start,
        \\            inline else => |n| return n.start,
        \\        }
        \\    }
        \\
        \\
    );
    // end
    try writer.writeAll(
        \\    pub fn end(self: Node) Index {
        \\        switch(self) {
        \\
    );
    for (self.root.grammar.childs.items[1..]) |node| {
        if (node.definition.childs.items[0] != .identifier) continue;
        const name = node.definition.childs.items[0].identifier.childs.items[0].ident.str();
        try writer.print(
            \\            .{s},
            \\
        , .{try self.toStandardName(name)});
    }
    try writer.writeAll(
        \\            => |n| return n.end,
        \\            inline else => |n| return n.end,
        \\        }
        \\    }
        \\
        \\
    );
    // str()
    try writer.writeAll(
        \\    pub fn str(self: Node) []const u8 {
        \\        switch(self) {
        \\
    );
    for (self.root.grammar.childs.items[1..]) |node| {
        if (node.definition.childs.items[0] != .identifier) continue;
        const name = node.definition.childs.items[0].identifier.childs.items[0].ident.str();
        try writer.print(
            \\            .{s},
            \\
        , .{try self.toStandardName(name)});
    }
    try writer.writeAll(
        \\            => |n| return n.str(),
        \\            inline else => |n| return n.str(),
        \\        }
        \\    }
        \\
        \\
    );
    // fields
    for (self.root.grammar.childs.items[1..]) |node| {
        const def = node.definition;
        switch (def.childs.items[0]) {
            .attribute => |attr| {
                switch (attr.childs.items[0]) {
                    .void => {},
                    .leaf => {
                        const raw_name = def.childs.items[1].identifier.childs.items[0].ident.str();
                        const name = try self.toStandardName(raw_name);
                        try writer.print("    {s}: Leaf,\n", .{name});
                    },
                    else => unreachable,
                }
            },
            .identifier => |ident| {
                const raw_name = ident.childs.items[0].ident.str();
                const name = try self.toStandardName(raw_name);
                try writer.print("    {s}: Value,\n", .{name});
            },
            else => unreachable,
        }
    }
}

fn genParseFunc(self: *Analyzer, writer: *Writer) !void {
    for (self.root.grammar.childs.items[1..]) |node| {
        const def = node.definition;
        switch (def.childs.items[0]) {
            .attribute => |attr| {
                switch (attr.childs.items[0]) {
                    .void => try self.genParseFuncVoid(writer, &def),
                    .leaf => try self.genParseFuncLeaf(writer, &def),
                    else => unreachable,
                }
            },
            .identifier => try self.genParseFuncValue(writer, &def),
            else => unreachable,
        }
    }
}

fn toStandardFuncName(self: *Analyzer, name: []const u8) ![]const u8 {
    const allocator = self.arena.allocator();
    const PARSE = "@\"parse";
    const result = try allocator.alloc(u8, name.len + PARSE.len + 1);
    @memcpy(result[0..PARSE.len], PARSE);
    @memcpy(result[PARSE.len..(result.len - 1)], name);
    if (isStandardName(result[2..(result.len - 1)])) return result[2..(result.len - 1)];
    result[result.len - 1] = '"';
    return result;
}

fn genParseFuncVoid(self: *Analyzer, writer: *Writer, def: *const Node.Value) !void {
    const name = def.childs.items[1].identifier.childs.items[0].ident.str();
    const func_name = try self.toStandardFuncName(name);
    try writer.print("fn {s}(self: *Parser) !void {{\n", .{func_name});

    try writer.print(
        \\    try self.push("{s}");
        \\    defer self.pop();
        \\
        \\
    , .{name});

    try writer.writeAll(
        \\    const start = self.store();
        \\    errdefer self.restore(start);
        \\
        \\
    );

    try writer.writeAll("    _ = try ");
    try self.genParseCall(writer, &def.childs.items[2]);
    try writer.writeAll(";\n\n");

    try writer.writeAll("}\n\n");
}

fn genParseFuncLeaf(self: *Analyzer, writer: *Writer, def: *const Node.Value) !void {
    const name = def.childs.items[1].identifier.childs.items[0].ident.str();
    const func_name = try self.toStandardFuncName(name);
    try writer.print("fn {s}(self: *Parser) !Node {{\n", .{func_name});

    try writer.print(
        \\    try self.push("{s}");
        \\    defer self.pop();
        \\
        \\
    , .{name});

    try writer.writeAll(
        \\    const start = self.store();
        \\    errdefer self.restore(start);
        \\
        \\
    );

    try writer.writeAll("    _ = try ");
    try self.genParseCall(writer, &def.childs.items[2]);
    try writer.writeAll(";\n\n");

    try writer.print(
        \\    return .{{
        \\        .{s} = .{{
        \\            .start = start,
        \\            .end = self.pos,
        \\            .ref = self.ref,
        \\        }},
        \\    }};
        \\
        \\
    , .{try self.toStandardName(name)});

    try writer.writeAll("}\n\n");
}

fn genParseFuncValue(self: *Analyzer, writer: *Writer, def: *const Node.Value) !void {
    const name = def.childs.items[0].identifier.childs.items[0].ident.str();
    const func_name = try self.toStandardFuncName(name);
    try writer.print("fn {s}(self: *Parser) !Node {{\n", .{func_name});

    try writer.print(
        \\    try self.push("{s}");
        \\    defer self.pop();
        \\
        \\
    , .{name});

    try writer.writeAll(
        \\    const start = self.store();
        \\    errdefer self.restore(start);
        \\
        \\
    );

    try writer.writeAll("    const childs = try ");
    try self.genParseCall(writer, &def.childs.items[1]);
    try writer.writeAll(";\n\n");

    try writer.print(
        \\    return .{{
        \\        .{s} = .{{
        \\            .start = start,
        \\            .end = self.pos,
        \\            .ref = self.ref,
        \\            .childs = childs,
        \\        }},
        \\    }};
        \\
        \\
    , .{try self.toStandardName(name)});

    try writer.writeAll("}\n\n");
}

fn genParseCall(self: *Analyzer, writer: *Writer, node: *const Node) !void {
    try writer.writeAll("self.require(");
    try self.genParseCall2(writer, node);
    try writer.writeAll(")");
}

fn genParseCall2(self: *Analyzer, writer: *Writer, node: *const Node) !void {
    blk: switch (node.*) {
        .expression => |v| {
            if (v.childs.items.len == 1) {
                try self.genParseCall2(writer, &v.childs.items[0]);
                break :blk;
            }
            try writer.writeAll(".{ Parser.choice, .{.{");
            for (v.childs.items) |item| {
                try self.genParseCall2(writer, &item);
            }
            try writer.writeAll("}}},");
        },
        .sequence => |v| {
            if (v.childs.items.len == 1) {
                try self.genParseCall2(writer, &v.childs.items[0]);
                break :blk;
            }
            try writer.writeAll(".{ Parser.sequence, .{.{");
            for (v.childs.items) |item| {
                try self.genParseCall2(writer, &item);
            }
            try writer.writeAll("}}},");
        },
        .prefix => |v| {
            switch (v.childs.items[0]) {
                .@"and" => {
                    try writer.writeAll(".{ Parser.@\"and\", .{");
                    try self.genParseCall2(writer, &v.childs.items[1]);
                    try writer.writeAll("}},");
                },
                .not => {
                    try writer.writeAll(".{ Parser.not, .{");
                    try self.genParseCall2(writer, &v.childs.items[1]);
                    try writer.writeAll("}},");
                },
                .suffix => try self.genParseCall2(writer, &v.childs.items[0]),
                else => unreachable,
            }
        },
        .suffix => |v| {
            const primary = &v.childs.items[0];
            if (v.childs.items.len == 1) {
                try self.genParseCall2(writer, primary);
            } else {
                switch (v.childs.items[1]) {
                    .question => {
                        try writer.writeAll(".{ Parser.optional, .{");
                        try self.genParseCall2(writer, primary);
                        try writer.writeAll("}},");
                    },
                    .star => {
                        try writer.writeAll(".{ Parser.repeat, .{");
                        try self.genParseCall2(writer, primary);
                        try writer.writeAll("}},");
                    },
                    .plus => {
                        try writer.writeAll(".{ Parser.repeatPlus, .{");
                        try self.genParseCall2(writer, primary);
                        try writer.writeAll("}},");
                    },
                    else => unreachable,
                }
            }
        },
        .primary => |v| {
            try self.genParseCall2(writer, &v.childs.items[0]);
        },
        .dot => try writer.writeAll(".{ Parser.dot, .{} },"),
        .identifier => |v| {
            const name = try self.toStandardFuncName(v.childs.items[0].ident.str());
            try writer.print(".{{ Parser.{s}, .{{}} }},", .{name});
        },
        .class => |v| try self.genParseClass(writer, v),
        .literal => |v| try self.genParseLiteral(writer, v),
        else => unreachable,
    }
}

fn genParseClass(self: *Analyzer, writer: *Writer, value: Node.Value) !void {
    try writer.writeAll(".{ Parser.exceptChar, .{&.{");

    for (value.childs.items) |item| {
        const range = item.range;
        switch (range.childs.items.len) {
            1 => try self.genCharactor(writer, range.childs.items[0]),
            2 => try self.genRange(writer, range.childs.items[0], range.childs.items[1]),
            else => unreachable,
        }
    }

    try writer.writeAll("}}},");
}

fn genParseLiteral(self: *Analyzer, writer: *Writer, value: Node.Value) !void {
    try writer.writeAll(".{ Parser.exceptString, .{&.{");
    for (value.childs.items) |item| {
        try self.genCharactor(writer, item);
    }
    try writer.writeAll("}}},");
}

fn parseOct(str: []const u8) u8 {
    switch (str.len) {
        1 => return str[0] - '0',
        2 => return ((str[0] - '0') << 3) | (str[1] - '0'),
        3 => return ((str[0] - '0') << 6) | ((str[1] - '0') << 3) | (str[2] - '0'),
        else => unreachable,
    }
}

fn parseHexOne(c: u8) u21 {
    switch (c) {
        '0'...'9' => return @intCast(c - '0'),
        'a'...'z' => return @intCast(c - 'a' + 10),
        'A'...'Z' => return @intCast(c - 'A' + 10),
        else => unreachable,
    }
}

fn parseHex(str: []const u8) u21 {
    var result: u21 = 0;
    for (str) |n| {
        const num = parseHexOne(n);
        result = (result << 4) | num;
    }
    return result;
}

fn genCharactor(self: *Analyzer, writer: *Writer, node: Node) !void {
    try writer.print("{d}, ", .{self.toInteger(node)});
}

fn toInteger(_: *Analyzer, node: Node) u21 {
    const char = node.char;
    switch (char.childs.items[0]) {
        .charunescaped => |v| {
            const code = std.unicode.utf8Decode(v.str()) catch unreachable;
            return code;
        }, // .
        .charspecial => |v| switch (v.str()[1]) {
            'n' => return @intCast('\n'),
            'r' => return @intCast('\r'),
            't' => return @intCast('\t'),
            '\'' => return @intCast('\''),
            '"' => return @intCast('"'),
            '[' => return @intCast('['),
            ']' => return @intCast(']'),
            '\\' => return @intCast('\\'),
            '-' => return @intCast('-'),
            else => unreachable,
        }, // \n \r \t \' \" \[ \] \\
        .charunicode => |v| return parseHex(v.str()[2..]), // \u(1)f(f(f(f(f))))
        else => unreachable,
    }
}

fn genRange(self: *Analyzer, writer: *Writer, start: Node, end: Node) !void {
    const s = self.toInteger(start);
    const e = self.toInteger(end) + 1;
    for (s..e) |ch| {
        try writer.print("{d}, ", .{ch});
    }
}

fn genParse(self: *Analyzer, writer: *Writer) !void {
    try writer.writeAll(
        \\pub fn parse(self: *Parser) !Node.Value {
        \\    const start = self.store();
        \\    errdefer self.restore(start);
        \\
        \\    const childs = try 
    );

    const header = self.root.grammar.childs.items[0].header;
    const start = header.childs.items[1].startexpr;
    const expr = start.childs.items[0];
    _ = expr.expression;
    try self.genParseCall(writer, &expr);

    try writer.writeAll(
        \\;
        \\
        \\    return .{
        \\        .start = start,
        \\        .end = self.pos,
        \\        .ref = self.ref,
        \\        .childs = childs,
        \\    };
        \\}
    );
}

fn genNullableSet(_: *Analyzer, writer: *Writer, checker: *const Checker) !void {
    try writer.writeAll(
        \\pub const NULLABLE = [_][]const u8 {
        \\
    );
    var iter = checker.nullable.keyIterator();
    while (iter.next()) |item| {
        try writer.print("    \"{s}\",\n", .{item.*});
    }
    try writer.writeAll(
        \\};
        \\
        \\
    );
}
