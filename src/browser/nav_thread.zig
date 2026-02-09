const std = @import("std");
const shared = @import("shared");

const input_queue = @import("input_queue.zig");
const chrome = @import("chrome.zig");
const history_mod = @import("history.zig");
const nav_enter = @import("nav_enter.zig");
const nav_hittest = @import("nav_hittest.zig");
const nav_links = @import("nav_links.zig");
const nav_metrics = @import("nav_metrics.zig");
const nav_start = @import("nav_start.zig");
const nav_support = @import("nav_support.zig");
const nav_types = @import("nav_types.zig");
const prefetch = @import("prefetch.zig");
const nav_resources = @import("nav_resources.zig");
const nav_status = @import("nav_status.zig");
const url_mod = @import("url.zig");
const ipc_tx = @import("ipc_tx.zig");

const ipc = shared.ipc;
const LoadState = nav_types.LoadState;
const ResourceRoute = nav_resources.ResourceRoute;

pub const Args = struct {
    alloc: std.mem.Allocator,
    run_dir_rel: []const u8,
    initial_url: []const u8,
    surface_width: u32,
    surface_height: u32,
    net: ipc.Connection,
    renderer: ipc.Connection,
    gpu: ipc.Connection,
    input: *input_queue.Queue,
    request_repaint: *const fn () void,
};

pub fn main(args: Args) void {
    mainImpl(args) catch |err| {
        switch (err) {
            // Common during shutdown when the UI forcibly closes IPC fds.
            error.EndOfStream,
            error.BrokenPipe,
            error.NotOpenForReading,
            error.SocketNotConnected,
            error.ConnectionResetByPeer,
            => return,
            else => {},
        }
        std.debug.print("browser: nav thread error: {s}\n", .{@errorName(err)});
    };
}

