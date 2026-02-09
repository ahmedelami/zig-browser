const std = @import("std");
const shared = @import("shared");

const chrome = @import("chrome.zig");
const history_mod = @import("history.zig");
const nav_links = @import("nav_links.zig");
const nav_metrics = @import("nav_metrics.zig");
const nav_start = @import("nav_start.zig");
const nav_types = @import("nav_types.zig");
const nav_hittest = @import("nav_hittest.zig");
const url_mod = @import("url.zig");
const ipc_tx = @import("ipc_tx.zig");

const ipc = shared.ipc;

pub const Context = struct {
    alloc: std.mem.Allocator,
    run_dir: *std.fs.Dir,
    timer: *std.time.Timer,
    navm: *nav_metrics.NavMetrics,
    run_dir_rel: []const u8,
    net: *ipc.Connection,
    renderer: *ipc.Connection,
    renderer_tx: *ipc_tx.Tx,
    gpu: *ipc.Connection,
    request_repaint: *const fn () void,
    surface_w_i32: i32,
    surface_h_i32: i32,
    scroll_y: *i32,
    url_buf: *std.ArrayList(u8),
    content_dl: *[]u8,
    request_id_counter: *u32,
    frame_id: *u32,
    load: *nav_types.LoadState,
    history: *history_mod.History,
    links: *std.ArrayList(nav_links.Link),
    link_rects: *std.ArrayList(nav_hittest.LinkRect),
    fresh_address: *bool,
};

pub fn onEnter(ctx: *Context) !void {
    ctx.scroll_y.* = 0;

    if (std.mem.startsWith(u8, ctx.url_buf.items, ":")) {
        try handleCommand(ctx);
        ctx.fresh_address.* = true;
        return;
    }

    nav_links.clear(ctx.alloc, ctx.links);
    ctx.link_rects.items.len = 0;
    try nav_start.startNavigation(
        ctx.alloc,
        ctx.run_dir,
        ctx.timer,
        ctx.navm,
        ctx.run_dir_rel,
        ctx.net,
        ctx.renderer,
        ctx.renderer_tx,
        ctx.gpu,
        ctx.request_repaint,
        ctx.surface_w_i32,
        ctx.surface_h_i32,
        ctx.scroll_y.*,
        ctx.url_buf,
        ctx.content_dl,
        ctx.request_id_counter,
        ctx.frame_id,
        ctx.load,
    );
    try ctx.history.push(ctx.url_buf.items);
    ctx.fresh_address.* = true;
}

fn handleCommand(ctx: *Context) !void {
    const cmdline = std.mem.trim(u8, ctx.url_buf.items[1..], " \t\r\n");
    var toks = std.mem.tokenizeAny(u8, cmdline, " \t\r\n");
    const cmd = toks.next() orelse "";

    if (std.ascii.eqlIgnoreCase(cmd, "help")) {
        return navigateAndPush(ctx, "about:help");
    }

    if (std.ascii.eqlIgnoreCase(cmd, "links")) {
        return showLinks(ctx);
    }

    if (std.ascii.eqlIgnoreCase(cmd, "open")) {
        const idx_str = toks.next() orelse "";
        const link_idx = std.fmt.parseInt(u32, idx_str, 10) catch 0;
        return openLinkIndex(ctx, link_idx);
    }

    if (std.ascii.eqlIgnoreCase(cmd, "back")) {
        if (ctx.history.back()) |u| return navigateNoPush(ctx, u);
        return;
    }

    if (std.ascii.eqlIgnoreCase(cmd, "forward")) {
        if (ctx.history.forward()) |u| return navigateNoPush(ctx, u);
        return;
    }

    if (std.ascii.eqlIgnoreCase(cmd, "reload")) {
        if (ctx.history.current()) |u| return navigateNoPush(ctx, u);
        return;
    }

    return showMessageKeepUrl(ctx, "Unknown command. Try :help");
}

