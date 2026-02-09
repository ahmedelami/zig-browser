const std = @import("std");
const shared = @import("shared");

const util = shared.util;

const NavLast = struct {
    url: []const u8,
    request_id: u32,
    canceled: bool,
    status_code: u32,
    net_source: u32,
    net_result: u32,
    total_sent: u32,
    net_begin_us: ?u64 = null,
    first_display_list_us: ?u64 = null,
    first_frame_ready_us: ?u64 = null,
    net_end_us: ?u64 = null,
    renderer_done_us: ?u64 = null,
    done_us: u64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const url = (try util.argValue("--url")) orelse return error.MissingUrl;
    const iterations: usize = (try parseUsizeArg("--iterations")) orelse 10;
    const timeout_ms: u64 = (try parseU64Arg("--timeout-ms")) orelse 15_000;
    const cold = util.hasArg("--cold");
    const artifacts = util.hasArg("--artifacts");
    const verbose = util.hasArg("--verbose");

    const browser_exe = try findSiblingExe(alloc, "zb_browser");
    defer alloc.free(browser_exe);

    const bench_root = try makeBenchRootDir(alloc);
    defer alloc.free(bench_root);
    try std.fs.cwd().makePath(bench_root);

    var ttfb: std.ArrayListUnmanaged(u64) = .{};
    defer ttfb.deinit(alloc);
    var first_frame: std.ArrayListUnmanaged(u64) = .{};
    defer first_frame.deinit(alloc);
    var done: std.ArrayListUnmanaged(u64) = .{};
    defer done.deinit(alloc);

    var ok: usize = 0;
    var failed: usize = 0;
    var canceled: usize = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        if (cold) try clearDiskCache();

        const run_dir = try std.fmt.allocPrint(alloc, "{s}/iter-{d:0>4}", .{ bench_root, i });
        defer alloc.free(run_dir);
        try std.fs.cwd().makePath(run_dir);

        runOnce(alloc, browser_exe, run_dir, url, timeout_ms, artifacts) catch {
            failed += 1;
            continue;
        };

        const nav = parseNavLast(alloc, run_dir) catch {
            failed += 1;
            continue;
        };
        defer nav.deinit();

        const v = nav.value;
        if (v.canceled) {
            canceled += 1;
            continue;
        }
        if (v.net_result != 0) {
            failed += 1;
            continue;
        }
        const nb = v.net_begin_us orelse {
            failed += 1;
            continue;
        };
        const ff = v.first_frame_ready_us orelse {
            failed += 1;
            continue;
        };
        ok += 1;
        try ttfb.append(alloc, nb);
        try first_frame.append(alloc, ff);
        try done.append(alloc, v.done_us);

        if (verbose) {
            std.debug.print(
                "iter {d}: status={d} src={s} ttfb={d}ms first_frame={d}ms done={d}ms bytes={d}\n",
                .{ i, v.status_code, netSourceLabel(v.net_source), nb / 1000, ff / 1000, v.done_us / 1000, v.total_sent },
            );
        }
    }

    std.debug.print("navbench url: {s}\n", .{url});
    std.debug.print("iterations: {d} ok={d} failed={d} canceled={d}\n", .{ iterations, ok, failed, canceled });
    if (cold) std.debug.print("mode: cold (disk cache cleared each iter)\n", .{});

    if (ok == 0) return error.NoSamples;

    try printMetric(ttfb.items, "ttfb_us");
    try printMetric(first_frame.items, "first_frame_us");
    try printMetric(done.items, "done_us");
}

fn parseUsizeArg(flag: []const u8) !?usize {
    var it = std.process.args();
    _ = it.next();
    while (it.next()) |arg| {
        if (!std.mem.eql(u8, arg, flag)) continue;
        const val = it.next() orelse return error.MissingValue;
        return try std.fmt.parseInt(usize, val, 10);
    }
    return null;
}

fn parseU64Arg(flag: []const u8) !?u64 {
    const n = (try parseUsizeArg(flag)) orelse return null;
    return @intCast(n);
}

