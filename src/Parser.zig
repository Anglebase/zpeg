const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const List = std.ArrayList;

const CharClass = union(enum) {
    char: u8,
    range: struct {
        start: u8,
        end: u8,
    },
};

const Parser = @This();
const Index = usize;

ref: []const u8,
pos: Index,
arena: ArenaAllocator,
err_pos: Index,

/// Create a parser.
///
/// Call the method 'deinit' when it is no longer in use.
/// Caller should ensure that the `source`'s lifetime is longer than this parser.
pub fn init(allocator: Allocator, source: []const u8) !Parser {
    const arena = std.heap.ArenaAllocator.init(allocator);
    return .{
        .arena = arena,
        .pos = 0,
        .ref = source,
        .err_pos = 0,
    };
}

/// See `init`.
pub fn deinit(self: *Parser) void {
    self.arena.deinit();
}

pub fn reset(self: *Parser) void {
    self.err_msg = null;
    self.pos = 0;
}

/// Peek current charactor.
fn peek(self: *Parser) ?u8 {
    if (self.isEOF()) {
        @branchHint(.cold);
        return null;
    }
    return self.ref[self.pos];
}

fn substr(self: *Parser, start: Index, len: Index) ?[]const u8 {
    const end = start + len;
    if (end > self.ref.len) return null;
    return self.ref[start..end];
}

/// Change the current position to the next character.
fn advance(self: *Parser) void {
    self.pos += 1;
}

fn store(self: *Parser) Index {
    return self.pos;
}

fn restore(self: *Parser, pos: Index) void {
    self.pos = pos;
}

fn dot(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    self.advance();
}

/// ""
fn exceptString(self: *Parser, string: []const u8) !void {
    const start = self.store();
    errdefer self.restore(start);

    if (self.pos + string.len - 1 >= self.ref.len) return error.UnexceptEOF;

    if (std.mem.eql(u8, self.ref[self.pos..(self.pos + string.len)], string)) {
        self.pos += string.len;
        return;
    }
    return error.UnexceptChar;
}

