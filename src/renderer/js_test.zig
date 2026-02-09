const std = @import("std");

const dom_mod = @import("dom.zig");
const js = @import("js/js.zig");

test "js: document.title assignment" {
    var dom = try dom_mod.Dom.init(std.testing.allocator);
    defer dom.deinit();

    var engine = js.Engine.init(&dom);
    const res = js.eval(&engine, "document.title = \"hi\";");
    try std.testing.expect(res.err == null);
    try std.testing.expect(res.dirty);
    try std.testing.expectEqualStrings("hi", dom.title.items);
}

test "js: console.log does not dirty title" {
    var dom = try dom_mod.Dom.init(std.testing.allocator);
    defer dom.deinit();

    var engine = js.Engine.init(&dom);
    const res = js.eval(&engine, "console.log(\"ok\");");
    try std.testing.expect(res.err == null);
    try std.testing.expect(!res.dirty);
}

const HostCapture = struct {
    alloc: std.mem.Allocator,
    cookie: std.ArrayList(u8),
    nav_url: std.ArrayList(u8),
    nav_mode: ?js.NavMode = null,

    fn init(alloc: std.mem.Allocator) !HostCapture {
        return .{
            .alloc = alloc,
            .cookie = try std.ArrayList(u8).initCapacity(alloc, 64),
            .nav_url = try std.ArrayList(u8).initCapacity(alloc, 128),
            .nav_mode = null,
        };
    }

    fn deinit(self: *HostCapture) void {
        self.cookie.deinit(self.alloc);
        self.nav_url.deinit(self.alloc);
        self.* = undefined;
    }
};

fn hostSetCookie(ctx_ptr: *anyopaque, cookie: []const u8) void {
    const cap: *HostCapture = @ptrCast(@alignCast(ctx_ptr));
    cap.cookie.items.len = 0;
    cap.cookie.appendSlice(cap.alloc, cookie) catch {};
}

fn hostNavigate(ctx_ptr: *anyopaque, mode: js.NavMode, url: []const u8) void {
    const cap: *HostCapture = @ptrCast(@alignCast(ctx_ptr));
    cap.nav_mode = mode;
    cap.nav_url.items.len = 0;
    cap.nav_url.appendSlice(cap.alloc, url) catch {};
}

test "js: document.cookie assignment calls host" {
    var dom = try dom_mod.Dom.init(std.testing.allocator);
    defer dom.deinit();

    var cap = try HostCapture.init(std.testing.allocator);
    defer cap.deinit();

    var engine = js.Engine.init(&dom);
    engine.setHost(.{
        .ctx = @ptrCast(&cap),
        .set_cookie = hostSetCookie,
        .navigate = hostNavigate,
    });

    const res = js.eval(&engine, "document.cookie = \"a=b; Path=/\";");
    try std.testing.expect(res.err == null);
    try std.testing.expectEqualStrings("a=b; Path=/", cap.cookie.items);
}

test "js: location.replace calls host navigate" {
    var dom = try dom_mod.Dom.init(std.testing.allocator);
    defer dom.deinit();

    var cap = try HostCapture.init(std.testing.allocator);
    defer cap.deinit();

    var engine = js.Engine.init(&dom);
    engine.setHost(.{
        .ctx = @ptrCast(&cap),
        .set_cookie = hostSetCookie,
        .navigate = hostNavigate,
    });

    const res = js.eval(&engine, "location.replace(\"https://example.com/\");");
    try std.testing.expect(res.err == null);
    try std.testing.expectEqual(js.NavMode.replace, cap.nav_mode.?);
    try std.testing.expectEqualStrings("https://example.com/", cap.nav_url.items);
}
