const std = @import("std");
const shared = @import("shared");

const ipc = shared.ipc;
const util = shared.util;

const nav_links = @import("nav_links.zig");
const nav_support = @import("nav_support.zig");
const url_mod = @import("url.zig");

pub const Prefetcher = struct {
    alloc: std.mem.Allocator,
    net: *ipc.Connection,

    inflight: std.ArrayListUnmanaged(u32) = .{},
    max_inflight: usize = 4,
    max_per_nav: usize = 3,

    pub fn init(self: *Prefetcher, alloc: std.mem.Allocator, net: *ipc.Connection) void {
        self.* = .{
            .alloc = alloc,
            .net = net,
        };
    }

    pub fn deinit(self: *Prefetcher) void {
        self.inflight.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn cancelAll(self: *Prefetcher) void {
        for (self.inflight.items) |rid| {
            var payload: [4]u8 = undefined;
            std.mem.writeInt(u32, payload[0..4], rid, .little);
            self.net.send(.net_cancel_request, payload[0..]) catch {};
        }
        self.inflight.items.len = 0;
    }

    pub fn onNetFetchEnd(self: *Prefetcher, request_id: u32) void {
        var i: usize = 0;
        while (i < self.inflight.items.len) : (i += 1) {
            if (self.inflight.items[i] == request_id) {
                _ = self.inflight.swapRemove(i);
                break;
            }
        }
    }

    pub fn maybeStart(self: *Prefetcher, request_id_counter: *u32, base_url: []const u8, links: []const nav_links.Link) void {
        if (self.inflight.items.len >= self.max_inflight) return;
        if (links.len == 0) return;
        if (std.mem.startsWith(u8, base_url, "about:")) return;

        const debug = util.hasArg("--prefetch-debug");
        var base_host_buf: [std.Uri.host_name_max]u8 = undefined;
        const base_uri = std.Uri.parse(base_url) catch return;
        const base_host = base_uri.getHost(&base_host_buf) catch return;

        var origin_buf: [std.Uri.host_name_max + 80]u8 = undefined;
        const origin = if (base_uri.port) |p|
            std.fmt.bufPrint(&origin_buf, "{s}://{s}:{d}", .{ base_uri.scheme, base_host, p }) catch return
        else
            std.fmt.bufPrint(&origin_buf, "{s}://{s}", .{ base_uri.scheme, base_host }) catch return;

        if (debug) std.debug.print("browser: prefetch origin={s} base={s}\n", .{ origin, base_url });

        var started: usize = 0;
        var seen_hashes: [8]u64 = undefined;
        var seen_len: usize = 0;
        seen_hashes[0] = std.hash.Wyhash.hash(0, base_url);
        seen_len = 1;

        for (links) |lnk| {
            if (started >= self.max_per_nav) break;
            if (self.inflight.items.len >= self.max_inflight) break;

            // Resolve (and filter) to same-host http(s) URLs.
            const resolved = url_mod.resolveHref(self.alloc, base_url, lnk.href) catch continue;
            defer self.alloc.free(resolved);

            if (resolved.len > 2048) continue;
            if (!(std.mem.startsWith(u8, resolved, "https://") or std.mem.startsWith(u8, resolved, "http://"))) continue;

            const h = std.hash.Wyhash.hash(0, resolved);
            var dup = false;
            for (seen_hashes[0..seen_len]) |prev| {
                if (prev == h) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            if (seen_len < seen_hashes.len) {
                seen_hashes[seen_len] = h;
                seen_len += 1;
            }

            if (!std.mem.startsWith(u8, resolved, origin)) continue;
            const next = resolved[origin.len..];
            if (next.len != 0 and next[0] != '/' and next[0] != ':' and next[0] != '?' and next[0] != '#') continue;

            const rid = request_id_counter.*;
            request_id_counter.* +%= 1;
            self.inflight.append(self.alloc, rid) catch {};
            nav_support.netSendFetchUrl(self.alloc, self.net, rid, resolved) catch {};
            if (debug) std.debug.print("browser: prefetch rid={d} url={s}\n", .{ rid, resolved });
            started += 1;
        }
    }
};
