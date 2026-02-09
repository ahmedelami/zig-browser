const std = @import("std");
const shared = @import("shared");

const ipc = shared.ipc;
const TraceWriter = shared.trace.TraceWriter;

const http = std.http;

const cache_mod = @import("cache.zig");
const cancel_mod = @import("cancel.zig");
const conn_pool = @import("conn_pool.zig");
const disk_cache = @import("disk_cache.zig");
const cookies_mod = @import("cookies.zig");
const fetch_tracker = @import("fetch_tracker.zig");
const http_conn = @import("http_conn.zig");
const stream_writer = @import("stream_writer.zig");

pub const FetchArgs = struct {
    alloc: std.mem.Allocator,
    conn: *ipc.Connection,
    send_mutex: *std.Thread.Mutex,
    trace: ?*TraceWriter,
    trace_mutex: *std.Thread.Mutex,
    ca_bundle: *const std.crypto.Certificate.Bundle,
    pool: *conn_pool.ConnPool,
    disk: ?*disk_cache.DiskCache,
    cookies: *cookies_mod.CookieJar,
    cache: *cache_mod.Cache,
    cancels: *cancel_mod.CancelManager,
    tracker: *fetch_tracker.FetchTracker,
    request_id: u32,
    url: []u8,
};

pub fn threadMain(args: FetchArgs) void {
    threadMainImpl(args) catch |err| {
        std.debug.print("net: fetch thread error: {s}\n", .{@errorName(err)});
    };
}

const CacheCapture = struct {
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(u8),
    max_bytes: usize,
    overflow: bool = false,

    fn onChunk(ctx: *anyopaque, bytes: []const u8) void {
        const self: *CacheCapture = @ptrCast(@alignCast(ctx));
        if (self.overflow) return;
        if (bytes.len == 0) return;
        if (self.list.items.len + bytes.len > self.max_bytes) {
            self.overflow = true;
            return;
        }
        self.list.appendSlice(self.alloc, bytes) catch {
            self.overflow = true;
        };
    }
};

