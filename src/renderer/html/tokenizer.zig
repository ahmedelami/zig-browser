const std = @import("std");

const tag_mod = @import("tag.zig");

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Tokenizer = struct {
    alloc: std.mem.Allocator,
    mode: Mode = .data,

    text_buf: std.ArrayList(u8),

    // Tag parsing.
    tag_is_end: bool = false,
    tag_name: [64]u8 = undefined,
    tag_name_len: usize = 0,
    tag_last_non_space: u8 = 0,
    attrs_buf: std.ArrayList(u8),
    attrs: [16]Attribute = undefined,
    attrs_len: usize = 0,

    // Comment parsing.
    comment_prev2: u8 = 0,
    comment_prev1: u8 = 0,

    // Entity parsing.
    entity: [16]u8 = undefined,
    entity_len: usize = 0,

    // Raw text skipping (script/style).
    skip: Skip = .none,
    pending_lt: bool = false,
    pending_lt_buf: [64]u8 = undefined,
    pending_lt_len: usize = 0,
    pending_lt_is_end: bool = false,
    pending_lt_seen_slash: bool = false,
    pending_lt_raw: [96]u8 = undefined,
    pending_lt_raw_len: usize = 0,
    skip_text_buf: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) !Tokenizer {
        var text_buf = try std.ArrayList(u8).initCapacity(alloc, 4 * 1024);
        errdefer text_buf.deinit(alloc);
        var attrs_buf = try std.ArrayList(u8).initCapacity(alloc, 256);
        errdefer attrs_buf.deinit(alloc);
        var skip_text_buf = try std.ArrayList(u8).initCapacity(alloc, 4 * 1024);
        errdefer skip_text_buf.deinit(alloc);
        return .{ .alloc = alloc, .text_buf = text_buf, .attrs_buf = attrs_buf, .skip_text_buf = skip_text_buf };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.text_buf.deinit(self.alloc);
        self.attrs_buf.deinit(self.alloc);
        self.skip_text_buf.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn reset(self: *Tokenizer) void {
        self.mode = .data;
        self.text_buf.items.len = 0;
        self.tag_is_end = false;
        self.tag_name_len = 0;
        self.tag_last_non_space = 0;
        self.attrs_buf.items.len = 0;
        self.attrs_len = 0;
        self.comment_prev2 = 0;
        self.comment_prev1 = 0;
        self.entity_len = 0;
        self.skip = .none;
        self.pending_lt = false;
        self.pending_lt_len = 0;
        self.pending_lt_is_end = false;
        self.pending_lt_seen_slash = false;
        self.pending_lt_raw_len = 0;
        self.skip_text_buf.items.len = 0;
    }

    pub fn feed(self: *Tokenizer, chunk: []const u8, sink: anytype) !void {
        var i: usize = 0;
        while (i < chunk.len) {
            const c = chunk[i];

            if (self.skip != .none) {
                try self.feedSkip(c, sink);
                i += 1;
                continue;
            }

            switch (self.mode) {
                .data => {
                    if (c == '<') {
                        try self.flushText(sink);
                        self.mode = .tag_open;
                        self.attrs_buf.items.len = 0;
                        self.attrs_len = 0;
                        i += 1;
                        continue;
                    }
                    if (c == '&') {
                        self.mode = .entity;
                        self.entity_len = 0;
                        i += 1;
                        continue;
                    }

                    try self.text_buf.append(self.alloc, c);
                    if (self.text_buf.items.len >= 32 * 1024) try self.flushText(sink);
                    i += 1;
                    continue;
                },
                .tag_open => {
                    if (c == '/') {
                        self.tag_is_end = true;
                        self.tag_name_len = 0;
                        self.attrs_buf.items.len = 0;
                        self.attrs_len = 0;
                        self.mode = .tag_name;
                        i += 1;
                        continue;
                    }
                    if (c == '!') {
                        self.tag_is_end = false;
                        self.mode = .bang;
                        self.comment_prev2 = 0;
                        self.comment_prev1 = 0;
                        i += 1;
                        continue;
                    }
                    if (c == '?') {
                        self.tag_is_end = false;
                        self.mode = .skip_to_gt;
                        i += 1;
                        continue;
                    }

                    self.tag_is_end = false;
                    self.tag_name_len = 0;
                    self.tag_last_non_space = 0;
                    self.attrs_buf.items.len = 0;
                    self.attrs_len = 0;
                    self.mode = .tag_name;
                    // reprocess this char as part of name
                    continue;
                },
                .bang => {
                    // Detect <!-- comment -->. If not a comment, skip until '>'.
                    if (self.comment_prev2 == 0 and self.comment_prev1 == 0 and c == '-') {
                        self.comment_prev1 = '-';
                        i += 1;
                        continue;
                    }
                    if (self.comment_prev2 == 0 and self.comment_prev1 == '-' and c == '-') {
                        self.mode = .comment;
                        self.comment_prev2 = 0;
                        self.comment_prev1 = 0;
                        i += 1;
                        continue;
                    }

                    self.mode = .skip_to_gt;
                    // reprocess in skip
                    continue;
                },
                .comment => {
                    if (self.comment_prev2 == '-' and self.comment_prev1 == '-' and c == '>') {
                        self.mode = .data;
                        self.comment_prev2 = 0;
                        self.comment_prev1 = 0;
                        i += 1;
                        continue;
                    }
                    self.comment_prev2 = self.comment_prev1;
                    self.comment_prev1 = c;
                    i += 1;
                    continue;
                },
                .skip_to_gt => {
                    if (c == '>') self.mode = .data;
                    i += 1;
                    continue;
                },
                .tag_name => {
                    if (c == '>') {
                        const name = self.tag_name[0..self.tag_name_len];
                        if (name.len != 0) {
                            if (self.tag_is_end) {
                                try sink.onEndTag(name);
                            } else {
                                const self_closing = self.tag_last_non_space == '/';
                                try sink.onStartTag(name, self.parseAttrs(), self_closing);
                                self.enterSkipIfNeeded(name);
                            }
                        }
                        self.mode = .data;
                        i += 1;
                        continue;
                    }

                    if (isSpace(c)) {
                        if (self.tag_name_len != 0) {
                            self.mode = .tag_attrs;
                            self.attrs_buf.items.len = 0;
                            self.attrs_len = 0;
                        }
                        i += 1;
                        continue;
                    }

                    if (self.tag_name_len == 0 and !self.tag_is_end and c == '/') {
                        // Handle malformed </> at least without crashing.
                        i += 1;
                        continue;
                    }

                    if (self.tag_name_len < self.tag_name.len and isTagNameChar(c)) {
                        self.tag_name[self.tag_name_len] = std.ascii.toLower(c);
                        self.tag_name_len += 1;
                    }
                    if (!isSpace(c)) self.tag_last_non_space = c;
                    i += 1;
                    continue;
                },
                .tag_attrs => {
                    if (!isSpace(c)) self.tag_last_non_space = c;
                    if (c == '>') {
                        const name = self.tag_name[0..self.tag_name_len];
                        if (name.len != 0) {
                            if (self.tag_is_end) {
                                try sink.onEndTag(name);
                            } else {
                                const self_closing = self.tag_last_non_space == '/';
                                try sink.onStartTag(name, self.parseAttrs(), self_closing);
                                self.enterSkipIfNeeded(name);
                            }
                        }
                        self.mode = .data;
                        self.attrs_buf.items.len = 0;
                        self.attrs_len = 0;
                        i += 1;
                        continue;
                    }

                    if (self.attrs_buf.items.len < 8 * 1024) {
                        try self.attrs_buf.append(self.alloc, c);
                    }
                    i += 1;
                    continue;
                },
                .entity => {
                    if (c == ';') {
                        if (decodeEntity(self.entity[0..self.entity_len])) |decoded| {
                            try self.text_buf.append(self.alloc, decoded);
                        } else {
                            try self.text_buf.append(self.alloc, '&');
                            try self.text_buf.appendSlice(self.alloc, self.entity[0..self.entity_len]);
                            try self.text_buf.append(self.alloc, ';');
                        }
                        self.entity_len = 0;
                        self.mode = .data;
                        i += 1;
                        continue;
                    }

                    if (self.entity_len >= self.entity.len or !isEntityChar(c)) {
                        try self.text_buf.append(self.alloc, '&');
                        try self.text_buf.appendSlice(self.alloc, self.entity[0..self.entity_len]);
                        self.entity_len = 0;
                        self.mode = .data;
                        continue; // reprocess current char in data
                    }

                    self.entity[self.entity_len] = c;
                    self.entity_len += 1;
                    i += 1;
                    continue;
                },
            }
        }

        // Flush plain text at chunk boundaries for progressive rendering. Leave partial entity/tag state intact.
        if (self.mode == .data and self.text_buf.items.len != 0) try self.flushText(sink);
    }

    pub fn finish(self: *Tokenizer, sink: anytype) !void {
        if (self.mode == .entity and self.entity_len != 0) {
            try self.text_buf.append(self.alloc, '&');
            try self.text_buf.appendSlice(self.alloc, self.entity[0..self.entity_len]);
            self.entity_len = 0;
        }
        self.mode = .data;
        if (self.text_buf.items.len != 0) try self.flushText(sink);
        self.skip = .none;
        self.pending_lt = false;
    }

    fn flushText(self: *Tokenizer, sink: anytype) !void {
        if (self.text_buf.items.len == 0) return;
        defer self.text_buf.items.len = 0;
        try sink.onText(self.text_buf.items);
    }

    fn parseAttrs(self: *Tokenizer) []const Attribute {
        self.attrs_len = 0;

        var i: usize = 0;
        const buf = self.attrs_buf.items;
        while (i < buf.len) {
            while (i < buf.len and isSpace(buf[i])) i += 1;
            if (i >= buf.len) break;

            const name_start = i;
            while (i < buf.len and !isSpace(buf[i]) and buf[i] != '=' and buf[i] != '>') i += 1;
            const name_end = i;
            if (name_end == name_start) {
                i += 1;
                continue;
            }

            // Lowercase in-place.
            for (buf[name_start..name_end]) |*b| b.* = std.ascii.toLower(b.*);
            const name = buf[name_start..name_end];
            if (std.mem.eql(u8, name, "/")) continue;

            while (i < buf.len and isSpace(buf[i])) i += 1;

            var value: []const u8 = &.{};
            if (i < buf.len and buf[i] == '=') {
                i += 1;
                while (i < buf.len and isSpace(buf[i])) i += 1;
                if (i < buf.len and (buf[i] == '"' or buf[i] == '\'')) {
                    const quote = buf[i];
                    i += 1;
                    const v_start = i;
                    while (i < buf.len and buf[i] != quote) i += 1;
                    const v_end = i;
                    value = buf[v_start..v_end];
                    if (i < buf.len and buf[i] == quote) i += 1;
                } else {
                    const v_start = i;
                    while (i < buf.len and !isSpace(buf[i]) and buf[i] != '>') i += 1;
                    const v_end = i;
                    value = buf[v_start..v_end];
                }
            }

            if (self.attrs_len < self.attrs.len) {
                self.attrs[self.attrs_len] = .{ .name = name, .value = value };
                self.attrs_len += 1;
            } else break;
        }

        return self.attrs[0..self.attrs_len];
    }

    fn enterSkipIfNeeded(self: *Tokenizer, name_lower: []const u8) void {
        const t = tag_mod.fromNameLower(name_lower);
        self.skip = switch (t) {
            .script => .script,
            .style => .style,
            else => .none,
        };
        self.skip_text_buf.items.len = 0;
        self.pending_lt = false;
        self.pending_lt_len = 0;
        self.pending_lt_is_end = false;
        self.pending_lt_seen_slash = false;
        self.pending_lt_raw_len = 0;
    }

    fn feedSkip(self: *Tokenizer, c: u8, sink: anytype) !void {
        // Only look for </script> or </style> in a very small, chunk-boundary-safe way.
        // For <style> and <script>, we also capture the raw bytes so we can parse/execute later.
        const capture = true;
        const max_skip_text_bytes: usize = 256 * 1024;

        if (!self.pending_lt) {
            if (c == '<') {
                self.pending_lt = true;
                self.pending_lt_len = 0;
                self.pending_lt_is_end = false;
                self.pending_lt_seen_slash = false;
                self.pending_lt_raw_len = 0;
                if (capture and self.pending_lt_raw_len < self.pending_lt_raw.len) {
                    self.pending_lt_raw[self.pending_lt_raw_len] = '<';
                    self.pending_lt_raw_len += 1;
                }
                return;
            }
            if (capture and self.skip_text_buf.items.len < max_skip_text_bytes) {
                self.skip_text_buf.append(self.alloc, c) catch {};
            }
            return;
        }

        if (capture and self.pending_lt_raw_len < self.pending_lt_raw.len) {
            self.pending_lt_raw[self.pending_lt_raw_len] = c;
            self.pending_lt_raw_len += 1;
        }

        if (!self.pending_lt_seen_slash) {
            if (c == '/') {
                self.pending_lt_seen_slash = true;
                self.pending_lt_is_end = true;
                return;
            }
            if (capture and self.skip_text_buf.items.len < max_skip_text_bytes) {
                const remain = max_skip_text_bytes - self.skip_text_buf.items.len;
                const n = @min(remain, self.pending_lt_raw_len);
                if (n != 0) self.skip_text_buf.appendSlice(self.alloc, self.pending_lt_raw[0..n]) catch {};
            }
            self.pending_lt = false;
            self.pending_lt_raw_len = 0;
            return;
        }

        if (c == '>') {
            const name = self.pending_lt_buf[0..self.pending_lt_len];
            const close_tag = switch (self.skip) {
                .script => std.mem.eql(u8, name, "script"),
                .style => std.mem.eql(u8, name, "style"),
                .none => false,
            };
            if (self.pending_lt_is_end and close_tag) {
                if (capture and self.skip_text_buf.items.len != 0) {
                    try sink.onText(self.skip_text_buf.items);
                    self.skip_text_buf.items.len = 0;
                }
                try sink.onEndTag(name);
                self.skip = .none;
            } else if (capture and self.skip_text_buf.items.len < max_skip_text_bytes) {
                const remain = max_skip_text_bytes - self.skip_text_buf.items.len;
                const n = @min(remain, self.pending_lt_raw_len);
                if (n != 0) self.skip_text_buf.appendSlice(self.alloc, self.pending_lt_raw[0..n]) catch {};
            }

            self.pending_lt = false;
            self.pending_lt_raw_len = 0;
            return;
        }

        if (self.pending_lt_len < self.pending_lt_buf.len and isTagNameChar(c)) {
            self.pending_lt_buf[self.pending_lt_len] = std.ascii.toLower(c);
            self.pending_lt_len += 1;
        } else if (!isSpace(c)) {
            if (capture and self.skip_text_buf.items.len < max_skip_text_bytes) {
                const remain = max_skip_text_bytes - self.skip_text_buf.items.len;
                const n = @min(remain, self.pending_lt_raw_len);
                if (n != 0) self.skip_text_buf.appendSlice(self.alloc, self.pending_lt_raw[0..n]) catch {};
            }
            self.pending_lt = false;
            self.pending_lt_raw_len = 0;
        }
    }
};

