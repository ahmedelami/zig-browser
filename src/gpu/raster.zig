const std = @import("std");
const shared = @import("shared");

const display_list = shared.display_list;
const font = @import("font8x8_basic.zig").font8x8_basic;

pub fn rasterIntoBgra8(
    surface_bgra: []u8,
    width: usize,
    height: usize,
    stride: usize,
    list_bytes: []const u8,
) !void {
    var reader = try display_list.Reader.init(list_bytes);
    while (try reader.next()) |cmd| {
        switch (cmd) {
            .clear => |c| clear(surface_bgra, width, height, stride, c),
            .rect => |r| drawRect(surface_bgra, width, height, stride, r.x, r.y, r.w, r.h, r.color_bgra),
            .text => |t| drawText(surface_bgra, width, height, stride, t.x, t.y, t.color_bgra, t.bytes),
            .bitmap => |b| drawBitmap(surface_bgra, width, height, stride, b.x, b.y, b.w, b.h, b.bgra),
        }
    }
}

fn clear(buf: []u8, width: usize, height: usize, stride: usize, color_bgra: u32) void {
    const b: u8 = @truncate(color_bgra);
    const g: u8 = @truncate(color_bgra >> 8);
    const r: u8 = @truncate(color_bgra >> 16);
    const a: u8 = @truncate(color_bgra >> 24);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = buf[y * stride ..][0 .. width * 4];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const p = x * 4;
            row[p + 0] = b;
            row[p + 1] = g;
            row[p + 2] = r;
            row[p + 3] = a;
        }
    }
}

fn drawRect(
    buf: []u8,
    width: usize,
    height: usize,
    stride: usize,
    x0: i32,
    y0: i32,
    w: i32,
    h: i32,
    color_bgra: u32,
) void {
    if (w <= 0 or h <= 0) return;

    const surface_w: i32 = @intCast(width);
    const surface_h: i32 = @intCast(height);

    const x1 = x0 + w;
    const y1 = y0 + h;

    const start_x: i32 = @max(0, x0);
    const start_y: i32 = @max(0, y0);
    const end_x: i32 = @min(surface_w, x1);
    const end_y: i32 = @min(surface_h, y1);

    if (end_x <= start_x or end_y <= start_y) return;

    const b: u8 = @truncate(color_bgra);
    const g: u8 = @truncate(color_bgra >> 8);
    const r: u8 = @truncate(color_bgra >> 16);
    const a: u8 = @truncate(color_bgra >> 24);

    var y: i32 = start_y;
    while (y < end_y) : (y += 1) {
        const row = buf[@as(usize, @intCast(y)) * stride ..];

        var x: i32 = start_x;
        while (x < end_x) : (x += 1) {
            const p = @as(usize, @intCast(x)) * 4;
            row[p + 0] = b;
            row[p + 1] = g;
            row[p + 2] = r;
            row[p + 3] = a;
        }
    }
}

fn drawText(
    buf: []u8,
    width: usize,
    height: usize,
    stride: usize,
    x0: i32,
    y0: i32,
    color_bgra: u32,
    text: []const u8,
) void {
    var x: i32 = x0;
    var y: i32 = y0;

    for (text) |ch| {
        switch (ch) {
            '\n' => {
                x = x0;
                y += 10;
                continue;
            },
            '\r' => continue,
            '\t' => {
                x += 8 * 4;
                continue;
            },
            else => {},
        }

        if (y + 8 > @as(i32, @intCast(height))) break;
        if (x + 8 > @as(i32, @intCast(width))) {
            x = x0;
            y += 10;
            if (y + 8 > @as(i32, @intCast(height))) break;
        }

        drawGlyph(buf, width, height, stride, x, y, color_bgra, ch);
        x += 8;
    }
}

fn drawGlyph(
    buf: []u8,
    width: usize,
    height: usize,
    stride: usize,
    x: i32,
    y: i32,
    color_bgra: u32,
    ch: u8,
) void {
    const idx: usize = if (ch < 128) ch else @as(usize, '?');
    const glyph = font[idx];

    const b: u8 = @truncate(color_bgra);
    const g: u8 = @truncate(color_bgra >> 8);
    const r: u8 = @truncate(color_bgra >> 16);
    const a: u8 = @truncate(color_bgra >> 24);

    var row_i: usize = 0;
    while (row_i < 8) : (row_i += 1) {
        const py_i: i32 = y + @as(i32, @intCast(row_i));
        if (py_i < 0 or py_i >= @as(i32, @intCast(height))) continue;

        const bits = glyph[row_i];
        var col_i: usize = 0;
        while (col_i < 8) : (col_i += 1) {
            if (((bits >> @intCast(col_i)) & 1) == 0) continue;

            const px_i: i32 = x + @as(i32, @intCast(col_i));
            if (px_i < 0 or px_i >= @as(i32, @intCast(width))) continue;

            const px: usize = @intCast(px_i);
            const py: usize = @intCast(py_i);
            const p = py * stride + px * 4;
            buf[p + 0] = b;
            buf[p + 1] = g;
            buf[p + 2] = r;
            buf[p + 3] = a;
        }
    }
}

fn drawBitmap(
    buf: []u8,
    width: usize,
    height: usize,
    stride: usize,
    x0: i32,
    y0: i32,
    w: i32,
    h: i32,
    bgra: []const u8,
) void {
    if (w <= 0 or h <= 0) return;

    const src_w: usize = @intCast(w);
    const src_h: usize = @intCast(h);
    const expected = std.math.mul(usize, src_w * src_h, 4) catch return;
    if (bgra.len < expected) return;

    const surface_w: i32 = @intCast(width);
    const surface_h: i32 = @intCast(height);

    const x1 = x0 + w;
    const y1 = y0 + h;
    const start_x: i32 = @max(0, x0);
    const start_y: i32 = @max(0, y0);
    const end_x: i32 = @min(surface_w, x1);
    const end_y: i32 = @min(surface_h, y1);
    if (end_x <= start_x or end_y <= start_y) return;

    var y: i32 = start_y;
    while (y < end_y) : (y += 1) {
        const sy: usize = @intCast(y - y0);
        const src_row = bgra[sy * src_w * 4 ..][0 .. src_w * 4];
        const dst_row = buf[@as(usize, @intCast(y)) * stride ..];

        var x: i32 = start_x;
        while (x < end_x) : (x += 1) {
            const sx: usize = @intCast(x - x0);
            const si = sx * 4;
            const di = @as(usize, @intCast(x)) * 4;

            const sb = src_row[si + 0];
            const sg = src_row[si + 1];
            const sr = src_row[si + 2];
            const sa = src_row[si + 3];
            if (sa == 0) continue;
            if (sa == 0xFF) {
                dst_row[di + 0] = sb;
                dst_row[di + 1] = sg;
                dst_row[di + 2] = sr;
                dst_row[di + 3] = 0xFF;
                continue;
            }

            const inv: u32 = 255 - sa;
            const a: u32 = sa;

            const db: u32 = dst_row[di + 0];
            const dg: u32 = dst_row[di + 1];
            const dr: u32 = dst_row[di + 2];

            dst_row[di + 0] = @intCast((@as(u32, sb) * a + db * inv + 127) / 255);
            dst_row[di + 1] = @intCast((@as(u32, sg) * a + dg * inv + 127) / 255);
            dst_row[di + 2] = @intCast((@as(u32, sr) * a + dr * inv + 127) / 255);
            dst_row[di + 3] = 0xFF;
        }
    }
}
