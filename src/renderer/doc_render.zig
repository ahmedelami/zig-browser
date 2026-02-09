const std = @import("std");
const shared = @import("shared");

const ipc = shared.ipc;
const util = shared.util;

const display_list = shared.display_list;
const dom_mod = @import("dom.zig");
const html_tokenizer = @import("html/tokenizer.zig");
const html_tree_builder = @import("html/tree_builder.zig");
const text_flow = @import("layout/text_flow.zig");
const css = @import("css.zig");
const doc_types = @import("doc_types.zig");

const DocResult = doc_types.DocResult;

pub fn sendDocDisplayList(
    alloc: std.mem.Allocator,
    conn: *ipc.Connection,
    request_id: u32,
    status_code: u32,
    result: DocResult,
    bytes_received: usize,
    total_sent: u32,
    viewport_w: u32,
    viewport_h: u32,
    scroll_y: u32,
    dom: *const dom_mod.Dom,
    images: []const text_flow.ImageView,
    css_loaded: u32,
    css_total: u32,
    css_rules: []const css.Rule,
) !void {
    var globals = css.globalsFromRules(css_rules);
    // Prefer DOM-aware body/html rules when available (e.g. "body.dark { ... }").
    if (dom.body) |body_id| {
        const body = dom.node(body_id).*;
        const decls = css.computeForElement(css_rules, body.tag, body.id, body.class);
        if (decls.background) |c| globals.bg = c;
        if (decls.color) |c| globals.text = c;
    }

    var header_buf: [192]u8 = undefined;
    const header = if (css_total == 0) blk: {
        break :blk if (status_code == 0) try std.fmt.bufPrint(
            &header_buf,
            "bytes_received={d} bytes_sent={d} result={s}",
            .{ bytes_received, total_sent, @tagName(result) },
        ) else try std.fmt.bufPrint(
            &header_buf,
            "status={d} bytes_received={d} bytes_sent={d} result={s}",
            .{ status_code, bytes_received, total_sent, @tagName(result) },
        );
    } else blk: {
        break :blk if (status_code == 0) try std.fmt.bufPrint(
            &header_buf,
            "bytes_received={d} bytes_sent={d} css={d}/{d} result={s}",
            .{ bytes_received, total_sent, css_loaded, css_total, @tagName(result) },
        ) else try std.fmt.bufPrint(
            &header_buf,
            "status={d} bytes_received={d} bytes_sent={d} css={d}/{d} result={s}",
            .{ status_code, bytes_received, total_sent, css_loaded, css_total, @tagName(result) },
        );
    };

    var layout_dump: ?std.ArrayList(u8) = null;
    defer if (layout_dump) |*d| d.deinit(alloc);

    var link_rects = try std.ArrayList(text_flow.LinkRect).initCapacity(alloc, 128);
    defer link_rects.deinit(alloc);

    var images_buf: [32]text_flow.ImageView = undefined;
    const images_limited = limitImageBytes(&images_buf, images, 4 * 1024 * 1024);

    if (util.hasArg("--artifacts")) {
        layout_dump = try std.ArrayList(u8).initCapacity(alloc, 16 * 1024);
    }

    var list_bytes = try renderDocDisplayList(
        alloc,
        dom,
        globals,
        header,
        result,
        viewport_w,
        viewport_h,
        scroll_y,
        css_rules,
        images_limited,
        if (layout_dump) |*d| d else null,
        &link_rects,
    );
    defer alloc.free(list_bytes);

    const max_payload: usize = @as(usize, ipc.max_payload_len);
    const max_rects: usize = 8192;
    var rect_count: u32 = @intCast(@min(link_rects.items.len, max_rects));
    var rect_bytes: usize = @as(usize, rect_count) * (4 + 4 * 4);
    var fixed_overhead: usize = list_bytes.len + rect_bytes + 16; // req_id+len + link_count + rect_count + list + rects

    if (fixed_overhead > max_payload) {
        const new_list = try renderDocDisplayList(
            alloc,
            dom,
            globals,
            header,
            result,
            viewport_w,
            viewport_h,
            scroll_y,
            css_rules,
            &.{},
            if (layout_dump) |*d| d else null,
            &link_rects,
        );
        alloc.free(list_bytes);
        list_bytes = new_list;
        rect_count = @intCast(@min(link_rects.items.len, max_rects));
        rect_bytes = @as(usize, rect_count) * (4 + 4 * 4);
        fixed_overhead = list_bytes.len + rect_bytes + 16;
    }

    if (fixed_overhead > max_payload) {
        link_rects.items.len = 0;
        rect_count = 0;
        rect_bytes = 0;
        const new_list = try renderFallbackDisplayList(alloc, globals, dom, header, viewport_w, viewport_h);
        alloc.free(list_bytes);
        list_bytes = new_list;
        fixed_overhead = list_bytes.len + 16;
    }

    const max_links: usize = 4096;
    const max_link_bytes: usize = max_payload -| fixed_overhead;
    var link_count: u32 = 0;
    var link_bytes: usize = 0;
    for (dom.nodes.items) |n| {
        if (n.kind != .element) continue;
        if (n.tag != .a) continue;
        const href = n.href orelse continue;
        if (n.link_index == 0) continue;
        if (@as(usize, link_count) >= max_links) break;

        const entry_bytes: usize = 8 + href.len;
        if (link_bytes + entry_bytes > max_link_bytes) break;
        link_count += 1;
        link_bytes += entry_bytes;
    }

    const payload_len: usize = fixed_overhead + link_bytes;
    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);

    std.mem.writeInt(u32, payload[0..4], request_id, .little);
    std.mem.writeInt(u32, payload[4..8], @intCast(list_bytes.len), .little);
    @memcpy(payload[8..][0..list_bytes.len], list_bytes);

    var idx: usize = 8 + list_bytes.len;
    std.mem.writeInt(u32, payload[idx..][0..4], link_count, .little);
    idx += 4;

    var written: u32 = 0;
    for (dom.nodes.items) |n| {
        if (written >= link_count) break;
        if (n.kind != .element) continue;
        if (n.tag != .a) continue;
        const href = n.href orelse continue;
        if (n.link_index == 0) continue;

        std.mem.writeInt(u32, payload[idx..][0..4], n.link_index, .little);
        idx += 4;
        std.mem.writeInt(u32, payload[idx..][0..4], @intCast(href.len), .little);
        idx += 4;
        @memcpy(payload[idx..][0..href.len], href);
        idx += href.len;
        written += 1;
    }

    std.mem.writeInt(u32, payload[idx..][0..4], rect_count, .little);
    idx += 4;

    var rect_written: u32 = 0;
    for (link_rects.items) |r| {
        if (rect_written >= rect_count) break;
        std.mem.writeInt(u32, payload[idx..][0..4], r.link_index, .little);
        idx += 4;
        std.mem.writeInt(i32, payload[idx..][0..4], r.x, .little);
        idx += 4;
        std.mem.writeInt(i32, payload[idx..][0..4], r.y, .little);
        idx += 4;
        std.mem.writeInt(i32, payload[idx..][0..4], r.w, .little);
        idx += 4;
        std.mem.writeInt(i32, payload[idx..][0..4], r.h, .little);
        idx += 4;
        rect_written += 1;
    }

    try conn.send(.renderer_display_list, payload);
}

