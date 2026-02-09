const std = @import("std");
const shared = @import("shared");

const util = shared.util;

const TraceEvent = struct {
    name: []const u8,
    ts: u64,
};

const Sample = struct {
    ipc_listen_ready_us: u64,
    children_spawned_us: u64,
    all_children_connected_us: u64,
    children_exited_us: u64,
    ui_first_present_submitted_us: u64,
};

const Budgets = struct {
    ipc_listen_ready_us_p95_max: u64 = 2_000_000,
    all_children_connected_us_p95_max: u64 = 15_000_000,
    children_exited_us_p95_max: u64 = 20_000_000,
    ui_first_present_submitted_us_p95_max: u64 = 1_000_000,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const iterations: usize = if (try parseUsizeArg("--iterations")) |n| n else 10;
    const with_ui = util.hasArg("--ui");
    const ui_quit_after_ms: u64 = if (try parseU64Arg("--ui-quit-after-ms")) |n| n else 500;

    const budgets = try loadBudgets(alloc);

    const browser_exe = try findSiblingExe(alloc, "zb_browser");
    defer alloc.free(browser_exe);

    const bench_root = try makeBenchRootDir(alloc);
    defer alloc.free(bench_root);

    try std.fs.cwd().makePath(bench_root);

    var samples = try alloc.alloc(Sample, iterations);
    defer alloc.free(samples);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const run_dir = try std.fmt.allocPrint(alloc, "{s}/iter-{d:0>4}", .{ bench_root, i });
        defer alloc.free(run_dir);

        try runOnce(alloc, browser_exe, run_dir, with_ui, ui_quit_after_ms);
        samples[i] = try parseSample(alloc, run_dir, with_ui);
    }

    const ipc_values = try collect(alloc, samples, .ipc_listen_ready_us);
    defer alloc.free(ipc_values);
    const connected_values = try collect(alloc, samples, .all_children_connected_us);
    defer alloc.free(connected_values);
    const exited_values = try collect(alloc, samples, .children_exited_us);
    defer alloc.free(exited_values);

    const ipc_p95 = try percentile(ipc_values, 0.95);
    const connected_p95 = try percentile(connected_values, 0.95);
    const exited_p95 = try percentile(exited_values, 0.95);

    std.debug.print("bench iterations: {d}\n", .{iterations});
    printMetric(samples, "ipc_listen_ready_us", .ipc_listen_ready_us);
    printMetric(samples, "children_spawned_us", .children_spawned_us);
    printMetric(samples, "all_children_connected_us", .all_children_connected_us);
    printMetric(samples, "children_exited_us", .children_exited_us);
    if (with_ui) printMetric(samples, "ui_first_present_submitted_us", .ui_first_present_submitted_us);
    std.debug.print("budgets (p95 max): ipc={d} connected={d} exited={d}\n", .{
        budgets.ipc_listen_ready_us_p95_max,
        budgets.all_children_connected_us_p95_max,
        budgets.children_exited_us_p95_max,
    });
    if (with_ui) std.debug.print("budgets (p95 max): ui_first_present_submitted_us={d}\n", .{budgets.ui_first_present_submitted_us_p95_max});

    var failed = false;
    if (ipc_p95 > budgets.ipc_listen_ready_us_p95_max) {
        std.debug.print("FAIL: ipc_listen_ready_us p95 {d} > {d}\n", .{ ipc_p95, budgets.ipc_listen_ready_us_p95_max });
        failed = true;
    }
    if (connected_p95 > budgets.all_children_connected_us_p95_max) {
        std.debug.print("FAIL: all_children_connected_us p95 {d} > {d}\n", .{ connected_p95, budgets.all_children_connected_us_p95_max });
        failed = true;
    }
    if (!with_ui) {
        if (exited_p95 > budgets.children_exited_us_p95_max) {
            std.debug.print("FAIL: children_exited_us p95 {d} > {d}\n", .{ exited_p95, budgets.children_exited_us_p95_max });
            failed = true;
        }
    }

    if (with_ui) {
        const ui_values = try collect(alloc, samples, .ui_first_present_submitted_us);
        defer alloc.free(ui_values);
        const ui_p95 = try percentile(ui_values, 0.95);
        if (ui_p95 > budgets.ui_first_present_submitted_us_p95_max) {
            std.debug.print("FAIL: ui_first_present_submitted_us p95 {d} > {d}\n", .{ ui_p95, budgets.ui_first_present_submitted_us_p95_max });
            failed = true;
        }
    }

    if (failed) return error.BudgetExceeded;
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

