const std = @import("std");

pub const Event = union(enum) {
    byte: u8, // UTF-8 bytes (restricted to ASCII for now)
    backspace,
    enter,
    scroll: i32, // pixels (positive/negative depends on platform)
    click: struct { x: i32, y: i32 }, // window coords, top-left origin
};

pub const Queue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    closed: bool = false,

    wakeup_r: std.posix.fd_t = -1,
    wakeup_w: std.posix.fd_t = -1,
    wakeup_inited: bool = false,

    buf: [256]Event = undefined,
    head: usize = 0,
    tail: usize = 0,

    pub fn init(self: *Queue) !void {
        if (self.wakeup_inited) return;
        const fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        self.wakeup_r = fds[0];
        self.wakeup_w = fds[1];
        self.wakeup_inited = true;
    }

    pub fn deinit(self: *Queue) void {
        if (!self.wakeup_inited) return;
        std.posix.close(self.wakeup_r);
        std.posix.close(self.wakeup_w);
        self.wakeup_r = -1;
        self.wakeup_w = -1;
        self.wakeup_inited = false;
    }

    pub fn wakeupFd(self: *const Queue) std.posix.fd_t {
        return self.wakeup_r;
    }

    pub fn drainWakeup(self: *Queue) void {
        if (!self.wakeup_inited) return;
        var buf_bytes: [64]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.wakeup_r, &buf_bytes) catch |err| switch (err) {
                error.WouldBlock => break,
                else => break,
            };
            if (n == 0) break;
        }
    }

    pub fn isClosed(self: *Queue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closed;
    }

    pub fn close(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
        self.wake();
    }

    pub fn push(self: *Queue, ev: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return;

        const next_tail = (self.tail + 1) % self.buf.len;
        if (next_tail == self.head) return; // drop on overflow

        self.buf[self.tail] = ev;
        self.tail = next_tail;
        self.cond.signal();
        self.wake();
    }

    pub fn pop(self: *Queue) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.head == self.tail) return null;
        const ev = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        return ev;
    }

    pub fn popWait(self: *Queue) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.head == self.tail and !self.closed) {
            self.cond.wait(&self.mutex);
        }

        if (self.head == self.tail) return null;
        const ev = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        return ev;
    }

    fn wake(self: *Queue) void {
        if (!self.wakeup_inited) return;
        var one: [1]u8 = .{0};
        _ = std.posix.write(self.wakeup_w, &one) catch {};
    }
};