fn limitImageBytes(
    out_buf: *[32]text_flow.ImageView,
    images: []const text_flow.ImageView,
    max_bytes: usize,
) []const text_flow.ImageView {
    var used: usize = 0;
    var n: usize = 0;
    for (images) |img| {
        if (n >= out_buf.len) break;
        if (img.bgra.len > max_bytes) continue;
        if (used + img.bgra.len > max_bytes) continue;
        out_buf[n] = img;
        used += img.bgra.len;
        n += 1;
    }
    return out_buf[0..n];
}

fn renderDocDisplayList(
    alloc: std.mem.Allocator,
    dom: *const dom_mod.Dom,
    globals: css.Globals,
    header: []const u8,
    result: DocResult,
    viewport_w: u32,
    viewport_h: u32,
    scroll_y: u32,
    css_rules: []const css.Rule,
    images: []const text_flow.ImageView,
    dump: ?*std.ArrayList(u8),
    rects: *std.ArrayList(text_flow.LinkRect),
) ![]u8 {
    rects.items.len = 0;
    if (dump) |d| d.items.len = 0;

    var dl = try display_list.Builder.init(alloc);
    defer dl.deinit();
    try dl.clear(globals.bg);

    const title_trim = std.mem.trim(u8, dom.title.items, " \t\r\n");
    const y0: i32 = if (title_trim.len != 0) 44 else 32;
    if (title_trim.len != 0) {
        try dl.text(16, 16, globals.heading, title_trim);
        try dl.text(16, 28, globals.muted, header);
    } else {
        try dl.text(16, 16, globals.muted, header);
    }

    if (result == .failed and dom.nodes.items.len <= 1) {
        try dl.text(16, y0, globals.text, "Network error (see trace-net.json / stderr).");
    } else {
        const max_i32_u32: u32 = @intCast(std.math.maxInt(i32));
        const scroll_clamped: u32 = @min(scroll_y, max_i32_u32);
        const vis_clamped: u32 = @min(viewport_h, max_i32_u32 - scroll_clamped);
        const overscan: u32 = @min(2048, viewport_h / 2);
        const clip_top_u32: u32 = scroll_clamped -| overscan;
        const clip_bot_u32: u32 = @min(max_i32_u32, scroll_clamped + vis_clamped + overscan);
        const clip_y0: i32 = @intCast(clip_top_u32);
        const clip_y1: i32 = @intCast(clip_bot_u32);
        _ = try text_flow.paintDom(alloc, &dl, dom, .{
            .viewport_w = @intCast(viewport_w),
            .viewport_h = clip_y1,
            .clip_y0 = clip_y0,
            .clip_y1 = clip_y1,
            .y0 = y0,
            .bg = globals.bg,
            .color_text = globals.text,
            .color_link = globals.link,
            .color_heading = globals.heading,
            .color_muted = globals.muted,
            .css_rules = css_rules,
            .images = images,
        }, dump, rects);
    }

    return try dl.finish();
}

