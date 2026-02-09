const std = @import("std");

pub const Hit = struct {
    status_code: u32,
    body: []u8,
};

pub const DiskCache = struct {
    alloc: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    dir_path: []u8,

    max_entries: usize = 2048,
    max_bytes: usize = 256 * 1024 * 1024,
    max_entry_body_bytes: usize = 2 * 1024 * 1024,

    const magic = [_]u8{ 'Z', 'B', 'C', '1' };
    const version: u16 = 1;
    const header_len: usize = 4 + 2 + 2 + 4 + 4 + 4; // magic + version + reserved + status + url_len + body_len

    pub fn init(alloc: std.mem.Allocator, dir_path: []const u8) !DiskCache {
        try std.fs.cwd().makePath(dir_path);
        return .{ .alloc = alloc, .dir_path = try alloc.dupe(u8, dir_path) };
    }

    pub fn deinit(self: *DiskCache) void {
        self.alloc.free(self.dir_path);
        self.* = undefined;
    }

    pub fn getCopy(self: *DiskCache, alloc: std.mem.Allocator, url: []const u8) ?Hit {
        self.mutex.lock();
        defer self.mutex.unlock();

        var name_buf: [72]u8 = undefined;
        const name = cacheFileName(url, &name_buf);

        var dir = std.fs.cwd().openDir(self.dir_path, .{}) catch return null;
        defer dir.close();

        const max_file_bytes = header_len + url.len + self.max_entry_body_bytes;
        const bytes = dir.readFileAlloc(alloc, name, max_file_bytes) catch return null;
        defer alloc.free(bytes);

        const parsed = parseEntry(bytes, url) catch {
            dir.deleteFile(name) catch {};
            return null;
        };

        const body = alloc.dupe(u8, parsed.body) catch return null;
        return .{ .status_code = parsed.status_code, .body = body };
    }

    pub fn put(self: *DiskCache, url: []const u8, status_code: u32, body: []const u8) bool {
        if (status_code == 0) return false;
        if (body.len == 0) return false;
        if (body.len > self.max_entry_body_bytes) return false;

        self.mutex.lock();
        defer self.mutex.unlock();

        var dir = std.fs.cwd().openDir(self.dir_path, .{}) catch return false;
        defer dir.close();

        var name_buf: [72]u8 = undefined;
        const final_name = cacheFileName(url, &name_buf);

        var tmp_buf: [96]u8 = undefined;
        const ts: u64 = @intCast(std.time.milliTimestamp());
        const pid: u32 = @intCast(std.c.getpid());
        const tmp_name = std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}.{d}", .{ final_name, pid, ts }) catch return false;

        const file = dir.createFile(tmp_name, .{ .truncate = true, .exclusive = true }) catch return false;
        defer file.close();

        var header: [header_len]u8 = undefined;
        @memcpy(header[0..4], &magic);
        std.mem.writeInt(u16, header[4..6], version, .little);
        std.mem.writeInt(u16, header[6..8], 0, .little);
        std.mem.writeInt(u32, header[8..12], status_code, .little);
        std.mem.writeInt(u32, header[12..16], @intCast(url.len), .little);
        std.mem.writeInt(u32, header[16..20], @intCast(body.len), .little);

        var buf: [64 * 1024]u8 = undefined;
        var w = file.writer(&buf);
        w.interface.writeAll(&header) catch {
            dir.deleteFile(tmp_name) catch {};
            return false;
        };
        w.interface.writeAll(url) catch {
            dir.deleteFile(tmp_name) catch {};
            return false;
        };
        w.interface.writeAll(body) catch {
            dir.deleteFile(tmp_name) catch {};
            return false;
        };
        w.interface.flush() catch {};
        file.sync() catch {};

        dir.rename(tmp_name, final_name) catch {
            dir.deleteFile(tmp_name) catch {};
            return false;
        };

        evictIfNeededLocked(self, dir) catch {};
        return true;
    }

    const Parsed = struct {
        status_code: u32,
        body: []const u8,
    };

    fn parseEntry(bytes: []const u8, url: []const u8) !Parsed {
        if (bytes.len < header_len) return error.BadCacheEntry;
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.BadCacheEntry;
        const ver = std.mem.readInt(u16, bytes[4..6], .little);
        if (ver != version) return error.BadCacheEntry;

        const status_code = std.mem.readInt(u32, bytes[8..12], .little);
        const url_len = std.mem.readInt(u32, bytes[12..16], .little);
        const body_len = std.mem.readInt(u32, bytes[16..20], .little);

        const total_needed: usize = header_len + @as(usize, url_len) + @as(usize, body_len);
        if (total_needed != bytes.len) return error.BadCacheEntry;
        if (url_len != url.len) return error.BadCacheEntry;

        const url_bytes = bytes[header_len .. header_len + url_len];
        if (!std.mem.eql(u8, url_bytes, url)) return error.BadCacheEntry;

        const body_bytes = bytes[header_len + url_len ..][0..body_len];
        return .{ .status_code = status_code, .body = body_bytes };
    }

    fn cacheFileName(url: []const u8, out: *[72]u8) []const u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return std.fmt.bufPrint(out, "{s}.zbc", .{hex[0..]}) catch unreachable;
    }

    const DiskEntry = struct {
        name: []u8,
        size: u64,
        mtime: i128,
    };

    fn evictIfNeededLocked(self: *DiskCache, dir: std.fs.Dir) !void {
        var entries = try std.ArrayList(DiskEntry).initCapacity(self.alloc, 128);
        defer {
            for (entries.items) |e| self.alloc.free(e.name);
            entries.deinit(self.alloc);
        }

        var total_bytes: u64 = 0;
        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (ent.kind != .file) continue;
            if (!std.mem.endsWith(u8, ent.name, ".zbc")) continue;

            const st = dir.statFile(ent.name) catch continue;
            total_bytes +|= st.size;
            entries.append(self.alloc, .{
                .name = try self.alloc.dupe(u8, ent.name),
                .size = st.size,
                .mtime = st.mtime,
            }) catch {};
        }

        if (entries.items.len <= self.max_entries and total_bytes <= self.max_bytes) return;

        std.sort.pdq(DiskEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: DiskEntry, b: DiskEntry) bool {
                return a.mtime < b.mtime;
            }
        }.lessThan);

        var i: usize = 0;
        while (i < entries.items.len and (entries.items.len - i > self.max_entries or total_bytes > self.max_bytes)) : (i += 1) {
            const victim = entries.items[i];
            dir.deleteFile(victim.name) catch continue;
            total_bytes -|= victim.size;
        }
    }
};
