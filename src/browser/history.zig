const std = @import("std");

pub const History = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList([]u8),
    index: usize = 0,

    pub fn init(alloc: std.mem.Allocator) !History {
        return .{
            .alloc = alloc,
            .entries = try std.ArrayList([]u8).initCapacity(alloc, 32),
            .index = 0,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |s| self.alloc.free(s);
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn current(self: *const History) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.index];
    }

    pub fn canBack(self: *const History) bool {
        return self.entries.items.len != 0 and self.index != 0;
    }

    pub fn canForward(self: *const History) bool {
        return self.entries.items.len != 0 and self.index + 1 < self.entries.items.len;
    }

    pub fn back(self: *History) ?[]const u8 {
        if (!self.canBack()) return null;
        self.index -= 1;
        return self.entries.items[self.index];
    }

    pub fn forward(self: *History) ?[]const u8 {
        if (!self.canForward()) return null;
        self.index += 1;
        return self.entries.items[self.index];
    }

    pub fn push(self: *History, url: []const u8) !void {
        if (self.entries.items.len == 0) {
            const copy = try self.alloc.dupe(u8, url);
            try self.entries.append(self.alloc, copy);
            self.index = 0;
            return;
        }

        const cur = self.entries.items[self.index];
        if (std.mem.eql(u8, cur, url)) return;

        // Drop forward history.
        var i = self.index + 1;
        while (i < self.entries.items.len) : (i += 1) {
            self.alloc.free(self.entries.items[i]);
        }
        self.entries.items.len = self.index + 1;

        const copy = try self.alloc.dupe(u8, url);
        try self.entries.append(self.alloc, copy);
        self.index = self.entries.items.len - 1;
    }

    pub fn replaceCurrent(self: *History, url: []const u8) !void {
        if (self.entries.items.len == 0) return try self.push(url);

        const cur = self.entries.items[self.index];
        if (std.mem.eql(u8, cur, url)) return;

        // Drop forward history.
        var i = self.index + 1;
        while (i < self.entries.items.len) : (i += 1) {
            self.alloc.free(self.entries.items[i]);
        }
        self.entries.items.len = self.index + 1;

        const copy = try self.alloc.dupe(u8, url);
        self.alloc.free(self.entries.items[self.index]);
        self.entries.items[self.index] = copy;
    }
};

test "History: push/back/forward" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var h = try History.init(alloc);
    defer h.deinit();

    try h.push("about:blank");
    try h.push("https://example.com");
    try std.testing.expectEqualStrings("https://example.com", h.current().?);

    _ = h.back();
    try std.testing.expectEqualStrings("about:blank", h.current().?);

    _ = h.forward();
    try std.testing.expectEqualStrings("https://example.com", h.current().?);
}

test "History: replaceCurrent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var h = try History.init(alloc);
    defer h.deinit();

    try h.push("https://example.com/a");
    try h.push("https://example.com/b");
    try h.replaceCurrent("https://example.com/b2");
    try std.testing.expectEqualStrings("https://example.com/b2", h.current().?);

    _ = h.back();
    try std.testing.expectEqualStrings("https://example.com/a", h.current().?);

    _ = h.forward();
    try std.testing.expectEqualStrings("https://example.com/b2", h.current().?);
}