/// []
fn exceptChar(self: *Parser, charclass: []const u8) !void {
    const start = self.store();
    errdefer self.restore(start);

    if (std.mem.containsAtLeast(
        u8,
        charclass,
        1,
        self.ref[self.pos..(self.pos + 1)],
    )) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

/// &e
fn @"and"(self: *Parser, item: anytype) !void {
    const start = self.store();
    defer self.restore(start);

    const func = item.@"0";
    const args = item.@"1";

    _ = @call(.auto, func, .{self} ++ args) catch return error.UnexceptToken;
}

/// !e
fn not(self: *Parser, item: anytype) !void {
    const start = self.store();
    defer self.restore(start);

    const func = item.@"0";
    const args = item.@"1";

    _ = @call(.auto, func, .{self} ++ args) catch return;
    return error.UnexceptToken;
}

/// e1 e2 ..
fn sequence(self: *Parser, list: anytype) anyerror!List(Node) {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var result = try List(Node).initCapacity(allocator, list.len);

    inline for (list) |item| {
        const func = item.@"0";
        const args = item.@"1";
        const func_info = @typeInfo(@TypeOf(func)).@"fn";
        switch (@typeInfo(func_info.return_type.?).error_union.payload) {
            void => try @call(.auto, func, .{self} ++ args),
            Node => {
                const node: Node = try @call(.auto, func, .{self} ++ args);
                try result.append(allocator, node);
            },
            List(Node) => {
                var node_list: List(Node) = try @call(.auto, func, .{self} ++ args);
                defer node_list.deinit(allocator);
                try result.appendSlice(allocator, node_list.items);
            },
            else => unreachable,
        }
    }
    return result;
}

/// e1 | e2 | ..
fn choice(self: *Parser, list: anytype) anyerror!List(Node) {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var result = try List(Node).initCapacity(allocator, list.len);

    inline for (list) |item| {
        const func = item.@"0";
        const args = item.@"1";
        const func_info = @typeInfo(@TypeOf(func)).@"fn";
        blk: switch (@typeInfo(func_info.return_type.?).error_union.payload) {
            void => {
                @call(.auto, func, .{self} ++ args) catch |err| {
                    if (err == error.OutOfMemory) {
                        return @errorCast(err);
                    }
                    break :blk;
                };
                return result;
            },
            Node => {
                const node: Node = @call(.auto, func, .{self} ++ args) catch |err| {
                    if (err == error.OutOfMemory) {
                        return @errorCast(err);
                    }
                    break :blk;
                };
                try result.append(allocator, node);
                return result;
            },
            List(Node) => {
                var node_list: List(Node) = @call(.auto, func, .{self} ++ args) catch |err| {
                    if (err == error.OutOfMemory) {
                        return @errorCast(err);
                    }
                    break :blk;
                };
                defer node_list.deinit(allocator);
                try result.appendSlice(allocator, node_list.items);
                return result;
            },
            else => unreachable,
        }
    }
    return error.NoMatches;
}

/// e*
fn repeat(self: *Parser, item: anytype) anyerror!List(Node) {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var result = try List(Node).initCapacity(allocator, 5);

    const func = item.@"0";
    const args = item.@"1";
    const func_info = @typeInfo(@TypeOf(func)).@"fn";

    while (true) {
        switch (@typeInfo(func_info.return_type.?).error_union.payload) {
            void => @call(.auto, func, .{self} ++ args) catch |err| {
                if (err == error.OutOfMemory) {
                    return @errorCast(err);
                }
                break;
            },
            Node => {
                const node: Node = @call(.auto, func, .{self} ++ args) catch |err| {
                    if (err == error.OutOfMemory) {
                        return @errorCast(err);
                    }
                    break;
                };
                try result.append(allocator, node);
            },
            List(Node) => {
                var node_list: List(Node) = @call(.auto, func, .{self} ++ args) catch |err| {
                    if (err == error.OutOfMemory) {
                        return @errorCast(err);
                    }
                    break;
                };
                defer node_list.deinit(allocator);
                try result.appendSlice(allocator, node_list.items);
            },
            else => unreachable,
        }
    }
    return result;
}

/// e+
fn repeatPlus(self: *Parser, item: anytype) anyerror!List(Node) {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var result = try List(Node).initCapacity(allocator, 5);

    const func = item.@"0";
    const args = item.@"1";
    const func_info = @typeInfo(@TypeOf(func)).@"fn";

    switch (@typeInfo(func_info.return_type.?).error_union.payload) {
        void => try @call(.auto, func, .{self} ++ args),
        Node => {
            const node: Node = try @call(.auto, func, .{self} ++ args);
            try result.append(allocator, node);
        },
        List(Node) => {
            var node_list: List(Node) = try @call(.auto, func, .{self} ++ args);
            defer node_list.deinit(allocator);
            try result.appendSlice(allocator, node_list.items);
        },
        else => unreachable,
    }

    while (true) {
        switch (@typeInfo(func_info.return_type.?).error_union.payload) {
            void => @call(.auto, func, .{self} ++ args) catch |err| {
                if (err == error.OutOfMemory) {
                    return @errorCast(err);
                }
                break;
            },
            Node => {
                const node: Node = @call(.auto, func, .{self} ++ args) catch |err| {
                    if (err == error.OutOfMemory) {
                        return @errorCast(err);
                    }
                    break;
                };
                try result.append(allocator, node);
            },
            List(Node) => {
                var node_list: List(Node) = @call(.auto, func, .{self} ++ args) catch |err| {
                    if (err == error.OutOfMemory) {
                        return @errorCast(err);
                    }
                    break;
                };
                defer node_list.deinit(allocator);
                try result.appendSlice(allocator, node_list.items);
            },
            else => unreachable,
        }
    }
    return result;
}

/// e?
fn optional(self: *Parser, item: anytype) anyerror!List(Node) {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var result = try List(Node).initCapacity(allocator, 5);

    const func = item.@"0";
    const args = item.@"1";
    const func_info = @typeInfo(@TypeOf(func)).@"fn";

    switch (@typeInfo(func_info.return_type.?).error_union.payload) {
        void => @call(.auto, func, .{self} ++ args) catch |err| {
            if (err == error.OutOfMemory) {
                return err;
            }
            return result;
        },
        Node => {
            const node: Node = @call(.auto, func, .{self} ++ args) catch |err| {
                if (err == error.OutOfMemory) {
                    return err;
                }
                return result;
            };
            try result.append(allocator, node);
        },
        List(Node) => {
            var node_list: List(Node) = @call(.auto, func, .{self} ++ args) catch |err| {
                if (err == error.OutOfMemory) {
                    return err;
                }
                return result;
            };
            defer node_list.deinit(allocator);
            try result.appendSlice(allocator, node_list.items);
        },
        else => unreachable,
    }
    return result;
}

fn require(self: *Parser, item: anytype) anyerror!List(Node) {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var result = try List(Node).initCapacity(allocator, 1);

    const func = item.@"0";
    const args = item.@"1";
    const func_info = @typeInfo(@TypeOf(func)).@"fn";

    switch (@typeInfo(func_info.return_type.?).error_union.payload) {
        void => try @call(.auto, func, .{self} ++ args),
        Node => {
            const node: Node = try @call(.auto, func, .{self} ++ args);
            try result.append(allocator, node);
        },
        List(Node) => {
            var node_list: List(Node) = try @call(.auto, func, .{self} ++ args);
            defer node_list.deinit(allocator);
            try result.appendSlice(allocator, node_list.items);
        },
        else => unreachable,
    }
    return result;
}

pub const Node = union(enum) {
    pub const Leaf = struct {
        start: Index,
        end: Index,
        ref: []const u8,

        pub fn str(self: @This()) []const u8 {
            return self.ref[self.start..self.end];
        }
    };

    pub const Value = struct {
        start: Index,
        end: Index,
        ref: []const u8,

        childs: List(Node),

        pub fn str(self: @This()) []const u8 {
            return self.ref[self.start..self.end];
        }
    };

    grammar: Value,
    header: Value,
    definition: Value,
    attribute: Value,
    expression: Value,
    sequence: Value,
    prefix: Value,
    suffix: Value,
    primary: Value,
    literal: Value,
    class: Value,
    range: Value,
    startexpr: Value,
    identifier: Value,
    ident: Leaf,
    char: Value,
    charspecial: Leaf,
    charoctalfull: Leaf,
    charoctalpart: Leaf,
    charunicode: Leaf,
    charunescaped: Leaf,
    void: Leaf,
    leaf: Leaf,
    @"and": Leaf,
    not: Leaf,
    question: Leaf,
    star: Leaf,
    plus: Leaf,
    dot: Leaf,
};

fn parseGrammar(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.sequence, .{.{.{ Parser.parseWHITESPACE, .{} },.{ Parser.parseHeader, .{} },.{ Parser.repeat, .{.{ Parser.parseDefinition, .{} },}},.{ Parser.parseFinal, .{} },.{ Parser.parseEOF, .{} },}}},);

    return .{
        .grammar = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseHeader(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.sequence, .{.{.{ Parser.parsePEG, .{} },.{ Parser.parseIdentifier, .{} },.{ Parser.parseStartExpr, .{} },}}},);

    return .{
        .header = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseDefinition(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.sequence, .{.{.{ Parser.optional, .{.{ Parser.parseAttribute, .{} },}},.{ Parser.parseIdentifier, .{} },.{ Parser.parseIS, .{} },.{ Parser.parseExpression, .{} },.{ Parser.parseSEMICOLON, .{} },}}},);

    return .{
        .definition = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseAttribute(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.sequence, .{.{.{ Parser.choice, .{.{.{ Parser.parseVOID, .{} },.{ Parser.parseLEAF, .{} },}}},.{ Parser.parseCOLON, .{} },}}},);

    return .{
        .attribute = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseExpression(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.sequence, .{.{.{ Parser.parseSequence, .{} },.{ Parser.repeat, .{.{ Parser.sequence, .{.{.{ Parser.parseSLASH, .{} },.{ Parser.parseSequence, .{} },}}},}},}}},);

    return .{
        .expression = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseSequence(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.repeatPlus, .{.{ Parser.parsePrefix, .{} },}},);

    return .{
        .sequence = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parsePrefix(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.sequence, .{.{.{ Parser.optional, .{.{ Parser.choice, .{.{.{ Parser.parseAND, .{} },.{ Parser.parseNOT, .{} },}}},}},.{ Parser.parseSuffix, .{} },}}},);

    return .{
        .prefix = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseSuffix(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.sequence, .{.{.{ Parser.parsePrimary, .{} },.{ Parser.optional, .{.{ Parser.choice, .{.{.{ Parser.parseQUESTION, .{} },.{ Parser.parseSTAR, .{} },.{ Parser.parsePLUS, .{} },}}},}},}}},);

    return .{
        .suffix = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parsePrimary(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.choice, .{.{.{ Parser.parseIdentifier, .{} },.{ Parser.sequence, .{.{.{ Parser.parseOPEN, .{} },.{ Parser.parseExpression, .{} },.{ Parser.parseCLOSE, .{} },}}},.{ Parser.parseLiteral, .{} },.{ Parser.parseClass, .{} },.{ Parser.parseDOT, .{} },}}},);

    return .{
        .primary = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseLiteral(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.choice, .{.{.{ Parser.sequence, .{.{.{ Parser.parseAPOSTROPH, .{} },.{ Parser.repeat, .{.{ Parser.sequence, .{.{.{ Parser.not, .{.{ Parser.parseAPOSTROPH, .{} },}},.{ Parser.parseChar, .{} },}}},}},.{ Parser.parseAPOSTROPH, .{} },.{ Parser.parseWHITESPACE, .{} },}}},.{ Parser.sequence, .{.{.{ Parser.parseDAPOSTROPH, .{} },.{ Parser.repeat, .{.{ Parser.sequence, .{.{.{ Parser.not, .{.{ Parser.parseDAPOSTROPH, .{} },}},.{ Parser.parseChar, .{} },}}},}},.{ Parser.parseDAPOSTROPH, .{} },.{ Parser.parseWHITESPACE, .{} },}}},}}},);

    return .{
        .literal = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseClass(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.sequence, .{.{.{ Parser.parseOPENB, .{} },.{ Parser.repeat, .{.{ Parser.sequence, .{.{.{ Parser.not, .{.{ Parser.parseCLOSEB, .{} },}},.{ Parser.parseRange, .{} },}}},}},.{ Parser.parseCLOSEB, .{} },.{ Parser.parseWHITESPACE, .{} },}}},);

    return .{
        .class = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseRange(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.choice, .{.{.{ Parser.sequence, .{.{.{ Parser.parseChar, .{} },.{ Parser.parseTO, .{} },.{ Parser.parseChar, .{} },}}},.{ Parser.parseChar, .{} },}}},);

    return .{
        .range = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseStartExpr(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.sequence, .{.{.{ Parser.parseOPEN, .{} },.{ Parser.parseExpression, .{} },.{ Parser.parseCLOSE, .{} },}}},);

    return .{
        .startexpr = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseFinal(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"END"}},.{ Parser.parseWHITESPACE, .{} },.{ Parser.parseSEMICOLON, .{} },.{ Parser.parseWHITESPACE, .{} },}}},);

}

