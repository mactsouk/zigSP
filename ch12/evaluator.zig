const std = @import("std");
const Allocator = std.mem.Allocator;

// --- AST & Tokens ---
const TokenType = enum { Illegal, Eof, Ident, Int, String, Assign, Plus, Minus, Asterisk, Slash, Bang, Lt, Gt, LtEq, GtEq, Eq, NotEq, SemiColon, LParen, RParen, LBrace, RBrace, Let, Return, If, Else };
const Token = struct { type: TokenType, literal: []const u8 };
const BinaryOp = enum { Add, Sub, Mul, Div, Eq, NotEq, Lt, Gt, LtEq, GtEq };

const Expr = union(enum) { Integer: i64, String: []const u8, Identifier: []const u8, Binary: struct { left: *Expr, op: BinaryOp, right: *Expr } };

// Updated Stmt to include Assign
const Stmt = union(enum) {
    Let: struct { name: []const u8, value: Expr },
    Assign: struct { name: []const u8, value: Expr }, // <--- Added this
    Return: Expr,
    Expression: Expr,
    If: struct { condition: Expr, consequence: []Stmt, alternative: ?[]Stmt },
};

// --- Evaluator Objects ---
const RuntimeVal = union(enum) {
    Integer: i64,
    String: []const u8,
    Boolean: bool,
    Void,
    ReturnWrapper: *RuntimeVal,
};

const Environment = struct {
    store: std.StringHashMap(RuntimeVal),
    allocator: Allocator,

    fn init(allocator: Allocator) Environment {
        return Environment{
            .store = std.StringHashMap(RuntimeVal).init(allocator),
            .allocator = allocator,
        };
    }
    fn get(self: *Environment, name: []const u8) ?RuntimeVal {
        return self.store.get(name);
    }
    fn set(self: *Environment, name: []const u8, val: RuntimeVal) !void {
        try self.store.put(name, val);
    }
};

// --- Evaluator Logic ---
fn eval(node: Stmt, env: *Environment) anyerror!RuntimeVal {
    switch (node) {
        .Expression => |expr| return evalExpr(expr, env),
        .Return => |expr| {
            const val = try evalExpr(expr, env);
            const ptr = try env.allocator.create(RuntimeVal);
            ptr.* = val;
            return RuntimeVal{ .ReturnWrapper = ptr };
        },
        .Let => |let_stmt| {
            const val = try evalExpr(let_stmt.value, env);
            try env.set(let_stmt.name, val);
            return .Void;
        },
        // Handle Assignment exactly like Let (update store)
        .Assign => |assign_stmt| {
            const val = try evalExpr(assign_stmt.value, env);
            try env.set(assign_stmt.name, val);
            return .Void;
        },
        .If => |if_stmt| {
            const cond = try evalExpr(if_stmt.condition, env);
            if (isTruthy(cond)) {
                return evalBlock(if_stmt.consequence, env);
            } else if (if_stmt.alternative) |alt| {
                return evalBlock(alt, env);
            }
            return .Void;
        },
    }
}

fn evalBlock(stmts: []Stmt, env: *Environment) anyerror!RuntimeVal {
    var result: RuntimeVal = .Void;
    for (stmts) |stmt| {
        result = try eval(stmt, env);
        if (result == .ReturnWrapper) return result;
    }
    return result;
}

fn isTruthy(val: RuntimeVal) bool {
    switch (val) {
        .Boolean => |b| return b,
        .Integer => |i| return i != 0,
        else => return true,
    }
}

