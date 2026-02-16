const std = @import("std");
const Parser = @import("Parser.zig");
const Node = Parser.Node;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Checker = @import("Checker.zig");
const List = std.ArrayList;
const KeyMap = std.StringHashMap(bool);

pub const Error = struct {
    pub const Tag = enum {
        undefined_ident,
        unnullable,
        left_recursion,
    };
    ref: *const Node,
    msg: []const u8,
    tag: Tag,
};

arena: ArenaAllocator,
root: *const Node,
err_stack: List(Error),

accessing: List([]const u8),
accessed: KeyMap,

pub fn init(gpa: Allocator, root: *const Node) !Checker {
    var arena = ArenaAllocator.init(gpa);
    const allocator = arena.allocator();
    return .{
        .root = root,
        .arena = arena,
        .err_stack = try .initCapacity(allocator, 0),
        .accessing = try .initCapacity(allocator, 0),
        .accessed = .init(gpa),
    };
}

pub fn deinit(self: *Checker) void {
    const allocator = self.arena.allocator();
    self.err_stack.deinit(allocator);
    self.accessing.deinit(allocator);
    self.accessed.deinit();

    self.arena.deinit();
}

fn pushError(self: *Checker, err: Error) !void {
    try self.err_stack.append(self.arena.allocator(), err);
}

fn getExpr(self: *Checker, name: []const u8) !*const Node {
    const root_ident =
        self.root.grammar.childs.items[0].header.childs.items[0]
            .identifier.childs.items[0].ident.str();
    if (std.mem.eql(u8, root_ident, name)) {
        return &self.root.grammar.childs.items[0]
            .header.childs.items[1].startexpr.childs.items[0];
    }
    for (self.root.grammar.childs.items[1..]) |*item| {
        const def = &item.definition;
        switch (def.childs.items[0]) {
            .attribute => {
                const id = def.childs.items[1].identifier.childs.items[0].ident.str();
                if (std.mem.eql(u8, id, name)) {
                    return &def.childs.items[2];
                }
            },
            .identifier => |v| {
                const id = v.childs.items[0].ident.str();
                if (std.mem.eql(u8, id, name)) {
                    return &def.childs.items[1];
                }
            },
            else => {},
        }
    }
    return error.UndefinedIdent;
}

pub fn checkRoot(self: *Checker) !void {
    const root_ident_node = &self.root.grammar.childs.items[0].header.childs.items[0];
    const root_ident = root_ident_node.identifier.childs.items[0].ident.str();
    _ = try self.check(root_ident, root_ident_node);
}

pub fn check(self: *Checker, name: []const u8, node: *const Node) error{
    LeftRecursion,
    Unnullable,
    UndefinedIdent,
    OutOfMemory,
}!bool {
    const expr = self.getExpr(name) catch |err| {
        try self.pushError(.{
            .ref = node,
            .msg = try std.fmt.allocPrint(
                self.arena.allocator(),
                "Undefined identifier '{s}'.",
                .{name},
            ),
            .tag = .undefined_ident,
        });
        return err;
    };

    return try self.checkNode(expr);
}

fn checkNode(self: *Checker, node: *const Node) error{
    LeftRecursion,
    Unnullable,
    UndefinedIdent,
    OutOfMemory,
}!bool {
    switch (node.*) {
        .expression => |v| {
            var result = false;
            for (v.childs.items) |*item| {
                result |= try self.checkNode(item);
            }
            return result;
        },
        .sequence => |v| {
            for (v.childs.items) |*item| {
                if (!try self.checkNode(item)) {
                    return false;
                }
            }
            return true;
        },
        .prefix => |v| {
            if (v.childs.items.len == 1) return try self.checkNode(&v.childs.items[0]);
            return true;
        },
        .suffix => |v| {
            if (v.childs.items.len == 1) return try self.checkNode(&v.childs.items[0]);
            switch (v.childs.items[1]) {
                .question => return true,
                .star => {
                    if (try self.checkNode(&v.childs.items[0])) {
                        try self.pushError(.{
                            .ref = node,
                            .msg = "Greedy matches are not allowed to be empty.",
                            .tag = .unnullable,
                        });
                        return error.Unnullable;
                    }
                    return true;
                },
                .plus => {
                    const result = try self.checkNode(&v.childs.items[0]);
                    if (result) {
                        try self.pushError(.{
                            .ref = node,
                            .msg = "Greedy matches are not allowed to be empty.",
                            .tag = .unnullable,
                        });
                        return error.Unnullable;
                    }
                    return result;
                },
                else => unreachable,
            }
        },
        .primary => |v| {
            return try self.checkNode(&v.childs.items[0]);
        },
        .identifier => |v| {
            const ident = v.childs.items[0].ident.str();
            if (self.accessed.contains(ident)) {
                return self.accessed.get(ident).?;
            }
            const access: ?usize = blk: {
                for (self.accessing.items, 0..) |item, i| {
                    if (std.mem.eql(u8, item, ident)) {
                        break :blk i;
                    }
                }
                break :blk null;
            };
            if (access) |pos| {
                const allocator = self.arena.allocator();
                var msg: []const u8 = ident;
                defer allocator.free(msg);
                for (self.accessing.items[(pos + 1)..], 0..) |item, i| {
                    const before = msg;
                    defer if (i != 0) allocator.free(before);
                    msg = try std.fmt.allocPrint(allocator, "{s} -> {s}", .{ msg, item });
                }
                try self.pushError(.{
                    .ref = node,
                    .msg = try std.fmt.allocPrint(
                        allocator,
                        "Detected left recursive path: {s} -> {s}",
                        .{ msg, ident },
                    ),
                    .tag = .left_recursion,
                });
                return error.LeftRecursion;
            }
            try self.accessing.append(self.arena.allocator(), ident);
            const result = try self.check(ident, node);
            _ = self.accessing.pop();
            try self.accessed.put(ident, result);
            return result;
        },
        .class, .literal, .dot => return false,
        else => unreachable,
    }
}
