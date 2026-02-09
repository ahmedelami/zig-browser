const std = @import("std");

const dom_mod = @import("../dom.zig");

pub const StringLit = struct {
    bytes: []const u8,
    has_escapes: bool = false,
};

pub const ErrorKind = enum(u8) {
    invalid_token,
    unterminated_string,
    invalid_char,
};

pub const ErrorInfo = struct {
    kind: ErrorKind,
    pos: usize,
};

pub const EvalResult = struct {
    dirty: bool = false,
    err: ?ErrorInfo = null,
};

pub const NavMode = enum(u32) {
    push = 0,
    replace = 1,
};

pub const Host = struct {
    ctx: ?*anyopaque = null,
    set_cookie: ?*const fn (ctx: *anyopaque, cookie: []const u8) void = null,
    navigate: ?*const fn (ctx: *anyopaque, mode: NavMode, url: []const u8) void = null,
};

pub const Engine = struct {
    dom: *dom_mod.Dom,
    dirty: bool = false,
    host: Host = .{},

    pub fn init(dom: *dom_mod.Dom) Engine {
        return .{ .dom = dom };
    }

    pub fn setHost(self: *Engine, host: Host) void {
        self.host = host;
    }

    pub fn clearDirty(self: *Engine) void {
        self.dirty = false;
    }

    pub fn setTitleLiteral(self: *Engine, lit: StringLit) void {
        const max_title_bytes: usize = 256;
        self.dom.title.items.len = 0;

        const a = self.dom.alloc();
        var i: usize = 0;
        while (i < lit.bytes.len and self.dom.title.items.len < max_title_bytes) {
            const c = lit.bytes[i];
            if (lit.has_escapes and c == '\\' and i + 1 < lit.bytes.len) {
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
                self.dom.title.append(a, decoded) catch break;
                i += 2;
                continue;
            }

            self.dom.title.append(a, c) catch break;
            i += 1;
        }

        self.dirty = true;
    }

    pub fn getTitle(self: *const Engine) []const u8 {
        return self.dom.title.items;
    }

    pub fn setCookieLiteral(self: *Engine, lit: StringLit) void {
        const cb = self.host.set_cookie orelse return;
        const ctx = self.host.ctx orelse return;

        var buf: [4096]u8 = undefined;
        const cookie = decodeStringLiteralBounded(buf[0..], lit);
        if (cookie.len == 0) return;
        cb(ctx, cookie);
    }

    pub fn navigateLiteral(self: *Engine, mode: NavMode, lit: StringLit) void {
        const cb = self.host.navigate orelse return;
        const ctx = self.host.ctx orelse return;

        var buf: [2048]u8 = undefined;
        const url = decodeStringLiteralBounded(buf[0..], lit);
        if (url.len == 0) return;
        cb(ctx, mode, url);
    }
};

fn decodeStringLiteralBounded(buf: []u8, lit: StringLit) []const u8 {
    if (buf.len == 0) return "";
    if (!lit.has_escapes) return lit.bytes[0..@min(lit.bytes.len, buf.len)];

    var out_len: usize = 0;
    var i: usize = 0;
    while (i < lit.bytes.len and out_len < buf.len) {
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
            buf[out_len] = decoded;
            out_len += 1;
            i += 2;
            continue;
        }
        buf[out_len] = c;
        out_len += 1;
        i += 1;
    }
    return buf[0..out_len];
}