fn evalExpr(expr: Expr, env: *Environment) anyerror!RuntimeVal {
    switch (expr) {
        .Integer => |i| return RuntimeVal{ .Integer = i },
        .String => |s| return RuntimeVal{ .String = s },
        .Identifier => |name| {
            if (env.get(name)) |val| return val;
            // std.debug.print is safe
            std.debug.print("Runtime Error: Identifier not found '{s}'\n", .{name});
            return error.IdentifierNotFound;
        },
        .Binary => |bin| {
            const left = try evalExpr(bin.left.*, env);
            const right = try evalExpr(bin.right.*, env);

            if (left == .Integer and right == .Integer) {
                const l = left.Integer;
                const r = right.Integer;
                return switch (bin.op) {
                    .Add => RuntimeVal{ .Integer = l + r },
                    .Sub => RuntimeVal{ .Integer = l - r },
                    .Mul => RuntimeVal{ .Integer = l * r },
                    .Div => RuntimeVal{ .Integer = @divTrunc(l, r) },
                    .Eq => RuntimeVal{ .Boolean = l == r },
                    .NotEq => RuntimeVal{ .Boolean = l != r },
                    .Lt => RuntimeVal{ .Boolean = l < r },
                    .Gt => RuntimeVal{ .Boolean = l > r },
                    .LtEq => RuntimeVal{ .Boolean = l <= r },
                    .GtEq => RuntimeVal{ .Boolean = l >= r },
                };
            }
            if (left == .String and right == .String and bin.op == .Add) {
                const s = try std.fmt.allocPrint(
                    env.allocator,
                    "{s}{s}",
                    .{ left.String, right.String },
                );
                return RuntimeVal{ .String = s };
            }

            return error.TypeMismatch;
        },
    }
}

// --- Lexer & Parser ---
const Lexer = struct {
    input: []const u8,
    allocator: Allocator,
    position: usize = 0,
    read_position: usize = 0,
    ch: u8 = 0,
    fn init(allocator: Allocator, input: []const u8) Lexer {
        var l = Lexer{ .input = input, .allocator = allocator };
        l.readChar();
        return l;
    }
    // readString decodes a double-quoted string, translating backslash escapes
    // (\n \t \r \0, and \" \\ taken literally). Taking the byte after a
    // backslash verbatim means an escaped backslash protects a following quote
    // instead of terminating the string early. OOM is treated as fatal.
    // Returns null when the literal hits end of input before a closing quote,
    // so the caller can emit an Illegal token instead of silently swallowing
    // the rest of the source as a string.
    fn readString(self: *Lexer) ?[]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        self.readChar(); // consume opening quote
        while (self.ch != '"' and self.ch != 0) {
            if (self.ch == '\\') {
                self.readChar();
                if (self.ch == 0) break;
                const decoded: u8 = switch (self.ch) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    else => self.ch,
                };
                buf.append(self.allocator, decoded) catch @panic("OOM");
            } else {
                buf.append(self.allocator, self.ch) catch @panic("OOM");
            }
            self.readChar();
        }
        if (self.ch != '"') return null; // unterminated string literal
        return buf.toOwnedSlice(self.allocator) catch @panic("OOM");
    }
    fn readChar(self: *Lexer) void {
        if (self.read_position >= self.input.len) self.ch = 0 else self.ch = self.input[self.read_position];
        self.position = self.read_position;
        self.read_position += 1;
    }
    fn peekChar(self: *Lexer) u8 {
        if (self.read_position >= self.input.len) return 0;
        return self.input[self.read_position];
    }
    fn skipWhitespace(self: *Lexer) void {
        while (std.ascii.isWhitespace(self.ch)) self.readChar();
    }
    fn nextToken(self: *Lexer) Token {
        self.skipWhitespace();
        var tok: Token = undefined;
        switch (self.ch) {
            '=' => {
                if (self.peekChar() == '=') {
                    self.readChar();
                    tok = .{ .type = .Eq, .literal = "==" };
                } else tok = .{ .type = .Assign, .literal = "=" };
            },
            '+' => tok = .{ .type = .Plus, .literal = "+" },
            '-' => tok = .{ .type = .Minus, .literal = "-" },
            '*' => tok = .{ .type = .Asterisk, .literal = "*" },
            '/' => tok = .{ .type = .Slash, .literal = "/" },
            ';' => tok = .{ .type = .SemiColon, .literal = ";" },
            '(' => tok = .{ .type = .LParen, .literal = "(" },
            ')' => tok = .{ .type = .RParen, .literal = ")" },
            '{' => tok = .{ .type = .LBrace, .literal = "{" },
            '}' => tok = .{ .type = .RBrace, .literal = "}" },
            '!' => {
                if (self.peekChar() == '=') {
                    self.readChar();
                    tok = .{ .type = .NotEq, .literal = "!=" };
                } else tok = .{ .type = .Bang, .literal = "!" };
            },
            '<' => {
                if (self.peekChar() == '=') {
                    self.readChar();
                    tok = .{ .type = .LtEq, .literal = "<=" };
                } else tok = .{ .type = .Lt, .literal = "<" };
            },
            '>' => {
                if (self.peekChar() == '=') {
                    self.readChar();
                    tok = .{ .type = .GtEq, .literal = ">=" };
                } else tok = .{ .type = .Gt, .literal = ">" };
            },
            '"' => tok = if (self.readString()) |s|
                .{ .type = .String, .literal = s }
            else
                .{ .type = .Illegal, .literal = "" },
            0 => tok = .{ .type = .Eof, .literal = "" },
            else => {
                if (std.ascii.isAlphabetic(self.ch)) {
                    const s = self.position;
                    while (std.ascii.isAlphabetic(self.ch) or std.ascii.isDigit(self.ch)) self.readChar();
                    const lit = self.input[s..self.position];
                    if (std.mem.eql(u8, lit, "let")) tok = .{ .type = .Let, .literal = lit } else if (std.mem.eql(u8, lit, "return")) tok = .{ .type = .Return, .literal = lit } else if (std.mem.eql(u8, lit, "if")) tok = .{ .type = .If, .literal = lit } else if (std.mem.eql(u8, lit, "else")) tok = .{ .type = .Else, .literal = lit } else tok = .{ .type = .Ident, .literal = lit };
                    return tok;
                } else if (std.ascii.isDigit(self.ch)) {
                    const s = self.position;
                    while (std.ascii.isDigit(self.ch)) self.readChar();
                    tok = .{ .type = .Int, .literal = self.input[s..self.position] };
                    return tok;
                }
                tok = .{ .type = .Illegal, .literal = "" };
            },
        }
        self.readChar();
        return tok;
    }
};

