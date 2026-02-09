const std = @import("std");

pub const TokenKind = enum(u8) {
    eof,
    invalid,
    ident,
    string,
    number,
    dot,
    l_paren,
    r_paren,
    comma,
    semicolon,
    eq,
};

pub const InvalidKind = enum(u8) {
    invalid_char,
    unterminated_string,
};

pub const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
    invalid: InvalidKind = .invalid_char,
    has_escapes: bool = false, // string literals only
};

pub const Lexer = struct {
    src: []const u8,
    idx: usize = 0,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    pub fn next(self: *Lexer) Token {
        self.skipTrivia();
        const start = self.idx;
        if (start >= self.src.len) return .{ .kind = .eof, .start = start, .end = start };

        const c = self.src[start];
        switch (c) {
            '.' => return self.one(.dot),
            '(' => return self.one(.l_paren),
            ')' => return self.one(.r_paren),
            ',' => return self.one(.comma),
            ';' => return self.one(.semicolon),
            '=' => return self.one(.eq),
            '"' => return self.lexString('"'),
            '\'' => return self.lexString('\''),
            '0'...'9' => return self.lexNumber(),
            else => {
                if (isIdentStart(c)) return self.lexIdent();
                self.idx += 1;
                return .{ .kind = .invalid, .start = start, .end = self.idx, .invalid = .invalid_char };
            },
        }
    }

    fn one(self: *Lexer, kind: TokenKind) Token {
        const start = self.idx;
        self.idx += 1;
        return .{ .kind = kind, .start = start, .end = self.idx };
    }

    fn skipTrivia(self: *Lexer) void {
        while (self.idx < self.src.len) {
            const c = self.src[self.idx];
            if (isSpace(c)) {
                self.idx += 1;
                continue;
            }

            if (c == '/' and self.idx + 1 < self.src.len) {
                const n = self.src[self.idx + 1];
                if (n == '/') {
                    self.idx += 2;
                    while (self.idx < self.src.len and self.src[self.idx] != '\n') self.idx += 1;
                    continue;
                }
                if (n == '*') {
                    self.idx += 2;
                    while (self.idx + 1 < self.src.len) : (self.idx += 1) {
                        if (self.src[self.idx] == '*' and self.src[self.idx + 1] == '/') {
                            self.idx += 2;
                            break;
                        }
                    }
                    continue;
                }
            }

            break;
        }
    }

    fn lexIdent(self: *Lexer) Token {
        const start = self.idx;
        self.idx += 1;
        while (self.idx < self.src.len and isIdentContinue(self.src[self.idx])) self.idx += 1;
        return .{ .kind = .ident, .start = start, .end = self.idx };
    }

    fn lexNumber(self: *Lexer) Token {
        const start = self.idx;
        self.idx += 1;
        while (self.idx < self.src.len) {
            const c = self.src[self.idx];
            if (c < '0' or c > '9') break;
            self.idx += 1;
        }
        return .{ .kind = .number, .start = start, .end = self.idx };
    }

    fn lexString(self: *Lexer, quote: u8) Token {
        const quote_pos = self.idx;
        self.idx += 1;
        const start = self.idx;
        var has_escapes: bool = false;

        while (self.idx < self.src.len) {
            const c = self.src[self.idx];
            if (c == quote) {
                const end = self.idx;
                self.idx += 1;
                return .{ .kind = .string, .start = start, .end = end, .has_escapes = has_escapes };
            }
            if (c == '\\') {
                has_escapes = true;
                self.idx += 1;
                if (self.idx >= self.src.len) break;
                self.idx += 1;
                continue;
            }
            self.idx += 1;
        }

        // Unterminated.
        return .{ .kind = .invalid, .start = quote_pos, .end = self.idx, .invalid = .unterminated_string };
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

