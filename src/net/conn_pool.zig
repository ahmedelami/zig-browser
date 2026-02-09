const std = @import("std");

const http_conn = @import("http_conn.zig");

pub const ConnPool = struct {
    alloc: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    map: std.StringHashMapUnmanaged(Entry) = .{},

    total_idle: usize = 0,
    max_idle_total: usize = 32,
    max_idle_per_key: usize = 4,
    idle_timeout_ms: u64 = 30_000,

    const Idle = struct {
        conn: *http_conn.Conn,
        last_used_ms: u64,
    };

    const Entry = struct {
        idle: std.ArrayListUnmanaged(Idle) = .{},
    };

    pub fn init(alloc: std.mem.Allocator) ConnPool {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *ConnPool) void {
        self.mutex.lock();
        {
            var it = self.map.iterator();
            while (it.next()) |kv| {
                const key_owned = kv.key_ptr.*;
                var entry = kv.value_ptr.*;
                for (entry.idle.items) |item| {
                    discardConn(self.alloc, item.conn);
                }
                entry.idle.deinit(self.alloc);
                self.alloc.free(key_owned);
            }
            self.map.deinit(self.alloc);
        }
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn discard(self: *ConnPool, conn: *http_conn.Conn) void {
        discardConn(self.alloc, conn);
    }

    pub fn acquire(
        self: *ConnPool,
        alloc_for_connect: std.mem.Allocator,
        scheme: http_conn.Scheme,
        host: []const u8,
        port: u16,
        ca_bundle: ?*const std.crypto.Certificate.Bundle,
    ) !*http_conn.Conn {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());

        var key_buf: [std.Uri.host_name_max + 64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}|{s}|{d}", .{ @tagName(scheme), host, port });

        while (true) {
            var stale: ?*http_conn.Conn = null;

            self.mutex.lock();
            if (self.map.getPtr(key)) |entry| {
                if (entry.idle.items.len != 0) {
                    const item = entry.idle.pop().?;
                    self.total_idle -|= 1;

                    if (isExpired(now_ms, item.last_used_ms, self.idle_timeout_ms)) {
                        stale = item.conn;
                    } else {
                        // Remove empty entry (and free key) once all idles are drained.
                        if (entry.idle.items.len == 0) {
                            if (self.map.fetchRemove(key)) |removed| {
                                var removed_entry = removed.value;
                                removed_entry.idle.deinit(self.alloc);
                                self.alloc.free(removed.key);
                            }
                        }
                        self.mutex.unlock();
                        return item.conn;
                    }
                }

                if (entry.idle.items.len == 0) {
                    if (self.map.fetchRemove(key)) |removed| {
                        var removed_entry = removed.value;
                        removed_entry.idle.deinit(self.alloc);
                        self.alloc.free(removed.key);
                    }
                }
            }
            self.mutex.unlock();

            if (stale) |c| {
                discardConn(self.alloc, c);
                continue;
            }
            break;
        }

        const conn = try self.alloc.create(http_conn.Conn);
        errdefer self.alloc.destroy(conn);
        conn.init(alloc_for_connect, scheme, host, port, ca_bundle) catch |err| {
            self.alloc.destroy(conn);
            return err;
        };
        return conn;
    }

    pub fn release(self: *ConnPool, scheme: http_conn.Scheme, host: []const u8, port: u16, conn: *http_conn.Conn) void {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());

        var key_buf: [std.Uri.host_name_max + 64]u8 = undefined;
        const key_tmp = std.fmt.bufPrint(&key_buf, "{s}|{s}|{d}", .{ @tagName(scheme), host, port }) catch {
            // Key formatting failed; don't pool.
            discardConn(self.alloc, conn);
            return;
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        const entry_ptr = self.map.getPtr(key_tmp) orelse blk: {
            const key_owned = self.alloc.dupe(u8, key_tmp) catch {
                discardConn(self.alloc, conn);
                return;
            };
            self.map.put(self.alloc, key_owned, .{}) catch {
                self.alloc.free(key_owned);
                discardConn(self.alloc, conn);
                return;
            };
            break :blk self.map.getPtr(key_owned).?;
        };

        // Keep newest connections; evict oldest per-key if needed.
        if (entry_ptr.idle.items.len >= self.max_idle_per_key) {
            const victim = entry_ptr.idle.orderedRemove(0);
            discardConn(self.alloc, victim.conn);
            self.total_idle -|= 1;
        }

        entry_ptr.idle.append(self.alloc, .{ .conn = conn, .last_used_ms = now_ms }) catch {
            discardConn(self.alloc, conn);
            return;
        };
        self.total_idle += 1;

        // Enforce global cap.
        while (self.total_idle > self.max_idle_total) {
            if (!evictOneOldestLocked(self, now_ms)) break;
        }
    }

    fn isExpired(now_ms: u64, last_ms: u64, timeout_ms: u64) bool {
        if (timeout_ms == 0) return false;
        if (now_ms < last_ms) return false;
        return (now_ms - last_ms) > timeout_ms;
    }

    fn discardConn(alloc: std.mem.Allocator, conn: *http_conn.Conn) void {
        conn.deinit();
        alloc.destroy(conn);
    }

    fn evictOneOldestLocked(self: *ConnPool, now_ms: u64) bool {
        _ = now_ms;
        var best_key: ?[]const u8 = null;
        var best_idx: usize = 0;
        var best_entry: ?*Entry = null;
        var best_ts: u64 = std.math.maxInt(u64);

        var it = self.map.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr;
            for (entry.idle.items, 0..) |item, idx| {
                if (item.last_used_ms < best_ts) {
                    best_ts = item.last_used_ms;
                    best_key = kv.key_ptr.*;
                    best_entry = entry;
                    best_idx = idx;
                }
            }
        }

        const entry = best_entry orelse return false;
        const key = best_key orelse return false;

        const victim = entry.idle.swapRemove(best_idx);
        discardConn(self.alloc, victim.conn);
        self.total_idle -|= 1;

        if (entry.idle.items.len == 0) {
            const removed = self.map.fetchRemove(key) orelse return true;
            var removed_entry = removed.value;
            removed_entry.idle.deinit(self.alloc);
            self.alloc.free(removed.key);
        }
        return true;
    }
};