fn loadBudgets(alloc: std.mem.Allocator) !Budgets {
    const path = "bench/budgets.json";
    const file_bytes = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return Budgets{};
    defer alloc.free(file_bytes);

    const parsed = try std.json.parseFromSlice(Budgets, alloc, file_bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return parsed.value;
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
    return std.fmt.allocPrint(alloc, "run/bench-{d}-{d}", .{ ts, pid });
}

fn runOnce(
    alloc: std.mem.Allocator,
    browser_exe: []const u8,
    run_dir: []const u8,
    with_ui: bool,
    ui_quit_after_ms: u64,
) !void {
    var ui_ms_buf: [32]u8 = undefined;
    const ui_ms_str = try std.fmt.bufPrint(&ui_ms_buf, "{d}", .{ui_quit_after_ms});

    var argv_buf: [6][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = browser_exe;
    argc += 1;
    if (with_ui) {
        argv_buf[argc] = "--run-dir";
        argc += 1;
        argv_buf[argc] = run_dir;
        argc += 1;
        argv_buf[argc] = "--quit-after-ms";
        argc += 1;
        argv_buf[argc] = ui_ms_str;
        argc += 1;
    } else {
        argv_buf[argc] = "--oneshot";
        argc += 1;
        argv_buf[argc] = "--run-dir";
        argc += 1;
        argv_buf[argc] = run_dir;
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

fn parseSample(alloc: std.mem.Allocator, run_dir: []const u8, with_ui: bool) !Sample {
    const trace_path = try std.fs.path.join(alloc, &.{ run_dir, "trace-browser.json" });
    defer alloc.free(trace_path);

    const trace_bytes = try std.fs.cwd().readFileAlloc(alloc, trace_path, 1 << 20);
    defer alloc.free(trace_bytes);

    const parsed = try std.json.parseFromSlice([]TraceEvent, alloc, trace_bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const events = parsed.value;
    const t0 = tsOf(events, "browser_start") orelse return error.MissingEvent;

    const ipc = (tsOf(events, "ipc_listen_ready") orelse return error.MissingEvent) - t0;
    const spawned = (tsOf(events, "children_spawned") orelse return error.MissingEvent) - t0;
    const connected = (tsOf(events, "all_children_connected") orelse return error.MissingEvent) - t0;
    const exited = (tsOf(events, "children_exited") orelse return error.MissingEvent) - t0;
    const ui_first_present = if (with_ui)
        (tsOf(events, "ui_first_present_submitted") orelse return error.MissingEvent) - t0
    else
        0;

    return .{
        .ipc_listen_ready_us = ipc,
        .children_spawned_us = spawned,
        .all_children_connected_us = connected,
        .children_exited_us = exited,
        .ui_first_present_submitted_us = ui_first_present,
    };
}

fn tsOf(events: []const TraceEvent, name: []const u8) ?u64 {
    for (events) |ev| {
        if (std.mem.eql(u8, ev.name, name)) return ev.ts;
    }
    return null;
}

const Field = enum {
    ipc_listen_ready_us,
    children_spawned_us,
    all_children_connected_us,
    children_exited_us,
    ui_first_present_submitted_us,
};

fn collect(alloc: std.mem.Allocator, samples: []const Sample, field: Field) ![]u64 {
    const values = try alloc.alloc(u64, samples.len);
    for (samples, 0..) |s, idx| {
        values[idx] = switch (field) {
            .ipc_listen_ready_us => s.ipc_listen_ready_us,
            .children_spawned_us => s.children_spawned_us,
            .all_children_connected_us => s.all_children_connected_us,
            .children_exited_us => s.children_exited_us,
            .ui_first_present_submitted_us => s.ui_first_present_submitted_us,
        };
    }
    std.sort.pdq(u64, values, {}, std.sort.asc(u64));
    return values;
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

fn printMetric(samples: []const Sample, label: []const u8, field: Field) void {
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    var sum: u128 = 0;

    var tmp: [1024]u64 = undefined;
    var values: []u64 = tmp[0..0];
    if (samples.len <= tmp.len) values = tmp[0..samples.len];

    for (samples, 0..) |s, idx| {
        const v: u64 = switch (field) {
            .ipc_listen_ready_us => s.ipc_listen_ready_us,
            .children_spawned_us => s.children_spawned_us,
            .all_children_connected_us => s.all_children_connected_us,
            .children_exited_us => s.children_exited_us,
            .ui_first_present_submitted_us => s.ui_first_present_submitted_us,
        };
        min = @min(min, v);
        max = @max(max, v);
        sum += v;
        if (values.len != 0) values[idx] = v;
    }

    const mean: u64 = @intCast(sum / samples.len);

    if (values.len != 0) {
        std.sort.pdq(u64, values, {}, std.sort.asc(u64));
        const p50 = percentile(values, 0.50) catch 0;
        const p95 = percentile(values, 0.95) catch 0;
        std.debug.print("{s}: min={d} mean={d} p50={d} p95={d} max={d}\n", .{ label, min, mean, p50, p95, max });
    } else {
        std.debug.print("{s}: min={d} mean={d} max={d}\n", .{ label, min, mean, max });
    }
}
