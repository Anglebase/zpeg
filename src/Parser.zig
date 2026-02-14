const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const List = std.ArrayList;

const Parser = @This();
const Index = usize;

ref: []const u8,
pos: Index,
arena: ArenaAllocator,
err_msg: ?[]const u8,

/// Create a parser.
///
/// Call the method 'deinit' when it is no longer in use.
/// Caller should ensure that the `source`'s lifetime is longer than this parser.
pub fn init(allocator: Allocator, source: []const u8) Parser {
    return .{
        .arena = ArenaAllocator.init(allocator),
        .err_msg = null,
        .pos = 0,
        .ref = source,
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

fn printError(self: *Parser, comptime fmt: []const u8, args: anytype) !void {
    const allocator = self.arena.allocator();
    self.err_msg = try std.fmt.allocPrint(allocator, fmt, args);
}

fn isEOF(self: *Parser) bool {
    return self.pos >= self.ref.len;
}

fn exceptNotEOF(self: *Parser) !void {
    if (self.isEOF()) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptEOF;
    }
}

fn exceptEOF(self: *Parser) !void {
    if (!self.isEOF()) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.ExceptEOF;
    }
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

fn except(self: *Parser, f: anytype) bool {
    const current = self.store();
    defer self.restore(current);

    _ = f(self) catch return false;
    return true;
}

pub const Node = union(enum) {
    eof,
    eol,
    comment,
    whitespace,
    is,
    final,
    semicolon,
    colon,
    slash,
    open,
    close,
    to,
    openb,
    closeb,
    apostroph,
    dapostroph,
    peg,
    hexdigit,

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
};

fn parseEOF(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    if (self.isEOF()) {
        return .eof;
    }
    try self.printError("At pos {d}.\n", .{self.pos});
    return error.UnexceptChar;
}

fn parseEOL(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    try self.exceptNotEOF();

    if (std.mem.eql(u8, self.substr(start, 2) orelse return error.UnexceptEOF, "\n\r")) {
        self.advance();
        self.advance();
    } else if (self.peek().? == '\r') {
        self.advance();
    } else if (self.peek().? == '\n') {
        self.advance();
    } else {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }

    return .eol;
}

fn parseCOMMENT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    try self.exceptNotEOF();

    if (self.peek().? != '#') {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();

    loop: while (true) : (self.advance()) {
        if (self.except(Parser.parseEOL)) {
            break :loop;
        }
        if (self.isEOF()) {
            break :loop;
        }
    }

    _ = try self.parseEOL();

    return .comment;
}

fn parseWHITESPACE(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    loop: while (true) {
        if (self.peek() == null) {
            break :loop;
        } else if (self.peek().? == ' ') {
            self.advance();
            continue :loop;
        } else if (self.peek().? == '\t') {
            self.advance();
            continue :loop;
        } else if (self.except(Parser.parseEOL)) {
            _ = try self.parseEOL();
            continue :loop;
        } else if (self.except(Parser.parseCOMMENT)) {
            _ = try self.parseCOMMENT();
            continue :loop;
        } else {
            break :loop;
        }
    }

    return .whitespace;
}

fn parseXDIGIT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<xdigit>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .xdigit = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}

