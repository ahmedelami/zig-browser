const std = @import("std");

pub const magic = [_]u8{ 'Z', 'B', 'D', 'L' };
pub const version: u16 = 2;

pub const Tag = enum(u8) {
    clear = 1,
    text = 2,
    rect = 3,
    bitmap = 4,
};

pub const Builder = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) !Builder {
        var list = try std.ArrayList(u8).initCapacity(alloc, magic.len + 2);
        errdefer list.deinit(alloc);

        try list.appendSlice(alloc, &magic);
        try appendInt(alloc, &list, u16, version);

        return .{ .alloc = alloc, .list = list };
    }

    pub fn deinit(self: *Builder) void {
        self.list.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn clear(self: *Builder, color_bgra: u32) !void {
        try self.list.append(self.alloc, @intFromEnum(Tag.clear));
        try appendInt(self.alloc, &self.list, u32, color_bgra);
    }

    pub fn text(self: *Builder, x: i32, y: i32, color_bgra: u32, bytes: []const u8) !void {
        try self.list.append(self.alloc, @intFromEnum(Tag.text));
        try appendInt(self.alloc, &self.list, i32, x);
        try appendInt(self.alloc, &self.list, i32, y);
        try appendInt(self.alloc, &self.list, u32, color_bgra);
        try appendInt(self.alloc, &self.list, u32, @intCast(bytes.len));
        try self.list.appendSlice(self.alloc, bytes);
    }

    pub fn rect(self: *Builder, x: i32, y: i32, w: i32, h: i32, color_bgra: u32) !void {
        try self.list.append(self.alloc, @intFromEnum(Tag.rect));
        try appendInt(self.alloc, &self.list, i32, x);
        try appendInt(self.alloc, &self.list, i32, y);
        try appendInt(self.alloc, &self.list, i32, w);
        try appendInt(self.alloc, &self.list, i32, h);
        try appendInt(self.alloc, &self.list, u32, color_bgra);
    }

    pub fn bitmap(self: *Builder, x: i32, y: i32, w: i32, h: i32, bgra: []const u8) !void {
        try self.list.append(self.alloc, @intFromEnum(Tag.bitmap));
        try appendInt(self.alloc, &self.list, i32, x);
        try appendInt(self.alloc, &self.list, i32, y);
        try appendInt(self.alloc, &self.list, i32, w);
        try appendInt(self.alloc, &self.list, i32, h);
        try appendInt(self.alloc, &self.list, u32, @intCast(bgra.len));
        try self.list.appendSlice(self.alloc, bgra);
    }

    pub fn finish(self: *Builder) ![]u8 {
        return try self.list.toOwnedSlice(self.alloc);
    }
};

pub const Command = union(Tag) {
    clear: u32,
    text: Text,
    rect: Rect,
    bitmap: Bitmap,

    pub const Text = struct {
        x: i32,
        y: i32,
        color_bgra: u32,
        bytes: []const u8,
    };

    pub const Rect = struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        color_bgra: u32,
    };

    pub const Bitmap = struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        bgra: []const u8,
    };
};

pub const Reader = struct {
    bytes: []const u8,
    index: usize,

    pub fn init(bytes: []const u8) !Reader {
        if (bytes.len < magic.len + 2) return error.BadDisplayList;
        if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.BadDisplayList;

        const ver = std.mem.readInt(u16, bytes[magic.len .. magic.len + 2], .little);
        if (ver != version) return error.UnsupportedDisplayListVersion;

        return .{ .bytes = bytes, .index = magic.len + 2 };
    }

    pub fn next(self: *Reader) !?Command {
        if (self.index >= self.bytes.len) return null;

        const tag_raw = self.bytes[self.index];
        self.index += 1;

        const tag: Tag = std.meta.intToEnum(Tag, tag_raw) catch return error.BadDisplayList;
        switch (tag) {
            .clear => {
                const c = try readInt(self, u32);
                return .{ .clear = c };
            },
            .text => {
                const x = try readInt(self, i32);
                const y = try readInt(self, i32);
                const color = try readInt(self, u32);
                const len = try readInt(self, u32);
                const n: usize = @intCast(len);
                if (self.index + n > self.bytes.len) return error.BadDisplayList;
                const s = self.bytes[self.index .. self.index + n];
                self.index += n;
                return .{ .text = .{ .x = x, .y = y, .color_bgra = color, .bytes = s } };
            },
            .rect => {
                const x = try readInt(self, i32);
                const y = try readInt(self, i32);
                const w = try readInt(self, i32);
                const h = try readInt(self, i32);
                const color = try readInt(self, u32);
                return .{ .rect = .{ .x = x, .y = y, .w = w, .h = h, .color_bgra = color } };
            },
            .bitmap => {
                const x = try readInt(self, i32);
                const y = try readInt(self, i32);
                const w = try readInt(self, i32);
                const h = try readInt(self, i32);
                const len = try readInt(self, u32);
                const n: usize = @intCast(len);
                if (self.index + n > self.bytes.len) return error.BadDisplayList;
                const bgra = self.bytes[self.index .. self.index + n];
                self.index += n;
                return .{ .bitmap = .{ .x = x, .y = y, .w = w, .h = h, .bgra = bgra } };
            },
        }
    }
};

fn appendInt(alloc: std.mem.Allocator, list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try list.appendSlice(alloc, &buf);
}

fn readInt(r: *Reader, comptime T: type) !T {
    const n = @sizeOf(T);
    if (r.index + n > r.bytes.len) return error.BadDisplayList;
    const bytes = r.bytes[r.index .. r.index + n];
    const ptr: *const [n]u8 = @ptrCast(bytes.ptr);
    const v = std.mem.readInt(T, ptr, .little);
    r.index += n;
    return v;
}
