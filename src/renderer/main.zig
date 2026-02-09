const std = @import("std");
const shared = @import("shared");

const ipc = shared.ipc;
const TraceWriter = shared.trace.TraceWriter;
const util = shared.util;

const display_list = shared.display_list;
const text_flow = @import("layout/text_flow.zig");
const css = @import("css.zig");
const doc_session = @import("doc_session.zig");
const doc_types = @import("doc_types.zig");
const doc_render = @import("doc_render.zig");
const png = @import("image/png.zig");
const js = @import("js/js.zig");

const DocResult = doc_types.DocResult;
const DocSession = doc_session.DocSession;

const JsHostCtx = struct {
    alloc: std.mem.Allocator,
    conn: *ipc.Connection,
    request_id: u32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const connect_path = (try util.argValue("--connect")) orelse return error.MissingConnect;
    const run_dir_path = (try util.argValue("--run-dir")) orelse return error.MissingRunDir;
    const artifacts = util.hasArg("--artifacts");

    const pid: u32 = @intCast(std.c.getpid());
    const tid: u32 = 0;

    var run_dir = try std.fs.cwd().openDir(run_dir_path, .{});
    defer run_dir.close();

    var trace = try TraceWriter.init(alloc, run_dir, "trace-renderer.json", pid, tid);
    defer trace.deinit();
    try trace.metaProcessName("zb_renderer");
    try trace.metaThreadName("main");
    try trace.instant("renderer_start", "lifecycle");

    var stream = try ipc.connectUnix(connect_path);
    defer stream.close();

    var conn: ipc.Connection = .{ .stream = stream };

    var hello_buf: [5]u8 = undefined;
    const hello_payload = ipc.encodeHello(&hello_buf, .{ .kind = .renderer, .pid = pid });
    try conn.send(.hello, hello_payload);

    var doc_req_id: ?u32 = null;
    var doc: DocSession = undefined;
    var doc_inited: bool = false;
    var doc_last_sent_bytes_received: usize = 0;
    var doc_last_sent_truncated: bool = false;
    var doc_last_send_ms: i64 = 0;
    var doc_status_code: u32 = 0;
    var doc_net_result: DocResult = .ok;
    var doc_total_sent: u32 = 0;
    defer if (doc_inited) doc.deinit();

    var js_engine: js.Engine = undefined;
    var js_inited: bool = false;
    var js_host_ctx: JsHostCtx = undefined;

    while (true) {
        const frame = conn.recvAlloc(alloc) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer alloc.free(frame.payload);

        switch (frame.header.msg_type) {
            .ping => {
                try conn.send(.pong, "");
            },
            .shutdown => break,
            .renderer_render_html => {
                var idx: usize = 0;
                const request_id = try ipc.readInt(frame.payload, &idx, u32);
                const html_len = try ipc.readInt(frame.payload, &idx, u32);
                const html_bytes = try ipc.readBytes(frame.payload, &idx, @intCast(html_len));

                try trace.instant("renderer_render_start", "renderer");

                const list_bytes = try doc_render.renderHtmlDisplayList(alloc, html_bytes, 1024, 768);
                defer alloc.free(list_bytes);

                const payload_len: usize = 8 + list_bytes.len;
                const payload = try alloc.alloc(u8, payload_len);
                defer alloc.free(payload);

                std.mem.writeInt(u32, payload[0..4], request_id, .little);
                std.mem.writeInt(u32, payload[4..8], @intCast(list_bytes.len), .little);
                @memcpy(payload[8..], list_bytes);

                try conn.send(.renderer_display_list, payload);
                try trace.instant("renderer_render_done", "renderer");
            },
            .renderer_begin_document => {
                var idx: usize = 0;
                const request_id = try ipc.readInt(frame.payload, &idx, u32);
                const viewport_w = try ipc.readInt(frame.payload, &idx, u32);
                const viewport_h = try ipc.readInt(frame.payload, &idx, u32);

                if (doc_inited) {
                    doc.deinit();
                    doc_inited = false;
                }
                doc_req_id = request_id;
                try doc.init(alloc, viewport_w, viewport_h);
                doc_inited = true;
                doc_last_sent_bytes_received = 0;
                doc_last_sent_truncated = false;
                doc_last_send_ms = 0;
                doc_status_code = 0;
                doc_net_result = .ok;
                doc_total_sent = 0;
                js_engine = js.Engine.init(&doc.dom);
                js_host_ctx = .{ .alloc = alloc, .conn = &conn, .request_id = request_id };
                js_engine.setHost(.{
                    .ctx = @ptrCast(&js_host_ctx),
                    .set_cookie = jsHostSetCookie,
                    .navigate = jsHostNavigate,
                });
                js_inited = true;

                try trace.instant("renderer_doc_begin", "renderer");
            },
            .renderer_set_scroll => {
                var idx: usize = 0;
                const request_id = try ipc.readInt(frame.payload, &idx, u32);
                const scroll_y = try ipc.readInt(frame.payload, &idx, u32);

                const cur_req_id = doc_req_id orelse continue;
                if (cur_req_id != request_id) continue;
                if (!doc_inited) continue;

                doc.scroll_y = scroll_y;
                const now_ms: i64 = @intCast(std.time.milliTimestamp());

                try trace.instant("renderer_scroll", "renderer");
                var result: DocResult = doc_net_result;
                if (result != .failed and doc.truncated) result = .truncated;
                var images_buf: [32]text_flow.ImageView = undefined;
                const images = gatherImageViews(&doc, &images_buf);
                try doc_render.sendDocDisplayList(
                    alloc,
                    &conn,
                    request_id,
                    doc_status_code,
                    result,
                    doc.bytes_received,
                    doc_total_sent,
                    doc.viewport_w,
                    doc.viewport_h,
                    doc.scroll_y,
                    &doc.dom,
                    images,
                    doc.stylesheet_done,
                    doc.stylesheet_total,
                    doc.css_rules.items,
                );
                doc_last_send_ms = now_ms;
            },
            .renderer_html_chunk => {
                var idx: usize = 0;
                const request_id = try ipc.readInt(frame.payload, &idx, u32);
                const chunk_len = try ipc.readInt(frame.payload, &idx, u32);
                const chunk = try ipc.readBytes(frame.payload, &idx, @intCast(chunk_len));

                const cur_req_id = doc_req_id orelse continue;
                if (cur_req_id != request_id) continue;
                if (!doc_inited) continue;

                try doc.feedChunk(chunk);
                flushPendingStylesheets(&conn, request_id, &doc) catch {};
                flushPendingImages(&conn, request_id, &doc) catch {};
                const js_dirty = if (js_inited) drainReadyScripts(&js_engine, &doc) else false;

                const now_ms: i64 = @intCast(std.time.milliTimestamp());
                const bytes_delta = doc.bytes_received - doc_last_sent_bytes_received;
                const send_timer = (doc_last_send_ms == 0) or (now_ms - doc_last_send_ms >= 50);
                const send_progress = bytes_delta >= 256 * 1024;
                const send_trunc = doc.truncated and !doc_last_sent_truncated;
                const send_js = js_dirty;
                if (!(send_timer or send_progress or send_trunc or send_js)) continue;

                try trace.instant("renderer_doc_update", "renderer");
                var result: DocResult = doc_net_result;
                if (result != .failed and doc.truncated) result = .truncated;
                var images_buf: [32]text_flow.ImageView = undefined;
                const images = gatherImageViews(&doc, &images_buf);
                try doc_render.sendDocDisplayList(
                    alloc,
                    &conn,
                    request_id,
                    doc_status_code,
                    result,
                    doc.bytes_received,
                    doc_total_sent,
                    doc.viewport_w,
                    doc.viewport_h,
                    doc.scroll_y,
                    &doc.dom,
                    images,
                    doc.stylesheet_done,
                    doc.stylesheet_total,
                    doc.css_rules.items,
                );
                doc_last_sent_bytes_received = doc.bytes_received;
                doc_last_sent_truncated = doc.truncated;
                doc_last_send_ms = now_ms;
            },
            .renderer_resource_begin => {
                var idx: usize = 0;
                const request_id = try ipc.readInt(frame.payload, &idx, u32);
                const resource_id = try ipc.readInt(frame.payload, &idx, u32);
                const status_code = try ipc.readInt(frame.payload, &idx, u32);
                // net source (optional): u32
                if (idx < frame.payload.len) _ = ipc.readInt(frame.payload, &idx, u32) catch 0;

                const cur_req_id = doc_req_id orelse continue;
                if (cur_req_id != request_id) continue;
                if (!doc_inited) continue;

                if (doc.stylesheetMut(resource_id)) |ss| {
                    ss.status_code = status_code;
                } else if (doc.imageMut(resource_id)) |img| {
                    img.status_code = status_code;
                }
            },
            .renderer_resource_chunk => {
                var idx: usize = 0;
                const request_id = try ipc.readInt(frame.payload, &idx, u32);
                const resource_id = try ipc.readInt(frame.payload, &idx, u32);
                const chunk_len = try ipc.readInt(frame.payload, &idx, u32);
                const chunk = try ipc.readBytes(frame.payload, &idx, @intCast(chunk_len));

                const cur_req_id = doc_req_id orelse continue;
                if (cur_req_id != request_id) continue;
                if (!doc_inited) continue;

                if (doc.stylesheetMut(resource_id)) |ss| {
                    if (ss.overflow) continue;
                    if (ss.bytes.items.len + chunk.len > DocSession.max_stylesheet_bytes) {
                        ss.overflow = true;
                        continue;
                    }
                    ss.bytes.appendSlice(doc.alloc, chunk) catch {
                        ss.overflow = true;
                    };
                } else if (doc.imageMut(resource_id)) |img| {
                    if (img.overflow) continue;
                    if (img.bytes.items.len + chunk.len > DocSession.max_image_bytes) {
                        img.overflow = true;
                        continue;
                    }
                    img.bytes.appendSlice(doc.alloc, chunk) catch {
                        img.overflow = true;
                    };
                }
            },
            .renderer_resource_end => {
                var idx: usize = 0;
                const request_id = try ipc.readInt(frame.payload, &idx, u32);
                const resource_id = try ipc.readInt(frame.payload, &idx, u32);
                const status_code = try ipc.readInt(frame.payload, &idx, u32);
                const net_result_raw = try ipc.readInt(frame.payload, &idx, u32);
                const total_sent = try ipc.readInt(frame.payload, &idx, u32);

                const cur_req_id = doc_req_id orelse continue;
                if (cur_req_id != request_id) continue;
                if (!doc_inited) continue;

                if (doc.stylesheetMut(resource_id)) |ss| {
                    ss.status_code = status_code;
                    ss.net_result = net_result_raw;
                    ss.total_sent = total_sent;
                    if (!ss.done) {
                        ss.done = true;
                        doc.stylesheet_done +%= 1;
                    }

                    // Best-effort parse CSS after the sheet completes.
                    const status_ok = status_code >= 200 and status_code < 300;
                    if (status_ok and net_result_raw == 0 and !ss.overflow) {
                        css.parseAppend(doc.alloc, &doc.css_rules, ss.bytes.items, DocSession.max_total_css_rules);
                    }

                    // Refresh the display list (CSS may have changed page colors).
                    var result: DocResult = doc_net_result;
                    if (result != .failed and doc.truncated) result = .truncated;
                    var images_buf: [32]text_flow.ImageView = undefined;
                    const images = gatherImageViews(&doc, &images_buf);
                    try doc_render.sendDocDisplayList(
                        alloc,
                        &conn,
                        request_id,
                        doc_status_code,
                        result,
                        doc.bytes_received,
                        doc_total_sent,
                        doc.viewport_w,
                        doc.viewport_h,
                        doc.scroll_y,
                        &doc.dom,
                        images,
                        doc.stylesheet_done,
                        doc.stylesheet_total,
                        doc.css_rules.items,
                    );

                    try maybeFinishDoc(&conn, &trace, artifacts, run_dir, request_id, result, &doc);
                } else if (doc.imageMut(resource_id)) |img| {
                    img.status_code = status_code;
                    img.net_result = net_result_raw;
                    img.total_sent = total_sent;
                    if (!img.done) img.done = true;

                    const status_ok = status_code >= 200 and status_code < 300;
                    const can_decode = status_ok and net_result_raw == 0 and !img.overflow and img.decoded == null;
                    if (can_decode and img.bytes.items.len >= 8 and std.mem.eql(u8, img.bytes.items[0..8], "\x89PNG\r\n\x1a\n")) {
                        if (png.decodeBgra8(doc.alloc, img.bytes.items, DocSession.max_image_pixels)) |decoded| {
                            img.decoded = decoded;
                            // Free the compressed bytes after decoding to keep memory bounded.
                            img.bytes.deinit(doc.alloc);
                            img.bytes = .{};

                            var result: DocResult = doc_net_result;
                            if (result != .failed and doc.truncated) result = .truncated;
                            var images_buf: [32]text_flow.ImageView = undefined;
                            const images = gatherImageViews(&doc, &images_buf);
                            try doc_render.sendDocDisplayList(
                                alloc,
                                &conn,
                                request_id,
                                doc_status_code,
                                result,
                                doc.bytes_received,
                                doc_total_sent,
                                doc.viewport_w,
                                doc.viewport_h,
                                doc.scroll_y,
                                &doc.dom,
                                images,
                                doc.stylesheet_done,
                                doc.stylesheet_total,
                                doc.css_rules.items,
                            );
                        } else |_| {}
                    }

                    var result: DocResult = doc_net_result;
                    if (result != .failed and doc.truncated) result = .truncated;
                    try maybeFinishDoc(&conn, &trace, artifacts, run_dir, request_id, result, &doc);
                }
            },
            .renderer_end_document => {
                var idx: usize = 0;
                const request_id = try ipc.readInt(frame.payload, &idx, u32);
                const status_code = try ipc.readInt(frame.payload, &idx, u32);
                const net_result_raw = try ipc.readInt(frame.payload, &idx, u32);
                const total_sent = try ipc.readInt(frame.payload, &idx, u32);
                const cur_req_id = doc_req_id orelse continue;
                if (cur_req_id != request_id) continue;
                if (!doc_inited) continue;

                doc_status_code = status_code;
                doc_total_sent = total_sent;
                doc_net_result = std.meta.intToEnum(DocResult, net_result_raw) catch .failed;

                // Finalize any pending entity/text state.
                try doc.finish();
                flushPendingStylesheets(&conn, request_id, &doc) catch {};
                flushPendingImages(&conn, request_id, &doc) catch {};
                doc.html_done = true;
                parseInlineStyleTags(&doc);
                if (js_inited) _ = drainReadyScripts(&js_engine, &doc);

                var result: DocResult = doc_net_result;
                if (result != .failed and doc.truncated) result = .truncated;

                // Always send a final display list so status/result/bytes_sent are reflected even if
                // the last chunk already produced identical text/byte counters.
                var images_buf: [32]text_flow.ImageView = undefined;
                const images = gatherImageViews(&doc, &images_buf);
                try doc_render.sendDocDisplayList(
                    alloc,
                    &conn,
                    request_id,
                    doc_status_code,
                    result,
                    doc.bytes_received,
                    doc_total_sent,
                    doc.viewport_w,
                    doc.viewport_h,
                    doc.scroll_y,
                    &doc.dom,
                    images,
                    doc.stylesheet_done,
                    doc.stylesheet_total,
                    doc.css_rules.items,
                );
                doc_last_sent_bytes_received = doc.bytes_received;
                doc_last_sent_truncated = doc.truncated;
                try maybeFinishDoc(&conn, &trace, artifacts, run_dir, request_id, result, &doc);
            },
            else => {},
        }
    }

    try trace.instant("renderer_exit", "lifecycle");
}

