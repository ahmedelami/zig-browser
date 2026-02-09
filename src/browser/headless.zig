const std = @import("std");
const shared = @import("shared");

const chrome = @import("chrome.zig");
const nav_metrics = @import("nav_metrics.zig");
const nav_start = @import("nav_start.zig");
const nav_support = @import("nav_support.zig");
const nav_types = @import("nav_types.zig");
const nav_resources = @import("nav_resources.zig");
const url_mod = @import("url.zig");
const ipc_tx = @import("ipc_tx.zig");

const ipc = shared.ipc;
const LoadState = nav_types.LoadState;

const ResourceRoute = nav_resources.ResourceRoute;

pub const Result = enum { nav_complete, timeout, end_of_stream };

pub fn run(
    alloc: std.mem.Allocator,
    run_dir: *std.fs.Dir,
    nav_timer: *std.time.Timer,
    run_dir_rel: []const u8,
    initial_url: []const u8,
    surface_w_i32: i32,
    surface_h_i32: i32,
    net: *ipc.Connection,
    renderer: *ipc.Connection,
    gpu: *ipc.Connection,
    timeout_ms: u64,
) !Result {
    var url_buf = try std.ArrayList(u8).initCapacity(alloc, 256);
    defer url_buf.deinit(alloc);
    try url_buf.appendSlice(alloc, initial_url);

    var content_dl = try chrome.renderPlainTextDisplayList(alloc, "Loading…");
    defer alloc.free(content_dl);

    const scroll_y: i32 = 0;
    var request_id: u32 = 100;
    var frame_id: u32 = 1;

    var load: LoadState = .{};
    var navm: nav_metrics.NavMetrics = .{};
    defer nav_metrics.reset(alloc, &navm);

    var resources = try std.ArrayList(ResourceRoute).initCapacity(alloc, 16);
    defer resources.deinit(alloc);

    var renderer_tx: ipc_tx.Tx = .{ .fd = renderer.stream.handle };
    defer renderer_tx.deinit(alloc);
    const max_renderer_pending: usize = 4 * 1024 * 1024;

    try nav_start.startNavigation(
        alloc,
        run_dir,
        nav_timer,
        &navm,
        run_dir_rel,
        net,
        renderer,
        &renderer_tx,
        gpu,
        noopRepaint,
        surface_w_i32,
        surface_h_i32,
        scroll_y,
        &url_buf,
        &content_dl,
        &request_id,
        &frame_id,
        &load,
    );

    var wall_timer = std.time.Timer.start() catch return .timeout;
    const timeout_ns: u64 = timeout_ms * std.time.ns_per_ms;

    const hup_mask = std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;
    var pollfds: [2]std.posix.pollfd = .{
        .{ .fd = net.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = renderer.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        if (load.active and load.net_done and load.renderer_done) {
            load.active = false;
            const done_us = nav_metrics.nowUs(nav_timer);
            nav_metrics.writeLast(run_dir, &navm, done_us) catch {};
            return .nav_complete;
        }

        if (wall_timer.read() >= timeout_ns) {
            if (load.active and navm.url.len != 0) {
                navm.canceled = true;
                const done_us = nav_metrics.nowUs(nav_timer);
                nav_metrics.writeLast(run_dir, &navm, done_us) catch {};
            }
            return .timeout;
        }

        const pending = renderer_tx.pending();
        pollfds[0].events = if (pending < max_renderer_pending) @as(@TypeOf(pollfds[0].events), std.posix.POLL.IN) else 0;
        pollfds[1].events = @as(@TypeOf(pollfds[1].events), std.posix.POLL.IN) | (if (pending != 0) @as(@TypeOf(pollfds[1].events), std.posix.POLL.OUT) else 0);
        pollfds[0].revents = 0;
        pollfds[1].revents = 0;
        _ = try std.posix.poll(&pollfds, 50);

        const net_re = pollfds[0].revents;
        const renderer_re = pollfds[1].revents;
        if ((net_re & hup_mask) != 0) return .end_of_stream;
        if ((renderer_re & hup_mask) != 0) return .end_of_stream;

        if ((renderer_re & std.posix.POLL.OUT) != 0) {
            renderer_tx.flush() catch |err| switch (err) {
                error.BrokenPipe => return .end_of_stream,
                else => return err,
            };
        }

        if ((net_re & std.posix.POLL.IN) != 0) {
            const frame = try net.recvAlloc(alloc);
            defer alloc.free(frame.payload);
            switch (frame.header.msg_type) {
                .net_fetch_begin => {
                    var idx: usize = 0;
                    const rid = try ipc.readInt(frame.payload, &idx, u32);
                    const status_code = try ipc.readInt(frame.payload, &idx, u32);
                    const source_code: u32 = if (idx < frame.payload.len)
                        (ipc.readInt(frame.payload, &idx, u32) catch 0)
                    else
                        0;

                    if (load.active and rid == load.request_id) {
                        if (navm.request_id == rid) {
                            navm.status_code = status_code;
                            navm.net_source = source_code;
                            if (navm.net_begin_us == null) navm.net_begin_us = nav_metrics.nowUs(nav_timer);
                        }
                    } else if (nav_resources.findIndex(resources.items, rid)) |route_idx| {
                        const route = resources.items[route_idx];
                        nav_resources.sendBegin(alloc, &renderer_tx, route, status_code, source_code) catch {};
                    }
                },
                .net_fetch_chunk => {
                    var idx: usize = 0;
                    const rid = try ipc.readInt(frame.payload, &idx, u32);
                    const chunk_len = try ipc.readInt(frame.payload, &idx, u32);
                    const chunk = try ipc.readBytes(frame.payload, &idx, @intCast(chunk_len));

                    if (load.active and rid == load.request_id) {
                        try renderer_tx.send(alloc, .renderer_html_chunk, frame.payload);
                    } else if (nav_resources.findIndex(resources.items, rid)) |route_idx| {
                        const route = resources.items[route_idx];
                        nav_resources.sendChunk(alloc, &renderer_tx, route, chunk) catch {};
                    }
                },
                .net_fetch_end => {
                    var idx: usize = 0;
                    const rid = try ipc.readInt(frame.payload, &idx, u32);
                    if (load.active and rid == load.request_id) {
                        const status_code = try ipc.readInt(frame.payload, &idx, u32);
                        const net_result = try ipc.readInt(frame.payload, &idx, u32);
                        const total_sent = try ipc.readInt(frame.payload, &idx, u32);

                        load.net_done = true;
                        if (navm.request_id == rid) {
                            navm.status_code = status_code;
                            navm.net_result = net_result;
                            navm.total_sent = total_sent;
                            navm.net_end_us = nav_metrics.nowUs(nav_timer);
                        }
                        try renderer_tx.send(alloc, .renderer_end_document, frame.payload);
                    } else {
                        if (nav_resources.findIndex(resources.items, rid)) |route_idx| {
                            const status_code = ipc.readInt(frame.payload, &idx, u32) catch 0;
                            const net_result = ipc.readInt(frame.payload, &idx, u32) catch 1;
                            const total_sent = ipc.readInt(frame.payload, &idx, u32) catch 0;
                            const route = resources.items[route_idx];
                            _ = resources.swapRemove(route_idx);
                            nav_resources.sendEnd(alloc, &renderer_tx, route, status_code, net_result, total_sent) catch {};
                        }
                    }
                },
                else => {},
            }
        }

        if ((renderer_re & std.posix.POLL.IN) != 0) {
            const frame = try renderer.recvAlloc(alloc);
            defer alloc.free(frame.payload);
            switch (frame.header.msg_type) {
                .renderer_display_list => {
                    if (load.active) {
                        var idx: usize = 0;
                        const rid = try ipc.readInt(frame.payload, &idx, u32);
                        if (rid == load.request_id) {
                            const list_len = try ipc.readInt(frame.payload, &idx, u32);
                            const list = try ipc.readBytes(frame.payload, &idx, @intCast(list_len));

                            if (navm.request_id == rid and navm.first_display_list_us == null) {
                                navm.first_display_list_us = nav_metrics.nowUs(nav_timer);
                            }

                            const new_content = try alloc.dupe(u8, list);
                            alloc.free(content_dl);
                            content_dl = new_content;

                            const status: []const u8 = if (load.active) "load" else "";
                            try chrome.submitComposedFrame(alloc, surface_w_i32, scroll_y, url_buf.items, status, content_dl, gpu, noopRepaint, frame_id);
                            if (navm.request_id == rid and navm.first_frame_ready_us == null) {
                                navm.first_frame_ready_us = nav_metrics.nowUs(nav_timer);
                            }
                            frame_id +%= 1;
                        }
                    }
                },
                .renderer_document_done => {
                    if (load.active) {
                        var idx: usize = 0;
                        const rid = try ipc.readInt(frame.payload, &idx, u32);
                        if (rid == load.request_id) {
                            load.renderer_done = true;
                            if (navm.request_id == rid) navm.renderer_done_us = nav_metrics.nowUs(nav_timer);
                        }
                    }
                },
                .renderer_request_resource => blk: {
                    var idx: usize = 0;
                    const doc_rid = try ipc.readInt(frame.payload, &idx, u32);
                    const resource_id = try ipc.readInt(frame.payload, &idx, u32);
                    const url_len = try ipc.readInt(frame.payload, &idx, u32);
                    const href = try ipc.readBytes(frame.payload, &idx, @intCast(url_len));

                    if (!load.active) break :blk;
                    if (doc_rid != load.request_id) break :blk;
                    if (resources.items.len >= 64) break :blk;

                    const resolved = url_mod.resolveHref(alloc, url_buf.items, href) catch break :blk;
                    defer alloc.free(resolved);

                    const net_rid = request_id;
                    request_id +%= 1;

                    resources.append(alloc, .{
                        .net_request_id = net_rid,
                        .doc_request_id = doc_rid,
                        .resource_id = resource_id,
                    }) catch break :blk;
                    nav_support.netSendFetchUrl(alloc, net, net_rid, resolved) catch {};
                },
                .renderer_set_cookie => blk: {
                    var idx: usize = 0;
                    const doc_rid = try ipc.readInt(frame.payload, &idx, u32);
                    const cookie_len = try ipc.readInt(frame.payload, &idx, u32);
                    const cookie = try ipc.readBytes(frame.payload, &idx, @intCast(cookie_len));

                    if (cookie.len == 0 or cookie.len > 4096) break :blk;
                    if (doc_rid != load.request_id) break :blk;
                    nav_support.netSendSetCookie(alloc, net, url_buf.items, cookie) catch {};
                },
                .renderer_navigate => blk: {
                    var idx: usize = 0;
                    const doc_rid = try ipc.readInt(frame.payload, &idx, u32);
                    _ = ipc.readInt(frame.payload, &idx, u32) catch 0; // mode (push/replace)
                    const url_len = try ipc.readInt(frame.payload, &idx, u32);
                    const href = try ipc.readBytes(frame.payload, &idx, @intCast(url_len));

                    if (href.len == 0 or href.len > 2048) break :blk;
                    if (doc_rid != load.request_id) break :blk;

                    nav_resources.cancelAll(net, &resources);
                    const resolved = url_mod.resolveHref(alloc, url_buf.items, href) catch break :blk;
                    defer alloc.free(resolved);

                    url_buf.items.len = 0;
                    try url_buf.appendSlice(alloc, resolved);
                    try nav_start.startNavigation(
                        alloc,
                        run_dir,
                        nav_timer,
                        &navm,
                        run_dir_rel,
                        net,
                        renderer,
                        &renderer_tx,
                        gpu,
                        noopRepaint,
                        surface_w_i32,
                        surface_h_i32,
                        scroll_y,
                        &url_buf,
                        &content_dl,
                        &request_id,
                        &frame_id,
                        &load,
                    );
                },
                else => {},
            }
        }
    }
}

fn noopRepaint() void {}
