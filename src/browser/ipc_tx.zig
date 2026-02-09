const std = @import("std");
const shared = @import("shared");

const ipc = shared.ipc;

pub const Tx = struct {
    fd: std.net.Stream.Handle,
    buf: std.ArrayListUnmanaged(u8) = .{},
    off: usize = 0,

    pub fn deinit(self: *Tx, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
        self.* = undefined;
    }

    pub fn pending(self: *const Tx) usize {
        return self.buf.items.len - self.off;
    }

    pub fn reset(self: *Tx) void {
        self.buf.items.len = 0;
        self.off = 0;
    }

    pub fn send(self: *Tx, alloc: std.mem.Allocator, msg_type: ipc.MsgType, payload: []const u8) !void {
        if (payload.len > ipc.max_payload_len) return error.PayloadTooLarge;

        self.compactIfNeeded();

        var header: [12]u8 = undefined;
        header[0] = 'Z';
        header[1] = 'B';
        header[2] = 'R';
        header[3] = '0';
        std.mem.writeInt(u16, header[4..6], ipc.wire_version, .little);
        std.mem.writeInt(u16, header[6..8], @intFromEnum(msg_type), .little);
        std.mem.writeInt(u32, header[8..12], @as(u32, @intCast(payload.len)), .little);

        const need = header.len + payload.len;
        try self.buf.ensureUnusedCapacity(alloc, need);
        self.buf.appendSliceAssumeCapacity(&header);
        self.buf.appendSliceAssumeCapacity(payload);
    }

    pub fn flush(self: *Tx) !void {
        const orig_flags_int: usize = try std.posix.fcntl(self.fd, std.posix.F.GETFL, 0);
        const nonblock_mask: usize = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
        const toggled = (orig_flags_int & nonblock_mask) == 0;
        if (toggled) {
            _ = try std.posix.fcntl(self.fd, std.posix.F.SETFL, orig_flags_int | nonblock_mask);
        }
        defer {
            if (toggled) _ = std.posix.fcntl(self.fd, std.posix.F.SETFL, orig_flags_int) catch {};
        }

        if (self.off >= self.buf.items.len) {
            self.buf.items.len = 0;
            self.off = 0;
            return;
        }

        const max_write: usize = 64 * 1024;
        const slice = self.buf.items[self.off..];
        const chunk = slice[0..@min(slice.len, max_write)];
        const n = std.posix.write(self.fd, chunk) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) return error.WriteZero;
        self.off += n;
        if (self.off >= self.buf.items.len) {
            self.buf.items.len = 0;
            self.off = 0;
        }
    }

    fn compactIfNeeded(self: *Tx) void {
        if (self.off == 0) return;
        const pending_bytes = self.pending();
        if (pending_bytes == 0) {
            self.buf.items.len = 0;
            self.off = 0;
            return;
        }

        if (self.off < 64 * 1024 and self.off * 2 < self.buf.items.len) return;
        std.mem.copyForwards(u8, self.buf.items[0..pending_bytes], self.buf.items[self.off..]);
        self.buf.items.len = pending_bytes;
        self.off = 0;
    }
};
