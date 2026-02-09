const std = @import("std");

pub fn resolveHref(alloc: std.mem.Allocator, base_url: []const u8, href_raw: []const u8) ![]u8 {
    const href = std.mem.trim(u8, href_raw, " \t\r\n");
    if (href.len == 0) return try alloc.dupe(u8, base_url);

    // Absolute URLs.
    if (std.mem.startsWith(u8, href, "about:")) return try alloc.dupe(u8, href);
    if (std.mem.indexOf(u8, href, "://") != null) return try alloc.dupe(u8, href);

    const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return try alloc.dupe(u8, href);
    const scheme = base_url[0..scheme_end];
    const rest = base_url[scheme_end + 3 ..];

    const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..auth_end];

    const base_path_full = blk: {
        const after = rest[auth_end..];
        if (after.len == 0) break :blk "/";
        if (after[0] != '/') break :blk "/";
        const path_end = std.mem.indexOfAny(u8, after, "?#") orelse after.len;
        break :blk after[0..path_end];
    };

    // Scheme-relative URLs: //host/path
    if (std.mem.startsWith(u8, href, "//")) {
        return try std.fmt.allocPrint(alloc, "{s}:{s}", .{ scheme, href });
    }

    // Fragment-only: keep current URL (minus old fragment).
    if (href[0] == '#') {
        const base_no_frag = base_url[0 .. std.mem.indexOfScalar(u8, base_url, '#') orelse base_url.len];
        return try std.fmt.allocPrint(alloc, "{s}{s}", .{ base_no_frag, href });
    }

    // Query-only: keep current path and replace query.
    if (href[0] == '?') {
        return try std.fmt.allocPrint(alloc, "{s}://{s}{s}{s}", .{ scheme, authority, base_path_full, href });
    }

    // Absolute path.
    if (href[0] == '/') {
        return try std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ scheme, authority, href });
    }

    // Relative path: join to base directory and normalize dot segments.
    const href_path, const href_suffix = splitPathSuffix(href);

    var base_dir = base_path_full;
    if (!std.mem.endsWith(u8, base_dir, "/")) {
        if (std.mem.lastIndexOfScalar(u8, base_dir, '/')) |p| {
            base_dir = base_dir[0 .. p + 1];
        } else {
            base_dir = "/";
        }
    }

    const joined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ base_dir, href_path });
    defer alloc.free(joined);

    const norm = try normalizePath(alloc, joined);
    defer alloc.free(norm);

    return try std.fmt.allocPrint(alloc, "{s}://{s}{s}{s}", .{ scheme, authority, norm, href_suffix });
}

fn splitPathSuffix(href: []const u8) struct { []const u8, []const u8 } {
    const pos = std.mem.indexOfAny(u8, href, "?#") orelse return .{ href, "" };
    return .{ href[0..pos], href[pos..] };
}

fn normalizePath(alloc: std.mem.Allocator, path_in: []const u8) ![]u8 {
    if (path_in.len == 0) return try alloc.dupe(u8, "/");
    const is_abs = path_in[0] == '/';
    const keep_trailing = std.mem.endsWith(u8, path_in, "/");

    var segs = try std.ArrayList([]const u8).initCapacity(alloc, 16);
    defer segs.deinit(alloc);

    var it = std.mem.splitScalar(u8, path_in, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len != 0) segs.items.len -= 1;
            continue;
        }
        try segs.append(alloc, seg);
    }

    var out = try std.ArrayList(u8).initCapacity(alloc, path_in.len);
    errdefer out.deinit(alloc);

    if (is_abs) try out.append(alloc, '/');
    for (segs.items, 0..) |seg, idx| {
        if (idx != 0) try out.append(alloc, '/');
        try out.appendSlice(alloc, seg);
    }
    if (keep_trailing and (out.items.len == 0 or out.items[out.items.len - 1] != '/')) {
        try out.append(alloc, '/');
    }
    if (out.items.len == 0) try out.append(alloc, '/');

    return out.toOwnedSlice(alloc);
}

test "resolveHref: relative path and query" {
    const alloc = std.testing.allocator;
    const base = "https://example.com/a/b/index.html?x=1#frag";

    const r1 = try resolveHref(alloc, base, "c.html");
    defer alloc.free(r1);
    try std.testing.expectEqualStrings("https://example.com/a/b/c.html", r1);

    const r2 = try resolveHref(alloc, base, "/z");
    defer alloc.free(r2);
    try std.testing.expectEqualStrings("https://example.com/z", r2);

    const r3 = try resolveHref(alloc, base, "?q=1");
    defer alloc.free(r3);
    try std.testing.expectEqualStrings("https://example.com/a/b/index.html?q=1", r3);

    const r4 = try resolveHref(alloc, base, "#top");
    defer alloc.free(r4);
    try std.testing.expectEqualStrings("https://example.com/a/b/index.html?x=1#top", r4);
}

