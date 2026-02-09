const std = @import("std");

pub const Stream = struct {
    alloc: std.mem.Allocator,
    max_out: usize,
    out: std.ArrayList(u8),
    truncated: bool = false,

    mode: Mode = .data,
    skip: Skip = .none,
    prev_space: bool = false,

    // Tag parsing state (while mode == .tag).
    tag_is_end: bool = false,
    tag_seen_bang: bool = false,
    tag_bang_dashes: u2 = 0,
    tag_name: [24]u8 = undefined,
    tag_name_len: usize = 0,
    tag_name_done: bool = false,
    tag_self_closing: bool = false,

    // Entity parsing state (while mode == .entity).
    entity: [16]u8 = undefined,
    entity_len: usize = 0,

    // Comment scanning state (while mode == .comment).
    comment_prev2: u8 = 0,
    comment_prev1: u8 = 0,

    pub fn init(alloc: std.mem.Allocator, max_out: usize) !Stream {
        var out = try std.ArrayList(u8).initCapacity(alloc, @min(max_out, 16 * 1024));
        errdefer out.deinit(alloc);
        return .{ .alloc = alloc, .max_out = max_out, .out = out };
    }

    pub fn deinit(self: *Stream) void {
        self.out.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn reset(self: *Stream) void {
        self.out.items.len = 0;
        self.truncated = false;
        self.mode = .data;
        self.skip = .none;
        self.prev_space = false;
        self.resetTagState();
        self.resetEntityState();
        self.resetCommentState();
    }

    pub fn bytes(self: *const Stream) []const u8 {
        return self.out.items;
    }

    pub fn feed(self: *Stream, chunk: []const u8) !void {
        if (self.truncated) return;

        var i: usize = 0;
        while (i < chunk.len) {
            const c = chunk[i];

            switch (self.mode) {
                .data => {
                    if (self.skip != .none) {
                        if (c == '<') {
                            self.startTag();
                            i += 1;
                            continue;
                        }
                        i += 1;
                        continue;
                    }

                    if (c == '<') {
                        self.startTag();
                        i += 1;
                        continue;
                    }

                    if (c == '&') {
                        self.startEntity();
                        i += 1;
                        continue;
                    }

                    if (isSpace(c)) {
                        try self.appendSpace();
                        i += 1;
                        continue;
                    }

                    try self.appendByte(c);
                    i += 1;
                    continue;
                },
                .tag => {
                    if (c == '>') {
                        try self.finishTag();
                        self.mode = .data;
                        i += 1;
                        continue;
                    }

                    if (self.tag_seen_bang and self.tag_name_len == 0 and !self.tag_name_done) {
                        if (self.tag_bang_dashes < 2) {
                            if (c == '-') {
                                self.tag_bang_dashes += 1;
                                if (self.tag_bang_dashes == 2) {
                                    // <!-- ... -->
                                    self.mode = .comment;
                                    self.resetCommentState();
                                }
                                i += 1;
                                continue;
                            }
                            // Not a comment, treat as a special tag and ignore until '>'.
                            self.tag_name_done = true;
                            i += 1;
                            continue;
                        }
                    }

                    if (!self.tag_name_done) {
                        if (self.tag_name_len == 0 and !self.tag_is_end and !self.tag_seen_bang) {
                            if (c == '/') {
                                self.tag_is_end = true;
                                i += 1;
                                continue;
                            }
                            if (c == '!') {
                                self.tag_seen_bang = true;
                                self.tag_bang_dashes = 0;
                                i += 1;
                                continue;
                            }
                            if (c == '?') {
                                // Processing instruction.
                                self.tag_name_done = true;
                                i += 1;
                                continue;
                            }
                        }

                        if (isSpace(c)) {
                            if (self.tag_name_len != 0) self.tag_name_done = true;
                            i += 1;
                            continue;
                        }

                        if (c == '/') {
                            if (self.tag_name_len != 0) {
                                self.tag_self_closing = true;
                                self.tag_name_done = true;
                            }
                            i += 1;
                            continue;
                        }

                        if (isTagNameChar(c)) {
                            if (self.tag_name_len < self.tag_name.len) {
                                self.tag_name[self.tag_name_len] = std.ascii.toLower(c);
                                self.tag_name_len += 1;
                            }
                            i += 1;
                            continue;
                        }

                        // Anything else ends the tag name; ignore the rest until '>'.
                        if (self.tag_name_len != 0) self.tag_name_done = true;
                        i += 1;
                        continue;
                    }

                    if (c == '/') self.tag_self_closing = true;
                    i += 1;
                    continue;
                },
                .entity => {
                    if (c == ';') {
                        try self.finishEntity();
                        self.mode = .data;
                        i += 1;
                        continue;
                    }

                    if (self.entity_len >= self.entity.len or !isEntityChar(c)) {
                        try self.flushEntityLiteral();
                        self.mode = .data;
                        // Reprocess this character in data mode.
                        continue;
                    }

                    self.entity[self.entity_len] = c;
                    self.entity_len += 1;
                    i += 1;
                    continue;
                },
                .comment => {
                    if (self.comment_prev2 == '-' and self.comment_prev1 == '-' and c == '>') {
                        self.mode = .data;
                        self.resetTagState();
                        self.resetCommentState();
                        i += 1;
                        continue;
                    }

                    self.comment_prev2 = self.comment_prev1;
                    self.comment_prev1 = c;
                    i += 1;
                    continue;
                },
            }
        }
    }

    fn appendByte(self: *Stream, c: u8) !void {
        if (self.out.items.len >= self.max_out) {
            self.truncated = true;
            return;
        }
        self.prev_space = false;
        try self.out.append(self.alloc, c);
    }

    fn appendLiteral(self: *Stream, literal: []const u8) !void {
        for (literal) |b| {
            try self.appendByte(b);
            if (self.truncated) return;
        }
    }

    fn appendSpace(self: *Stream) !void {
        if (self.out.items.len == 0) return;
        const last = self.out.items[self.out.items.len - 1];
        if (last == '\n') return;
        if (self.prev_space) return;
        try self.appendByte(' ');
        self.prev_space = true;
    }

    fn appendLineBreak(self: *Stream, count: u8) !void {
        if (self.out.items.len == 0) return;

        // Trim trailing spaces before breaking.
        while (self.out.items.len != 0 and self.out.items[self.out.items.len - 1] == ' ') {
            self.out.items.len -= 1;
        }
        if (self.out.items.len == 0) return;

        // Ensure at most two newlines, and at least `count` newlines.
        var nl_run: u8 = 0;
        var j: usize = self.out.items.len;
        while (j != 0) {
            const ch = self.out.items[j - 1];
            if (ch != '\n') break;
            nl_run += 1;
            if (nl_run == 2) break;
            j -= 1;
        }

        const want: u8 = @min(count, 2);
        if (nl_run >= want) return;
        try self.appendByte('\n');
        if (want == 2 and nl_run == 0) try self.appendByte('\n');
    }

    fn startTag(self: *Stream) void {
        self.mode = .tag;
        self.resetTagState();
    }

    fn resetTagState(self: *Stream) void {
        self.tag_is_end = false;
        self.tag_seen_bang = false;
        self.tag_bang_dashes = 0;
        self.tag_name_len = 0;
        self.tag_name_done = false;
        self.tag_self_closing = false;
    }

    fn finishTag(self: *Stream) !void {
        defer self.resetTagState();

        if (self.tag_name_len == 0) return;
        const name = self.tag_name[0..self.tag_name_len];

        if (self.skip != .none) {
            if (self.tag_is_end) {
                if (self.skip == .script and std.mem.eql(u8, name, "script")) self.skip = .none;
                if (self.skip == .style and std.mem.eql(u8, name, "style")) self.skip = .none;
            }
            return;
        }

        if (!self.tag_is_end) {
            if (std.mem.eql(u8, name, "script")) {
                try self.appendSpace();
                self.skip = .script;
                return;
            }
            if (std.mem.eql(u8, name, "style")) {
                try self.appendSpace();
                self.skip = .style;
                return;
            }
        }

        // Minimal semantics for readability in text rendering.
        if (std.mem.eql(u8, name, "br")) {
            try self.appendLineBreak(1);
            return;
        }

        if (!self.tag_is_end and std.mem.eql(u8, name, "li")) {
            try self.appendLineBreak(1);
            try self.appendLiteral("- ");
            return;
        }

        if (isBlockTag(name)) {
            // Use 2 newlines for block boundaries.
            try self.appendLineBreak(2);
        }
    }

    fn startEntity(self: *Stream) void {
        self.mode = .entity;
        self.resetEntityState();
    }

    fn resetEntityState(self: *Stream) void {
        self.entity_len = 0;
    }

    fn finishEntity(self: *Stream) !void {
        const ent = self.entity[0..self.entity_len];
        if (decodeEntity(ent)) |decoded| {
            if (decoded == ' ') {
                try self.appendSpace();
            } else {
                try self.appendByte(decoded);
            }
        } else {
            try self.appendByte('&');
            try self.appendLiteral(ent);
            try self.appendByte(';');
        }
        self.resetEntityState();
    }

    fn flushEntityLiteral(self: *Stream) !void {
        try self.appendByte('&');
        try self.appendLiteral(self.entity[0..self.entity_len]);
        self.resetEntityState();
    }

    fn resetCommentState(self: *Stream) void {
        self.comment_prev2 = 0;
        self.comment_prev1 = 0;
    }

    fn decodeEntity(ent_raw: []const u8) ?u8 {
        if (ent_raw.len == 0) return null;

        // Numeric entities: &#123; or &#x1f;
        if (ent_raw[0] == '#') {
            if (ent_raw.len >= 2 and (ent_raw[1] == 'x' or ent_raw[1] == 'X')) {
                const n = parseInt(u32, ent_raw[2..], 16) orelse return null;
                return toAsciiOrQuestion(n);
            }
            const n = parseInt(u32, ent_raw[1..], 10) orelse return null;
            return toAsciiOrQuestion(n);
        }

        // Named entities (common subset).
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
        if (n == 0xA0) return ' '; // nbsp
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

    fn isBlockTag(name: []const u8) bool {
        // Keep this list small and targeted; real layout comes later.
        return std.mem.eql(u8, name, "p") or
            std.mem.eql(u8, name, "div") or
            std.mem.eql(u8, name, "section") or
            std.mem.eql(u8, name, "article") or
            std.mem.eql(u8, name, "header") or
            std.mem.eql(u8, name, "footer") or
            std.mem.eql(u8, name, "nav") or
            std.mem.eql(u8, name, "main") or
            std.mem.eql(u8, name, "aside") or
            std.mem.eql(u8, name, "h1") or
            std.mem.eql(u8, name, "h2") or
            std.mem.eql(u8, name, "h3") or
            std.mem.eql(u8, name, "h4") or
            std.mem.eql(u8, name, "h5") or
            std.mem.eql(u8, name, "h6") or
            std.mem.eql(u8, name, "ul") or
            std.mem.eql(u8, name, "ol") or
            std.mem.eql(u8, name, "pre") or
            std.mem.eql(u8, name, "blockquote") or
            std.mem.eql(u8, name, "table") or
            std.mem.eql(u8, name, "tr") or
            std.mem.eql(u8, name, "hr");
    }
};

const Mode = enum { data, tag, entity, comment };
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

test "stream: entities across chunk boundaries" {
    const alloc = std.testing.allocator;
    var s = try Stream.init(alloc, 1024);
    defer s.deinit();

    try s.feed("hello &a");
    try s.feed("mp; world");
    try std.testing.expectEqualStrings("hello & world", s.bytes());
}

test "stream: tag boundary across chunks" {
    const alloc = std.testing.allocator;
    var s = try Stream.init(alloc, 1024);
    defer s.deinit();

    try s.feed("<div>hi");
    try s.feed("</div>");
    try std.testing.expect(std.mem.indexOf(u8, s.bytes(), "hi") != null);
}

test "stream: skips script contents" {
    const alloc = std.testing.allocator;
    var s = try Stream.init(alloc, 1024);
    defer s.deinit();

    try s.feed("a<script>var x=1</script>b");
    try std.testing.expectEqualStrings("a b", std.mem.trim(u8, s.bytes(), " \n"));
}