fn parseIdentifier(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.sequence, .{.{.{ Parser.parseIdent, .{} },.{ Parser.parseWHITESPACE, .{} },}}},);

    return .{
        .identifier = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseIdent(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptChar, .{"_:\u{41}\u{42}\u{43}\u{44}\u{45}\u{46}\u{47}\u{48}\u{49}\u{4a}\u{4b}\u{4c}\u{4d}\u{4e}\u{4f}\u{50}\u{51}\u{52}\u{53}\u{54}\u{55}\u{56}\u{57}\u{58}\u{59}\u{61}\u{62}\u{63}\u{64}\u{65}\u{66}\u{67}\u{68}\u{69}\u{6a}\u{6b}\u{6c}\u{6d}\u{6e}\u{6f}\u{70}\u{71}\u{72}\u{73}\u{74}\u{75}\u{76}\u{77}\u{78}\u{79}"}},.{ Parser.repeat, .{.{ Parser.exceptChar, .{"_:\u{41}\u{42}\u{43}\u{44}\u{45}\u{46}\u{47}\u{48}\u{49}\u{4a}\u{4b}\u{4c}\u{4d}\u{4e}\u{4f}\u{50}\u{51}\u{52}\u{53}\u{54}\u{55}\u{56}\u{57}\u{58}\u{59}\u{61}\u{62}\u{63}\u{64}\u{65}\u{66}\u{67}\u{68}\u{69}\u{6a}\u{6b}\u{6c}\u{6d}\u{6e}\u{6f}\u{70}\u{71}\u{72}\u{73}\u{74}\u{75}\u{76}\u{77}\u{78}\u{79}\u{30}\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}\u{37}\u{38}"}},}},}}},);

    return .{
        .ident = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseChar(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.choice, .{.{.{ Parser.parseCharSpecial, .{} },.{ Parser.parseCharOctalFull, .{} },.{ Parser.parseCharOctalPart, .{} },.{ Parser.parseCharUnicode, .{} },.{ Parser.parseCharUnescaped, .{} },}}},);

    return .{
        .char = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };

}

