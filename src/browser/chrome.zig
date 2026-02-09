const std = @import("std");
const shared = @import("shared");

const nav_support = @import("nav_support.zig");

const ipc = shared.ipc;
const display_list = shared.display_list;

pub const chrome_h: i32 = 56;
pub const content_y_off: i32 = chrome_h + 8;

pub fn submitComposedFrame(
    alloc: std.mem.Allocator,
    surface_w_i32: i32,
    scroll_y: i32,
    url: []const u8,
    status: []const u8,
    content_dl: []const u8,
    gpu: *ipc.Connection,
    request_repaint: *const fn () void,
    frame_id: u32,
) !void {
    const frame = try composeChromeFrame(alloc, surface_w_i32, scroll_y, url, status, content_dl);
    defer alloc.free(frame);

    try nav_support.gpuSubmitDisplayList(alloc, gpu, frame_id, frame);
    request_repaint();
}

pub fn renderPlainTextDisplayList(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var dl = try display_list.Builder.init(alloc);
    defer dl.deinit();
    try dl.clear(0xFF111418);
    try dl.text(16, 16, 0xFFE6E6E6, text);
    return try dl.finish();
}

fn composeChromeFrame(
    alloc: std.mem.Allocator,
    width: i32,
    scroll_y: i32,
    url: []const u8,
    status: []const u8,
    content_dl: []const u8,
) ![]u8 {
    const pad: i32 = 12;
    const addr_h: i32 = chrome_h - pad * 2;
    const addr_w: i32 = width - pad * 2;
    const char_w: i32 = 8;
    const text_y: i32 = pad + 16;
    const inner_left: i32 = pad + 8;
    const inner_right: i32 = pad + addr_w - 8;
    const inner_w: i32 = inner_right - inner_left;
    const max_chars: usize = @intCast(@max(0, @divTrunc(inner_w, char_w)));

    var frame = try display_list.Builder.init(alloc);
    defer frame.deinit();

    try frame.clear(0xFF111418);
    try frame.rect(0, 0, width, chrome_h, 0xFF1A1D24);
    try frame.rect(pad, pad, addr_w, addr_h, 0xFF2A2F3A);

    var status_text = status;
    if (status_text.len > max_chars) status_text = status_text[0..max_chars];
    const status_len_i32: i32 = @intCast(status_text.len);
    const status_px: i32 = status_len_i32 * char_w;
    const status_x: i32 = inner_right - status_px;

    const gap_px: i32 = if (status_text.len != 0) 8 else 0;
    const url_px_avail: i32 = @max(0, status_x - inner_left - gap_px);
    const url_chars_avail: usize = @intCast(@max(0, @divTrunc(url_px_avail, char_w)));

    const url_text = if (url.len > url_chars_avail) url[0..url_chars_avail] else url;
    try frame.text(inner_left, text_y, 0xFFE6E6E6, url_text);
    if (status_text.len != 0) try frame.text(status_x, text_y, 0xFFB5B9C4, status_text);

    const y_off: i32 = content_y_off - scroll_y;
    var reader = try display_list.Reader.init(content_dl);
    var painted_bg: bool = false;
    while (try reader.next()) |cmd| {
        switch (cmd) {
            .clear => |c| {
                if (!painted_bg) {
                    painted_bg = true;
                    // Treat the content display list's clear as the page background, but only
                    // for the content viewport (keep the chrome intact).
                    try frame.rect(0, content_y_off, width, 1_000_000, c);
                }
            },
            .text => |t| try frame.text(t.x, t.y + y_off, t.color_bgra, t.bytes),
            .rect => |r| try frame.rect(r.x, r.y + y_off, r.w, r.h, r.color_bgra),
            .bitmap => |b| try frame.bitmap(b.x, b.y + y_off, b.w, b.h, b.bgra),
        }
    }

    return try frame.finish();
}