pub fn openLinkIndex(ctx: *Context, link_idx: u32) !void {
    ctx.scroll_y.* = 0;
    const href = nav_links.findHref(ctx.links.items, link_idx) orelse {
        return showMessageKeepUrl(ctx, "No such link index.");
    };

    const base = ctx.history.current() orelse ctx.url_buf.items;
    const resolved = try url_mod.resolveHref(ctx.alloc, base, href);
    defer ctx.alloc.free(resolved);

    try navigateAndPush(ctx, resolved);
    ctx.fresh_address.* = true;
}

fn navigateAndPush(ctx: *Context, url: []const u8) !void {
    nav_links.clear(ctx.alloc, ctx.links);
    ctx.link_rects.items.len = 0;
    ctx.url_buf.items.len = 0;
    try ctx.url_buf.appendSlice(ctx.alloc, url);

    try nav_start.startNavigation(
        ctx.alloc,
        ctx.run_dir,
        ctx.timer,
        ctx.navm,
        ctx.run_dir_rel,
        ctx.net,
        ctx.renderer,
        ctx.renderer_tx,
        ctx.gpu,
        ctx.request_repaint,
        ctx.surface_w_i32,
        ctx.surface_h_i32,
        ctx.scroll_y.*,
        ctx.url_buf,
        ctx.content_dl,
        ctx.request_id_counter,
        ctx.frame_id,
        ctx.load,
    );

    try ctx.history.push(ctx.url_buf.items);
}

fn navigateNoPush(ctx: *Context, url: []const u8) !void {
    nav_links.clear(ctx.alloc, ctx.links);
    ctx.link_rects.items.len = 0;
    ctx.url_buf.items.len = 0;
    try ctx.url_buf.appendSlice(ctx.alloc, url);

    try nav_start.startNavigation(
        ctx.alloc,
        ctx.run_dir,
        ctx.timer,
        ctx.navm,
        ctx.run_dir_rel,
        ctx.net,
        ctx.renderer,
        ctx.renderer_tx,
        ctx.gpu,
        ctx.request_repaint,
        ctx.surface_w_i32,
        ctx.surface_h_i32,
        ctx.scroll_y.*,
        ctx.url_buf,
        ctx.content_dl,
        ctx.request_id_counter,
        ctx.frame_id,
        ctx.load,
    );
}

fn showLinks(ctx: *Context) !void {
    const base = ctx.history.current() orelse ctx.url_buf.items;
    const new_content = try nav_links.renderLinksDisplayList(ctx.alloc, base, ctx.links.items);
    ctx.alloc.free(ctx.content_dl.*);
    ctx.content_dl.* = new_content;
    ctx.link_rects.items.len = 0;

    // Restore the address bar to the current page URL.
    ctx.url_buf.items.len = 0;
    try ctx.url_buf.appendSlice(ctx.alloc, base);

    try chrome.submitComposedFrame(
        ctx.alloc,
        ctx.surface_w_i32,
        ctx.scroll_y.*,
        ctx.url_buf.items,
        "",
        ctx.content_dl.*,
        ctx.gpu,
        ctx.request_repaint,
        ctx.frame_id.*,
    );
    ctx.frame_id.* +%= 1;
}

fn showMessageKeepUrl(ctx: *Context, msg: []const u8) !void {
    const new_content = try chrome.renderPlainTextDisplayList(ctx.alloc, msg);
    ctx.alloc.free(ctx.content_dl.*);
    ctx.content_dl.* = new_content;
    ctx.link_rects.items.len = 0;

    const base = ctx.history.current() orelse ctx.url_buf.items;
    ctx.url_buf.items.len = 0;
    try ctx.url_buf.appendSlice(ctx.alloc, base);

    try chrome.submitComposedFrame(
        ctx.alloc,
        ctx.surface_w_i32,
        ctx.scroll_y.*,
        ctx.url_buf.items,
        "",
        ctx.content_dl.*,
        ctx.gpu,
        ctx.request_repaint,
        ctx.frame_id.*,
    );
    ctx.frame_id.* +%= 1;
}
