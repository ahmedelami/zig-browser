const std = @import("std");
const shared = @import("shared");

const ipc = shared.ipc;
const display_list = shared.display_list;
const TraceWriter = shared.trace.TraceWriter;
const util = shared.util;

const iosurface = @import("iosurface.zig");
const raster = @import("raster.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const connect_path = (try util.argValue("--connect")) orelse return error.MissingConnect;
    const run_dir_path = (try util.argValue("--run-dir")) orelse return error.MissingRunDir;
    const artifacts = util.hasArg("--artifacts");

    const pid: u32 = @intCast(std.c.getpid());
    const tid: u32 = 0;

    var run_dir = try std.fs.cwd().openDir(run_dir_path, .{});
    defer run_dir.close();

    var trace = try TraceWriter.init(alloc, run_dir, "trace-gpu.json", pid, tid);
    defer trace.deinit();
    try trace.metaProcessName("zb_gpu");
    try trace.metaThreadName("main");
    try trace.instant("gpu_start", "lifecycle");

    var stream = try ipc.connectUnix(connect_path);
    defer stream.close();

    var conn: ipc.Connection = .{ .stream = stream };

    var hello_buf: [5]u8 = undefined;
    const hello_payload = ipc.encodeHello(&hello_buf, .{ .kind = .gpu, .pid = pid });
    try conn.send(.hello, hello_payload);

    var surface: ?iosurface.Surface = null;
    defer if (surface) |*s| iosurface.destroy(s);

    var last_frame_id: u32 = 0;
    var last_display_list: ?[]u8 = null;
    defer if (last_display_list) |bytes| alloc.free(bytes);

    while (true) {
        const frame = conn.recvAlloc(alloc) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer alloc.free(frame.payload);

        switch (frame.header.msg_type) {
            .ping => {
                conn.send(.pong, "") catch |err| switch (err) {
                    error.BrokenPipe => break,
                    else => return err,
                };
            },
            .shutdown => break,
            .gpu_create_surface => {
                var idx: usize = 0;
                const width = try ipc.readInt(frame.payload, &idx, u32);
                const height = try ipc.readInt(frame.payload, &idx, u32);

                if (surface) |*s| iosurface.destroy(s);
                var s = try iosurface.createBgra8Surface(width, height);
                errdefer iosurface.destroy(&s);
                try trace.instant("gpu_surface_created", "gpu");

                var payload: [16]u8 = undefined;
                std.mem.writeInt(u32, payload[0..4], s.id, .little);
                std.mem.writeInt(u32, payload[4..8], s.width, .little);
                std.mem.writeInt(u32, payload[8..12], s.height, .little);
                std.mem.writeInt(u32, payload[12..16], s.stride, .little);
                conn.send(.gpu_surface_created, payload[0..]) catch |err| switch (err) {
                    error.BrokenPipe => break,
                    else => return err,
                };

                surface = s;
            },
            .gpu_submit_display_list => {
                const s = surface orelse continue;

                var idx: usize = 0;
                const frame_id = try ipc.readInt(frame.payload, &idx, u32);
                const list_len = try ipc.readInt(frame.payload, &idx, u32);
                const list_bytes = try ipc.readBytes(frame.payload, &idx, @intCast(list_len));

                if (artifacts) {
                    if (last_display_list) |bytes| alloc.free(bytes);
                    last_display_list = alloc.dupe(u8, list_bytes) catch null;
                    last_frame_id = frame_id;
                }

                try trace.instant("gpu_raster_start", "gpu");
                const base = try iosurface.lockForWrite(s.ref.?);
                defer iosurface.unlock(s.ref.?);

                const stride: usize = @intCast(s.stride);
                const height: usize = @intCast(s.height);
                const width: usize = @intCast(s.width);
                const surface_bytes = base[0 .. stride * height];

                try raster.rasterIntoBgra8(surface_bytes, width, height, stride, list_bytes);
                try trace.instant("gpu_raster_done", "gpu");

                var payload: [4]u8 = undefined;
                std.mem.writeInt(u32, payload[0..4], frame_id, .little);
                conn.send(.gpu_frame_ready, payload[0..]) catch |err| switch (err) {
                    error.BrokenPipe => break,
                    else => return err,
                };
            },
            else => {},
        }
    }

    if (artifacts) {
        if (surface) |s| {
            if (last_display_list) |bytes| dumpDisplayListArtifacts(run_dir, last_frame_id, bytes) catch {};
            dumpFrameArtifacts(alloc, run_dir, s) catch {};
        }
    }

    try trace.instant("gpu_exit", "lifecycle");
}