fn jsHostSetCookie(ctx_ptr: *anyopaque, cookie: []const u8) void {
    const ctx: *JsHostCtx = @ptrCast(@alignCast(ctx_ptr));
    if (cookie.len == 0) return;

    const max_cookie_len: usize = 4096;
    const n = @min(cookie.len, max_cookie_len);
    const payload_len: usize = 8 + n;
    const payload = ctx.alloc.alloc(u8, payload_len) catch return;
    defer ctx.alloc.free(payload);

    std.mem.writeInt(u32, payload[0..4], ctx.request_id, .little);
    std.mem.writeInt(u32, payload[4..8], @intCast(n), .little);
    @memcpy(payload[8..][0..n], cookie[0..n]);

    ctx.conn.send(.renderer_set_cookie, payload) catch {};
}

fn jsHostNavigate(ctx_ptr: *anyopaque, mode: js.NavMode, url: []const u8) void {
    const ctx: *JsHostCtx = @ptrCast(@alignCast(ctx_ptr));
    if (url.len == 0) return;

    const max_url_len: usize = 2048;
    const n = @min(url.len, max_url_len);
    const payload_len: usize = 12 + n;
    const payload = ctx.alloc.alloc(u8, payload_len) catch return;
    defer ctx.alloc.free(payload);

    std.mem.writeInt(u32, payload[0..4], ctx.request_id, .little);
    std.mem.writeInt(u32, payload[4..8], @intFromEnum(mode), .little);
    std.mem.writeInt(u32, payload[8..12], @intCast(n), .little);
    @memcpy(payload[12..][0..n], url[0..n]);

    ctx.conn.send(.renderer_navigate, payload) catch {};
}

