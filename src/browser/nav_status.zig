const std = @import("std");
const shared = @import("shared");

const nav_metrics = @import("nav_metrics.zig");
const nav_types = @import("nav_types.zig");

const ipc = shared.ipc;
const LoadState = nav_types.LoadState;

fn netSourceLabel(code: u32) []const u8 {
    const src: ipc.NetSource = std.meta.intToEnum(ipc.NetSource, code) catch .network;
    return switch (src) {
        .network => "net",
        .mem_cache => "mem",
        .disk_cache => "disk",
    };
}

fn relMs(start_us: u64, ts_us: ?u64) ?u64 {
    const t = ts_us orelse return null;
    if (t <= start_us) return 0;
    return (t - start_us) / 1000;
}

pub fn formatStatus(
    out: *[160]u8,
    timer: *std.time.Timer,
    navm: *const nav_metrics.NavMetrics,
    load: *const LoadState,
) []const u8 {
    if (navm.request_id == 0 or navm.start_us == 0) return "";

    var buf = out[0..];
    var idx: usize = 0;
    const src = netSourceLabel(navm.net_source);
    const s0 = std.fmt.bufPrint(buf[idx..], "{s}", .{src}) catch return "";
    idx += s0.len;

    if (load.active) {
        const now_us = nav_metrics.nowUs(timer);
        const elapsed_ms: u64 = if (now_us <= navm.start_us) 0 else (now_us - navm.start_us) / 1000;
        const s1 = std.fmt.bufPrint(buf[idx..], " load {d}ms", .{elapsed_ms}) catch return buf[0..idx];
        idx += s1.len;
        return buf[0..idx];
    }

    if (relMs(navm.start_us, navm.net_begin_us)) |ms| {
        const s = std.fmt.bufPrint(buf[idx..], " n{d}", .{ms}) catch return buf[0..idx];
        idx += s.len;
    }
    if (relMs(navm.start_us, navm.first_frame_ready_us)) |ms| {
        const s = std.fmt.bufPrint(buf[idx..], " f{d}", .{ms}) catch return buf[0..idx];
        idx += s.len;
    }

    var done_ts: u64 = 0;
    if (navm.net_end_us) |t| done_ts = @max(done_ts, t);
    if (navm.renderer_done_us) |t| done_ts = @max(done_ts, t);
    if (done_ts == 0) done_ts = nav_metrics.nowUs(timer);
    const done_ms: u64 = if (done_ts <= navm.start_us) 0 else (done_ts - navm.start_us) / 1000;
    {
        const s = std.fmt.bufPrint(buf[idx..], " d{d}", .{done_ms}) catch return buf[0..idx];
        idx += s.len;
    }

    if (navm.net_result != 0) {
        const label: []const u8 = switch (navm.net_result) {
            1 => " fail",
            2 => " trunc",
            else => " err",
        };
        const s = std.fmt.bufPrint(buf[idx..], "{s}", .{label}) catch return buf[0..idx];
        idx += s.len;
    }

    if (navm.status_code >= 400) {
        const s = std.fmt.bufPrint(buf[idx..], " http{d}", .{navm.status_code}) catch return buf[0..idx];
        idx += s.len;
    }

    return buf[0..idx];
}