fn parseCharSpecial(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"\\"}},.{ Parser.exceptChar, .{"nrt'\"[]\\"}},}}},);

    return .{
        .charspecial = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseCharOctalFull(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"\\"}},.{ Parser.exceptChar, .{"\u{30}\u{31}"}},.{ Parser.exceptChar, .{"\u{30}\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}"}},.{ Parser.exceptChar, .{"\u{30}\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}"}},}}},);

    return .{
        .charoctalfull = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseCharOctalPart(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"\\"}},.{ Parser.exceptChar, .{"\u{30}\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}"}},.{ Parser.optional, .{.{ Parser.exceptChar, .{"\u{30}\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}"}},}},}}},);

    return .{
        .charoctalpart = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseCharUnicode(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"\\"}},.{ Parser.exceptString, .{"u"}},.{ Parser.parseHexDigit, .{} },.{ Parser.optional, .{.{ Parser.sequence, .{.{.{ Parser.parseHexDigit, .{} },.{ Parser.optional, .{.{ Parser.sequence, .{.{.{ Parser.parseHexDigit, .{} },.{ Parser.optional, .{.{ Parser.parseHexDigit, .{} },}},}}},}},}}},}},}}},);

    return .{
        .charunicode = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseCharUnescaped(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.not, .{.{ Parser.exceptString, .{"\\"}},}},.{ Parser.dot, .{} },}}},);

    return .{
        .charunescaped = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseHexDigit(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.exceptChar, .{"\u{30}\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}\u{37}\u{38}\u{61}\u{62}\u{63}\u{64}\u{65}\u{41}\u{42}\u{43}\u{44}\u{45}"}},);

}