fn drainReadyScripts(engine: *js.Engine, doc: *DocSession) bool {
    var dirty: bool = false;
    while (doc.scripts_executed < doc.scripts_ready.items.len) {
        const id = doc.scripts_ready.items[doc.scripts_executed];
        doc.scripts_executed += 1;

        const n = doc.dom.nodeMut(id);
        if (n.kind != .element or n.tag != .script) continue;
        if (n.script_ran) continue;
        const src = n.script_text orelse continue;

        const res = js.eval(engine, src);
        n.script_ran = true;
        if (res.err) |e| {
            std.debug.print("js: {s} at byte {d}\n", .{ @tagName(e.kind), e.pos });
        }
        if (res.dirty) dirty = true;
    }
    return dirty;
}

fn parseInlineStyleTags(doc: *DocSession) void {
    if (doc.css_rules.items.len >= DocSession.max_total_css_rules) return;

    // `css.parseAppend` stores selector slices that reference the input bytes.
    // Inline <style> content is accumulated into a temporary buffer, so that
    // buffer must outlive the document.
    const a = doc.dom.alloc();
    var tmp: std.ArrayListUnmanaged(u8) = .{};
    defer tmp.deinit(a);

    var total_bytes: usize = 0;
    for (doc.dom.nodes.items) |n| {
        if (doc.css_rules.items.len >= DocSession.max_total_css_rules) break;
        if (total_bytes >= DocSession.max_stylesheet_bytes) break;
        if (n.kind != .element) continue;
        if (n.tag != .style) continue;

        tmp.items.len = 0;
        var child_opt = n.first_child;
        while (child_opt) |child| {
            const cn = doc.dom.node(child).*;
            if (cn.kind == .text) {
                const t = cn.text orelse &.{};
                if (t.len != 0 and tmp.items.len + t.len <= DocSession.max_stylesheet_bytes) {
                    tmp.appendSlice(a, t) catch break;
                }
            }
            child_opt = cn.next_sibling;
        }

        if (tmp.items.len == 0) continue;
        const remain = DocSession.max_stylesheet_bytes - total_bytes;
        const slice = tmp.items[0..@min(tmp.items.len, remain)];
        total_bytes += slice.len;
        css.parseAppend(doc.alloc, &doc.css_rules, slice, DocSession.max_total_css_rules);
    }
}