fn mainImpl(args: Args) !void {
    const alloc = args.alloc;
    var net = args.net;
    var renderer = args.renderer;
    var gpu = args.gpu;
    var renderer_tx: ipc_tx.Tx = .{ .fd = renderer.stream.handle };
    defer renderer_tx.deinit(alloc);
    const max_renderer_pending: usize = 4 * 1024 * 1024;
    var timer = try std.time.Timer.start();
    var run_dir = try std.fs.cwd().openDir(args.run_dir_rel, .{});
    defer run_dir.close();
    const surface_w_i32: i32 = @intCast(args.surface_width);
    const surface_h_i32: i32 = @intCast(args.surface_height);
    var url_buf = try std.ArrayList(u8).initCapacity(alloc, 256);
    defer url_buf.deinit(alloc);
    try url_buf.appendSlice(alloc, args.initial_url);
    var fresh_address: bool = true;
    var content_dl = try chrome.renderPlainTextDisplayList(alloc, "Loading…");
    defer alloc.free(content_dl);

    var status_buf: [160]u8 = undefined;
    var scroll_y: i32 = 0;

    var request_id: u32 = 100;
    var frame_id: u32 = 1;

    var load: LoadState = .{};
    var navm: nav_metrics.NavMetrics = .{};
    defer nav_metrics.reset(alloc, &navm);

    var history = try history_mod.History.init(alloc);
    defer history.deinit();

    var pf: prefetch.Prefetcher = undefined;
    pf.init(alloc, &net);
    defer pf.deinit();

    var links = try std.ArrayList(nav_links.Link).initCapacity(alloc, 64);
    defer {
        nav_links.clear(alloc, &links);
        links.deinit(alloc);
    }

    var link_rects = try std.ArrayList(nav_hittest.LinkRect).initCapacity(alloc, 128);
    defer link_rects.deinit(alloc);

    var resources = try std.ArrayList(ResourceRoute).initCapacity(alloc, 16);
    defer resources.deinit(alloc);
    try nav_start.startNavigation(
        alloc,
        &run_dir,
        &timer,
        &navm,
        args.run_dir_rel,
        &net,
        &renderer,
        &renderer_tx,
        &gpu,
        args.request_repaint,
        surface_w_i32,
        surface_h_i32,
        scroll_y,
        &url_buf,
        &content_dl,
        &request_id,
        &frame_id,
        &load,
    );
    try history.push(url_buf.items);

    const hup_mask = std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;

    var pollfds: [3]std.posix.pollfd = .{
        .{ .fd = net.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = renderer.stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = args.input.wakeupFd(), .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        const pending = renderer_tx.pending();
        pollfds[0].events = if (pending < max_renderer_pending) @as(@TypeOf(pollfds[0].events), std.posix.POLL.IN) else 0;
        pollfds[1].events = @as(@TypeOf(pollfds[1].events), std.posix.POLL.IN) | (if (pending != 0) @as(@TypeOf(pollfds[1].events), std.posix.POLL.OUT) else 0);
        pollfds[0].revents = 0;
        pollfds[1].revents = 0;
        pollfds[2].revents = 0;
        _ = try std.posix.poll(&pollfds, -1);

        const net_re = pollfds[0].revents;
        const renderer_re = pollfds[1].revents;
        if ((net_re & hup_mask) != 0) return error.EndOfStream;
        if ((renderer_re & hup_mask) != 0) return error.EndOfStream;

        if ((renderer_re & std.posix.POLL.OUT) != 0) renderer_tx.flush() catch {};

        if ((pollfds[2].revents & std.posix.POLL.IN) != 0) {
            args.input.drainWakeup();
            while (args.input.pop()) |ev| {
                switch (ev) {
                    .byte => |b| {
                        if (b >= 0x20 and b < 0x7F) {
                            if (fresh_address) {
                                url_buf.items.len = 0;
                                fresh_address = false;
                            }
                            if (url_buf.items.len < 2048) try url_buf.append(alloc, b);
                            const status = nav_status.formatStatus(&status_buf, &timer, &navm, &load);
                            try chrome.submitComposedFrame(alloc, surface_w_i32, scroll_y, url_buf.items, status, content_dl, &gpu, args.request_repaint, frame_id);
                            frame_id +%= 1;
                        }
                    },
                    .backspace => {
                        if (fresh_address) {
                            url_buf.items.len = 0;
                            fresh_address = false;
                        }
                        if (url_buf.items.len != 0) url_buf.items.len -= 1;
                        const status = nav_status.formatStatus(&status_buf, &timer, &navm, &load);
                        try chrome.submitComposedFrame(alloc, surface_w_i32, scroll_y, url_buf.items, status, content_dl, &gpu, args.request_repaint, frame_id);
                        frame_id +%= 1;
                    },
                    .enter => {
                        pf.cancelAll();
                        nav_resources.cancelAll(&net, &resources);
                        var ctx: nav_enter.Context = .{
                            .alloc = alloc,
                            .run_dir = &run_dir,
                            .timer = &timer,
                            .navm = &navm,
                            .run_dir_rel = args.run_dir_rel,
                            .net = &net,
                            .renderer = &renderer,
                            .renderer_tx = &renderer_tx,
                            .gpu = &gpu,
                            .request_repaint = args.request_repaint,
                            .surface_w_i32 = surface_w_i32,
                            .surface_h_i32 = surface_h_i32,
                            .scroll_y = &scroll_y,
                            .url_buf = &url_buf,
                            .content_dl = &content_dl,
                            .request_id_counter = &request_id,
                            .frame_id = &frame_id,
                            .load = &load,
                            .history = &history,
                            .links = &links,
                            .link_rects = &link_rects,
                            .fresh_address = &fresh_address,
                        };
                        try nav_enter.onEnter(&ctx);
                    },
                    .scroll => |dy| {
                        var new_scroll = scroll_y - dy;
                        if (new_scroll < 0) new_scroll = 0;
                        if (new_scroll > 1_000_000) new_scroll = 1_000_000;
                        if (new_scroll == scroll_y) continue;
                        scroll_y = new_scroll;

                        if (load.request_id != 0) {
                            var payload: [8]u8 = undefined;
                            std.mem.writeInt(u32, payload[0..4], load.request_id, .little);
                            std.mem.writeInt(u32, payload[4..8], @intCast(scroll_y), .little);
                            renderer_tx.send(alloc, .renderer_set_scroll, payload[0..]) catch {};
                        }

                        const status = nav_status.formatStatus(&status_buf, &timer, &navm, &load);
                        try chrome.submitComposedFrame(alloc, surface_w_i32, scroll_y, url_buf.items, status, content_dl, &gpu, args.request_repaint, frame_id);
                        frame_id +%= 1;
                    },
                    .click => |p| {
                        if (p.y < chrome.content_y_off) continue;
                        const content_x: i32 = p.x;
                        const content_y: i32 = (p.y - chrome.content_y_off) + scroll_y;
                        const link_idx = nav_hittest.hitTest(link_rects.items, content_x, content_y) orelse continue;

                        pf.cancelAll();
                        nav_resources.cancelAll(&net, &resources);
                        var ctx: nav_enter.Context = .{
                            .alloc = alloc,
                            .run_dir = &run_dir,
                            .timer = &timer,
                            .navm = &navm,
                            .run_dir_rel = args.run_dir_rel,
                            .net = &net,
                            .renderer = &renderer,
                            .renderer_tx = &renderer_tx,
                            .gpu = &gpu,
                            .request_repaint = args.request_repaint,
                            .surface_w_i32 = surface_w_i32,
                            .surface_h_i32 = surface_h_i32,
                            .scroll_y = &scroll_y,
                            .url_buf = &url_buf,
                            .content_dl = &content_dl,
                            .request_id_counter = &request_id,
                            .frame_id = &frame_id,
                            .load = &load,
                            .history = &history,
                            .links = &links,
                            .link_rects = &link_rects,
                            .fresh_address = &fresh_address,
                        };
                        try nav_enter.openLinkIndex(&ctx, link_idx);
                    },
                }
            }
            if (args.input.isClosed()) break;
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
                            if (navm.net_begin_us == null) navm.net_begin_us = nav_metrics.nowUs(&timer);
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
                            navm.net_end_us = nav_metrics.nowUs(&timer);
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
                        } else {
                            pf.onNetFetchEnd(rid);
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
                    var idx: usize = 0;
                    const rid = try ipc.readInt(frame.payload, &idx, u32);
                    if (rid == load.request_id) {
                        const list_len = try ipc.readInt(frame.payload, &idx, u32);
                        const list = try ipc.readBytes(frame.payload, &idx, @intCast(list_len));

                        // Optional link map tail: u32 count; repeated { u32 index, u32 href_len, href_bytes }.
                        if (idx < frame.payload.len) {
                            const raw_count = ipc.readInt(frame.payload, &idx, u32) catch 0;
                            const count: u32 = @min(raw_count, 4096);
                            nav_links.clear(alloc, &links);
                            link_rects.items.len = 0;
                            var i: u32 = 0;
                            while (i < count) : (i += 1) {
                                const link_index = ipc.readInt(frame.payload, &idx, u32) catch break;
                                const href_len = ipc.readInt(frame.payload, &idx, u32) catch break;
                                const href_bytes = ipc.readBytes(frame.payload, &idx, @intCast(href_len)) catch break;
                                const href_copy = try alloc.dupe(u8, href_bytes);
                                try links.append(alloc, .{ .index = link_index, .href = href_copy });
                            }
                        }

                        // Optional link rect tail: u32 count; repeated { u32 index, i32 x, i32 y, i32 w, i32 h }.
                        if (idx < frame.payload.len) {
                            const raw_count = ipc.readInt(frame.payload, &idx, u32) catch 0;
                            const count: u32 = @min(raw_count, 8192);
                            link_rects.items.len = 0;
                            var i: u32 = 0;
                            while (i < count) : (i += 1) {
                                const link_index = ipc.readInt(frame.payload, &idx, u32) catch break;
                                const x = ipc.readInt(frame.payload, &idx, i32) catch break;
                                const y = ipc.readInt(frame.payload, &idx, i32) catch break;
                                const w = ipc.readInt(frame.payload, &idx, i32) catch break;
                                const h = ipc.readInt(frame.payload, &idx, i32) catch break;
                                try link_rects.append(alloc, .{
                                    .link_index = link_index,
                                    .x = x,
                                    .y = y,
                                    .w = w,
                                    .h = h,
                                });
                            }
                        }

                        if (navm.request_id == rid and navm.first_display_list_us == null) {
                            navm.first_display_list_us = nav_metrics.nowUs(&timer);
                        }

                        const new_content = try alloc.dupe(u8, list);
                        alloc.free(content_dl);
                        content_dl = new_content;

                        const status = nav_status.formatStatus(&status_buf, &timer, &navm, &load);
                        try chrome.submitComposedFrame(alloc, surface_w_i32, scroll_y, url_buf.items, status, content_dl, &gpu, args.request_repaint, frame_id);
                        if (navm.request_id == rid and navm.first_frame_ready_us == null) {
                            navm.first_frame_ready_us = nav_metrics.nowUs(&timer);
                        }
                        frame_id +%= 1;
                    }
                },
                .renderer_document_done => {
                    if (load.active) {
                        var idx: usize = 0;
                        const rid = try ipc.readInt(frame.payload, &idx, u32);
                        if (rid == load.request_id) {
                            load.renderer_done = true;
                            if (navm.request_id == rid) navm.renderer_done_us = nav_metrics.nowUs(&timer);
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

                    const base = history.current() orelse url_buf.items;
                    const resolved = url_mod.resolveHref(alloc, base, href) catch break :blk;
                    defer alloc.free(resolved);

                    const net_rid = request_id;
                    request_id +%= 1;

                    resources.append(alloc, .{
                        .net_request_id = net_rid,
                        .doc_request_id = doc_rid,
                        .resource_id = resource_id,
                    }) catch break :blk;
                    nav_support.netSendFetchUrl(alloc, &net, net_rid, resolved) catch {};
                },
                .renderer_set_cookie => blk: {
                    var idx: usize = 0;
                    const doc_rid = try ipc.readInt(frame.payload, &idx, u32);
                    const cookie_len = try ipc.readInt(frame.payload, &idx, u32);
                    const cookie = try ipc.readBytes(frame.payload, &idx, @intCast(cookie_len));

                    if (cookie.len == 0 or cookie.len > 4096) break :blk;
                    if (doc_rid != load.request_id) break :blk;

                    const base = history.current() orelse url_buf.items;
                    nav_support.netSendSetCookie(alloc, &net, base, cookie) catch {};
                },
                .renderer_navigate => blk: {
                    var idx: usize = 0;
                    const doc_rid = try ipc.readInt(frame.payload, &idx, u32);
                    const mode = ipc.readInt(frame.payload, &idx, u32) catch 0;
                    const url_len = try ipc.readInt(frame.payload, &idx, u32);
                    const href = try ipc.readBytes(frame.payload, &idx, @intCast(url_len));

                    if (href.len == 0 or href.len > 2048) break :blk;
                    if (doc_rid != load.request_id) break :blk;

                    pf.cancelAll();
                    nav_resources.cancelAll(&net, &resources);
                    scroll_y = 0;

                    nav_links.clear(alloc, &links);
                    link_rects.items.len = 0;

                    const base = history.current() orelse url_buf.items;
                    const resolved = url_mod.resolveHref(alloc, base, href) catch break :blk;
                    defer alloc.free(resolved);

                    url_buf.items.len = 0;
                    try url_buf.appendSlice(alloc, resolved);

                    try nav_start.startNavigation(
                        alloc,
                        &run_dir,
                        &timer,
                        &navm,
                        args.run_dir_rel,
                        &net,
                        &renderer,
                        &renderer_tx,
                        &gpu,
                        args.request_repaint,
                        surface_w_i32,
                        surface_h_i32,
                        scroll_y,
                        &url_buf,
                        &content_dl,
                        &request_id,
                        &frame_id,
                        &load,
                    );

                    if (mode == 0) {
                        try history.push(url_buf.items);
                    } else {
                        try history.replaceCurrent(url_buf.items);
                    }
                    fresh_address = true;
                },
                else => {},
            }
        }

        if (load.active and load.net_done and load.renderer_done) {
            load.active = false;
            if (navm.url.len != 0) {
                const done_us = nav_metrics.nowUs(&timer);
                nav_metrics.writeLast(&run_dir, &navm, done_us) catch {};
            }

            // Prefetch a few same-host links after a successful navigation to make the next click
            // feel instant (warm net cache). Prefetch requests are canceled on the next user nav.
            const base = history.current() orelse url_buf.items;
            pf.maybeStart(&request_id, base, links.items);
        }
    }

    if (load.active and navm.url.len != 0) {
        pf.cancelAll();
        navm.canceled = true;
        const done_us = nav_metrics.nowUs(&timer);
        nav_metrics.writeLast(&run_dir, &navm, done_us) catch {};
    }
}