fn parseTO(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.exceptString, .{"-"}},);

}

fn parseOPENB(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.exceptString, .{"["}},);

}

fn parseCLOSEB(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.exceptString, .{"]"}},);

}

fn parseAPOSTROPH(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.exceptString, .{"'"}},);

}

fn parseDAPOSTROPH(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.exceptString, .{"\""}},);

}

fn parsePEG(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"PEG"}},.{ Parser.not, .{.{ Parser.exceptChar, .{"_:\u{41}\u{42}\u{43}\u{44}\u{45}\u{46}\u{47}\u{48}\u{49}\u{4a}\u{4b}\u{4c}\u{4d}\u{4e}\u{4f}\u{50}\u{51}\u{52}\u{53}\u{54}\u{55}\u{56}\u{57}\u{58}\u{59}\u{61}\u{62}\u{63}\u{64}\u{65}\u{66}\u{67}\u{68}\u{69}\u{6a}\u{6b}\u{6c}\u{6d}\u{6e}\u{6f}\u{70}\u{71}\u{72}\u{73}\u{74}\u{75}\u{76}\u{77}\u{78}\u{79}\u{30}\u{31}\u{32}\u{33}\u{34}\u{35}\u{36}\u{37}\u{38}"}},}},.{ Parser.parseWHITESPACE, .{} },}}},);

}

