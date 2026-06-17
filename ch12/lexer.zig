const std = @import("std");

pub const TokenType = enum {
    Illegal,
    Eof,
    Ident,
    Int,
    String,
    Assign,
    Plus,
    Minus,
    Asterisk,
    Slash,
    Bang,
    Lt,
    Gt,
    LtEq,
    GtEq,
    Eq,
    NotEq,
    Comma,
    SemiColon,
    LParen,
    RParen,
    LBrace,
    RBrace,
    Let,
    Return,
    If,
    Else,
};

pub const Token = struct {
    type: TokenType,
    literal: []const u8,
};

pub const Lexer = struct {
    input: []const u8,
    allocator: std.mem.Allocator,
    position: usize = 0,
    read_position: usize = 0,
    ch: u8 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        input: []const u8,
    ) Lexer {
        var l = Lexer{ .input = input, .allocator = allocator };
        l.readChar();
        return l;
    }

    fn readChar(self: *Lexer) void {
        if (self.read_position >= self.input.len) {
            self.ch = 0;
        } else {
            self.ch = self.input[self.read_position];
        }
        self.position = self.read_position;
        self.read_position += 1;
    }

    fn peekChar(self: *Lexer) u8 {
        if (self.read_position >= self.input.len) return 0;
        return self.input[self.read_position];
    }

    fn skipWhitespace(self: *Lexer) void {
        while (std.ascii.isWhitespace(self.ch)) {
            self.readChar();
        }
    }

    fn readIdentifier(self: *Lexer) []const u8 {
        const start = self.position;
        while (std.ascii.isAlphabetic(self.ch) or
            self.ch == '_' or
            std.ascii.isDigit(self.ch))
        {
            self.readChar();
        }
        return self.input[start..self.position];
    }

    fn readNumber(self: *Lexer) []const u8 {
        const start = self.position;
        while (std.ascii.isDigit(self.ch)) {
            self.readChar();
        }
        return self.input[start..self.position];
    }

    // readString consumes a double-quoted string and returns its decoded
    // contents. Backslash escapes are translated explicitly: the byte after
    // a backslash is taken literally (with the usual \n, \t, \r, \0
    // mappings), so an escaped backslash (\\) correctly protects the
    // following quote instead of confusing the terminator search. The
    // caller owns the returned slice.
    fn readString(self: *Lexer) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        self.readChar(); // consume the opening quote
        while (self.ch != '"' and self.ch != 0) {
            if (self.ch == '\\') {
                self.readChar();
                if (self.ch == 0) break; // trailing backslash at EOF
                const decoded: u8 = switch (self.ch) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    // \" \\ and any other escape are literal
                    else => self.ch,
                };
                try buf.append(self.allocator, decoded);
            } else {
                try buf.append(self.allocator, self.ch);
            }
            self.readChar();
        }
        // The loop stops on a closing quote or on end of input.
        // Reaching EOF first means the literal was never closed,
        // e.g. `"hello;` — report it rather than silently returning
        // everything up to EOF as a string.
        if (self.ch != '"') return error.UnterminatedString;
        return buf.toOwnedSlice(self.allocator);
    }

    fn lookupIdent(ident: []const u8) TokenType {
        if (std.mem.eql(u8, ident, "let")) return .Let;
        if (std.mem.eql(u8, ident, "return")) return .Return;
        if (std.mem.eql(u8, ident, "if")) return .If;
        if (std.mem.eql(u8, ident, "else")) return .Else;
        return .Ident;
    }

    pub fn nextToken(self: *Lexer) !Token {
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
            '!' => {
                if (self.peekChar() == '=') {
                    self.readChar();
                    tok = .{ .type = .NotEq, .literal = "!=" };
                } else {
                    tok = .{ .type = .Bang, .literal = "!" };
                }
            },
            '<' => {
                if (self.peekChar() == '=') {
                    self.readChar();
                    tok = .{ .type = .LtEq, .literal = "<=" };
                } else {
                    tok = .{ .type = .Lt, .literal = "<" };
                }
            },
            '>' => {
                if (self.peekChar() == '=') {
                    self.readChar();
                    tok = .{ .type = .GtEq, .literal = ">=" };
                } else {
                    tok = .{ .type = .Gt, .literal = ">" };
                }
            },
            '+' => tok = .{ .type = .Plus, .literal = "+" },
            '-' => tok = .{ .type = .Minus, .literal = "-" },
            '*' => tok = .{ .type = .Asterisk, .literal = "*" },
            '/' => tok = .{ .type = .Slash, .literal = "/" },
            ';' => tok = .{ .type = .SemiColon, .literal = ";" },
            ',' => tok = .{ .type = .Comma, .literal = "," },
            '(' => tok = .{ .type = .LParen, .literal = "(" },
            ')' => tok = .{ .type = .RParen, .literal = ")" },
            '{' => tok = .{ .type = .LBrace, .literal = "{" },
            '}' => tok = .{ .type = .RBrace, .literal = "}" },
            '"' => {
                tok.type = .String;
                tok.literal = try self.readString();
            },
            0 => tok = .{ .type = .Eof, .literal = "" },
            else => {
                if (std.ascii.isAlphabetic(self.ch)) {
                    const literal = self.readIdentifier();
                    tok.type = lookupIdent(literal);
                    tok.literal = literal;
                    return tok;
                } else if (std.ascii.isDigit(self.ch)) {
                    tok.type = .Int;
                    tok.literal = self.readNumber();
                    return tok;
                } else {
                    tok = .{ .type = .Illegal, .literal = "" };
                }
            },
        }
        self.readChar();
        return tok;
    }
};

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

    std.debug.print("Lexing file: {s}\n----------------\n", .{filename});

    var lexer = Lexer.init(allocator, input);

    while (true) {
        const tok = try lexer.nextToken();
        std.debug.print("Type: {any} Literal: {s}\n", .{ tok.type, tok.literal });
        if (tok.type == .Eof) break;
    }
}
