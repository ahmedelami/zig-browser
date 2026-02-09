const std = @import("std");

pub const NavMetrics = struct {
    request_id: u32 = 0,
    url: []u8 = &.{},
    start_us: u64 = 0,

    status_code: u32 = 0,
    net_source: u32 = 0,
    net_result: u32 = 0,
    total_sent: u32 = 0,
    canceled: bool = false,

    net_begin_us: ?u64 = null,
    first_display_list_us: ?u64 = null,
    first_frame_ready_us: ?u64 = null,
    net_end_us: ?u64 = null,
    renderer_done_us: ?u64 = null,
};

pub fn nowUs(timer: *std.time.Timer) u64 {
    return timer.read() / std.time.ns_per_us;
}

pub fn reset(alloc: std.mem.Allocator, nav: *NavMetrics) void {
    if (nav.url.len != 0) alloc.free(nav.url);
    nav.* = .{};
}

fn relUs(start_us: u64, ts_us: ?u64) ?u64 {
    const t = ts_us orelse return null;
    if (t < start_us) return 0;
    return t - start_us;
}

pub fn writeLast(dir: *std.fs.Dir, nav: *const NavMetrics, done_us: u64) !void {
    const Out = struct {
        url: []const u8,
        request_id: u32,
        canceled: bool,
        status_code: u32,
        net_source: u32,
        net_result: u32,
        total_sent: u32,
        net_begin_us: ?u64,
        first_display_list_us: ?u64,
        first_frame_ready_us: ?u64,
        net_end_us: ?u64,
        renderer_done_us: ?u64,
        done_us: u64,
    };

    const start = nav.start_us;
    const out = Out{
        .url = nav.url,
        .request_id = nav.request_id,
        .canceled = nav.canceled,
        .status_code = nav.status_code,
        .net_source = nav.net_source,
        .net_result = nav.net_result,
        .total_sent = nav.total_sent,
        .net_begin_us = relUs(start, nav.net_begin_us),
        .first_display_list_us = relUs(start, nav.first_display_list_us),
        .first_frame_ready_us = relUs(start, nav.first_frame_ready_us),
        .net_end_us = relUs(start, nav.net_end_us),
        .renderer_done_us = relUs(start, nav.renderer_done_us),
        .done_us = if (done_us < start) 0 else done_us - start,
    };

    const file = try dir.createFile("nav_last.json", .{ .truncate = true });
    defer file.close();

    var buf: [8 * 1024]u8 = undefined;
    var fw = file.writer(&buf);
    defer fw.interface.flush() catch {};

    try std.json.Stringify.value(out, .{ .whitespace = .indent_2 }, &fw.interface);
    try fw.interface.writeAll("\n");

    if (!nav.canceled and nav.net_end_us != null and nav.renderer_done_us != null) {
        const done = try dir.createFile("nav_done.flag", .{ .truncate = true });
        done.close();
    }
}
