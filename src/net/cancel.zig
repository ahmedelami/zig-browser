const std = @import("std");

pub const CancelManager = struct {
    alloc: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    canceled: std.AutoHashMapUnmanaged(u32, void) = .{},
    inflight_fd: std.AutoHashMapUnmanaged(u32, std.posix.fd_t) = .{},

    pub fn init(alloc: std.mem.Allocator) CancelManager {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *CancelManager) void {
        self.mutex.lock();
        self.canceled.deinit(self.alloc);
        self.inflight_fd.deinit(self.alloc);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn clear(self: *CancelManager, request_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.canceled.remove(request_id);
    }

    pub fn register(self: *CancelManager, request_id: u32, fd: std.posix.fd_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.inflight_fd.put(self.alloc, request_id, fd) catch {};
        if (self.canceled.contains(request_id)) {
            std.posix.shutdown(fd, .both) catch {};
        }
    }

    pub fn finish(self: *CancelManager, request_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.inflight_fd.remove(request_id);
        _ = self.canceled.remove(request_id);

        // Avoid unbounded growth if the browser misbehaves.
        if (self.canceled.count() > 4096) self.canceled.clearRetainingCapacity();
        if (self.inflight_fd.count() > 4096) self.inflight_fd.clearRetainingCapacity();
    }

    pub fn cancel(self: *CancelManager, request_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.canceled.put(self.alloc, request_id, {}) catch {};
        if (self.inflight_fd.get(request_id)) |fd| {
            std.posix.shutdown(fd, .both) catch {};
        }

        if (self.canceled.count() > 4096) self.canceled.clearRetainingCapacity();
    }

    pub fn isCanceled(self: *CancelManager, request_id: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.canceled.contains(request_id);
    }

    pub fn cancelAll(self: *CancelManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.inflight_fd.iterator();
        while (it.next()) |kv| {
            const request_id = kv.key_ptr.*;
            const fd = kv.value_ptr.*;
            self.canceled.put(self.alloc, request_id, {}) catch {};
            std.posix.shutdown(fd, .both) catch {};
        }

        if (self.canceled.count() > 4096) self.canceled.clearRetainingCapacity();
    }
};
