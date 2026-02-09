const std = @import("std");

pub const TraceWriter = struct {
    alloc: std.mem.Allocator,
    buf: []u8,
    writer: std.fs.File.Writer,
    pid: u32,
    tid: u32,
    timer: std.time.Timer,
    first: bool = true,

    pub fn init(alloc: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8, pid: u32, tid: u32) !TraceWriter {
        const file = try dir.createFile(filename, .{ .truncate = true });
        errdefer file.close();

        const timer = try std.time.Timer.start();

        const buf = try alloc.alloc(u8, 4096);
        errdefer alloc.free(buf);

        var writer = file.writer(buf);
        try writer.interface.writeAll("[\n");

        return .{
            .alloc = alloc,
            .buf = buf,
            .writer = writer,
            .pid = pid,
            .tid = tid,
            .timer = timer,
            .first = true,
        };
    }

    pub fn deinit(self: *TraceWriter) void {
        self.writer.interface.writeAll("\n]\n") catch {};
        self.writer.interface.flush() catch {};
        self.writer.file.close();
        self.alloc.free(self.buf);
        self.* = undefined;
    }

    fn tsMicros(self: *TraceWriter) u64 {
        return self.timer.read() / std.time.ns_per_us;
    }

    pub fn metaProcessName(self: *TraceWriter, name: []const u8) !void {
        const Args = struct { name: []const u8 };
        const Event = struct {
            name: []const u8,
            ph: []const u8,
            ts: u64,
            pid: u32,
            tid: u32,
            args: Args,
        };
        try self.writeJson(Event{
            .name = "process_name",
            .ph = "M",
            .ts = self.tsMicros(),
            .pid = self.pid,
            .tid = self.tid,
            .args = .{ .name = name },
        });
    }

    pub fn metaThreadName(self: *TraceWriter, name: []const u8) !void {
        const Args = struct { name: []const u8 };
        const Event = struct {
            name: []const u8,
            ph: []const u8,
            ts: u64,
            pid: u32,
            tid: u32,
            args: Args,
        };
        try self.writeJson(Event{
            .name = "thread_name",
            .ph = "M",
            .ts = self.tsMicros(),
            .pid = self.pid,
            .tid = self.tid,
            .args = .{ .name = name },
        });
    }

    pub fn instant(self: *TraceWriter, name: []const u8, cat: []const u8) !void {
        const Event = struct {
            name: []const u8,
            cat: []const u8,
            ph: []const u8,
            ts: u64,
            pid: u32,
            tid: u32,
            s: []const u8,
        };
        try self.writeJson(Event{
            .name = name,
            .cat = cat,
            .ph = "i",
            .ts = self.tsMicros(),
            .pid = self.pid,
            .tid = self.tid,
            .s = "t",
        });
    }

    fn writeJson(self: *TraceWriter, event: anytype) !void {
        if (!self.first) try self.writer.interface.writeAll(",\n") else self.first = false;
        try std.json.Stringify.value(event, .{}, &self.writer.interface);
    }
};
