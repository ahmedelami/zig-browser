const std = @import("std");
const shared = @import("shared");

const display_list = shared.display_list;

pub const Link = struct {
    index: u32,
    href: []u8,
};

pub fn clear(alloc: std.mem.Allocator, links: *std.ArrayList(Link)) void {
    for (links.items) |l| alloc.free(l.href);
    links.items.len = 0;
}

pub fn findHref(links: []const Link, index: u32) ?[]const u8 {
    for (links) |l| {
        if (l.index == index) return l.href;
    }
    return null;
}

pub fn renderLinksDisplayList(alloc: std.mem.Allocator, base_url: []const u8, links: []const Link) ![]u8 {
    var dl = try display_list.Builder.init(alloc);
    defer dl.deinit();
    try dl.clear(0xFF111418);

    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "links={d} base={s}", .{ links.len, base_url }) catch "links";
    try dl.text(16, 16, 0xFF9AA4B2, header);

    var y: i32 = 32;
    var shown: usize = 0;
    for (links) |l| {
        if (shown >= 200) break;
        var line_buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "[{d}] {s}", .{ l.index, l.href }) catch continue;
        try dl.text(16, y, 0xFF61AFEF, line);
        y += 10;
        shown += 1;
    }
    if (links.len > shown) {
        try dl.text(16, y, 0xFF9AA4B2, "… (truncated)");
    }

    return try dl.finish();
}

