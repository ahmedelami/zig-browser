const std = @import("std");

pub const DecodedImage = struct {
    width: u32,
    height: u32,
    bgra: []u8, // width*height*4, BGRA8, unpremultiplied
};

pub fn freeDecoded(alloc: std.mem.Allocator, img: *DecodedImage) void {
    alloc.free(img.bgra);
    img.* = undefined;
}

pub fn decodeBgra8(alloc: std.mem.Allocator, png_bytes: []const u8, max_pixels: usize) !DecodedImage {
    const sig = "\x89PNG\r\n\x1a\n";
    if (png_bytes.len < sig.len) return error.BadPng;
    if (!std.mem.eql(u8, png_bytes[0..sig.len], sig)) return error.BadPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var compression: u8 = 0;
    var filter: u8 = 0;
    var interlace: u8 = 0;
    var saw_ihdr = false;
    var plte: ?[]const u8 = null;
    var trns: ?[]const u8 = null;

    var idat = std.ArrayList(u8).initCapacity(alloc, 32 * 1024) catch std.ArrayList(u8).initCapacity(alloc, 0) catch unreachable;
    defer idat.deinit(alloc);

    var idx: usize = sig.len;
    while (idx + 12 <= png_bytes.len) {
        const len = readBeU32(png_bytes[idx..][0..4]);
        idx += 4;
        const typ = png_bytes[idx..][0..4];
        idx += 4;

        const data_len: usize = @intCast(len);
        if (idx + data_len + 4 > png_bytes.len) return error.TruncatedPng;
        const data = png_bytes[idx .. idx + data_len];
        idx += data_len;
        idx += 4; // crc (ignored)

        if (std.mem.eql(u8, typ, "IHDR")) {
            if (data.len != 13) return error.BadPng;
            width = readBeU32(data[0..4]);
            height = readBeU32(data[4..8]);
            bit_depth = data[8];
            color_type = data[9];
            compression = data[10];
            filter = data[11];
            interlace = data[12];
            saw_ihdr = true;
            continue;
        }

        if (!saw_ihdr) continue;

        if (std.mem.eql(u8, typ, "IDAT")) {
            if (data.len != 0) idat.appendSlice(alloc, data) catch return error.OutOfMemory;
            continue;
        }
        if (std.mem.eql(u8, typ, "PLTE")) {
            plte = data;
            continue;
        }
        if (std.mem.eql(u8, typ, "tRNS")) {
            trns = data;
            continue;
        }
        if (std.mem.eql(u8, typ, "IEND")) break;
    }

    if (!saw_ihdr) return error.MissingIHDR;
    if (width == 0 or height == 0) return error.BadPng;
    if (compression != 0 or filter != 0) return error.UnsupportedPng;
    if (interlace != 0) return error.UnsupportedPng;

    if (color_type == 3 and plte == null) return error.MissingPLTE;
    if (color_type == 2 or color_type == 4 or color_type == 6) {
        if (bit_depth != 8) return error.UnsupportedPng;
    } else if (color_type == 0 or color_type == 3) {
        if (!(bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8)) return error.UnsupportedPng;
    } else {
        return error.UnsupportedPng;
    }

    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    if (w == 0 or h == 0) return error.BadPng;
    if (w > 32_768 or h > 32_768) return error.ImageTooLarge;
    const pixels = std.math.mul(usize, w, h) catch return error.ImageTooLarge;
    if (pixels > max_pixels) return error.ImageTooLarge;

    const bits_per_pixel: usize = switch (color_type) {
        0 => bit_depth,
        2 => 3 * bit_depth,
        3 => bit_depth,
        4 => 2 * bit_depth,
        6 => 4 * bit_depth,
        else => return error.UnsupportedPng,
    };
    const bpp: usize = @max(1, (bits_per_pixel + 7) / 8);

    const row_bits = std.math.mul(usize, w, bits_per_pixel) catch return error.ImageTooLarge;
    const row_bytes = (row_bits + 7) / 8;
    const scanline_bytes = 1 + row_bytes;
    const expected = std.math.mul(usize, h, scanline_bytes) catch return error.ImageTooLarge;
    if (expected > 64 * 1024 * 1024) return error.ImageTooLarge;
    if (idat.items.len == 0) return error.MissingIDAT;

    const scan = try alloc.alloc(u8, expected);
    defer alloc.free(scan);

    var out_w = std.Io.Writer.fixed(scan);
    var in_r = std.Io.Reader.fixed(idat.items);
    const window: []u8 = &.{};
    var decomp = std.compress.flate.Decompress.init(&in_r, .zlib, window);

    _ = decomp.reader.streamRemaining(&out_w) catch return error.BadZlib;
    if (out_w.end != expected) return error.BadZlib;

    const raw_len = std.math.mul(usize, h, row_bytes) catch return error.ImageTooLarge;
    const raw = try alloc.alloc(u8, raw_len);
    defer alloc.free(raw);

    unfilter(raw, scan, w, h, bpp);

    const bgra_len = std.math.mul(usize, w * h, 4) catch return error.ImageTooLarge;
    const bgra = try alloc.alloc(u8, bgra_len);
    errdefer alloc.free(bgra);

    switch (color_type) {
        0 => { // grayscale
            var y: usize = 0;
            while (y < h) : (y += 1) {
                const src_row = raw[y * row_bytes ..][0..row_bytes];
                const dst_row = bgra[y * w * 4 ..][0 .. w * 4];
                var x: usize = 0;
                while (x < w) : (x += 1) {
                    const s = readPackedSample(src_row, x, bit_depth);
                    const g = scaleSampleTo8(s, bit_depth);
                    const di = x * 4;
                    dst_row[di + 0] = g;
                    dst_row[di + 1] = g;
                    dst_row[di + 2] = g;
                    dst_row[di + 3] = 0xFF;
                }
            }
        },
        2 => { // RGB
            var y: usize = 0;
            while (y < h) : (y += 1) {
                const src_row = raw[y * row_bytes ..][0..row_bytes];
                const dst_row = bgra[y * w * 4 ..][0 .. w * 4];
                var x: usize = 0;
                while (x < w) : (x += 1) {
                    const si = x * 3;
                    const di = x * 4;
                    dst_row[di + 0] = src_row[si + 2];
                    dst_row[di + 1] = src_row[si + 1];
                    dst_row[di + 2] = src_row[si + 0];
                    dst_row[di + 3] = 0xFF;
                }
            }
        },
        3 => { // palette
            const pal = plte.?;
            const n_entries: usize = @min(256, pal.len / 3);
            const alpha = trns orelse &.{};

            var y: usize = 0;
            while (y < h) : (y += 1) {
                const src_row = raw[y * row_bytes ..][0..row_bytes];
                const dst_row = bgra[y * w * 4 ..][0 .. w * 4];
                var x: usize = 0;
                while (x < w) : (x += 1) {
                    const idx8: u8 = readPackedSample(src_row, x, bit_depth);
                    const pi: usize = @intCast(idx8);
                    const di = x * 4;
                    if (pi >= n_entries) {
                        dst_row[di + 0] = 0;
                        dst_row[di + 1] = 0;
                        dst_row[di + 2] = 0;
                        dst_row[di + 3] = 0xFF;
                        continue;
                    }

                    const base = pi * 3;
                    const r = pal[base + 0];
                    const g = pal[base + 1];
                    const b = pal[base + 2];
                    const a: u8 = if (pi < alpha.len) alpha[pi] else 0xFF;
                    dst_row[di + 0] = b;
                    dst_row[di + 1] = g;
                    dst_row[di + 2] = r;
                    dst_row[di + 3] = a;
                }
            }
        },
        4 => { // grayscale + alpha
            var y: usize = 0;
            while (y < h) : (y += 1) {
                const src_row = raw[y * row_bytes ..][0..row_bytes];
                const dst_row = bgra[y * w * 4 ..][0 .. w * 4];
                var x: usize = 0;
                while (x < w) : (x += 1) {
                    const si = x * 2;
                    const di = x * 4;
                    const g = src_row[si + 0];
                    dst_row[di + 0] = g;
                    dst_row[di + 1] = g;
                    dst_row[di + 2] = g;
                    dst_row[di + 3] = src_row[si + 1];
                }
            }
        },
        6 => { // RGBA
            var y: usize = 0;
            while (y < h) : (y += 1) {
                const src_row = raw[y * row_bytes ..][0..row_bytes];
                const dst_row = bgra[y * w * 4 ..][0 .. w * 4];
                var x: usize = 0;
                while (x < w) : (x += 1) {
                    const si = x * 4;
                    const di = x * 4;
                    dst_row[di + 0] = src_row[si + 2];
                    dst_row[di + 1] = src_row[si + 1];
                    dst_row[di + 2] = src_row[si + 0];
                    dst_row[di + 3] = src_row[si + 3];
                }
            }
        },
        else => return error.UnsupportedPng,
    }

    return .{ .width = width, .height = height, .bgra = bgra };
}

