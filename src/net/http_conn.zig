const std = @import("std");

const zb_tls = @import("tls/client.zig");

pub const Scheme = enum {
    http,
    https,
};

pub const Conn = struct {
    stream: std.net.Stream,
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,

    tls_client: ?zb_tls = null,

    // Backing buffers (keep these near the bottom; they must outlive tls_client).
    _stream_read_buf: [zb_tls.min_buffer_len]u8 = undefined,
    _stream_write_buf: [zb_tls.min_buffer_len]u8 = undefined,
    _tls_read_buf: [zb_tls.min_buffer_len + http_read_extra]u8 = undefined,
    _tls_write_buf: [tls_plain_write_buf_len]u8 = undefined,

    pub const http_read_extra: usize = 8 * 1024;
    pub const tls_plain_write_buf_len: usize = 1024;

    pub fn init(
        self: *Conn,
        alloc: std.mem.Allocator,
        scheme: Scheme,
        host: []const u8,
        port: u16,
        ca_bundle: ?*const std.crypto.Certificate.Bundle,
    ) !void {
        var stream = try std.net.tcpConnectToHost(alloc, host, port);
        errdefer stream.close();

        self.* = .{
            .stream = stream,
            .stream_reader = undefined,
            .stream_writer = undefined,
            .tls_client = null,
        };
        self.stream_reader = self.stream.reader(&self._stream_read_buf);
        self.stream_writer = self.stream.writer(&self._stream_write_buf);

        if (scheme == .https) {
            const bundle = ca_bundle orelse return error.MissingCaBundle;

            var alert: std.crypto.tls.Alert = undefined;
            self.tls_client = zb_tls.init(
                self.stream_reader.interface(),
                &self.stream_writer.interface,
                .{
                    .host = .{ .explicit = host },
                    .ca = .{ .bundle = bundle.* },
                    .read_buffer = &self._tls_read_buf,
                    .write_buffer = &self._tls_write_buf,
                    .allow_truncation_attacks = true,
                    .alert = &alert,
                },
            ) catch |err| {
                if (err == error.TlsAlert) {
                    std.debug.print(
                        "net: tls alert: level={s} description={s}\n",
                        .{ @tagName(alert.level), @tagName(alert.description) },
                    );
                }
                return err;
            };
        }
    }

    pub fn deinit(self: *Conn) void {
        if (self.tls_client) |*tls| {
            tls.end() catch {};
        }
        self.stream.close();
        self.* = undefined;
    }

    pub fn fd(self: *Conn) std.posix.fd_t {
        return self.stream.handle;
    }

    pub fn reader(self: *Conn) *std.Io.Reader {
        if (self.tls_client) |*tls| return &tls.reader;
        return self.stream_reader.interface();
    }

    pub fn writer(self: *Conn) *std.Io.Writer {
        if (self.tls_client) |*tls| return &tls.writer;
        return &self.stream_writer.interface;
    }

    pub fn flush(self: *Conn) std.Io.Writer.Error!void {
        if (self.tls_client) |*tls| try tls.writer.flush();
        try self.stream_writer.interface.flush();
    }
};
