const std = @import("std");
const builtin = @import("builtin");
const ProcessKind = @import("process_kind.zig").ProcessKind;

pub const MsgType = enum(u16) {
    hello = 1,
    ping = 2,
    pong = 3,
    shutdown = 4,

    gpu_create_surface = 10,
    gpu_surface_created = 11,
    gpu_submit_display_list = 12,
    gpu_frame_ready = 13,

    net_fetch_url = 20,
    net_fetch_response = 21,
    net_fetch_begin = 22,
    net_fetch_chunk = 23,
    net_fetch_end = 24,
    net_cancel_request = 25,
    net_set_cookie = 26,

    renderer_render_html = 30,
    renderer_display_list = 31,
    renderer_begin_document = 32,
    renderer_html_chunk = 33,
    renderer_end_document = 34,
    renderer_document_done = 35,

    renderer_request_resource = 36,
    renderer_resource_begin = 37,
    renderer_resource_chunk = 38,
    renderer_resource_end = 39,

    renderer_set_scroll = 40,
    renderer_set_cookie = 41,
    renderer_navigate = 42,
};

pub const NetSource = enum(u32) {
    network = 0,
    mem_cache = 1,
    disk_cache = 2,
};

pub const FrameHeader = struct {
    msg_type: MsgType,
    payload_len: u32,
};

const magic_bytes = [_]u8{ 'Z', 'B', 'R', '0' };
pub const wire_version: u16 = 1;
const header_len: usize = 4 + 2 + 2 + 4; // magic + version + type + payload_len
pub const max_payload_len: u32 = 8 * 1024 * 1024;

pub const Frame = struct {
    header: FrameHeader,
    payload: []u8,
};

pub const Hello = struct {
    kind: ProcessKind,
    pid: u32,
};

pub const Connection = struct {
    stream: std.net.Stream,

    pub fn send(self: *Connection, msg_type: MsgType, payload: []const u8) !void {
        var header_buf: [header_len]u8 = undefined;
        @memcpy(header_buf[0..4], &magic_bytes);
        std.mem.writeInt(u16, header_buf[4..6], wire_version, .little);
        std.mem.writeInt(u16, header_buf[6..8], @intFromEnum(msg_type), .little);
        std.mem.writeInt(u32, header_buf[8..12], @as(u32, @intCast(payload.len)), .little);

        try writeAll(self.stream.handle, &header_buf);
        try writeAll(self.stream.handle, payload);
    }

    pub fn recvAlloc(self: *Connection, alloc: std.mem.Allocator) !Frame {
        var header_buf: [header_len]u8 = undefined;
        try readNoEof(self.stream.handle, &header_buf);

        if (!std.mem.eql(u8, header_buf[0..4], &magic_bytes)) return error.BadMagic;
        const version = std.mem.readInt(u16, header_buf[4..6], .little);
        if (version != wire_version) return error.BadVersion;

        const msg_type_raw = std.mem.readInt(u16, header_buf[6..8], .little);
        const payload_len = std.mem.readInt(u32, header_buf[8..12], .little);
        if (payload_len > max_payload_len) return error.PayloadTooLarge;

        const msg_type: MsgType = std.meta.intToEnum(MsgType, msg_type_raw) catch return error.BadMsgType;

        const payload = try alloc.alloc(u8, payload_len);
        errdefer alloc.free(payload);
        try readNoEof(self.stream.handle, payload);

        return .{
            .header = .{ .msg_type = msg_type, .payload_len = payload_len },
            .payload = payload,
        };
    }
};

fn writeAll(handle: std.net.Stream.Handle, bytes: []const u8) !void {
    if (builtin.os.tag == .windows) @compileError("ipc.writeAll: windows unsupported");

    var index: usize = 0;
    while (index < bytes.len) {
        const n = try std.posix.write(handle, bytes[index..]);
        if (n == 0) return error.WriteZero;
        index += n;
    }
}

fn readNoEof(handle: std.net.Stream.Handle, buf: []u8) !void {
    if (builtin.os.tag == .windows) @compileError("ipc.readNoEof: windows unsupported");

    var index: usize = 0;
    while (index < buf.len) {
        const n = try std.posix.read(handle, buf[index..]);
        if (n == 0) return error.EndOfStream;
        index += n;
    }
}

pub fn encodeHello(buf: *[5]u8, hello: Hello) []const u8 {
    buf[0] = @intFromEnum(hello.kind);
    std.mem.writeInt(u32, buf[1..5], hello.pid, .little);
    return buf[0..5];
}

pub fn decodeHello(payload: []const u8) !Hello {
    if (payload.len != 5) return error.BadHelloLen;
    const kind_raw = payload[0];
    const kind: ProcessKind = std.meta.intToEnum(ProcessKind, kind_raw) catch return error.BadProcessKind;
    const pid = std.mem.readInt(u32, payload[1..5], .little);
    return .{ .kind = kind, .pid = pid };
}

pub fn listenUnix(path: []const u8) !std.net.Server {
    const addr = try std.net.Address.initUnix(path);
    return addr.listen(.{ .kernel_backlog = 16 });
}

pub fn connectUnix(path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(path);
}

pub fn readInt(payload: []const u8, index: *usize, comptime T: type) !T {
    const n = @sizeOf(T);
    if (index.* + n > payload.len) return error.BadPayload;
    const bytes = payload[index.* .. index.* + n];
    const ptr: *const [n]u8 = @ptrCast(bytes.ptr);
    const v = std.mem.readInt(T, ptr, .little);
    index.* += n;
    return v;
}

pub fn readBytes(payload: []const u8, index: *usize, len: usize) ![]const u8 {
    if (index.* + len > payload.len) return error.BadPayload;
    const out = payload[index.* .. index.* + len];
    index.* += len;
    return out;
}
