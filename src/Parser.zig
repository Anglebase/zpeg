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
err_stack: List(struct { Index, []const u8 }),

/// Create a parser.
///
/// Call the method 'deinit' when it is no longer in use.
/// Caller should ensure that the `source`'s lifetime is longer than this parser.
pub fn init(allocator: Allocator, source: []const u8) !Parser {
    var arena = std.heap.ArenaAllocator.init(allocator);
    return .{
        .arena = arena,
        .pos = 0,
        .ref = source,
        .err_stack = try .initCapacity(arena.allocator(), 0),
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

fn alnum(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isAlphanumeric(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn alpha(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isAlphabetic(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn ascii(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isAscii(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn control(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isControl(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn ddigit(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isDigit(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn digit(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isDigit(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn graph(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isPrint(self.ref[self.pos]) and !std.ascii.isWhitespace(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn lower(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isLower(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn print(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isPrint(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn punct(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isAscii(self.ref[self.pos]) and
        !std.ascii.isAlphanumeric(self.ref[self.pos]) and
        !std.ascii.isWhitespace(self.ref[self.pos]))
    {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn space(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isWhitespace(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn upper(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isUpper(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
}

fn wordchar(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isAscii(self.ref[self.pos])) {
        self.advance();
        return;
    }
}

fn xdigit(self: *Parser) !void {
    if (self.pos >= self.ref.len) return error.UnexceptEOF;
    if (std.ascii.isHex(self.ref[self.pos])) {
        self.advance();
        return;
    }
    return error.UnexceptChar;
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
fn repeat(self: *Parser, item: anytype) error{OutOfMemory}!List(Node) {
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

    xdigit: Leaf,
    alnum: Leaf,
    alpha: Leaf,
    ascii: Leaf,
    control: Leaf,
    ddigit: Leaf,
    digit: Leaf,
    graph: Leaf,
    lower: Leaf,
    print: Leaf,
    punct: Leaf,
    space: Leaf,
    upper: Leaf,
    wordchar: Leaf,
    void: Leaf,
    leaf: Leaf,
    @"and": Leaf,
    not: Leaf,
    question: Leaf,
    star: Leaf,
    plus: Leaf,
    dot: Leaf,
    charunescaped: Leaf,
    charunicode: Leaf,
    ident: Leaf,
    charspecial: Leaf,
    charoctalfull: Leaf,
    charoctalpart: Leaf,

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
    char: Value,
};

fn parseGrammar(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.sequence(.{
        .{ Parser.parseWHITESPACE, .{} },
        .{ Parser.parseHeader, .{} },
        .{ Parser.repeat, .{.{ Parser.parseDefinition, .{} }} },
        .{ Parser.parseFinal, .{} },
        .{ Parser.parseEOF, .{} },
    });

    return .{ .grammar = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseHeader(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.sequence(.{
        .{ Parser.parsePEG, .{} },
        .{ Parser.parseIdentifier, .{} },
        .{ Parser.parseStartExpr, .{} },
    });

    return .{ .header = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseDefinition(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.sequence(.{
        .{ Parser.optional, .{.{ Parser.parseAttribute, .{} }} },
        .{ Parser.parseIdentifier, .{} },
        .{ Parser.parseIS, .{} },
        .{ Parser.parseExpression, .{} },
        .{ Parser.parseSEMICOLON, .{} },
    });

    return .{ .definition = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseAttribute(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.sequence(.{
        .{ Parser.optional, .{.{ Parser.choice, .{.{
            .{ Parser.parseVOID, .{} },
            .{ Parser.parseLEAF, .{} },
        }} }} },
        .{ Parser.parseCOLON, .{} },
    });

    return .{ .attribute = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseExpression(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.sequence(.{
        .{ Parser.parseSequence, .{} },
        .{ Parser.repeat, .{.{ Parser.sequence, .{.{
            .{ Parser.parseSLASH, .{} },
            .{ Parser.parseSequence, .{} },
        }} }} },
    });

    return .{ .expression = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseSequence(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.repeatPlus(.{ Parser.parsePrefix, .{} });

    return .{ .sequence = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parsePrefix(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.sequence(.{
        .{ Parser.optional, .{.{ Parser.choice, .{.{
            .{ Parser.parseAND, .{} },
            .{ Parser.parseNOT, .{} },
        }} }} },
        .{ Parser.parseSuffix, .{} },
    });

    return .{ .prefix = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseSuffix(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.sequence(.{
        .{ Parser.parsePrimary, .{} },
        .{ Parser.optional, .{.{ Parser.choice, .{.{
            .{ Parser.parseQUESTION, .{} },
            .{ Parser.parseSTAR, .{} },
            .{ Parser.parsePLUS, .{} },
        }} }} },
    });

    return .{ .suffix = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parsePrimary(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.choice(.{
        .{ Parser.parseALNUM, .{} },
        .{ Parser.parseALPHA, .{} },
        .{ Parser.parseASCII, .{} },
        .{ Parser.parseCONTROL, .{} },
        .{ Parser.parseDDIGIT, .{} },
        .{ Parser.parseDIGIT, .{} },
        .{ Parser.parseGRAPH, .{} },
        .{ Parser.parseLOWER, .{} },
        .{ Parser.parsePRINTABLE, .{} },
        .{ Parser.parsePUNCT, .{} },
        .{ Parser.parseSPACE, .{} },
        .{ Parser.parseUPPER, .{} },
        .{ Parser.parseWORDCHAR, .{} },
        .{ Parser.parseXDIGIT, .{} },
        .{ Parser.parseIdentifier, .{} },
        .{ Parser.sequence, .{.{
            .{ Parser.parseOPEN, .{} },
            .{ Parser.parseExpression, .{} },
            .{ Parser.parseCLOSE, .{} },
        }} },
        .{ Parser.parseLiteral, .{} },
        .{ Parser.parseClass, .{} },
        .{ Parser.parseDOT, .{} },
    });

    return .{ .primary = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseLiteral(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.choice(.{
        .{ Parser.sequence, .{.{
            .{ Parser.parseAPOSTROPH, .{} },
            .{ Parser.repeat, .{.{ Parser.sequence, .{.{
                .{ Parser.not, .{.{ Parser.parseAPOSTROPH, .{} }} },
                .{ Parser.parseChar, .{} },
            }} }} },
            .{ Parser.parseAPOSTROPH, .{} },
            .{ Parser.parseWHITESPACE, .{} },
        }} },
        .{ Parser.sequence, .{.{
            .{ Parser.parseDAPOSTROPH, .{} },
            .{ Parser.repeat, .{.{ Parser.sequence, .{.{
                .{ Parser.not, .{.{ Parser.parseDAPOSTROPH, .{} }} },
                .{ Parser.parseChar, .{} },
            }} }} },
            .{ Parser.parseDAPOSTROPH, .{} },
            .{ Parser.parseWHITESPACE, .{} },
        }} },
    });

    return .{ .literal = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseClass(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.sequence(.{
        .{ Parser.parseOPENB, .{} },
        .{ Parser.repeat, .{.{ Parser.sequence, .{.{
            .{ Parser.not, .{.{ Parser.parseCLOSEB, .{} }} },
            .{ Parser.parseRange, .{} },
        }} }} },
        .{ Parser.parseCLOSEB, .{} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .class = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseRange(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.choice(.{
        .{ Parser.sequence, .{.{
            .{ Parser.parseChar, .{} },
            .{ Parser.parseTO, .{} },
            .{ Parser.parseChar, .{} },
        }} },
        .{ Parser.parseChar, .{} },
    });

    return .{ .range = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseStartExpr(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.sequence(.{
        .{ Parser.parseOPEN, .{} },
        .{ Parser.parseExpression, .{} },
        .{ Parser.parseCLOSE, .{} },
    });

    return .{ .startexpr = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseIdentifier(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.sequence(.{
        .{ Parser.parseIdent, .{} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .identifier = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseChar(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const childs = try self.choice(.{
        .{ Parser.parseCharSpecial, .{} },
        .{ Parser.parseCharOctalFull, .{} },
        .{ Parser.parseCharOctalPart, .{} },
        .{ Parser.parseCharUnicode, .{} },
        .{ Parser.parseCharUnescaped, .{} },
    });

    return .{ .char = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}

fn parseIdent(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.choice, .{.{
            .{ Parser.exceptChar, .{"_:"} },
            .{ Parser.alpha, .{} },
        }} },
        .{ Parser.repeat, .{.{ Parser.choice, .{.{
            .{ Parser.exceptChar, .{"_:"} },
            .{ Parser.alnum, .{} },
        }} }} },
    });

    return .{ .ident = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseCharSpecial(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"\\"} },
        .{ Parser.exceptChar, .{"nrt'\"[]\\"} },
    });

    return .{ .charspecial = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseCharOctalFull(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"\\"} },
        .{ Parser.exceptChar, .{"012"} },
        .{ Parser.exceptChar, .{"01234567"} },
        .{ Parser.exceptChar, .{"01234567"} },
    });

    return .{ .charoctalfull = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseCharOctalPart(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"\\"} },
        .{ Parser.exceptChar, .{"01234567"} },
        .{ Parser.optional, .{.{ Parser.exceptChar, .{"01234567"} }} },
    });

    return .{ .charoctalpart = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseCharUnicode(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"\\"} },
        .{ Parser.exceptString, .{"u"} },
        .{ Parser.parseHexDigit, .{} },
        .{ Parser.optional, .{.{ Parser.sequence, .{.{
            .{ Parser.parseHexDigit, .{} },
            .{ Parser.optional, .{.{ Parser.sequence, .{.{
                .{ Parser.parseHexDigit, .{} },
                .{ Parser.optional, .{.{ Parser.parseHexDigit, .{} }} },
            }} }} },
        }} }} },
    });

    return .{ .charunicode = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseCharUnescaped(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.not, .{.{ Parser.exceptString, .{"\\"} }} },
        .{ Parser.dot, .{} },
    });

    return .{ .charunescaped = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseVOID(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"void"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .void = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseLEAF(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"leaf"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .leaf = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseAND(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"&"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .@"and" = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseNOT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"!"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .not = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseQUESTION(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"?"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .question = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseSTAR(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"*"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .star = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parsePLUS(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"+"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .plus = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseDOT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"."} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .dot = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseALNUM(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<alnum>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .alnum = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseALPHA(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<alpha>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .alpha = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseASCII(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<ascii>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .ascii = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseCONTROL(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<control>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .control = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseDDIGIT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<ddigit>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .ddigit = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseDIGIT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<digit>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .digit = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseGRAPH(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<graph>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .graph = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseLOWER(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<lower>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .lower = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parsePRINTABLE(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<print>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .print = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parsePUNCT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<punct>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .punct = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseSPACE(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<space>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .space = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseUPPER(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<upper>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .upper = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseWORDCHAR(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<wordchar>"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .wordchar = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseXDIGIT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"xdigit"} },
        .{ Parser.parseWHITESPACE, .{} },
    });

    return .{ .xdigit = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
    } };
}

fn parseFinal(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"END"} },
        .{ Parser.parseWHITESPACE, .{} },
        .{ Parser.parseSEMICOLON, .{} },
        .{ Parser.parseWHITESPACE, .{} },
    });
}

fn parseHexDigit(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.exceptChar("0123456789abcdefABCDEF");
}

fn parseTO(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.exceptString("-");
}

fn parseOPENB(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.exceptString("[");
}

fn parseCLOSEB(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.exceptString("]");
}

fn parseAPOSTROPH(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.exceptString("'");
}

fn parseDAPOSTROPH(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.exceptString("\"");
}

fn parsePEG(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"PEG"} },
        .{ Parser.not, .{.{ Parser.choice, .{.{
            .{ Parser.exceptChar, .{"_:"} },
            .{ Parser.alnum, .{} },
        }} }} },
        .{ Parser.parseWHITESPACE, .{} },
    });
}

fn parseIS(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"<-"} },
        .{ Parser.parseWHITESPACE, .{} },
    });
}

fn parseSEMICOLON(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{";"} },
        .{ Parser.parseWHITESPACE, .{} },
    });
}

fn parseCOLON(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{":"} },
        .{ Parser.parseWHITESPACE, .{} },
    });
}

fn parseSLASH(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"/"} },
        .{ Parser.parseWHITESPACE, .{} },
    });
}

fn parseOPEN(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"("} },
        .{ Parser.parseWHITESPACE, .{} },
    });
}

fn parseCLOSE(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{")"} },
        .{ Parser.parseWHITESPACE, .{} },
    });
}

fn parseWHITESPACE(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.repeat(.{ Parser.choice, .{.{
        .{ Parser.exceptString, .{" "} },
        .{ Parser.exceptString, .{"\t"} },
        .{ Parser.parseEOL, .{} },
        .{ Parser.parseCOMMENT, .{} },
    }} });
}

fn parseCOMMENT(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.sequence(.{
        .{ Parser.exceptString, .{"#"} },
        .{ Parser.repeat, .{.{ Parser.sequence, .{.{
            .{ Parser.not, .{.{ Parser.parseEOL, .{} }} },
            .{ Parser.dot, .{} },
        }} }} },
        .{ Parser.parseEOL, .{} },
    });
}

fn parseEOL(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.choice(.{
        .{ Parser.exceptString, .{"\n\r"} },
        .{ Parser.exceptString, .{"\n"} },
        .{ Parser.exceptString, .{"\r"} },
    });
}

fn parseEOF(self: *Parser) !void {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.not(.{ Parser.dot, .{} });
}

pub fn parse(self: *Parser) !Node {
    return try self.parseGrammar();
}