fn dumpDisplayListArtifacts(dir: std.fs.Dir, frame_id: u32, bytes: []const u8) !void {
    {
        const file = try dir.createFile("gpu_last_display_list.zbdl", .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
    }

    const file = try dir.createFile("gpu_last_display_list.txt", .{ .truncate = true });
    defer file.close();

    var buf: [16 * 1024]u8 = undefined;
    var fw = file.writer(&buf);
    defer fw.interface.flush() catch {};

    try fw.interface.print("frame_id: {d}\nbytes: {d}\n\n", .{ frame_id, bytes.len });

    var reader = display_list.Reader.init(bytes) catch |err| {
        try fw.interface.print("error: bad display list ({s})\n", .{@errorName(err)});
        return;
    };

    var i: usize = 0;
    while (try reader.next()) |cmd| : (i += 1) {
        switch (cmd) {
            .clear => |c| {
                try fw.interface.print("{d}: clear color=0x{X:0>8}\n", .{ i, c });
            },
            .rect => |r| {
                try fw.interface.print(
                    "{d}: rect x={d} y={d} w={d} h={d} color=0x{X:0>8}\n",
                    .{ i, r.x, r.y, r.w, r.h, r.color_bgra },
                );
            },
            .text => |t| {
                try fw.interface.print(
                    "{d}: text x={d} y={d} color=0x{X:0>8} len={d} preview=\"",
                    .{ i, t.x, t.y, t.color_bgra, t.bytes.len },
                );
                try writeEscapedPreview(&fw.interface, t.bytes, 120);
                try fw.interface.writeAll("\"\n");
            },
            .bitmap => |b| {
                try fw.interface.print(
                    "{d}: bitmap x={d} y={d} w={d} h={d} bytes={d}\n",
                    .{ i, b.x, b.y, b.w, b.h, b.bgra.len },
                );
            },
        }
    }
}

fn writeEscapedPreview(w: anytype, bytes: []const u8, max_len: usize) !void {
    const n = @min(bytes.len, max_len);
    for (bytes[0..n]) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c >= 0x20 and c < 0x7F) try w.writeByte(c) else try w.writeByte('.');
            },
        }
    }
    if (bytes.len > n) try w.writeAll("…");
}

fn dumpFrameArtifacts(alloc: std.mem.Allocator, dir: std.fs.Dir, s: iosurface.Surface) !void {
    const surface_ref = s.ref orelse return;
    const base = try iosurface.lockForWrite(surface_ref);
    defer iosurface.unlock(surface_ref);

    const stride: usize = @intCast(s.stride);
    const height: usize = @intCast(s.height);
    const width: usize = @intCast(s.width);
    const surface_bytes = base[0 .. stride * height];

    {
        const meta = try dir.createFile("gpu_last_frame.txt", .{ .truncate = true });
        defer meta.close();
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "width={d} height={d} stride={d}\n", .{ s.width, s.height, s.stride });
        try meta.writeAll(line);
    }

    const file = try dir.createFile("gpu_last_frame.ppm", .{ .truncate = true });
    defer file.close();

    var writer_buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(&writer_buf);
    defer fw.interface.flush() catch {};

    try fw.interface.print("P6\n{d} {d}\n255\n", .{ s.width, s.height });

    const row_rgb = try alloc.alloc(u8, width * 3);
    defer alloc.free(row_rgb);

    for (0..height) |y| {
        const row_bgra = surface_bytes[y * stride .. y * stride + width * 4];
        for (0..width) |x| {
            const src = row_bgra[x * 4 .. x * 4 + 4];
            row_rgb[x * 3 + 0] = src[2];
            row_rgb[x * 3 + 1] = src[1];
            row_rgb[x * 3 + 2] = src[0];
        }
        try fw.interface.writeAll(row_rgb);
    }
}