fn flushPendingStylesheets(conn: *ipc.Connection, doc_request_id: u32, doc: *DocSession) !void {
    if (doc.pending_stylesheets.items.len == 0) return;

    var scratch: [12 + 2048]u8 = undefined;
    for (doc.pending_stylesheets.items) |ss| {
        doc.ensureStylesheet(ss.resource_id, ss.href);
        if (ss.href.len > 2048) continue;
        std.mem.writeInt(u32, scratch[0..4], doc_request_id, .little);
        std.mem.writeInt(u32, scratch[4..8], ss.resource_id, .little);
        std.mem.writeInt(u32, scratch[8..12], @intCast(ss.href.len), .little);
        @memcpy(scratch[12..][0..ss.href.len], ss.href);
        try conn.send(.renderer_request_resource, scratch[0 .. 12 + ss.href.len]);
    }
    doc.pending_stylesheets.items.len = 0;
}

fn flushPendingImages(conn: *ipc.Connection, doc_request_id: u32, doc: *DocSession) !void {
    if (doc.pending_images.items.len == 0) return;

    var scratch: [12 + 2048]u8 = undefined;
    for (doc.pending_images.items) |img| {
        doc.ensureImage(img.resource_id, img.src);
        if (img.src.len > 2048) continue;
        std.mem.writeInt(u32, scratch[0..4], doc_request_id, .little);
        std.mem.writeInt(u32, scratch[4..8], img.resource_id, .little);
        std.mem.writeInt(u32, scratch[8..12], @intCast(img.src.len), .little);
        @memcpy(scratch[12..][0..img.src.len], img.src);
        try conn.send(.renderer_request_resource, scratch[0 .. 12 + img.src.len]);
    }
    doc.pending_images.items.len = 0;
}

