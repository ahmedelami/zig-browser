const std = @import("std");

pub fn decodeHtmlEntitiesAlloc(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return try alloc.dupe(u8, raw);

    // HTML entities always decode to <= original bytes length for valid inputs
    // (e.g. "&amp;" -> "&", "&#x1F600;" -> 4 bytes).
    const tmp = try alloc.alloc(u8, raw.len);
    errdefer alloc.free(tmp);

    var ri: usize = 0;
    var wi: usize = 0;
    while (ri < raw.len) {
        const c = raw[ri];
        if (c != '&') {
            tmp[wi] = c;
            wi += 1;
            ri += 1;
            continue;
        }

        const semi = std.mem.indexOfScalarPos(u8, raw, ri + 1, ';') orelse {
            tmp[wi] = '&';
            wi += 1;
            ri += 1;
            continue;
        };
        const ent = raw[ri + 1 .. semi];
        if (decodeEntity(ent, tmp[wi..])) |n| {
            wi += n;
            ri = semi + 1;
            continue;
        }

        // Unknown or invalid entity: preserve literal bytes.
        const lit_len = semi - ri + 1;
        @memcpy(tmp[wi..][0..lit_len], raw[ri .. semi + 1]);
        wi += lit_len;
        ri = semi + 1;
    }

    if (wi == tmp.len) return tmp;
    const out = try alloc.dupe(u8, tmp[0..wi]);
    alloc.free(tmp);
    return out;
}

fn decodeEntity(ent_raw: []const u8, dst: []u8) ?usize {
    if (ent_raw.len == 0) return null;

    if (ent_raw[0] == '#') {
        const cp_u32 = if (ent_raw.len >= 2 and (ent_raw[1] == 'x' or ent_raw[1] == 'X'))
            parseInt(u32, ent_raw[2..], 16) orelse return null
        else
            parseInt(u32, ent_raw[1..], 10) orelse return null;

        if (cp_u32 > 0x10FFFF) return null;
        if (cp_u32 >= 0xD800 and cp_u32 <= 0xDFFF) return null; // surrogate range
        const cp: u21 = @intCast(cp_u32);
        return utf8Encode(cp, dst);
    }

    // ASCII-only named entities we care about for URLs/attrs.
    var lower_buf: [16]u8 = undefined;
    const n = @min(ent_raw.len, lower_buf.len);
    for (ent_raw[0..n], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const ent = lower_buf[0..n];

    if (std.mem.eql(u8, ent, "amp")) return writeByte(dst, '&');
    if (std.mem.eql(u8, ent, "lt")) return writeByte(dst, '<');
    if (std.mem.eql(u8, ent, "gt")) return writeByte(dst, '>');
    if (std.mem.eql(u8, ent, "quot")) return writeByte(dst, '"');
    if (std.mem.eql(u8, ent, "apos")) return writeByte(dst, '\'');
    if (std.mem.eql(u8, ent, "nbsp")) return writeByte(dst, ' ');
    if (std.mem.eql(u8, ent, "#39")) return writeByte(dst, '\'');
    return null;
}

fn writeByte(dst: []u8, b: u8) ?usize {
    if (dst.len == 0) return null;
    dst[0] = b;
    return 1;
}

fn utf8Encode(cp: u21, dst: []u8) ?usize {
    if (cp <= 0x7F) {
        if (dst.len < 1) return null;
        dst[0] = @intCast(cp);
        return 1;
    }
    if (cp <= 0x7FF) {
        if (dst.len < 2) return null;
        dst[0] = @intCast(0xC0 | (cp >> 6));
        dst[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp <= 0xFFFF) {
        if (dst.len < 3) return null;
        dst[0] = @intCast(0xE0 | (cp >> 12));
        dst[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dst[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    if (cp <= 0x10FFFF) {
        if (dst.len < 4) return null;
        dst[0] = @intCast(0xF0 | (cp >> 18));
        dst[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        dst[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dst[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
    return null;
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

test "entities: decode attribute entities" {
    const alloc = std.testing.allocator;
    {
        const out = try decodeHtmlEntitiesAlloc(alloc, "a&amp;b");
        defer alloc.free(out);
        try std.testing.expectEqualStrings("a&b", out);
    }
    {
        const out = try decodeHtmlEntitiesAlloc(alloc, "x&#38;y");
        defer alloc.free(out);
        try std.testing.expectEqualStrings("x&y", out);
    }
    {
        const out = try decodeHtmlEntitiesAlloc(alloc, "x&#x26;y");
        defer alloc.free(out);
        try std.testing.expectEqualStrings("x&y", out);
    }
    {
        const out = try decodeHtmlEntitiesAlloc(alloc, "no-entities");
        defer alloc.free(out);
        try std.testing.expectEqualStrings("no-entities", out);
    }
    {
        const out = try decodeHtmlEntitiesAlloc(alloc, "bad &bogus; ok");
        defer alloc.free(out);
        try std.testing.expectEqualStrings("bad &bogus; ok", out);
    }
}
