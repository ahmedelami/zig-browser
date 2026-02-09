const std = @import("std");
const shared = @import("shared");

const ipc = shared.ipc;

pub const StreamResult = enum(u32) {
    ok = 0,
    failed = 1,
    truncated = 2,
};

pub const ChunkSink = struct {
    ctx: *anyopaque,
    onChunk: *const fn (ctx: *anyopaque, bytes: []const u8) void,
};

pub const stream_chunk_bytes: usize = 4 * 1024;
pub const writer_buffer_bytes: usize = 64 * 1024;

pub const ChunkedIpcWriter = struct {
    alloc: std.mem.Allocator,
    conn: *ipc.Connection,
    send_mutex: *std.Thread.Mutex,
    request_id: u32,
    max_total_bytes: usize,
    sink: ?ChunkSink = null,

    total_sent: usize = 0,
    sent_index: usize = 0,
    truncated: bool = false,

    writer: std.Io.Writer,
    scratch: [8 + stream_chunk_bytes]u8 = undefined,

    pub fn init(
        alloc: std.mem.Allocator,
        conn: *ipc.Connection,
        send_mutex: *std.Thread.Mutex,
        request_id: u32,
        max_total_bytes: usize,
        sink: ?ChunkSink,
    ) !ChunkedIpcWriter {
        const buf = try alloc.alloc(u8, writer_buffer_bytes);
        return .{
            .alloc = alloc,
            .conn = conn,
            .send_mutex = send_mutex,
            .request_id = request_id,
            .max_total_bytes = max_total_bytes,
            .sink = sink,
            .writer = .{
                .buffer = buf,
                .end = 0,
                .vtable = &vtable,
            },
        };
    }

    pub fn deinit(self: *ChunkedIpcWriter) void {
        self.alloc.free(self.writer.buffer);
        self.* = undefined;
    }

    pub fn flushAvailable(self: *ChunkedIpcWriter) std.Io.Writer.Error!void {
        while (self.unsentLen() >= stream_chunk_bytes) {
            try self.sendBytes(self.writer.buffer[self.sent_index .. self.sent_index + stream_chunk_bytes]);
            self.sent_index += stream_chunk_bytes;
        }
    }

    pub fn flushAll(self: *ChunkedIpcWriter) std.Io.Writer.Error!void {
        while (self.sent_index < self.writer.end) {
            const n = @min(stream_chunk_bytes, self.writer.end - self.sent_index);
            try self.sendBytes(self.writer.buffer[self.sent_index .. self.sent_index + n]);
            self.sent_index += n;
        }
    }

    fn unsentLen(self: *const ChunkedIpcWriter) usize {
        return self.writer.end - self.sent_index;
    }

    fn sendBytes(self: *ChunkedIpcWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;

        if (self.totalSentAfter(bytes.len) > self.max_total_bytes) {
            const remaining = self.max_total_bytes -| self.total_sent;
            if (remaining == 0) {
                self.truncated = true;
                return error.WriteFailed;
            }

            // Send the remaining budget and then stop.
            try self.sendBytesNoBudget(bytes[0..remaining]);
            self.total_sent += remaining;
            self.truncated = true;
            return error.WriteFailed;
        }

        try self.sendBytesNoBudget(bytes);
        self.total_sent += bytes.len;
    }

    fn totalSentAfter(self: *const ChunkedIpcWriter, add: usize) usize {
        return self.total_sent + add;
    }

    fn sendBytesNoBudget(self: *ChunkedIpcWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        if (bytes.len > stream_chunk_bytes) return error.WriteFailed;

        std.mem.writeInt(u32, self.scratch[0..4], self.request_id, .little);
        std.mem.writeInt(u32, self.scratch[4..8], @intCast(bytes.len), .little);
        @memcpy(self.scratch[8..][0..bytes.len], bytes);

        self.send_mutex.lock();
        self.conn.send(.net_fetch_chunk, self.scratch[0 .. 8 + bytes.len]) catch {
            self.send_mutex.unlock();
            return error.WriteFailed;
        };
        self.send_mutex.unlock();

        if (self.sink) |s| s.onChunk(s.ctx, bytes);
    }

    fn flushUpTo(self: *ChunkedIpcWriter, index: usize) std.Io.Writer.Error!void {
        if (index <= self.sent_index) return;
        var i = self.sent_index;
        while (i < index) {
            const n = @min(stream_chunk_bytes, index - i);
            try self.sendBytes(self.writer.buffer[i .. i + n]);
            i += n;
        }
        self.sent_index = index;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ChunkedIpcWriter = @alignCast(@fieldParentPtr("writer", w));

        self.flushAll() catch return error.WriteFailed;
        w.end = 0;
        self.sent_index = 0;

        if (data.len == 0) return 0;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            var off: usize = 0;
            while (off < slice.len) {
                const n = @min(stream_chunk_bytes, slice.len - off);
                self.sendBytes(slice[off .. off + n]) catch return error.WriteFailed;
                off += n;
            }
            consumed += slice.len;
        }

        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            var off: usize = 0;
            while (off < pattern.len) {
                const n = @min(stream_chunk_bytes, pattern.len - off);
                self.sendBytes(pattern[off .. off + n]) catch return error.WriteFailed;
                off += n;
            }
            consumed += pattern.len;
        }

        return consumed;
    }

    fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        const self: *ChunkedIpcWriter = @alignCast(@fieldParentPtr("writer", w));
        if (w.buffer.len < preserve + capacity) return error.WriteFailed;

        // Before discarding prefix bytes, ensure they're sent.
        const preserved_head = w.end -| preserve;
        self.flushUpTo(preserved_head) catch return error.WriteFailed;

        const preserved_len = w.end - preserved_head;
        if (preserved_head != 0 and preserved_len != 0) {
            @memmove(w.buffer[0..preserved_len], w.buffer[preserved_head..w.end]);
        }

        w.end = preserved_len;
        self.sent_index -= preserved_head;

        if (w.buffer.len - w.end < capacity) return error.WriteFailed;
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.noopFlush,
        .rebase = rebase,
    };
};
