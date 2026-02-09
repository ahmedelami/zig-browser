const std = @import("std");
const builtin = @import("builtin");

pub const MachineInfo = struct {
    collected_at_unix_s: i64,

    os: Os,
    hw: Hw,
    tooling: Tooling,

    pub const Os = struct {
        product: []const u8,
        product_version: ?[]const u8,
        build_version: ?[]const u8,
        kernel_version: ?[]const u8,
    };

    pub const PerfLevel = struct {
        index: u32,
        name: ?[]const u8,
        physicalcpu: ?u32,
        logicalcpu: ?u32,
        l1icachesize: ?u64,
        l1dcachesize: ?u64,
        l2cachesize: ?u64,
        cpusperl2: ?u32,
    };

    pub const Hw = struct {
        model: ?[]const u8,
        machine: ?[]const u8,
        chip: ?[]const u8,

        memsize_bytes: ?u64,
        pagesize_bytes: ?u64,

        ncpu: ?u32,
        physicalcpu: ?u32,
        logicalcpu: ?u32,

        cachelinesize_bytes: ?u64,
        cpufamily: ?u64,
        tbfrequency_hz: ?u64,

        perflevels: []const PerfLevel,
    };

    pub const Tooling = struct {
        zig_version: []const u8,
        self_exe_path: ?[]const u8,
        target: []const u8,
    };
};

pub fn collect(alloc: std.mem.Allocator) !MachineInfo {
    const zig_ver = builtin.zig_version;
    const zig_version_str = try std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{ zig_ver.major, zig_ver.minor, zig_ver.patch });

    const self_exe_path = std.fs.selfExePathAlloc(alloc) catch null;

    const target_str = try std.fmt.allocPrint(alloc, "{s}-{s}", .{ @tagName(builtin.target.cpu.arch), @tagName(builtin.target.os.tag) });

    const nperflevels_u64 = sysctlU64Opt("hw.nperflevels") orelse 0;
    const nperflevels: u32 = @intCast(@min(nperflevels_u64, std.math.maxInt(u32)));
    var perflevels = try alloc.alloc(MachineInfo.PerfLevel, nperflevels);

    var i: u32 = 0;
    while (i < nperflevels) : (i += 1) {
        perflevels[i] = try collectPerfLevel(alloc, i);
    }

    return .{
        .collected_at_unix_s = std.time.timestamp(),
        .os = .{
            .product = switch (builtin.os.tag) {
                .macos => "macOS",
                else => @tagName(builtin.os.tag),
            },
            .product_version = sysctlStringOpt(alloc, "kern.osproductversion"),
            .build_version = sysctlStringOpt(alloc, "kern.osversion"),
            .kernel_version = sysctlStringOpt(alloc, "kern.version"),
        },
        .hw = .{
            .model = sysctlStringOpt(alloc, "hw.model"),
            .machine = sysctlStringOpt(alloc, "hw.machine"),
            .chip = sysctlStringOpt(alloc, "machdep.cpu.brand_string"),

            .memsize_bytes = sysctlU64Opt("hw.memsize"),
            .pagesize_bytes = sysctlU64Opt("hw.pagesize"),

            .ncpu = castU32(sysctlU64Opt("hw.ncpu")),
            .physicalcpu = castU32(sysctlU64Opt("hw.physicalcpu")),
            .logicalcpu = castU32(sysctlU64Opt("hw.logicalcpu")),

            .cachelinesize_bytes = sysctlU64Opt("hw.cachelinesize"),
            .cpufamily = sysctlU64Opt("hw.cpufamily"),
            .tbfrequency_hz = sysctlU64Opt("hw.tbfrequency"),

            .perflevels = perflevels,
        },
        .tooling = .{
            .zig_version = zig_version_str,
            .self_exe_path = self_exe_path,
            .target = target_str,
        },
    };
}

pub fn writeJson(dir: std.fs.Dir, filename: []const u8, alloc: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const info = try collect(arena.allocator());

    const file = try dir.createFile(filename, .{ .truncate = true });
    defer file.close();

    var buf: [16 * 1024]u8 = undefined;
    var fw = file.writer(&buf);
    defer fw.interface.flush() catch {};

    try std.json.Stringify.value(info, .{ .whitespace = .indent_2 }, &fw.interface);
    try fw.interface.writeAll("\n");
}

fn castU32(value: ?u64) ?u32 {
    const v = value orelse return null;
    if (v > std.math.maxInt(u32)) return null;
    return @intCast(v);
}

fn collectPerfLevel(alloc: std.mem.Allocator, index: u32) !MachineInfo.PerfLevel {
    var key_buf: [64:0]u8 = undefined;

    const name = sysctlStringOpt(alloc, try std.fmt.bufPrintZ(&key_buf, "hw.perflevel{d}.name", .{index}));
    const physicalcpu = castU32(sysctlU64Opt(try std.fmt.bufPrintZ(&key_buf, "hw.perflevel{d}.physicalcpu", .{index})));
    const logicalcpu = castU32(sysctlU64Opt(try std.fmt.bufPrintZ(&key_buf, "hw.perflevel{d}.logicalcpu", .{index})));
    const l1i = sysctlU64Opt(try std.fmt.bufPrintZ(&key_buf, "hw.perflevel{d}.l1icachesize", .{index}));
    const l1d = sysctlU64Opt(try std.fmt.bufPrintZ(&key_buf, "hw.perflevel{d}.l1dcachesize", .{index}));
    const l2 = sysctlU64Opt(try std.fmt.bufPrintZ(&key_buf, "hw.perflevel{d}.l2cachesize", .{index}));
    const cpusperl2 = castU32(sysctlU64Opt(try std.fmt.bufPrintZ(&key_buf, "hw.perflevel{d}.cpusperl2", .{index})));

    return .{
        .index = index,
        .name = name,
        .physicalcpu = physicalcpu,
        .logicalcpu = logicalcpu,
        .l1icachesize = l1i,
        .l1dcachesize = l1d,
        .l2cachesize = l2,
        .cpusperl2 = cpusperl2,
    };
}

fn sysctlU64Opt(name: [:0]const u8) ?u64 {
    var value: u64 = 0;
    var len: usize = @sizeOf(u64);

    std.posix.sysctlbynameZ(name.ptr, &value, &len, null, 0) catch return null;
    return value;
}

fn sysctlStringOpt(alloc: std.mem.Allocator, name: [:0]const u8) ?[]const u8 {
    var len: usize = 0;
    std.posix.sysctlbynameZ(name.ptr, null, &len, null, 0) catch return null;
    if (len == 0) return "";

    const buf = alloc.alloc(u8, len) catch return null;
    errdefer alloc.free(buf);
    std.posix.sysctlbynameZ(name.ptr, buf.ptr, &len, null, 0) catch return null;
    return std.mem.sliceTo(buf, 0);
}