fn renderFallbackDisplayList(
    alloc: std.mem.Allocator,
    globals: css.Globals,
    dom: *const dom_mod.Dom,
    header: []const u8,
    viewport_w: u32,
    viewport_h: u32,
) ![]u8 {
    _ = viewport_w;
    _ = viewport_h;
    var dl = try display_list.Builder.init(alloc);
    defer dl.deinit();
    try dl.clear(globals.bg);

    const title_trim = std.mem.trim(u8, dom.title.items, " \t\r\n");
    if (title_trim.len != 0) try dl.text(16, 16, globals.heading, title_trim);
    try dl.text(16, 32, globals.muted, header);
    try dl.text(16, 48, globals.text, "Page too large to render safely (IPC payload cap).");
    return try dl.finish();
}

pub fn renderHtmlDisplayList(alloc: std.mem.Allocator, html_bytes: []const u8, viewport_w: u32, viewport_h: u32) ![]u8 {
    var dom = try dom_mod.Dom.init(alloc);
    defer dom.deinit();

    var tokenizer = try html_tokenizer.Tokenizer.init(alloc);
    defer tokenizer.deinit();

    var pending: std.ArrayListUnmanaged(html_tree_builder.StylesheetLink) = .{};
    var builder = html_tree_builder.Builder.init(&dom, &pending, null, null);
    try tokenizer.feed(html_bytes, &builder);
    try tokenizer.finish(&builder);

    var dl = try display_list.Builder.init(alloc);
    defer dl.deinit();
    try dl.clear(0xFF111418);

    _ = try text_flow.paintDom(alloc, &dl, &dom, .{
        .viewport_w = @intCast(viewport_w),
        .viewport_h = @intCast(viewport_h),
        .y0 = 16,
    }, null, null);
    return try dl.finish();
}

