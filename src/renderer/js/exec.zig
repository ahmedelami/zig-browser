const std = @import("std");

const lexer_mod = @import("lexer.zig");
const types = @import("types.zig");

pub fn eval(engine: *types.Engine, source: []const u8) types.EvalResult {
    engine.clearDirty();

    var p: Parser = .{
        .engine = engine,
        .source = source,
        .lexer = lexer_mod.Lexer.init(source),
    };
    const err = p.run();
    return .{ .dirty = engine.dirty, .err = err };
}

const Parser = struct {
    engine: *types.Engine,
    source: []const u8,
    lexer: lexer_mod.Lexer,
    tok: lexer_mod.Token = undefined,

    fn run(self: *Parser) ?types.ErrorInfo {
        self.advance();

        while (self.tok.kind != .eof) {
            if (self.tok.kind == .invalid) {
                if (self.tok.invalid == .unterminated_string) return self.errInvalidToken();
                self.advance();
                continue;
            }

            // Directive prologue or plain string literal statement: treat as no-op.
            if (self.tok.kind == .string) {
                self.advance();
                self.eatOptionalSemicolon();
                continue;
            }

            if (self.tok.kind != .ident) {
                self.advance();
                continue;
            }

            const ident = self.slice(self.tok);
            if (std.mem.eql(u8, ident, "document")) {
                if (self.tryDocumentAssignment()) continue;
                continue;
            }
            if (std.mem.eql(u8, ident, "console")) {
                if (self.tryConsoleLog()) continue;
                continue;
            }
            if (std.mem.eql(u8, ident, "location")) {
                if (self.tryLocationReplace()) continue;
                continue;
            }
            if (std.mem.eql(u8, ident, "window")) {
                if (self.tryWindowLocationReplace()) continue;
                continue;
            }

            self.advance();
        }

        return null;
    }

    fn advance(self: *Parser) void {
        self.tok = self.lexer.next();
    }

    fn slice(self: *const Parser, t: lexer_mod.Token) []const u8 {
        return self.source[t.start..t.end];
    }

    fn eatOptionalSemicolon(self: *Parser) void {
        if (self.tok.kind == .semicolon) self.advance();
    }

    fn errInvalidToken(self: *const Parser) types.ErrorInfo {
        const kind: types.ErrorKind = switch (self.tok.invalid) {
            .unterminated_string => .unterminated_string,
            .invalid_char => .invalid_char,
        };
        return .{ .kind = kind, .pos = self.tok.start };
    }

    fn tryDocumentAssignment(self: *Parser) bool {
        // document.{title|cookie} = "..."
        self.advance(); // consume 'document'
        if (self.tok.kind != .dot) return false;
        self.advance(); // consume '.'
        if (self.tok.kind != .ident) return false;
        const prop = self.slice(self.tok);
        self.advance(); // consume property
        if (self.tok.kind != .eq) return false;
        self.advance(); // consume '='

        if (self.tok.kind != .string) return false;
        const lit: types.StringLit = .{ .bytes = self.slice(self.tok), .has_escapes = self.tok.has_escapes };
        if (std.mem.eql(u8, prop, "title")) {
            self.engine.setTitleLiteral(lit);
        } else if (std.mem.eql(u8, prop, "cookie")) {
            self.engine.setCookieLiteral(lit);
        }
        self.advance(); // consume string
        self.eatOptionalSemicolon();
        return true;
    }

    fn tryConsoleLog(self: *Parser) bool {
        // console.log(...)
        self.advance(); // consume 'console'
        if (self.tok.kind != .dot) return false;
        self.advance(); // consume '.'
        if (self.tok.kind != .ident) return false;
        if (!std.mem.eql(u8, self.slice(self.tok), "log")) return false;
        self.advance(); // consume 'log'
        if (self.tok.kind != .l_paren) return false;
        self.advance(); // consume '('

        var buf: [4096]u8 = undefined;
        var bw = std.fs.File.stderr().writer(&buf);
        defer bw.interface.flush() catch {};
        const w = &bw.interface;
        w.writeAll("js console: ") catch {};

        var first: bool = true;
        var used: usize = 0;
        const max_console_bytes: usize = 2048;

        while (self.tok.kind != .eof and self.tok.kind != .r_paren) {
            if (!first) {
                if (used + 1 > max_console_bytes) break;
                w.writeByte(' ') catch {};
                used += 1;
            }
            first = false;

            if (self.tok.kind == .string) {
                const lit: types.StringLit = .{ .bytes = self.slice(self.tok), .has_escapes = self.tok.has_escapes };
                used += writeStringLiteralBounded(w, lit, max_console_bytes - used) catch 0;
                self.advance();
            } else if (self.tok.kind == .ident and std.mem.eql(u8, self.slice(self.tok), "document")) {
                used += self.writeDocumentTitle(w, max_console_bytes - used) catch 0;
            } else if (self.tok.kind == .number) {
                used += writeTokenBounded(w, self.slice(self.tok), max_console_bytes - used) catch 0;
                self.advance();
            } else {
                // Best-effort: skip unknown tokens.
                self.advance();
            }

            if (self.tok.kind == .comma) {
                self.advance();
                continue;
            }
        }

        if (self.tok.kind == .r_paren) self.advance(); // consume ')'
        self.eatOptionalSemicolon();
        w.writeByte('\n') catch {};
        return true;
    }

    fn tryLocationReplace(self: *Parser) bool {
        // location.replace("...")
        self.advance(); // consume 'location'
        if (self.tok.kind != .dot) return false;
        self.advance(); // consume '.'
        if (self.tok.kind != .ident) return false;
        if (!std.mem.eql(u8, self.slice(self.tok), "replace")) return false;
        self.advance(); // consume 'replace'
        if (self.tok.kind != .l_paren) return false;
        self.advance(); // consume '('
        if (self.tok.kind != .string) return false;
        const lit: types.StringLit = .{ .bytes = self.slice(self.tok), .has_escapes = self.tok.has_escapes };
        self.engine.navigateLiteral(.replace, lit);
        self.advance(); // consume string
        if (self.tok.kind != .r_paren) return false;
        self.advance(); // consume ')'
        self.eatOptionalSemicolon();
        return true;
    }

    fn tryWindowLocationReplace(self: *Parser) bool {
        // window.location.replace("...")
        self.advance(); // consume 'window'
        if (self.tok.kind != .dot) return false;
        self.advance(); // consume '.'
        if (self.tok.kind != .ident) return false;
        if (!std.mem.eql(u8, self.slice(self.tok), "location")) return false;
        self.advance(); // consume 'location'
        if (self.tok.kind != .dot) return false;
        self.advance(); // consume '.'
        if (self.tok.kind != .ident) return false;
        if (!std.mem.eql(u8, self.slice(self.tok), "replace")) return false;
        self.advance(); // consume 'replace'
        if (self.tok.kind != .l_paren) return false;
        self.advance(); // consume '('
        if (self.tok.kind != .string) return false;
        const lit: types.StringLit = .{ .bytes = self.slice(self.tok), .has_escapes = self.tok.has_escapes };
        self.engine.navigateLiteral(.replace, lit);
        self.advance(); // consume string
        if (self.tok.kind != .r_paren) return false;
        self.advance(); // consume ')'
        self.eatOptionalSemicolon();
        return true;
    }

    fn writeDocumentTitle(self: *Parser, w: anytype, max_bytes: usize) !usize {
        // document.title (value only)
        self.advance(); // consume 'document'
        if (self.tok.kind != .dot) return 0;
        self.advance();
        if (self.tok.kind != .ident) return 0;
        if (!std.mem.eql(u8, self.slice(self.tok), "title")) return 0;
        self.advance();
        const t = std.mem.trim(u8, self.engine.getTitle(), " \t\r\n");
        return try writeTokenBounded(w, t, max_bytes);
    }
};

fn writeTokenBounded(w: anytype, bytes: []const u8, max_bytes: usize) !usize {
    const n = @min(bytes.len, max_bytes);
    if (n != 0) try w.writeAll(bytes[0..n]);
    return n;
}

fn writeStringLiteralBounded(w: anytype, lit: types.StringLit, max_bytes: usize) !usize {
    if (!lit.has_escapes) return try writeTokenBounded(w, lit.bytes, max_bytes);

    var used: usize = 0;
    var i: usize = 0;
    while (i < lit.bytes.len and used < max_bytes) {
        const c = lit.bytes[i];
        if (c == '\\' and i + 1 < lit.bytes.len) {
            const e = lit.bytes[i + 1];
            const decoded: u8 = switch (e) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                else => e,
            };
            try w.writeByte(decoded);
            used += 1;
            i += 2;
            continue;
        }
        try w.writeByte(c);
        used += 1;
        i += 1;
    }
    return used;
}
