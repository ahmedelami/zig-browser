const std = @import("std");
const shared = @import("shared");

const chrome = @import("chrome.zig");
const nav_metrics = @import("nav_metrics.zig");
const nav_support = @import("nav_support.zig");
const nav_types = @import("nav_types.zig");
const ipc_tx = @import("ipc_tx.zig");

const ipc = shared.ipc;
const util = shared.util;

pub fn startNavigation(
    alloc: std.mem.Allocator,
    run_dir: *std.fs.Dir,
    timer: *std.time.Timer,
    navm: *nav_metrics.NavMetrics,
    run_dir_rel: []const u8,
    net: *ipc.Connection,
    renderer: *ipc.Connection,
    renderer_tx: ?*ipc_tx.Tx,
    gpu: *ipc.Connection,
    request_repaint: *const fn () void,
    surface_w_i32: i32,
    surface_h_i32: i32,
    scroll_y: i32,
    url_buf: *std.ArrayList(u8),
    content_dl: *[]u8,
    request_id_counter: *u32,
    frame_id: *u32,
    load: *nav_types.LoadState,
) !void {
    const start_us = nav_metrics.nowUs(timer);
    const debug_nav = util.hasArg("--debug-nav");

    run_dir.deleteFile("nav_done.flag") catch {};

    if (load.active and navm.url.len != 0 and navm.request_id == load.request_id) {
        navm.canceled = true;
        if (debug_nav) std.debug.print("browser: nav cancel t={d}us rid={d} url={s}\n", .{ start_us, navm.request_id, navm.url });
        nav_metrics.writeLast(run_dir, navm, start_us) catch {};
    }

    if (load.active) {
        var cancel_payload: [4]u8 = undefined;
        std.mem.writeInt(u32, cancel_payload[0..4], load.request_id, .little);
        net.send(.net_cancel_request, cancel_payload[0..]) catch {};
    }
    nav_metrics.reset(alloc, navm);

    const request_id = request_id_counter.*;
    request_id_counter.* +%= 1;

    const url_norm = try nav_support.normalizeUrl(alloc, url_buf.items);
    defer alloc.free(url_norm);

    // Reflect canonicalized URL in the address bar.
    url_buf.items.len = 0;
    try url_buf.appendSlice(alloc, url_norm);

    const loading = try chrome.renderPlainTextDisplayList(alloc, "Loading…");
    alloc.free(content_dl.*);
    content_dl.* = loading;
    try chrome.submitComposedFrame(alloc, surface_w_i32, scroll_y, url_buf.items, "loading", content_dl.*, gpu, request_repaint, frame_id.*);
    frame_id.* +%= 1;

    load.* = .{};

    const viewport_w: u32 = @intCast(surface_w_i32);
    const viewport_h_i32: i32 = surface_h_i32 - chrome.content_y_off;
    const viewport_h: u32 = @intCast(@max(1, viewport_h_i32));

    var begin_payload: [12]u8 = undefined;
    std.mem.writeInt(u32, begin_payload[0..4], request_id, .little);
    std.mem.writeInt(u32, begin_payload[4..8], viewport_w, .little);
    std.mem.writeInt(u32, begin_payload[8..12], viewport_h, .little);
    if (renderer_tx) |tx| {
        try tx.send(alloc, .renderer_begin_document, begin_payload[0..]);
    } else {
        try renderer.send(.renderer_begin_document, begin_payload[0..]);
    }
    if (std.mem.startsWith(u8, url_buf.items, "about:")) {
        const html_bytes = try nav_support.loadAboutHtml(alloc, run_dir_rel, url_buf.items);
        defer alloc.free(html_bytes);

        const chunk_payload_len: usize = 8 + html_bytes.len;
        const chunk_payload = try alloc.alloc(u8, chunk_payload_len);
        defer alloc.free(chunk_payload);
        std.mem.writeInt(u32, chunk_payload[0..4], request_id, .little);
        std.mem.writeInt(u32, chunk_payload[4..8], @intCast(html_bytes.len), .little);
        @memcpy(chunk_payload[8..], html_bytes);

        if (renderer_tx) |tx| {
            try tx.send(alloc, .renderer_html_chunk, chunk_payload);
        } else {
            try renderer.send(.renderer_html_chunk, chunk_payload);
        }

        var end_payload: [16]u8 = undefined;
        std.mem.writeInt(u32, end_payload[0..4], request_id, .little);
        std.mem.writeInt(u32, end_payload[4..8], 200, .little);
        std.mem.writeInt(u32, end_payload[8..12], 0, .little);
        std.mem.writeInt(u32, end_payload[12..16], @intCast(@min(html_bytes.len, std.math.maxInt(u32))), .little);
        if (renderer_tx) |tx| {
            try tx.send(alloc, .renderer_end_document, end_payload[0..]);
        } else {
            try renderer.send(.renderer_end_document, end_payload[0..]);
        }

        load.* = .{
            .active = true,
            .request_id = request_id,
            .net_done = true,
            .renderer_done = false,
        };

        navm.request_id = request_id;
        navm.url = try alloc.dupe(u8, url_buf.items);
        navm.start_us = start_us;
        navm.status_code = 200;
        navm.net_source = @intFromEnum(ipc.NetSource.mem_cache);
        navm.net_result = 0;
        navm.total_sent = @intCast(@min(html_bytes.len, std.math.maxInt(u32)));
        navm.net_begin_us = start_us;
        navm.net_end_us = start_us;
        if (debug_nav) std.debug.print("browser: nav start t={d}us rid={d} url={s}\n", .{ start_us, request_id, navm.url });
        return;
    }

    try nav_support.netSendFetchUrl(alloc, net, request_id, url_buf.items);

    load.* = .{
        .active = true,
        .request_id = request_id,
        .net_done = false,
        .renderer_done = false,
    };

    // Start nav metrics for this request id.
    navm.request_id = request_id;
    navm.url = try alloc.dupe(u8, url_buf.items);
    navm.start_us = start_us;
    if (debug_nav) std.debug.print("browser: nav start t={d}us rid={d} url={s}\n", .{ start_us, request_id, navm.url });
}