fn gatherImageViews(doc: *const DocSession, buf: *[32]text_flow.ImageView) []const text_flow.ImageView {
    var n: usize = 0;
    for (doc.images.items) |img| {
        const d = img.decoded orelse continue;
        if (n >= buf.len) break;
        buf[n] = .{
            .resource_id = img.resource_id,
            .width = @intCast(d.width),
            .height = @intCast(d.height),
            .bgra = d.bgra,
        };
        n += 1;
    }
    return buf[0..n];
}

fn maybeFinishDoc(
    conn: *ipc.Connection,
    trace: *TraceWriter,
    artifacts: bool,
    run_dir: std.fs.Dir,
    request_id: u32,
    result: DocResult,
    doc: *DocSession,
) !void {
    if (doc.done_sent) return;
    if (!doc.html_done) return;
    if (doc.stylesheet_done < doc.stylesheet_total) return;

    var done_payload: [8]u8 = undefined;
    std.mem.writeInt(u32, done_payload[0..4], request_id, .little);
    std.mem.writeInt(u32, done_payload[4..8], @intFromEnum(result), .little);
    try conn.send(.renderer_document_done, done_payload[0..]);
    try trace.instant("renderer_doc_done", "renderer");
    doc.done_sent = true;

    if (artifacts) doc_render.dumpDocArtifacts(
        run_dir,
        &doc.dom,
        doc.viewport_w,
        doc.viewport_h,
        doc.bytes_received,
        doc.truncated,
    ) catch {};
}