const Parser = struct {
    l: Lexer,
    cur: Token,
    peek: Token,
    alloc: Allocator,
    fn init(a: Allocator, l: Lexer) Parser {
        var p = Parser{ .l = l, .alloc = a, .cur = undefined, .peek = undefined };
        p.next();
        p.next();
        return p;
    }
    fn next(self: *Parser) void {
        self.cur = self.peek;
        self.peek = self.l.nextToken();
    }

    fn parseProgram(self: *Parser) anyerror![]Stmt {
        var s = std.ArrayList(Stmt).empty;
        while (self.cur.type != .Eof) {
            try s.append(self.alloc, try self.parseStmt());
            self.next();
        }
        return s.toOwnedSlice(self.alloc);
    }

    // UPDATED: Lookahead to distinguish Assign (x = 1) from Expr (x + 1)
    fn parseStmt(self: *Parser) anyerror!Stmt {
        switch (self.cur.type) {
            .Let => return self.parseLet(),
            .Return => return self.parseRet(),
            .If => return self.parseIf(),
            .Ident => {
                if (self.peek.type == .Assign) {
                    return self.parseAssign();
                }
                return self.parseExprStmt();
            },
            else => return self.parseExprStmt(),
        }
    }

    fn parseLet(self: *Parser) anyerror!Stmt {
        self.next();
        const n = self.cur.literal;
        self.next();
        self.next(); // skip name, skip =
        const v = try self.parseExpr();
        if (self.peek.type == .SemiColon) self.next();
        return Stmt{ .Let = .{ .name = n, .value = v } };
    }

    // NEW: Handle assignment
    fn parseAssign(self: *Parser) anyerror!Stmt {
        const n = self.cur.literal; // Store identifier name
        self.next(); // move to =
        self.next(); // move past =
        const v = try self.parseExpr();
        if (self.peek.type == .SemiColon) self.next();
        return Stmt{ .Assign = .{ .name = n, .value = v } };
    }

    fn parseRet(self: *Parser) anyerror!Stmt {
        self.next();
        const v = try self.parseExpr();
        if (self.peek.type == .SemiColon) self.next();
        return Stmt{ .Return = v };
    }
    fn parseExprStmt(self: *Parser) anyerror!Stmt {
        const e = try self.parseExpr();
        if (self.peek.type == .SemiColon) self.next();
        return Stmt{ .Expression = e };
    }
    fn parseIf(self: *Parser) anyerror!Stmt {
        self.next();
        const c = try self.parseExpr();
        self.next();
        const cons = try self.parseBlock();
        var alt: ?[]Stmt = null;
        if (self.peek.type == .Else) {
            self.next();
            self.next();
            alt = try self.parseBlock();
        }
        return Stmt{ .If = .{ .condition = c, .consequence = cons, .alternative = alt } };
    }
    fn parseBlock(self: *Parser) anyerror![]Stmt {
        var s = std.ArrayList(Stmt).empty;
        self.next();
        while (self.cur.type != .RBrace and self.cur.type != .Eof) {
            try s.append(self.alloc, try self.parseStmt());
            self.next();
        }
        return s.toOwnedSlice(self.alloc);
    }

    fn parseExpr(self: *Parser) anyerror!Expr {
        return self.parseEq();
    }

    fn parseEq(self: *Parser) anyerror!Expr {
        var l = try self.parseRel();
        while (self.peek.type == .Eq or self.peek.type == .NotEq) {
            self.next();
            const op: BinaryOp = if (self.cur.type == .Eq) .Eq else .NotEq;
            self.next(); // Advance past operator
            const r = try self.parseRel();
            const lp = try self.alloc.create(Expr);
            lp.* = l;
            const rp = try self.alloc.create(Expr);
            rp.* = r;
            l = Expr{ .Binary = .{ .left = lp, .op = op, .right = rp } };
        }
        return l;
    }

    fn parseRel(self: *Parser) anyerror!Expr {
        var l = try self.parseAdd();
        while (self.peek.type == .Lt or self.peek.type == .Gt or
            self.peek.type == .LtEq or self.peek.type == .GtEq)
        {
            self.next();
            var op: BinaryOp = undefined;
            if (self.cur.type == .Lt) op = .Lt else if (self.cur.type == .Gt) op = .Gt else if (self.cur.type == .LtEq) op = .LtEq else op = .GtEq;
            self.next(); // Advance past operator
            const r = try self.parseAdd();
            const lp = try self.alloc.create(Expr);
            lp.* = l;
            const rp = try self.alloc.create(Expr);
            rp.* = r;
            l = Expr{ .Binary = .{ .left = lp, .op = op, .right = rp } };
        }
        return l;
    }

    fn parseAdd(self: *Parser) anyerror!Expr {
        var l = try self.parseMul();
        while (self.peek.type == .Plus or self.peek.type == .Minus) {
            self.next();
            const op: BinaryOp = if (self.cur.type == .Plus) .Add else .Sub;
            self.next(); // Advance past operator
            const r = try self.parseMul();
            const lp = try self.alloc.create(Expr);
            lp.* = l;
            const rp = try self.alloc.create(Expr);
            rp.* = r;
            l = Expr{ .Binary = .{ .left = lp, .op = op, .right = rp } };
        }
        return l;
    }

    fn parseMul(self: *Parser) anyerror!Expr {
        var l = try self.parsePri();
        while (self.peek.type == .Asterisk or self.peek.type == .Slash) {
            self.next();
            const op: BinaryOp = if (self.cur.type == .Asterisk) .Mul else .Div;
            self.next(); // Advance past operator
            const r = try self.parsePri();
            const lp = try self.alloc.create(Expr);
            lp.* = l;
            const rp = try self.alloc.create(Expr);
            rp.* = r;
            l = Expr{ .Binary = .{ .left = lp, .op = op, .right = rp } };
        }
        return l;
    }

    fn parsePri(self: *Parser) anyerror!Expr {
        switch (self.cur.type) {
            .Int => return Expr{ .Integer = try std.fmt.parseInt(i64, self.cur.literal, 10) },
            .String => return Expr{ .String = self.cur.literal },
            .Ident => return Expr{ .Identifier = self.cur.literal },
            .LParen => {
                self.next();
                const e = try self.parseExpr();
                self.next();
                return e;
            },
            else => return error.UnexpectedToken,
        }
    }
};