fn threadMainImpl(args: FetchArgs) !void {
    const alloc = args.alloc;
    defer args.tracker.finish();

    var url_owned = args.url;
    var url_in_cache: bool = false;
    defer if (!url_in_cache) alloc.free(url_owned);

    var active_conn: ?*http_conn.Conn = null;
    var active_scheme: http_conn.Scheme = .http;
    var active_host: []const u8 = &.{};
    var active_port: u16 = 0;
    var reuse_conn: bool = false;
    defer {
        if (active_conn) |c| {
            if (reuse_conn) {
                args.pool.release(active_scheme, active_host, active_port, c);
            } else {
                args.pool.discard(c);
            }
        }
    }
    defer args.cancels.finish(args.request_id);

    traceInstantLocked(args.trace, args.trace_mutex, "net_fetch_start", "net");

    const max_total_bytes: usize = 16 * 1024 * 1024;
    const max_redirects: usize = 5;
    const max_head_len: usize = 64 * 1024;

    var status_code: u32 = 0;
    var result_kind: stream_writer.StreamResult = .ok;

    if (args.cancels.isCanceled(args.request_id)) {
        result_kind = .failed;
        sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, 0, .network) catch {};
        sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, 0, result_kind, 0) catch {};
        return;
    }

    var http_reader: http.Reader = undefined;
    var head: http.Client.Response.Head = undefined;

    var redirects_left: usize = max_redirects;
    var uri: std.Uri = undefined;
    var scheme: http_conn.Scheme = .http;
    var host_name_buf: [std.Uri.host_name_max]u8 = undefined;
    var host: []const u8 = &.{};
    var port: u16 = 0;
    var req_path: []const u8 = "/";
    while (true) {
        if (args.cancels.isCanceled(args.request_id)) {
            result_kind = .failed;
            sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, 0, .network) catch {};
            sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, 0, result_kind, 0) catch {};
            return;
        }

        uri = std.Uri.parse(url_owned) catch |err| {
            std.debug.print("net: url parse error: {s} url={s}\n", .{ @errorName(err), url_owned });
            result_kind = .failed;
            sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, 0, .network) catch {};
            sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, 0, result_kind, 0) catch {};
            return;
        };

        scheme = if (std.mem.eql(u8, uri.scheme, "https"))
            .https
        else if (std.mem.eql(u8, uri.scheme, "http"))
            .http
        else {
            std.debug.print("net: unsupported scheme: {s} url={s}\n", .{ uri.scheme, url_owned });
            result_kind = .failed;
            sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, 0, .network) catch {};
            sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, 0, result_kind, 0) catch {};
            return;
        };

        host = uri.getHost(&host_name_buf) catch |err| {
            std.debug.print("net: host parse error: {s} url={s}\n", .{ @errorName(err), url_owned });
            result_kind = .failed;
            sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, 0, .network) catch {};
            sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, 0, result_kind, 0) catch {};
            return;
        };

        port = uri.port orelse switch (scheme) {
            .https => 443,
            .http => 80,
        };
        req_path = uriPathForCookies(uri);

        // Redirects are handled by closing the current connection (we don't consume bodies on redirect).
        // For the terminal request, we may return the connection to the pool if keep-alive is allowed.
        reuse_conn = false;
        if (active_conn) |c| {
            args.pool.discard(c);
            active_conn = null;
        }

        // Retry once on a dead keep-alive connection (common when servers close idle conns).
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            active_conn = args.pool.acquire(alloc, scheme, host, port, args.ca_bundle) catch |err| {
                std.debug.print("net: connect error: {s} url={s}\n", .{ @errorName(err), url_owned });
                result_kind = .failed;
                sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, 0, .network) catch {};
                sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, 0, result_kind, 0) catch {};
                return;
            };
            active_scheme = scheme;
            active_host = host;
            active_port = port;
            args.cancels.register(args.request_id, active_conn.?.fd());

            const cookie_header = args.cookies.buildCookieHeader(alloc, scheme, host, req_path);
            defer if (cookie_header) |h| alloc.free(h);
            writeGetRequest(active_conn.?.writer(), host, uri, cookie_header) catch |err| {
                if (attempts == 0) {
                    args.pool.discard(active_conn.?);
                    active_conn = null;
                    continue;
                }
                std.debug.print("net: send error: {s} url={s}\n", .{ @errorName(err), url_owned });
                result_kind = .failed;
                sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, 0, .network) catch {};
                sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, 0, result_kind, 0) catch {};
                return;
            };
            active_conn.?.flush() catch |err| {
                if (attempts == 0) {
                    args.pool.discard(active_conn.?);
                    active_conn = null;
                    continue;
                }
                std.debug.print("net: flush error: {s} url={s}\n", .{ @errorName(err), url_owned });
                result_kind = .failed;
                sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, 0, .network) catch {};
                sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, 0, result_kind, 0) catch {};
                return;
            };
            break;
        }

        http_reader = .{
            .in = active_conn.?.reader(),
            .interface = undefined,
            .state = .ready,
            .max_head_len = max_head_len,
        };
        const head_bytes = http_reader.receiveHead() catch |err| {
            if ((err == error.HttpConnectionClosing or err == error.HttpRequestTruncated) and attempts == 0) {
                // Retry once when the server closed an idle keep-alive connection before responding.
                args.pool.discard(active_conn.?);
                active_conn = null;
                continue;
            }
            std.debug.print("net: receive head error: {s} url={s}\n", .{ @errorName(err), url_owned });
            result_kind = .failed;
            sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, 0, .network) catch {};
            sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, 0, result_kind, 0) catch {};
            return;
        };

        head = http.Client.Response.Head.parse(head_bytes) catch |err| {
            if (err == error.HttpHeadersInvalid and attempts == 0) {
                // Best-effort retry once (some servers can send garbage if a keep-alive connection
                // was silently closed).
                args.pool.discard(active_conn.?);
                active_conn = null;
                continue;
            }
            std.debug.print("net: head parse error: {s} url={s}\n", .{ @errorName(err), url_owned });
            result_kind = .failed;
            sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, 0, .network) catch {};
            sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, 0, result_kind, 0) catch {};
            return;
        };

        status_code = @intFromEnum(head.status);
        args.cookies.ingestFromHead(scheme, host, req_path, head);

        if (redirects_left != 0) {
            if (head.location) |loc_raw| {
                const code = status_code;
                if (code == 300 or code == 301 or code == 302 or code == 303 or code == 307 or code == 308) {
                    const loc = std.mem.trim(u8, loc_raw, " \t\r\n");
                    if (loc.len != 0) {
                        const next_url = resolveRedirectUrl(alloc, uri, loc) catch |err| {
                            std.debug.print("net: redirect resolve error: {s} url={s}\n", .{ @errorName(err), url_owned });
                            break;
                        };
                        redirects_left -= 1;
                        alloc.free(url_owned);
                        url_owned = next_url;
                        continue;
                    }
                }
            }
        }

        break;
    }

    sendNetFetchBegin(args.conn, args.send_mutex, args.request_id, status_code, .network) catch {};
    const status_ok = status_code >= 200 and status_code < 300;

    var cache_body: std.ArrayListUnmanaged(u8) = .{};
    defer cache_body.deinit(alloc);

    var capture: CacheCapture = .{
        .alloc = alloc,
        .list = &cache_body,
        .max_bytes = args.cache.max_entry_body_bytes,
    };
    const sink: ?stream_writer.ChunkSink = if (status_ok) .{ .ctx = &capture, .onChunk = CacheCapture.onChunk } else null;

    var body_to_ipc = stream_writer.ChunkedIpcWriter.init(
        alloc,
        args.conn,
        args.send_mutex,
        args.request_id,
        max_total_bytes,
        sink,
    ) catch |err| {
        std.debug.print("net: writer init error: {s} url={s}\n", .{ @errorName(err), url_owned });
        result_kind = .failed;
        sendNetFetchEnd(args.conn, args.send_mutex, args.request_id, status_code, result_kind, 0) catch {};
        return;
    };
    defer body_to_ipc.deinit();

    var transfer_buf: [64]u8 = undefined;

    // Stability-first: don't negotiate gzip/deflate right now (see request headers),
    // and fail fast if a server still sends compressed bodies.
    if (head.content_encoding != .identity) {
        std.debug.print("net: unsupported content-encoding={s} url={s}\n", .{ @tagName(head.content_encoding), url_owned });
        result_kind = .failed;
    } else {
        const body_reader = http_reader.bodyReader(
            &transfer_buf,
            head.transfer_encoding,
            head.content_length,
        );

        while (true) {
            if (args.cancels.isCanceled(args.request_id)) {
                result_kind = .failed;
                break;
            }
            const n = body_reader.stream(&body_to_ipc.writer, .limited(stream_writer.stream_chunk_bytes)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.WriteFailed => {
                    result_kind = if (body_to_ipc.truncated) .truncated else .failed;
                    break;
                },
                error.ReadFailed => {
                    result_kind = .failed;
                    break;
                },
            };
            if (n == 0) continue;

            body_to_ipc.flushAvailable() catch {
                result_kind = if (body_to_ipc.truncated) .truncated else .failed;
                break;
            };
        }
    }

    body_to_ipc.flushAll() catch {
        if (result_kind == .ok) result_kind = if (body_to_ipc.truncated) .truncated else .failed;
    };

    sendNetFetchEnd(
        args.conn,
        args.send_mutex,
        args.request_id,
        status_code,
        result_kind,
        @intCast(body_to_ipc.total_sent),
    ) catch {};

    const cache_ok = result_kind == .ok and status_ok and !capture.overflow and !args.cancels.isCanceled(args.request_id);
    cache_store: {
        if (!cache_ok) break :cache_store;
        if (cache_body.items.len == 0) break :cache_store;
        const cache_bytes = cache_body.items.len;
        const body_owned = cache_body.toOwnedSlice(alloc) catch break :cache_store;
        if (args.disk) |d| {
            if (d.put(url_owned, status_code, body_owned)) {
                std.debug.print("net: disk cache store: {s} bytes={d}\n", .{ url_owned, cache_bytes });
            }
        }
        std.debug.print("net: cache store: {s} bytes={d}\n", .{ url_owned, cache_bytes });
        args.cache.putOwned(url_owned, status_code, body_owned);
        url_in_cache = true;
    }

    traceInstantLocked(args.trace, args.trace_mutex, "net_fetch_done", "net");

    const can_keep_alive = head.keep_alive and !(head.transfer_encoding == .none and head.content_length == null);
    reuse_conn = result_kind == .ok and status_ok and can_keep_alive and !args.cancels.isCanceled(args.request_id);
}