fn parseALNUM(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<alnum>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .alnum = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseALPHA(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<alpha>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .alpha = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseASCII(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<ascii>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .ascii = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseCONTROL(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<control>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .control = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseDDIGIT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<ddigit>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .ddigit = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseDIGIT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<digit>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .digit = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseGRAPH(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<graph>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .graph = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseLOWER(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<lower>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .lower = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parsePRINTABLE(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<print>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .print = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parsePUNCT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<punct>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .punct = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseSPACE(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<space>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .space = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseUPPER(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<upper>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .upper = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseWORDCHAR(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<wordchar>";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .wordchar = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseIS(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "<-";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .is;
}
fn parseVOID(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "void";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

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

    const str = "leaf";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .leaf = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseSEMICOLON(self: *Parser) !Node {
    const start = self.store();
    std.debug.print("Pos: {d}\n", .{self.pos});
    errdefer self.restore(start);

    const str = ";";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .semicolon;
}
fn parseCOLON(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = ":";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .colon;
}
fn parseSLASH(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "/";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .slash;
}
fn parseAND(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "&";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

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

    const str = "!";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

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

    const str = "?";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

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

    const str = "*";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

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

    const str = "+";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .plus = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
fn parseOPEN(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "(";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .open;
}
fn parseCLOSE(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = ")";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .close;
}
fn parseDOT(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = ".";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    _ = try self.parseWHITESPACE();

    return .{
        .dot = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}

fn parseTO(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "-";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    return .to;
}
fn parseOPENB(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "[";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    return .openb;
}
fn parseCLOSEB(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "]";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    return .closeb;
}
fn parseAPOSTROPH(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "'";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    return .apostroph;
}
fn parseDAPOSTROPH(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "\"";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    return .dapostroph;
}

fn parsePEG(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "PEG";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }
    inline for (str) |_| {
        self.advance();
    }

    const ch = self.peek() orelse return error.UnexceptEOF;
    if (ch == '_' or ch == ':' or std.ascii.isAlphanumeric(ch)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }

    _ = try self.parseWHITESPACE();

    return .peg;
}

fn parseHexDigit(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const ch = self.peek() orelse return error.UnexceptEOF;
    if (!(('0' <= ch and ch <= '9') or ('A' <= ch and ch <= 'F') or ('a' <= ch and ch <= 'f'))) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();

    return .hexdigit;
}

fn parseCharUnescaped(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    if (self.peek() != null and self.peek().? == '\\') {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    try self.exceptNotEOF();
    self.advance();

    return .{
        .charunescaped = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}

pub fn parseGrammar(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    _ = try self.parseWHITESPACE();
    try childs.append(allocator, try self.parseHeader());

    while (true) {
        const node = self.parseDefinition() catch break;
        try childs.append(allocator, node);
    }

    _ = try self.parseFinal();
    _ = try self.parseEOF();

    return .{
        .grammar = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parseHeader(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    _ = try self.parsePEG();
    try childs.append(allocator, try self.parseIdentifier());
    try childs.append(allocator, try self.parseStartExpr());

    return .{
        .header = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parseDefinition(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    if (self.except(Parser.parseAttribute)) {
        try childs.append(allocator, self.parseAttribute() catch unreachable);
    }
    try childs.append(allocator, try self.parseIdentifier());
    _ = try self.parseIS();
    try childs.append(allocator, try self.parseExpression());
    _ = try self.parseSEMICOLON();

    return .{ .definition = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}
pub fn parseAttribute(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    if (self.except(Parser.parseVOID)) {
        try childs.append(allocator, self.parseVOID() catch unreachable);
    } else if (self.except(Parser.parseLEAF)) {
        try childs.append(allocator, self.parseLEAF() catch unreachable);
    }
    _ = try self.parseCOLON();

    return .{ .attribute = .{
        .start = start,
        .end = self.pos,
        .ref = self.ref,
        .childs = childs,
    } };
}
pub fn parseExpression(self: *Parser) anyerror!Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    try childs.append(allocator, try self.parseSequence());
    while (true) {
        _ = self.parseSLASH() catch break;
        try childs.append(allocator, self.parseSequence() catch {
            _ = childs.pop();
            break;
        });
    }

    return .{
        .expression = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parseSequence(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    try childs.append(allocator, try self.parsePrefix());
    while (true) {
        try childs.append(allocator, self.parsePrefix() catch break);
    }

    return .{
        .sequence = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parsePrefix(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    if (self.except(Parser.parseAND)) {
        try childs.append(allocator, self.parseAND() catch unreachable);
    } else if (self.except(Parser.parseNOT)) {
        try childs.append(allocator, self.parseNOT() catch unreachable);
    }

    try childs.append(allocator, try self.parseSuffix());

    return .{
        .prefix = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parseSuffix(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    try childs.append(allocator, try self.parsePrimary());
    if (self.except(Parser.parseQUESTION)) {
        try childs.append(allocator, self.parseQUESTION() catch unreachable);
    } else if (self.except(Parser.parseSTAR)) {
        try childs.append(allocator, self.parseSTAR() catch unreachable);
    } else if (self.except(Parser.parsePLUS)) {
        try childs.append(allocator, self.parsePLUS() catch unreachable);
    }

    return .{
        .suffix = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parsePrimary(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    var vaild = false;
    if (!vaild and self.except(Parser.parseALNUM)) {
        try childs.append(allocator, self.parseALNUM() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseALPHA)) {
        try childs.append(allocator, self.parseALPHA() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseASCII)) {
        try childs.append(allocator, self.parseASCII() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseCONTROL)) {
        try childs.append(allocator, self.parseCONTROL() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseDDIGIT)) {
        try childs.append(allocator, self.parseDDIGIT() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseDIGIT)) {
        try childs.append(allocator, self.parseDIGIT() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseGRAPH)) {
        try childs.append(allocator, self.parseGRAPH() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseLOWER)) {
        try childs.append(allocator, self.parseLOWER() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parsePRINTABLE)) {
        try childs.append(allocator, self.parsePRINTABLE() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parsePUNCT)) {
        try childs.append(allocator, self.parsePUNCT() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseSPACE)) {
        try childs.append(allocator, self.parseSPACE() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseUPPER)) {
        try childs.append(allocator, self.parseUPPER() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseWORDCHAR)) {
        try childs.append(allocator, self.parseWORDCHAR() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseXDIGIT)) {
        try childs.append(allocator, self.parseXDIGIT() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseIdentifier)) {
        try childs.append(allocator, self.parseIdentifier() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseOPEN)) {
        _ = self.parseOPEN() catch unreachable;
        if (self.except(Parser.parseExpression)) {
            try childs.append(allocator, self.parseExpression() catch unreachable);
        }
        if (self.except(Parser.parseCLOSE)) {
            _ = self.parseCLOSE() catch unreachable;
        } else {
            _ = childs.pop();
        }
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseLiteral)) {
        try childs.append(allocator, self.parseLiteral() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseClass)) {
        try childs.append(allocator, self.parseClass() catch unreachable);
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseDOT)) {
        try childs.append(allocator, self.parseDOT() catch unreachable);
        vaild = true;
    }
    if (!vaild) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }

    return .{
        .primary = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parseLiteral(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    var vaild = false;
    if (!vaild and self.except(Parser.parseAPOSTROPH)) blk: {
        _ = self.parseAPOSTROPH() catch unreachable;
        while (true) {
            if (self.except(Parser.parseAPOSTROPH)) break;
            try childs.append(allocator, self.parseChar() catch break);
        }
        _ = self.parseAPOSTROPH() catch break :blk;
        _ = self.parseWHITESPACE() catch break :blk;
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseDAPOSTROPH)) blk: {
        _ = self.parseDAPOSTROPH() catch unreachable;
        while (true) {
            if (self.except(Parser.parseDAPOSTROPH)) break;
            try childs.append(allocator, self.parseChar() catch break);
        }
        _ = self.parseDAPOSTROPH() catch break :blk;
        _ = self.parseWHITESPACE() catch break :blk;
        vaild = true;
    }
    if (!vaild) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }

    return .{
        .literal = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parseClass(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    _=try self.parseOPENB();
    while (true) {
        if (self.except(Parser.parseCLOSEB)) break;
        try childs.append(allocator, self.parseChar() catch break);
    }
    _=try self.parseCLOSEB();
    _=try self.parseWHITESPACE();

    return .{
        .class = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parseRange(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    var vaild = false;
    if (!vaild and self.except(Parser.parseChar)) {
        try childs.append(allocator, try self.parseChar());
        _ = try self.parseTO();
        try childs.append(allocator, try self.parseChar());
        vaild = true;
    }
    if (!vaild and self.except(Parser.parseChar)) {
        try childs.append(allocator, try self.parseChar());
        vaild = true;
    }
    if (!vaild) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }

    return .{
        .range = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parseStartExpr(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    _ = try self.parseOPEN();
    try childs.append(allocator, try self.parseExpression());
    _ = try self.parseCLOSE();

    return .{
        .startexpr = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parseFinal(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const str = "END";
    if (!std.mem.eql(u8, self.substr(start, str.len) orelse return error.UnexceptEOF, str)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    inline for (str) |_| {
        self.advance();
    }
    _ = try self.parseWHITESPACE();
    _ = try self.parseSEMICOLON();
    _ = try self.parseWHITESPACE();

    return .final;
}
pub fn parseIdentifier(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    _ = try self.parseIdent();
    _ = try self.parseWHITESPACE();

    return .{
        .ident = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
pub fn parseIdent(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    const ch = self.peek() orelse return error.UnexceptEOF;
    if (ch != '_' and ch != ':' and !std.ascii.isAlphabetic(ch)) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();
    while (true) : (self.advance()) {
        const c = self.peek() orelse break;
        if (c != '_' and c != ':' and !std.ascii.isAlphanumeric(c)) {
            break;
        }
    }

    return .{
        .ident = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
pub fn parseChar(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);
    const allocator = self.arena.allocator();
    var childs = try List(Node).initCapacity(allocator, 10);

    if (self.except(Parser.parseCharSpecial)) {
        try childs.append(allocator, self.parseCharSpecial() catch unreachable);
    } else if (self.except(Parser.parseCharOctalFull)) {
        try childs.append(allocator, self.parseCharOctalFull() catch unreachable);
    } else if (self.except(Parser.parseCharOctalPart)) {
        try childs.append(allocator, self.parseCharOctalPart() catch unreachable);
    } else if (self.except(Parser.parseCharUnicode)) {
        try childs.append(allocator, self.parseCharUnicode() catch unreachable);
    } else if (self.except(Parser.parseCharUnescaped)) {
        try childs.append(allocator, self.parseCharUnescaped() catch unreachable);
    } else {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptSymbol;
    }

    return .{
        .char = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
            .childs = childs,
        },
    };
}
pub fn parseCharSpecial(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    if ((self.peek() orelse return error.UnexceptEOF) != '\\') {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();
    const group = "nrt'\"[]\\";
    if (!std.mem.containsAtLeast(
        u8,
        group,
        1,
        self.substr(self.pos, 1) orelse return error.UnexceptEOF,
    )) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();
    return .{
        .charspecial = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
pub fn parseCharOctalFull(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    if ((self.peek() orelse return error.UnexceptEOF) != '\\') {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();
    const c1 = self.peek() orelse return error.UnexceptEOF;
    if (!('0' <= c1 and c1 <= '2')) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();
    const c2 = self.peek() orelse return error.UnexceptEOF;
    if (!('0' <= c2 and c2 <= '7')) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();
    const c3 = self.peek() orelse return error.UnexceptEOF;
    if (!('0' <= c3 and c3 <= '7')) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();

    return .{
        .charoctalfull = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
pub fn parseCharOctalPart(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    if ((self.peek() orelse return error.UnexceptEOF) != '\\') {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();
    const c1 = self.peek() orelse return error.UnexceptEOF;
    if (!('0' <= c1 and c1 <= '7')) {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();
    const c2 = self.peek() orelse return error.UnexceptEOF;
    if ('0' <= c2 and c2 <= '7') {
        self.advance();
    }

    return .{
        .charoctalpart = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}
pub fn parseCharUnicode(self: *Parser) !Node {
    const start = self.store();
    errdefer self.restore(start);

    if ((self.peek() orelse return error.UnexceptEOF) != '\\') {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();
    if ((self.peek() orelse return error.UnexceptEOF) != 'u') {
        try self.printError("At pos {d}.\n", .{self.pos});
        return error.UnexceptChar;
    }
    self.advance();

    _ = try self.parseHexDigit();
    if (self.except(Parser.parseHexDigit)) {
        _ = self.parseHexDigit() catch unreachable;
        if (self.except(Parser.parseHexDigit)) {
            _ = self.parseHexDigit() catch unreachable;
            if (self.except(Parser.parseHexDigit)) {
                _ = self.parseHexDigit() catch unreachable;
            }
        }
    }

    return .{
        .charunicode = .{
            .start = start,
            .end = self.pos,
            .ref = self.ref,
        },
    };
}

pub fn parse(self: *Parser) !Node {
    return try self.parseGrammar();
}
