const std = @import("std");

pub const FetchTracker = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    active: usize = 0,

    pub fn start(self: *FetchTracker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active += 1;
    }

    pub fn finish(self: *FetchTracker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active -|= 1;
        self.cond.broadcast();
    }

    pub fn waitAll(self: *FetchTracker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.active != 0) self.cond.wait(&self.mutex);
    }

    pub fn waitAllTimeout(self: *FetchTracker, timeout_ns: u64) error{Timeout}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.active != 0) {
            self.cond.timedWait(&self.mutex, timeout_ns) catch return error.Timeout;
        }
    }
};
