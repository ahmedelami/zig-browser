const std = @import("std");
const shared = @import("shared");

const ProcessKind = shared.process_kind.ProcessKind;
const ipc = shared.ipc;
const TraceWriter = shared.trace.TraceWriter;
const util = shared.util;

const cache_mod = @import("cache.zig");
const cancel_mod = @import("cancel.zig");
const conn_pool = @import("conn_pool.zig");
const cookies_mod = @import("cookies.zig");
const disk_cache = @import("disk_cache.zig");
const fetch_tracker = @import("fetch_tracker.zig");
const fetch_worker = @import("fetch_worker.zig");
const http_conn = @import("http_conn.zig");
const stream_writer = @import("stream_writer.zig");

const FetchTracker = fetch_tracker.FetchTracker;
const FetchArgs = fetch_worker.FetchArgs;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const connect_path = (try util.argValue("--connect")) orelse return error.MissingConnect;
    const run_dir_path = (try util.argValue("--run-dir")) orelse return error.MissingRunDir;

    const pid: u32 = @intCast(std.c.getpid());
    const tid: u32 = 0;

    var run_dir = try std.fs.cwd().openDir(run_dir_path, .{});
    defer run_dir.close();

    var trace = try TraceWriter.init(alloc, run_dir, "trace-net.json", pid, tid);
    defer trace.deinit();
    try trace.metaProcessName("zb_net");
    try trace.metaThreadName("main");
    try trace.instant("net_start", "lifecycle");

    var stream = try ipc.connectUnix(connect_path);
    defer stream.close();

    var conn: ipc.Connection = .{ .stream = stream };

    var hello_buf: [5]u8 = undefined;
    const hello_payload = ipc.encodeHello(&hello_buf, .{ .kind = .net, .pid = pid });
    try conn.send(.hello, hello_payload);

    var send_mutex = std.Thread.Mutex{};
    var trace_mutex = std.Thread.Mutex{};

    var cache = cache_mod.Cache.init(alloc);
    defer cache.deinit();

    var cancels = cancel_mod.CancelManager.init(alloc);
    defer cancels.deinit();

    var pool = conn_pool.ConnPool.init(alloc);
    defer pool.deinit();

    var cookies = cookies_mod.CookieJar.init(alloc);
    defer cookies.deinit();

    var disk_opt: ?disk_cache.DiskCache = disk_cache.DiskCache.init(alloc, "run/http-cache") catch |err| blk: {
        std.debug.print("net: disk cache disabled: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (disk_opt) |*d| d.deinit();

    var ca_bundle: std.crypto.Certificate.Bundle = .{};
    defer ca_bundle.deinit(alloc);
    ca_bundle.rescan(alloc) catch |err| {
        std.debug.print("net: ca bundle rescan failed: {s}\n", .{@errorName(err)});
    };

    var tracker: FetchTracker = .{};

    while (true) {
        const frame = conn.recvAlloc(alloc) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer alloc.free(frame.payload);

        switch (frame.header.msg_type) {
            .ping => {
                try sendLocked(&conn, &send_mutex, .pong, "");
            },
            .shutdown => break,
            .net_fetch_url => {
                var idx: usize = 0;
                const request_id = try ipc.readInt(frame.payload, &idx, u32);
                const url_len = try ipc.readInt(frame.payload, &idx, u32);
                const url = try ipc.readBytes(frame.payload, &idx, @intCast(url_len));

                if (cache.getCopy(alloc, url)) |hit| {
                    defer alloc.free(hit.body);

                    traceInstantLocked(&trace, &trace_mutex, "net_cache_hit", "net");
                    std.debug.print("net: cache hit: {s}\n", .{url});

                    fetch_worker.sendNetFetchBegin(&conn, &send_mutex, request_id, hit.status_code, .mem_cache) catch {};
                    var off: usize = 0;
                    while (off < hit.body.len) {
                        const n = @min(stream_writer.stream_chunk_bytes, hit.body.len - off);
                        fetch_worker.sendNetFetchChunk(&conn, &send_mutex, request_id, hit.body[off .. off + n]) catch {};
                        off += n;
                    }
                    fetch_worker.sendNetFetchEnd(&conn, &send_mutex, request_id, hit.status_code, .ok, @intCast(hit.body.len)) catch {};
                    continue;
                }

                if (disk_opt) |*disk| {
                    if (disk.getCopy(alloc, url)) |hit| {
                        traceInstantLocked(&trace, &trace_mutex, "net_disk_cache_hit", "net");
                        std.debug.print("net: disk cache hit: {s}\n", .{url});

                        fetch_worker.sendNetFetchBegin(&conn, &send_mutex, request_id, hit.status_code, .disk_cache) catch {};
                        var off: usize = 0;
                        while (off < hit.body.len) {
                            const n = @min(stream_writer.stream_chunk_bytes, hit.body.len - off);
                            fetch_worker.sendNetFetchChunk(&conn, &send_mutex, request_id, hit.body[off .. off + n]) catch {};
                            off += n;
                        }
                        fetch_worker.sendNetFetchEnd(&conn, &send_mutex, request_id, hit.status_code, .ok, @intCast(hit.body.len)) catch {};

                        // Warm the in-memory cache for fast reuse within this run.
                        const url_owned = alloc.dupe(u8, url) catch {
                            alloc.free(hit.body);
                            continue;
                        };
                        cache.putOwned(url_owned, hit.status_code, hit.body);
                        continue;
                    }
                }

                const url_owned = try alloc.dupe(u8, url);
                const args = FetchArgs{
                    .alloc = alloc,
                    .conn = &conn,
                    .send_mutex = &send_mutex,
                    .trace = &trace,
                    .trace_mutex = &trace_mutex,
                    .ca_bundle = &ca_bundle,
                    .pool = &pool,
                    .disk = if (disk_opt) |*d| d else null,
                    .cookies = &cookies,
                    .cache = &cache,
                    .cancels = &cancels,
                    .tracker = &tracker,
                    .request_id = request_id,
                    .url = url_owned,
                };

                tracker.start();
                const t = std.Thread.spawn(.{}, fetch_worker.threadMain, .{args}) catch |err| {
                    tracker.finish();
                    alloc.free(url_owned);
                    return err;
                };
                t.detach();
            },
            .net_cancel_request => {
                var idx: usize = 0;
                const request_id = try ipc.readInt(frame.payload, &idx, u32);
                cancels.cancel(request_id);
                traceInstantLocked(&trace, &trace_mutex, "net_cancel", "net");
            },
            .net_set_cookie => {
                var idx: usize = 0;
                const url_len = try ipc.readInt(frame.payload, &idx, u32);
                const url = try ipc.readBytes(frame.payload, &idx, @intCast(url_len));
                const cookie_len = try ipc.readInt(frame.payload, &idx, u32);
                const cookie = try ipc.readBytes(frame.payload, &idx, @intCast(cookie_len));
                if (url.len == 0 or cookie.len == 0) continue;

                const uri = std.Uri.parse(url) catch continue;
                const scheme: http_conn.Scheme = if (std.mem.eql(u8, uri.scheme, "https"))
                    .https
                else if (std.mem.eql(u8, uri.scheme, "http"))
                    .http
                else
                    continue;

                var host_name_buf: [std.Uri.host_name_max]u8 = undefined;
                const host = uri.getHost(&host_name_buf) catch continue;
                const req_path = uriPathForCookies(uri);

                cookies.ingestSetCookie(scheme, host, req_path, cookie);
                std.debug.print("net: cookie set: host={s}\n", .{host});
                traceInstantLocked(&trace, &trace_mutex, "net_set_cookie", "net");
            },
            else => {},
        }
    }

    cancels.cancelAll();
    tracker.waitAllTimeout(2 * std.time.ns_per_s) catch {};
    try trace.instant("net_exit", "lifecycle");
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

fn uriPathForCookies(uri: std.Uri) []const u8 {
    const uri_path: std.Uri.Component = if (uri.path.isEmpty()) .{ .percent_encoded = "/" } else uri.path;
    return switch (uri_path) {
        .raw => |s| if (s.len == 0) "/" else s,
        .percent_encoded => |s| if (s.len == 0) "/" else s,
    };
}