const Mode = enum { data, tag_open, bang, comment, skip_to_gt, tag_name, tag_attrs, entity };
const Skip = enum { none, script, style };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn isTagNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn isEntityChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '#' or c == 'x' or c == 'X';
}

fn decodeEntity(ent_raw: []const u8) ?u8 {
    if (ent_raw.len == 0) return null;

    if (ent_raw[0] == '#') {
        if (ent_raw.len >= 2 and (ent_raw[1] == 'x' or ent_raw[1] == 'X')) {
            const n = parseInt(u32, ent_raw[2..], 16) orelse return null;
            return toAsciiOrQuestion(n);
        }
        const n = parseInt(u32, ent_raw[1..], 10) orelse return null;
        return toAsciiOrQuestion(n);
    }

    var lower: [16]u8 = undefined;
    const n = @min(ent_raw.len, lower.len);
    for (ent_raw[0..n], 0..) |c, idx| lower[idx] = std.ascii.toLower(c);
    const ent = lower[0..n];

    if (std.mem.eql(u8, ent, "lt")) return '<';
    if (std.mem.eql(u8, ent, "gt")) return '>';
    if (std.mem.eql(u8, ent, "amp")) return '&';
    if (std.mem.eql(u8, ent, "quot")) return '"';
    if (std.mem.eql(u8, ent, "apos")) return '\'';
    if (std.mem.eql(u8, ent, "nbsp")) return ' ';
    if (std.mem.eql(u8, ent, "#39")) return '\'';
    return null;
}