// --- AST pretty-printing ---
// printExpr mirrors the default {any} struct-literal rendering, but prints
// []const u8 payloads as text instead of raw byte arrays (so an identifier
// shows as `a` rather than `{ 97 }`). Binary children stay collapsed as
// `.{ ... }`, matching the default formatter's pointer-recursion cutoff.
fn printExpr(expr: Expr) void {
    switch (expr) {
        .Integer => |i| std.debug.print(".{{ .Integer = {d} }}", .{i}),
        .String => |s| std.debug.print(".{{ .String = {s} }}", .{s}),
        .Identifier => |s| std.debug.print(".{{ .Identifier = {s} }}", .{s}),
        .Binary => std.debug.print(".{{ .Binary = .{{ ... }} }}", .{}),
    }
}

fn printStmt(stmt: Stmt) void {
    switch (stmt) {
        .Let => |s| {
            std.debug.print(".{{ .Let = .{{ .name = {s}, .value = ", .{s.name});
            printExpr(s.value);
            std.debug.print(" }} }}", .{});
        },
        .Assign => |s| {
            std.debug.print(".{{ .Assign = .{{ .name = {s}, .value = ", .{s.name});
            printExpr(s.value);
            std.debug.print(" }} }}", .{});
        },
        .Return => |e| {
            std.debug.print(".{{ .Return = ", .{});
            printExpr(e);
            std.debug.print(" }}", .{});
        },
        .Expression => |e| {
            std.debug.print(".{{ .Expression = ", .{});
            printExpr(e);
            std.debug.print(" }}", .{});
        },
        .If => |s| {
            std.debug.print(".{{ .If = .{{ .condition = ", .{});
            printExpr(s.condition);
            std.debug.print(", .consequence = {d} stmt(s)", .{s.consequence.len});
            if (s.alternative) |alt| std.debug.print(", .alternative = {d} stmt(s)", .{alt.len});
            std.debug.print(" }} }}", .{});
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <filename>\n", .{args[0]});
        return;
    }

    const filename = args[1];
    const file = try std.Io.Dir.cwd().openFile(io, filename, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const input = try allocator.alloc(u8, stat.size);
    _ = try file.readPositionalAll(io, input, 0);
    std.debug.print("Running {s}...\n----------------\n", .{filename});

    const l = Lexer.init(allocator, input);
    var p = Parser.init(allocator, l);

    const program = p.parseProgram() catch |err| {
        std.debug.print("Parsing Error: {}\n", .{err});
        return;
    };

    std.debug.print("Parsed AST:\n", .{});
    for (program, 0..) |stmt, i| {
        std.debug.print("Stmt {d}: ", .{i});
        printStmt(stmt);
        std.debug.print("\n", .{});
    }
    std.debug.print("----------------\n", .{});

    var env = Environment.init(allocator);
    var result: RuntimeVal = .Void;

    for (program) |stmt| {
        result = try eval(stmt, &env);
        if (result == .ReturnWrapper) {
            result = result.ReturnWrapper.*;
            break;
        }
    }

    std.debug.print("----------------\nEvaluator Result: ", .{});
    switch (result) {
        .Integer => |i| std.debug.print("{d}\n", .{i}),
        .String => |s| std.debug.print("\"{s}\"\n", .{s}),
        .Boolean => |b| std.debug.print("{}\n", .{b}),
        else => std.debug.print("Void\n", .{}),
    }
}