pub fn dumpDocArtifacts(
    run_dir: std.fs.Dir,
    dom: *dom_mod.Dom,
    viewport_w: u32,
    viewport_h: u32,
    bytes_received: usize,
    truncated: bool,
) !void {
    {
        const file = try run_dir.createFile("renderer_dom.txt", .{ .truncate = true });
        defer file.close();
        var buf: [64 * 1024]u8 = undefined;
        var w = file.writer(&buf);
        defer w.interface.flush() catch {};
        try w.interface.print("nodes={d} bytes_received={d} truncated={}\n\n", .{ dom.nodes.items.len, bytes_received, truncated });
        try dom.dump(&w.interface, 2000);
    }

    {
        const file = try run_dir.createFile("renderer_layout.txt", .{ .truncate = true });
        defer file.close();

        var buf: [64 * 1024]u8 = undefined;
        var w = file.writer(&buf);
        defer w.interface.flush() catch {};

        try w.interface.print("viewport={d}x{d}\n", .{ viewport_w, viewport_h });
        try w.interface.print("nodes={d} bytes_received={d} truncated={}\n\n", .{ dom.nodes.items.len, bytes_received, truncated });

        var dl = try display_list.Builder.init(dom.alloc());
        defer dl.deinit();
        try dl.clear(0xFF111418);

        var dump = try std.ArrayList(u8).initCapacity(dom.alloc(), 16 * 1024);
        defer dump.deinit(dom.alloc());
        _ = try text_flow.paintDom(dom.alloc(), &dl, dom, .{
            .viewport_w = @intCast(viewport_w),
            .viewport_h = @intCast(viewport_h),
            .y0 = 32,
        }, &dump, null);

        try w.interface.writeAll(dump.items);
    }

    {
        const file = try run_dir.createFile("renderer_scripts.txt", .{ .truncate = true });
        defer file.close();

        var buf: [64 * 1024]u8 = undefined;
        var w = file.writer(&buf);
        defer w.interface.flush() catch {};

        const max_total_dump_bytes: usize = 512 * 1024;
        const max_dump_scripts: usize = 32;
        const max_preview_bytes: usize = 160;
        const max_script_file_bytes: usize = 256 * 1024;

        run_dir.makePath("renderer_scripts") catch {};
        var scripts_dir = run_dir.openDir("renderer_scripts", .{}) catch null;
        defer if (scripts_dir) |*d| d.close();

        var total_scripts: usize = 0;
        var captured_scripts: usize = 0;
        var overflow_scripts: usize = 0;
        var dumped_scripts: usize = 0;
        var dumped_bytes: usize = 0;

        try w.interface.writeAll("scripts:\n");
        for (dom.nodes.items, 0..) |n, node_idx| {
            if (n.kind != .element or n.tag != .script) continue;
            total_scripts += 1;

            const src_opt = n.script_text;
            if (src_opt != null) captured_scripts += 1;
            if (n.script_overflow) overflow_scripts += 1;

            const src_len: usize = if (src_opt) |s| s.len else 0;
            const h: u64 = if (src_opt) |s| std.hash.Wyhash.hash(0, s) else 0;

            try w.interface.print(
                "- node={d} bytes={d} ran={} overflow={} hash=0x{x}\n",
                .{ node_idx, src_len, n.script_ran, n.script_overflow, h },
            );
            if (src_opt) |src| {
                try w.interface.writeAll("  preview: \"");
                dom_mod.Dom.writeEscapedPreview(&w.interface, src, max_preview_bytes) catch {};
                try w.interface.writeAll("\"\n");

                if (scripts_dir != null and dumped_scripts < max_dump_scripts and dumped_bytes < max_total_dump_bytes) {
                    const remain_total = max_total_dump_bytes - dumped_bytes;
                    const to_write = @min(src.len, @min(max_script_file_bytes, remain_total));

                    var name_buf: [96]u8 = undefined;
                    const name = std.fmt.bufPrint(&name_buf, "script_{d}_0x{x}.js", .{ dumped_scripts, h }) catch "script.js";
                    if (scripts_dir) |*d| {
                        const js_file = d.createFile(name, .{ .truncate = true }) catch null;
                        if (js_file) |f| {
                            defer f.close();
                            _ = f.writeAll(src[0..to_write]) catch {};
                            if (to_write < src.len) _ = f.writeAll("\n/* ... truncated ... */\n") catch {};
                            dumped_scripts += 1;
                            dumped_bytes += to_write;
                        }
                    }
                }
            }
        }

        try w.interface.print(
            "\nsummary: total={d} captured={d} overflow={d} dumped_files={d} dumped_bytes={d}\n",
            .{ total_scripts, captured_scripts, overflow_scripts, dumped_scripts, dumped_bytes },
        );
    }
}