fn parseIS(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"<-"}},.{ Parser.parseWHITESPACE, .{} },}}},);

}

fn parseVOID(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"void"}},.{ Parser.parseWHITESPACE, .{} },}}},);

    return .{
        .void = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseLEAF(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"leaf"}},.{ Parser.parseWHITESPACE, .{} },}}},);

    return .{
        .leaf = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseSEMICOLON(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{";"}},.{ Parser.parseWHITESPACE, .{} },}}},);

}

fn parseCOLON(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{":"}},.{ Parser.parseWHITESPACE, .{} },}}},);

}

fn parseSLASH(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"/"}},.{ Parser.parseWHITESPACE, .{} },}}},);

}

fn parseAND(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"&"}},.{ Parser.parseWHITESPACE, .{} },}}},);

    return .{
        .@"and" = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseNOT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"!"}},.{ Parser.parseWHITESPACE, .{} },}}},);

    return .{
        .not = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseQUESTION(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"?"}},.{ Parser.parseWHITESPACE, .{} },}}},);

    return .{
        .question = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseSTAR(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"*"}},.{ Parser.parseWHITESPACE, .{} },}}},);

    return .{
        .star = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parsePLUS(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"+"}},.{ Parser.parseWHITESPACE, .{} },}}},);

    return .{
        .plus = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseOPEN(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"("}},.{ Parser.parseWHITESPACE, .{} },}}},);

}

fn parseCLOSE(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{")"}},.{ Parser.parseWHITESPACE, .{} },}}},);

}

fn parseDOT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"."}},.{ Parser.parseWHITESPACE, .{} },}}},);

    return .{
        .dot = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };

}

fn parseWHITESPACE(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.repeat, .{.{ Parser.choice, .{.{.{ Parser.exceptString, .{" "}},.{ Parser.exceptString, .{"\t"}},.{ Parser.parseEOL, .{} },.{ Parser.parseCOMMENT, .{} },}}},}},);

}

fn parseCOMMENT(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.sequence, .{.{.{ Parser.exceptString, .{"#"}},.{ Parser.repeat, .{.{ Parser.sequence, .{.{.{ Parser.not, .{.{ Parser.parseEOL, .{} },}},.{ Parser.dot, .{} },}}},}},.{ Parser.parseEOL, .{} },}}},);

}

fn parseEOL(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.choice, .{.{.{ Parser.exceptString, .{"\n\r"}},.{ Parser.exceptString, .{"\n"}},.{ Parser.exceptString, .{"\r"}},}}},);

}

fn parseEOF(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.require(.{ Parser.not, .{.{ Parser.dot, .{} },}},);

}

pub fn parse(self: *Parser) !Node.Value {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.require(.{ Parser.parseGrammar, .{} },);

    return .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    };
}