fn toAsciiOrQuestion(n: u32) u8 {
    if (n <= 0x7F) return @intCast(n);
    if (n == 0xA0) return ' ';
    return '?';
}

fn parseInt(comptime T: type, s: []const u8, base: u8) ?T {
    if (s.len == 0) return null;
    var v: T = 0;
    for (s) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        if (d >= base) return null;
        v = v * @as(T, @intCast(base)) + @as(T, @intCast(d));
    }
    return v;
}

test "tokenizer: chunk boundary in tag" {
    const alloc = std.testing.allocator;
    var t = try Tokenizer.init(alloc);
    defer t.deinit();

    const Sink = struct {
        saw_p: bool = false,
        pub fn onStartTag(self: *@This(), name: []const u8, _: []const Attribute, _: bool) !void {
            if (std.mem.eql(u8, name, "p")) self.saw_p = true;
        }
        pub fn onEndTag(_: *@This(), _: []const u8) !void {}
        pub fn onText(_: *@This(), _: []const u8) !void {}
    };

    var s: Sink = .{};
    try t.feed("<p", &s);
    try t.feed(">", &s);
    try std.testing.expect(s.saw_p);
}

test "tokenizer: entity across chunks" {
    const alloc = std.testing.allocator;
    var t = try Tokenizer.init(alloc);
    defer t.deinit();

    const Sink = struct {
        out: std.ArrayList(u8),
        pub fn init(a: std.mem.Allocator) !@This() {
            return .{ .out = try std.ArrayList(u8).initCapacity(a, 64) };
        }
        pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
            self.out.deinit(a);
        }
        pub fn onStartTag(_: *@This(), _: []const u8, _: []const Attribute, _: bool) !void {}
        pub fn onEndTag(_: *@This(), _: []const u8) !void {}
        pub fn onText(self: *@This(), bytes: []const u8) !void {
            try self.out.appendSlice(std.testing.allocator, bytes);
        }
    };

    var s = try Sink.init(alloc);
    defer s.deinit(alloc);

    try t.feed("a &a", &s);
    try t.feed("mp; b", &s);
    try t.finish(&s);
    try std.testing.expectEqualStrings("a & b", s.out.items);
}
