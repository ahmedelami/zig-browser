const std = @import("std");
const shared = @import("shared");

const ipc = shared.ipc;
const util = shared.util;

pub fn normalizeUrl(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len == 0) return try alloc.dupe(u8, "about:blank");
    if (std.mem.startsWith(u8, trimmed, "about:")) return try alloc.dupe(u8, trimmed);
    if (std.mem.indexOf(u8, trimmed, "://") != null) return try alloc.dupe(u8, trimmed);
    if (isLocalHost(trimmed)) return try std.fmt.allocPrint(alloc, "http://{s}", .{trimmed});
    if (shouldSearch(trimmed)) return buildSearchUrl(alloc, trimmed);
    return try std.fmt.allocPrint(alloc, "https://{s}", .{trimmed});
}

fn shouldSearch(input: []const u8) bool {
    // Heuristic: if it contains whitespace, or looks like a bare word without a dot/port/path,
    // treat it as a search query (so you can type "zig language" into the address bar).
    if (std.mem.indexOfAny(u8, input, " \t\r\n") != null) return true;

    // If it looks like a hostname/IP/relative path, don't search.
    if (std.mem.indexOfScalar(u8, input, '.') != null) return false;
    if (std.mem.indexOfScalar(u8, input, ':') != null) return false;
    if (std.mem.indexOfScalar(u8, input, '/') != null) return false;

    // Single token with no separators: treat as search.
    return true;
}

fn isLocalHost(input: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(input, "localhost")) return true;
    if (std.mem.startsWith(u8, input, "localhost:")) return true;
    if (std.mem.startsWith(u8, input, "127.0.0.1")) return true;
    if (std.mem.startsWith(u8, input, "0.0.0.0")) return true;
    return false;
}

fn buildSearchUrl(alloc: std.mem.Allocator, query_raw: []const u8) ![]u8 {
    const q = std.mem.trim(u8, query_raw, " \t\r\n");
    if (q.len == 0) return try alloc.dupe(u8, "about:blank");

    var out = try std.ArrayList(u8).initCapacity(alloc, 64 + q.len);
    errdefer out.deinit(alloc);

    const engine_raw = util.argValue("--search-engine") catch null;
    if (engine_raw) |eng| {
        if (std.ascii.eqlIgnoreCase(eng, "google")) {
            try out.appendSlice(alloc, "https://www.google.com/search?hl=en&q=");
        } else if (std.ascii.eqlIgnoreCase(eng, "bing")) {
            try out.appendSlice(alloc, "https://www.bing.com/search?q=");
        } else if (std.ascii.eqlIgnoreCase(eng, "ddg") or std.ascii.eqlIgnoreCase(eng, "duckduckgo")) {
            try out.appendSlice(alloc, "https://lite.duckduckgo.com/lite/?q=");
        } else {
            // Default: Google (may require JS/cookies for full results).
            try out.appendSlice(alloc, "https://www.google.com/search?hl=en&q=");
        }
    } else {
        // Default: Google (may require JS/cookies for full results).
        try out.appendSlice(alloc, "https://www.google.com/search?hl=en&q=");
    }

    for (q) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(alloc, c);
            continue;
        }
        if (c == ' ') {
            try out.append(alloc, '+');
            continue;
        }
        var buf: [3]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "%{X:0>2}", .{c}) catch continue;
        try out.appendSlice(alloc, &buf);
    }

    return out.toOwnedSlice(alloc);
}

pub fn netSendFetchUrl(alloc: std.mem.Allocator, net: *ipc.Connection, request_id: u32, url: []const u8) !void {
    const payload_len: usize = 8 + url.len;
    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);
    std.mem.writeInt(u32, payload[0..4], request_id, .little);
    std.mem.writeInt(u32, payload[4..8], @intCast(url.len), .little);
    @memcpy(payload[8..], url);

    try net.send(.net_fetch_url, payload);
}

pub fn netSendSetCookie(alloc: std.mem.Allocator, net: *ipc.Connection, url: []const u8, cookie: []const u8) !void {
    const payload_len: usize = 8 + url.len + cookie.len;
    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);
    std.mem.writeInt(u32, payload[0..4], @intCast(url.len), .little);
    @memcpy(payload[4..][0..url.len], url);
    const off = 4 + url.len;
    const cookie_len_ptr: *[4]u8 = @ptrCast(payload[off .. off + 4].ptr);
    std.mem.writeInt(u32, cookie_len_ptr, @intCast(cookie.len), .little);
    @memcpy(payload[off + 4 ..], cookie);
    try net.send(.net_set_cookie, payload);
}

pub fn rendererRenderHtml(alloc: std.mem.Allocator, renderer: *ipc.Connection, request_id: u32, html: []const u8) ![]u8 {
    const payload_len: usize = 8 + html.len;
    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);
    std.mem.writeInt(u32, payload[0..4], request_id, .little);
    std.mem.writeInt(u32, payload[4..8], @intCast(html.len), .little);
    @memcpy(payload[8..], html);

    try renderer.send(.renderer_render_html, payload);

    const frame = try renderer.recvAlloc(alloc);
    defer alloc.free(frame.payload);
    if (frame.header.msg_type != .renderer_display_list) return error.ExpectedRendererDisplayList;

    var idx: usize = 0;
    _ = try ipc.readInt(frame.payload, &idx, u32); // request_id
    const list_len = try ipc.readInt(frame.payload, &idx, u32);
    const list = try ipc.readBytes(frame.payload, &idx, @intCast(list_len));
    return try alloc.dupe(u8, list);
}

