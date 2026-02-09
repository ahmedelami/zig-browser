const std = @import("std");

pub const Hit = struct {
    status_code: u32,
    body: []u8,
};

pub const Cache = struct {
    alloc: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    map: std.StringHashMapUnmanaged(Entry) = .{},
    total_bytes: usize = 0,
    use_counter: u64 = 0,

    max_entries: usize = 128,
    max_bytes: usize = 64 * 1024 * 1024,
    max_entry_body_bytes: usize = 2 * 1024 * 1024,

    const Entry = struct {
        url: []u8,
        status_code: u32,
        body: []u8,
        last_use: u64,
    };

    pub fn init(alloc: std.mem.Allocator) Cache {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Cache) void {
        self.mutex.lock();
        var it = self.map.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            self.alloc.free(e.body);
            self.alloc.free(e.url);
        }
        self.map.deinit(self.alloc);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn getCopy(self: *Cache, alloc: std.mem.Allocator, url: []const u8) ?Hit {
        self.mutex.lock();
        defer self.mutex.unlock();

        var e = self.map.getPtr(url) orelse return null;
        self.use_counter +%= 1;
        e.last_use = self.use_counter;

        const body_copy = alloc.dupe(u8, e.body) catch return null;
        return .{ .status_code = e.status_code, .body = body_copy };
    }

    pub fn putOwned(self: *Cache, url_owned: []u8, status_code: u32, body_owned: []u8) void {
        if (status_code == 0 or body_owned.len == 0) {
            self.alloc.free(body_owned);
            self.alloc.free(url_owned);
            return;
        }
        if (body_owned.len > self.max_entry_body_bytes) {
            self.alloc.free(body_owned);
            self.alloc.free(url_owned);
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        self.use_counter +%= 1;
        const e: Entry = .{
            .url = url_owned,
            .status_code = status_code,
            .body = body_owned,
            .last_use = self.use_counter,
        };

        const entry_bytes = url_owned.len + body_owned.len;
        const old = self.map.fetchPut(self.alloc, url_owned, e) catch {
            self.alloc.free(body_owned);
            self.alloc.free(url_owned);
            return;
        };

        if (old) |kv| {
            const prev = kv.value;
            self.total_bytes -|= prev.url.len + prev.body.len;
            self.alloc.free(prev.body);
            self.alloc.free(prev.url);
        }
        self.total_bytes += entry_bytes;

        self.evictIfNeeded();
    }

    fn evictIfNeeded(self: *Cache) void {
        while (self.map.count() > self.max_entries or self.total_bytes > self.max_bytes) {
            var oldest_key: ?[]const u8 = null;
            var oldest_use: u64 = std.math.maxInt(u64);

            var it = self.map.iterator();
            while (it.next()) |kv| {
                const e = kv.value_ptr.*;
                if (e.last_use < oldest_use) {
                    oldest_use = e.last_use;
                    oldest_key = kv.key_ptr.*;
                }
            }

            const k = oldest_key orelse break;
            const removed = self.map.fetchRemove(k) orelse break;
            const prev = removed.value;
            self.total_bytes -|= prev.url.len + prev.body.len;
            self.alloc.free(prev.body);
            self.alloc.free(prev.url);
        }
    }
};
