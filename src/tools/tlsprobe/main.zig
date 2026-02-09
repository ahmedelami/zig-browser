const std = @import("std");

const zb_tls = @import("zb_tls");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const url_arg = try argValue("--url");
    const host_arg = try argValue("--host");
    const port_arg = try argValue("--port");
    const do_http = hasArg("--http");

    const host, const port, const uri_opt = blk: {
        if (url_arg) |url| {
            const uri = try std.Uri.parse(url);
            var host_buf: [std.Uri.host_name_max]u8 = undefined;
            const h = try uri.getHost(&host_buf);
            const p: u16 = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) 443 else 80;
            break :blk .{ try alloc.dupe(u8, h), p, uri };
        }
        if (host_arg) |h| {
            const p: u16 = if (port_arg) |s| try std.fmt.parseInt(u16, s, 10) else 443;
            break :blk .{ try alloc.dupe(u8, h), p, null };
        }
        return error.MissingHost;
    };
    defer alloc.free(host);

    var ca_bundle: std.crypto.Certificate.Bundle = .{};
    defer ca_bundle.deinit(alloc);
    try ca_bundle.rescan(alloc);

    var stream = try std.net.tcpConnectToHost(alloc, host, port);
    defer stream.close();

    var stream_read_buf: [zb_tls.min_buffer_len]u8 = undefined;
    var stream_write_buf: [zb_tls.min_buffer_len]u8 = undefined;
    var tls_read_buf: [zb_tls.min_buffer_len + 8 * 1024]u8 = undefined;
    var tls_write_buf: [1024]u8 = undefined;

    var stream_reader = stream.reader(&stream_read_buf);
    var stream_writer = stream.writer(&stream_write_buf);

    var alert: std.crypto.tls.Alert = undefined;
    var tls_client = zb_tls.init(
        stream_reader.interface(),
        &stream_writer.interface,
        .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = ca_bundle },
            .read_buffer = &tls_read_buf,
            .write_buffer = &tls_write_buf,
            .allow_truncation_attacks = true,
            .alert = &alert,
        },
    ) catch |err| {
        std.debug.print("tls init error: {s}\n", .{@errorName(err)});
        if (err == error.TlsAlert) {
            std.debug.print("tls alert: level={s} description={s}\n", .{ @tagName(alert.level), @tagName(alert.description) });
        }
        return;
    };

    std.debug.print(
        "tls ok: version={s} cipher={s}\n",
        .{ @tagName(tls_client.tls_version), @tagName(tls_client.application_cipher) },
    );

    if (do_http) {
        const uri = uri_opt orelse std.Uri.parse("https://example.com/") catch unreachable;
        try tls_client.writer.writeAll("GET ");
        const path: std.Uri.Component = if (uri.path.isEmpty()) .{ .percent_encoded = "/" } else uri.path;
        try path.formatPath(&tls_client.writer);
        if (uri.query) |q| {
            try tls_client.writer.writeByte('?');
            try q.formatQuery(&tls_client.writer);
        }
        try tls_client.writer.writeAll(" HTTP/1.1\r\n");
        try tls_client.writer.print("Host: {s}\r\n", .{host});
        try tls_client.writer.writeAll("Connection: close\r\n\r\n");
        try tls_client.writer.flush();
        try stream_writer.interface.flush();

        var http_reader: std.http.Reader = .{
            .in = &tls_client.reader,
            .interface = undefined,
            .state = .ready,
            .max_head_len = 64 * 1024,
        };
        const head_bytes = try http_reader.receiveHead();
        const head = try std.http.Client.Response.Head.parse(head_bytes);
        std.debug.print("http ok: status={d} encoding={s} transfer={s}\n", .{
            @intFromEnum(head.status),
            @tagName(head.content_encoding),
            @tagName(head.transfer_encoding),
        });
    }
}

fn argValue(flag: []const u8) !?[]const u8 {
    var it = std.process.args();
    _ = it.next(); // exe
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, flag)) return it.next() orelse return error.MissingValue;
    }
    return null;
}

fn hasArg(flag: []const u8) bool {
    var it = std.process.args();
    _ = it.next(); // exe
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}