pub fn gpuSubmitDisplayList(alloc: std.mem.Allocator, gpu: *ipc.Connection, frame_id: u32, list: []const u8) !void {
    const payload_len: usize = 8 + list.len;
    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);
    std.mem.writeInt(u32, payload[0..4], frame_id, .little);
    std.mem.writeInt(u32, payload[4..8], @intCast(list.len), .little);
    @memcpy(payload[8..], list);

    try gpu.send(.gpu_submit_display_list, payload);

    const frame = try gpu.recvAlloc(alloc);
    defer alloc.free(frame.payload);
    if (frame.header.msg_type != .gpu_frame_ready) return error.ExpectedGpuFrameReady;
}

pub fn loadAboutHtml(alloc: std.mem.Allocator, run_dir_rel: []const u8, url: []const u8) ![]u8 {
    if (std.mem.eql(u8, url, "about:blank")) {
        return try alloc.dupe(u8, "<!doctype html><title>about:blank</title><body></body>");
    }

    if (std.mem.eql(u8, url, "about:version")) {
        const machine_path = try std.fs.path.join(alloc, &.{ run_dir_rel, "machine.json" });
        defer alloc.free(machine_path);
        const machine_json = try std.fs.cwd().readFileAlloc(alloc, machine_path, 1 << 20);
        defer alloc.free(machine_json);

        return try std.fmt.allocPrint(alloc, "<!doctype html><title>about:version</title><body><pre>{s}</pre></body>", .{machine_json});
    }

    if (std.mem.eql(u8, url, "about:tracing")) {
        var buf = try std.ArrayList(u8).initCapacity(alloc, 1024);
        errdefer buf.deinit(alloc);

        try buf.appendSlice(alloc, "<!doctype html><title>about:tracing</title><body><pre>\n");
        try buf.appendSlice(alloc, "Trace files live under the current run dir.\n\n");
        try buf.appendSlice(alloc, "Expected files:\n");
        try buf.appendSlice(alloc, "  trace-browser.json\n  trace-net.json\n  trace-renderer.json\n  trace-gpu.json\n");
        try buf.appendSlice(alloc, "</pre></body>");
        return buf.toOwnedSlice(alloc);
    }

    if (std.mem.eql(u8, url, "about:metrics")) {
        const nav_path = try std.fs.path.join(alloc, &.{ run_dir_rel, "nav_last.json" });
        defer alloc.free(nav_path);
        const nav_json = std.fs.cwd().readFileAlloc(alloc, nav_path, 64 * 1024) catch |err| {
            return try std.fmt.allocPrint(alloc, "<!doctype html><title>about:metrics</title><body><pre>missing nav_last.json: {s}</pre></body>", .{@errorName(err)});
        };
        defer alloc.free(nav_json);
        return try std.fmt.allocPrint(alloc, "<!doctype html><title>about:metrics</title><body><pre>{s}</pre></body>", .{nav_json});
    }

    if (std.mem.eql(u8, url, "about:js")) {
        const html = try alloc.dupe(u8,
            \\<!doctype html><title>about:js</title><body>
            \\<h1>about:js</h1>
            \\<p>Inline JS smoke test.</p>
            \\<script>
            \\console.log("js ok");
            \\document.title = "about:js (JS ok)";
            \\</script>
            \\<p>If JS ran, the header title should change.</p>
            \\</body>
        );
        return html;
    }

    if (std.mem.eql(u8, url, "about:cache")) {
        var dir = std.fs.cwd().openDir("run/http-cache", .{ .iterate = true }) catch |err| {
            return try std.fmt.allocPrint(alloc, "<!doctype html><title>about:cache</title><body><pre>cache dir unavailable: {s}</pre></body>", .{@errorName(err)});
        };
        defer dir.close();

        var count: u64 = 0;
        var total_bytes: u64 = 0;
        var it = dir.iterate();
        while (it.next() catch null) |ent| {
            if (ent.kind != .file) continue;
            if (!std.mem.endsWith(u8, ent.name, ".zbc")) continue;
            const st = dir.statFile(ent.name) catch continue;
            count += 1;
            total_bytes +|= st.size;
        }

        return try std.fmt.allocPrint(
            alloc,
            "<!doctype html><title>about:cache</title><body><pre>dir: run/http-cache\nentries: {d}\nbytes: {d}\n\n(clear by deleting run/http-cache/*.zbc)</pre></body>",
            .{ count, total_bytes },
        );
    }

    if (std.mem.eql(u8, url, "about:help")) {
        const help = try alloc.dupe(u8,
            \\<!doctype html><title>about:help</title><body>
            \\<h1>zig-browser</h1>
            \\<p>Tip: type a search query (e.g. <pre>zig language</pre>) to search (default: Google). Override: <pre>--search-engine ddg</pre> (DuckDuckGo Lite) or <pre>--search-engine bing</pre>.</p>
            \\<p>Commands (type into the address bar):</p>
            \\<ul>
            \\  <li><pre>:help</pre></li>
            \\  <li><pre>:links</pre> (list numbered links)</li>
            \\  <li><pre>:open N</pre> (open link N)</li>
            \\  <li><pre>:back</pre> / <pre>:forward</pre> / <pre>:reload</pre></li>
            \\</ul>
            \\<p>Debug pages:</p>
            \\<ul>
            \\  <li><pre>about:metrics</pre> (last navigation timings + cache source)</li>
            \\  <li><pre>about:cache</pre> (disk cache stats)</li>
            \\  <li><pre>about:js</pre> (JS smoke test)</li>
            \\  <li><pre>about:tracing</pre></li>
            \\</ul>
            \\</body>
        );
        return help;
    }

    // Future: about:cache, about:flags, about:memory, etc.
    return error.UnsupportedUrlScheme;
}
