const std = @import("std");

pub const LinkRect = struct {
    link_index: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub fn hitTest(rects: []const LinkRect, x: i32, y: i32) ?u32 {
    const px: i64 = x;
    const py: i64 = y;
    for (rects) |r| {
        if (r.link_index == 0) continue;
        if (r.w <= 0 or r.h <= 0) continue;

        const x0: i64 = r.x;
        const y0: i64 = r.y;
        const x1: i64 = x0 + r.w;
        const y1: i64 = y0 + r.h;
        if (px >= x0 and px < x1 and py >= y0 and py < y1) return r.link_index;
    }
    return null;
}

test "hitTest basic" {
    const rects: [2]LinkRect = .{
        .{ .link_index = 3, .x = 10, .y = 10, .w = 20, .h = 10 },
        .{ .link_index = 4, .x = 0, .y = 0, .w = 5, .h = 5 },
    };
    try std.testing.expectEqual(@as(?u32, 3), hitTest(&rects, 10, 10));
    try std.testing.expectEqual(@as(?u32, 3), hitTest(&rects, 29, 19));
    try std.testing.expectEqual(@as(?u32, null), hitTest(&rects, 30, 20));
    try std.testing.expectEqual(@as(?u32, 4), hitTest(&rects, 0, 0));
}

