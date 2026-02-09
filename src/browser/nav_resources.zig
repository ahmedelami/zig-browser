const std = @import("std");
const shared = @import("shared");

const ipc = shared.ipc;
const ipc_tx = @import("ipc_tx.zig");

pub const ResourceRoute = struct {
    net_request_id: u32,
    doc_request_id: u32,
    resource_id: u32,
};

pub fn cancelAll(net: *ipc.Connection, routes: *std.ArrayList(ResourceRoute)) void {
    for (routes.items) |r| {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], r.net_request_id, .little);
        net.send(.net_cancel_request, payload[0..]) catch {};
    }
    routes.items.len = 0;
}

pub fn findIndex(routes: []const ResourceRoute, net_rid: u32) ?usize {
    for (routes, 0..) |r, i| {
        if (r.net_request_id == net_rid) return i;
    }
    return null;
}

pub fn sendBegin(
    alloc: std.mem.Allocator,
    renderer_tx: *ipc_tx.Tx,
    route: ResourceRoute,
    status_code: u32,
    source_code: u32,
) !void {
    var payload: [16]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], route.doc_request_id, .little);
    std.mem.writeInt(u32, payload[4..8], route.resource_id, .little);
    std.mem.writeInt(u32, payload[8..12], status_code, .little);
    std.mem.writeInt(u32, payload[12..16], source_code, .little);
    try renderer_tx.send(alloc, .renderer_resource_begin, payload[0..]);
}

pub fn sendChunk(
    alloc: std.mem.Allocator,
    renderer_tx: *ipc_tx.Tx,
    route: ResourceRoute,
    bytes: []const u8,
) !void {
    if (bytes.len == 0) return;
    const payload_len: usize = 12 + bytes.len;
    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);
    std.mem.writeInt(u32, payload[0..4], route.doc_request_id, .little);
    std.mem.writeInt(u32, payload[4..8], route.resource_id, .little);
    std.mem.writeInt(u32, payload[8..12], @intCast(bytes.len), .little);
    @memcpy(payload[12..], bytes);
    try renderer_tx.send(alloc, .renderer_resource_chunk, payload);
}

pub fn sendEnd(
    alloc: std.mem.Allocator,
    renderer_tx: *ipc_tx.Tx,
    route: ResourceRoute,
    status_code: u32,
    net_result: u32,
    total_sent: u32,
) !void {
    var payload: [20]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], route.doc_request_id, .little);
    std.mem.writeInt(u32, payload[4..8], route.resource_id, .little);
    std.mem.writeInt(u32, payload[8..12], status_code, .little);
    std.mem.writeInt(u32, payload[12..16], net_result, .little);
    std.mem.writeInt(u32, payload[16..20], total_sent, .little);
    try renderer_tx.send(alloc, .renderer_resource_end, payload[0..]);
}