fn uriPathForCookies(uri: std.Uri) []const u8 {
    const uri_path: std.Uri.Component = if (uri.path.isEmpty()) .{ .percent_encoded = "/" } else uri.path;
    return switch (uri_path) {
        .raw => |s| if (s.len == 0) "/" else s,
        .percent_encoded => |s| if (s.len == 0) "/" else s,
    };
}

fn writeGetRequest(w: *std.Io.Writer, host: []const u8, uri: std.Uri, cookie_header: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll("GET ");

    const uri_path: std.Uri.Component = if (uri.path.isEmpty()) .{ .percent_encoded = "/" } else uri.path;
    try uri_path.formatPath(w);
    if (uri.query) |q| {
        try w.writeByte('?');
        try q.formatQuery(w);
    }

    try w.writeAll(" HTTP/1.1\r\n");
    try w.print("Host: {s}\r\n", .{host});
    try w.writeAll("User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36\r\n");
    try w.writeAll("Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n");
    try w.writeAll("Accept-Language: en-US,en;q=0.9\r\n");
    try w.writeAll("Connection: keep-alive\r\n");
    if (cookie_header) |c| {
        try w.writeAll("Cookie: ");
        try w.writeAll(c);
        try w.writeAll("\r\n");
    }
    try w.writeAll("\r\n");
}

