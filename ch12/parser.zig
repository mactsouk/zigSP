const std = @import("std");
const Allocator = std.mem.Allocator;

// --- AST Definitions ---
const BinaryOp = enum { Add, Sub, Mul, Div, Eq, NotEq, Lt, Gt, LtEq, GtEq };

const Expr = union(enum) {
    Integer: i64,
    String: []const u8,
    Identifier: []const u8,
    Binary: struct { left: *Expr, op: BinaryOp, right: *Expr },
};

const Stmt = union(enum) {
    Let: struct { name: []const u8, value: Expr },
    Assign: struct { name: []const u8, value: Expr }, // Added for assignment support
    Return: Expr,
    Expression: Expr,
    If: struct { condition: Expr, consequence: []Stmt, alternative: ?[]Stmt },
};

// --- Parser ---
const Parser = struct {
    l: Lexer,
    cur_token: Token,
    peek_token: Token,
    allocator: Allocator,

    fn init(allocator: Allocator, l: Lexer) Parser {
        var p = Parser{
            .l = l,
            .allocator = allocator,
            .cur_token = undefined,
            .peek_token = undefined,
        };
        p.nextToken();
        p.nextToken();
        return p;
    }

    fn nextToken(self: *Parser) void {
        self.cur_token = self.peek_token;
        self.peek_token = self.l.nextToken();
    }

    fn expectPeek(self: *Parser, t: TokenType) !void {
        if (self.peek_token.type == t) {
            self.nextToken();
        } else {
            std.debug.print("Expected {any}, got {any}\n", .{ t, self.peek_token.type });
            return error.UnexpectedToken;
        }
    }

    // Explicit anyerror to match the evaluator's fixed recursion handling
    fn parseProgram(self: *Parser) anyerror![]Stmt {
        var statements = std.ArrayList(Stmt).empty;

        while (self.cur_token.type != .Eof) {
            const stmt = try self.parseStatement();
            try statements.append(self.allocator, stmt);
            self.nextToken();
        }
        return statements.toOwnedSlice(self.allocator);
    }

    fn parseStatement(self: *Parser) anyerror!Stmt {
        switch (self.cur_token.type) {
            .Let => return self.parseLetStatement(),
            .Return => return self.parseReturnStatement(),
            .If => return self.parseIfStatement(),
            .Ident => {
                if (self.peek_token.type == .Assign) {
                    return self.parseAssignStatement();
                }
                return self.parseExpressionStatement();
            },
            else => return self.parseExpressionStatement(),
        }
    }

    fn parseLetStatement(self: *Parser) anyerror!Stmt {
        try self.expectPeek(.Ident);
        const name = self.cur_token.literal;
        try self.expectPeek(.Assign);
        self.nextToken();
        const value = try self.parseExpression();
        if (self.peek_token.type == .SemiColon) self.nextToken();
        return Stmt{ .Let = .{ .name = name, .value = value } };
    }

    fn parseAssignStatement(self: *Parser) anyerror!Stmt {
        const name = self.cur_token.literal;
        self.nextToken(); // move to =
        self.nextToken(); // move past =
        const value = try self.parseExpression();
        if (self.peek_token.type == .SemiColon) self.nextToken();
        return Stmt{ .Assign = .{ .name = name, .value = value } };
    }

    fn parseReturnStatement(self: *Parser) anyerror!Stmt {
        self.nextToken();
        const value = try self.parseExpression();
        if (self.peek_token.type == .SemiColon) self.nextToken();
        return Stmt{ .Return = value };
    }

    fn parseExpressionStatement(self: *Parser) anyerror!Stmt {
        const expr = try self.parseExpression();
        if (self.peek_token.type == .SemiColon) self.nextToken();
        return Stmt{ .Expression = expr };
    }

    fn parseIfStatement(self: *Parser) anyerror!Stmt {
        self.nextToken();
        const condition = try self.parseExpression();
        try self.expectPeek(.LBrace);
        const consequence = try self.parseBlock();
        var alternative: ?[]Stmt = null;
        if (self.peek_token.type == .Else) {
            self.nextToken();
            try self.expectPeek(.LBrace);
            alternative = try self.parseBlock();
        }
        return Stmt{ .If = .{
            .condition = condition,
            .consequence = consequence,
            .alternative = alternative,
        } };
    }

    fn parseBlock(self: *Parser) anyerror![]Stmt {
        var stmts = std.ArrayList(Stmt).empty;
        self.nextToken();
        while (self.cur_token.type != .RBrace and self.cur_token.type != .Eof) {
            try stmts.append(self.allocator, try self.parseStatement());
            self.nextToken();
        }
        return stmts.toOwnedSlice(self.allocator);
    }

    fn parseExpression(self: *Parser) anyerror!Expr {
        return self.parseEquality();
    }

    fn parseEquality(self: *Parser) anyerror!Expr {
        var left = try self.parseRelational();
        while (self.peek_token.type == .Eq or self.peek_token.type == .NotEq) {
            self.nextToken();
            const op: BinaryOp = if (self.cur_token.type == .Eq) .Eq else .NotEq;
            self.nextToken(); // Advance past operator
            const right = try self.parseRelational();
            const left_ptr = try self.allocator.create(Expr);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Expr);
            right_ptr.* = right;
            left = Expr{ .Binary = .{ .left = left_ptr, .op = op, .right = right_ptr } };
        }
        return left;
    }

    fn parseRelational(self: *Parser) anyerror!Expr {
        var left = try self.parseAddition();
        while (self.peek_token.type == .Lt or self.peek_token.type == .Gt or
            self.peek_token.type == .LtEq or self.peek_token.type == .GtEq)
        {
            self.nextToken();
            var op: BinaryOp = undefined;
            switch (self.cur_token.type) {
                .Lt => op = .Lt,
                .Gt => op = .Gt,
                .LtEq => op = .LtEq,
                .GtEq => op = .GtEq,
                else => unreachable,
            }
            self.nextToken(); // Advance past operator
            const right = try self.parseAddition();
            const left_ptr = try self.allocator.create(Expr);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Expr);
            right_ptr.* = right;
            left = Expr{ .Binary = .{ .left = left_ptr, .op = op, .right = right_ptr } };
        }
        return left;
    }

    fn parseAddition(self: *Parser) anyerror!Expr {
        var left = try self.parseMultiplication();
        while (self.peek_token.type == .Plus or
            self.peek_token.type == .Minus)
        {
            self.nextToken();
            const op: BinaryOp = if (self.cur_token.type == .Plus)
                .Add
            else
                .Sub;
            self.nextToken(); // Advance past operator
            const right = try self.parseMultiplication();
            const left_ptr = try self.allocator.create(Expr);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Expr);
            right_ptr.* = right;
            left = Expr{
                .Binary = .{ .left = left_ptr, .op = op, .right = right_ptr },
            };
        }
        return left;
    }

    fn parseMultiplication(self: *Parser) anyerror!Expr {
        var left = try self.parsePrimary();
        while (self.peek_token.type == .Asterisk or self.peek_token.type == .Slash) {
            self.nextToken();
            const op: BinaryOp = if (self.cur_token.type == .Asterisk) .Mul else .Div;
            self.nextToken(); // Advance past operator
            const right = try self.parsePrimary();
            const left_ptr = try self.allocator.create(Expr);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Expr);
            right_ptr.* = right;
            left = Expr{ .Binary = .{ .left = left_ptr, .op = op, .right = right_ptr } };
        }
        return left;
    }

    fn parsePrimary(self: *Parser) anyerror!Expr {
        switch (self.cur_token.type) {
            .Int => return Expr{ .Integer = try std.fmt.parseInt(i64, self.cur_token.literal, 10) },
            .String => return Expr{ .String = self.cur_token.literal },
            .Ident => return Expr{ .Identifier = self.cur_token.literal },
            .LParen => {
                self.nextToken();
                const expr = try self.parseExpression();
                try self.expectPeek(.RParen);
                return expr;
            },
            else => return error.UnexpectedToken,
        }
    }
};

// --- Lexer (Included for Autonomy) ---
const TokenType = enum { Illegal, Eof, Ident, Int, String, Assign, Plus, Minus, Asterisk, Slash, Bang, Lt, Gt, LtEq, GtEq, Eq, NotEq, Comma, SemiColon, LParen, RParen, LBrace, RBrace, Let, Return, If, Else };
const Token = struct { type: TokenType, literal: []const u8 };
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
                } else {
                    tok = .{ .type = .Assign, .literal = "=" };
                }
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
            '<' => tok = .{ .type = .Lt, .literal = "<" },
            '>' => tok = .{ .type = .Gt, .literal = ">" },
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

    std.debug.print("Parsing file: {s}\n----------------\n", .{filename});

    const lexer = Lexer.init(allocator, input);
    var parser = Parser.init(allocator, lexer);

    const statements = parser.parseProgram() catch |err| {
        std.debug.print("Parser Error: {}\n", .{err});
        return;
    };

    std.debug.print("Successfully parsed {d} statements.\n", .{statements.len});
    for (statements, 0..) |stmt, i| {
        std.debug.print("Stmt {d}: ", .{i});
        printStmt(stmt);
        std.debug.print("\n", .{});
    }
}