fn findSiblingExe(alloc: std.mem.Allocator, exe_name: []const u8) ![]u8 {
    const sibling = try util.siblingExePath(alloc, exe_name);
    if (pathExists(sibling)) return sibling;
    alloc.free(sibling);

    const fallback = try std.fs.path.join(alloc, &.{ "zig-out", "bin", exe_name });
    if (pathExists(fallback)) return fallback;
    alloc.free(fallback);

    return error.ExeNotFound;
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{ .mode = .read_only }) catch return false;
    return true;
}

fn makeBenchRootDir(alloc: std.mem.Allocator) ![]u8 {
    const ts = std.time.timestamp();
    const pid: i32 = std.c.getpid();
    return std.fmt.allocPrint(alloc, "run/navbench-{d}-{d}", .{ ts, pid });
}

fn runOnce(
    alloc: std.mem.Allocator,
    browser_exe: []const u8,
    run_dir: []const u8,
    url: []const u8,
    timeout_ms: u64,
    artifacts: bool,
) !void {
    var ms_buf: [32]u8 = undefined;
    const ms_str = try std.fmt.bufPrint(&ms_buf, "{d}", .{timeout_ms});

    var argv_buf: [10][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = browser_exe;
    argc += 1;
    argv_buf[argc] = "--headless";
    argc += 1;
    argv_buf[argc] = "--url";
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;
    argv_buf[argc] = "--run-dir";
    argc += 1;
    argv_buf[argc] = run_dir;
    argc += 1;
    argv_buf[argc] = "--quit-after-ms";
    argc += 1;
    argv_buf[argc] = ms_str;
    argc += 1;
    if (!artifacts) {
        argv_buf[argc] = "--no-artifacts";
        argc += 1;
    }

    var child = std.process.Child.init(argv_buf[0..argc], alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.BrowserFailed,
        else => return error.BrowserFailed,
    }
}

fn parseNavLast(alloc: std.mem.Allocator, run_dir: []const u8) !std.json.Parsed(NavLast) {
    const nav_path = try std.fs.path.join(alloc, &.{ run_dir, "nav_last.json" });
    defer alloc.free(nav_path);
    const nav_bytes = try std.fs.cwd().readFileAlloc(alloc, nav_path, 64 * 1024);
    defer alloc.free(nav_bytes);
    return try std.json.parseFromSlice(NavLast, alloc, nav_bytes, .{ .ignore_unknown_fields = true });
}

fn clearDiskCache() !void {
    var dir = std.fs.cwd().openDir("run/http-cache", .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".zbc")) continue;
        dir.deleteFile(ent.name) catch {};
    }
}

fn percentile(values_sorted: []u64, p: f64) !u64 {
    if (!(p > 0 and p <= 1)) return error.BadPercentile;
    if (values_sorted.len == 0) return error.NoValues;

    const n: f64 = @floatFromInt(values_sorted.len);
    const rank_f = std.math.ceil(p * n);
    const rank: usize = @intFromFloat(rank_f);
    const idx: usize = if (rank == 0) 0 else rank - 1;
    return values_sorted[@min(idx, values_sorted.len - 1)];
}

fn printMetric(values: []u64, label: []const u8) !void {
    if (values.len == 0) return;

    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    var sum: u128 = 0;
    for (values) |v| {
        min = @min(min, v);
        max = @max(max, v);
        sum += v;
    }
    const mean: u64 = @intCast(sum / values.len);

    std.sort.pdq(u64, values, {}, std.sort.asc(u64));
    const p50 = try percentile(values, 0.50);
    const p95 = try percentile(values, 0.95);
    std.debug.print("{s}: min={d} mean={d} p50={d} p95={d} max={d}\n", .{ label, min, mean, p50, p95, max });
}

fn netSourceLabel(code: u32) []const u8 {
    return switch (code) {
        0 => "net",
        1 => "mem",
        2 => "disk",
        else => "unknown",
    };
}