fn resolveRedirectUrl(alloc: std.mem.Allocator, base: std.Uri, location: []const u8) ![]u8 {
    if (location.len > 8 * 1024) return error.RedirectLocationTooLong;

    const base_path_len: usize = switch (base.path) {
        .raw => |s| s.len,
        .percent_encoded => |s| s.len,
    };

    const extra: usize = base_path_len + 512;
    var buf = try alloc.alloc(u8, location.len + extra);
    defer alloc.free(buf);

    @memcpy(buf[0..location.len], location);
    var aux_buf = buf;
    const resolved = try std.Uri.resolveInPlace(base, location.len, &aux_buf);

    return try std.fmt.allocPrint(alloc, "{f}", .{resolved.fmt(.all)});
}

fn sendLocked(conn: *ipc.Connection, mutex: *std.Thread.Mutex, msg_type: ipc.MsgType, payload: []const u8) !void {
    mutex.lock();
    defer mutex.unlock();
    try conn.send(msg_type, payload);
}

fn traceInstantLocked(trace: ?*TraceWriter, mutex: *std.Thread.Mutex, name: []const u8, cat: []const u8) void {
    const t = trace orelse return;
    mutex.lock();
    defer mutex.unlock();
    t.instant(name, cat) catch {};
}

pub fn sendNetFetchBegin(
    conn: *ipc.Connection,
    mutex: *std.Thread.Mutex,
    request_id: u32,
    status_code: u32,
    source: ipc.NetSource,
) !void {
    var payload: [12]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], request_id, .little);
    std.mem.writeInt(u32, payload[4..8], status_code, .little);
    std.mem.writeInt(u32, payload[8..12], @intFromEnum(source), .little);
    try sendLocked(conn, mutex, .net_fetch_begin, payload[0..]);
}

pub fn sendNetFetchEnd(
    conn: *ipc.Connection,
    mutex: *std.Thread.Mutex,
    request_id: u32,
    status_code: u32,
    result_kind: stream_writer.StreamResult,
    total_sent: u32,
) !void {
    var payload: [16]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], request_id, .little);
    std.mem.writeInt(u32, payload[4..8], status_code, .little);
    std.mem.writeInt(u32, payload[8..12], @intFromEnum(result_kind), .little);
    std.mem.writeInt(u32, payload[12..16], total_sent, .little);
    try sendLocked(conn, mutex, .net_fetch_end, payload[0..]);
}

pub fn sendNetFetchChunk(
    conn: *ipc.Connection,
    mutex: *std.Thread.Mutex,
    request_id: u32,
    bytes: []const u8,
) !void {
    if (bytes.len == 0) return;
    if (bytes.len > stream_writer.stream_chunk_bytes) return error.BadPayload;

    var scratch: [8 + stream_writer.stream_chunk_bytes]u8 = undefined;
    std.mem.writeInt(u32, scratch[0..4], request_id, .little);
    std.mem.writeInt(u32, scratch[4..8], @intCast(bytes.len), .little);
    @memcpy(scratch[8..][0..bytes.len], bytes);
    try sendLocked(conn, mutex, .net_fetch_chunk, scratch[0 .. 8 + bytes.len]);
}