fn readBeU32(bytes: []const u8) u32 {
    const ptr: *const [4]u8 = @ptrCast(bytes.ptr);
    return std.mem.readInt(u32, ptr, .big);
}

fn unfilter(dst: []u8, scan: []const u8, width: usize, height: usize, bpp: usize) void {
    const row_bytes = width * bpp;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const scan_off = y * (1 + row_bytes);
        const filter_type = scan[scan_off];
        const src = scan[scan_off + 1 ..][0..row_bytes];
        const out = dst[y * row_bytes ..][0..row_bytes];
        const prev = if (y == 0) null else dst[(y - 1) * row_bytes ..][0..row_bytes];

        switch (filter_type) {
            0 => @memcpy(out, src),
            1 => {
                var i: usize = 0;
                while (i < row_bytes) : (i += 1) {
                    const left: u8 = if (i >= bpp) out[i - bpp] else 0;
                    out[i] = src[i] +% left;
                }
            },
            2 => {
                var i: usize = 0;
                while (i < row_bytes) : (i += 1) {
                    const up: u8 = if (prev) |p| p[i] else 0;
                    out[i] = src[i] +% up;
                }
            },
            3 => {
                var i: usize = 0;
                while (i < row_bytes) : (i += 1) {
                    const left: u8 = if (i >= bpp) out[i - bpp] else 0;
                    const up: u8 = if (prev) |p| p[i] else 0;
                    const avg: u8 = @intCast((@as(u16, left) + @as(u16, up)) / 2);
                    out[i] = src[i] +% avg;
                }
            },
            4 => {
                var i: usize = 0;
                while (i < row_bytes) : (i += 1) {
                    const a: u8 = if (i >= bpp) out[i - bpp] else 0;
                    const b: u8 = if (prev) |p| p[i] else 0;
                    const c: u8 = if (prev) |p| if (i >= bpp) p[i - bpp] else 0 else 0;
                    out[i] = src[i] +% paeth(a, b, c);
                }
            },
            else => @memcpy(out, src), // best-effort
        }
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const pa: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const da: i32 = pa - @as(i32, a);
    const db: i32 = pa - @as(i32, b);
    const dc: i32 = pa - @as(i32, c);
    const p_a: i32 = if (da < 0) -da else da;
    const p_b: i32 = if (db < 0) -db else db;
    const p_c: i32 = if (dc < 0) -dc else dc;
    if (p_a <= p_b and p_a <= p_c) return a;
    if (p_b <= p_c) return b;
    return c;
}

fn readPackedSample(row: []const u8, x: usize, bit_depth: u8) u8 {
    if (bit_depth == 8) return row[x];
    const bd: u8 = @max(1, bit_depth);
    const ppb: usize = 8 / bd;
    const byte_index: usize = x / ppb;
    const within: usize = x % ppb;
    const shift: u3 = @intCast((ppb - 1 - within) * bd);
    const mask: u8 = @intCast((@as(u16, 1) << @intCast(bd)) - 1);
    return (row[byte_index] >> shift) & mask;
}

fn scaleSampleTo8(sample: u8, bit_depth: u8) u8 {
    if (bit_depth == 8) return sample;
    const max_sample: u16 = (@as(u16, 1) << @intCast(bit_depth)) - 1;
    return @intCast((@as(u16, sample) * 255 + max_sample / 2) / max_sample);
}
