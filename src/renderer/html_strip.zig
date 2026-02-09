const std = @import("std");

pub fn stripToText(alloc: std.mem.Allocator, html: []const u8, max_out: usize) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, @min(html.len, max_out));
    errdefer out.deinit(alloc);

    var in_tag = false;
    var prev_space = false;

    var i: usize = 0;
    while (i < html.len and out.items.len < max_out) : (i += 1) {
        const c = html[i];

        if (in_tag) {
            if (c == '>') in_tag = false;
            continue;
        }

        if (c == '<') {
            in_tag = true;
            continue;
        }

        if (c == '&') {
            if (try decodeEntity(alloc, &out, html, &i)) {
                prev_space = false;
                continue;
            }
        }

        if (isSpace(c)) {
            if (!prev_space and out.items.len != 0) try out.append(alloc, ' ');
            prev_space = true;
            continue;
        }

        prev_space = false;
        try out.append(alloc, c);
    }

    return out.toOwnedSlice(alloc);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn decodeEntity(alloc: std.mem.Allocator, out: *std.ArrayList(u8), html: []const u8, i: *usize) !bool {
    const start = i.*;
    var j = start + 1;
    while (j < html.len and j - start <= 10) : (j += 1) {
        if (html[j] == ';') break;
    }
    if (j >= html.len or html[j] != ';') return false;

    const ent = html[start + 1 .. j];
    const decoded: ?u8 = if (std.mem.eql(u8, ent, "lt")) '<' else if (std.mem.eql(u8, ent, "gt")) '>' else if (std.mem.eql(u8, ent, "amp")) '&' else if (std.mem.eql(u8, ent, "quot")) '"' else if (std.mem.eql(u8, ent, "apos")) '\'' else if (std.mem.eql(u8, ent, "#39")) '\'' else if (std.mem.eql(u8, ent, "nbsp")) ' ' else null;

    if (decoded) |c| {
        try out.append(alloc, c);
        i.* = j;
        return true;
    }

    return false;
}
