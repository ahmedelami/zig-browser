const std = @import("std");

pub fn argValue(flag: []const u8) !?[]const u8 {
    var it = std.process.args();
    _ = it.next(); // exe
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, flag)) {
            return it.next() orelse return error.MissingValue;
        }
    }
    return null;
}

pub fn hasArg(flag: []const u8) bool {
    var it = std.process.args();
    _ = it.next(); // exe
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

pub fn nowUnixSeconds() i64 {
    return std.time.timestamp();
}

pub fn makeRunDir(alloc: std.mem.Allocator, base: []const u8) ![]u8 {
    const pid: i32 = std.c.getpid();
    const ts = nowUnixSeconds();
    return std.fmt.allocPrint(alloc, "{s}/{d}-{d}", .{ base, ts, pid });
}

pub fn siblingExePath(alloc: std.mem.Allocator, exe_name: []const u8) ![]u8 {
    const self_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(self_path);

    const dir = std.fs.path.dirname(self_path) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, exe_name });
}
