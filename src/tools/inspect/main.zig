const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var run_dir_path: ?[]const u8 = null;
    var ascii: bool = false;
    var latest: bool = false;
    var verbose: bool = false;
    var open: bool = false;

    var it = std.process.args();
    _ = it.next(); // exe
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--run-dir")) {
            run_dir_path = it.next() orelse return error.MissingRunDir;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ascii")) {
            ascii = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--open")) {
            open = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--latest")) {
            latest = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "--") and run_dir_path == null) {
            run_dir_path = arg;
            continue;
        }
    }

    var run_dir_owned: ?[]u8 = null;
    defer if (run_dir_owned) |p| alloc.free(p);
    const run_dir = run_dir_path orelse blk: {
        if (!latest) latest = true;
        run_dir_owned = try resolveLatestRunDir(alloc);
        break :blk run_dir_owned.?;
    };

    var dir = try std.fs.cwd().openDir(run_dir, .{ .iterate = true });
    defer dir.close();

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("zb_inspect\n");
    try stdout.writeAll("run dir: ");
    try stdout.writeAll(run_dir);
    try stdout.writeAll("\n\n");

    try printFileInfo(stdout, dir, "machine.json");
    try printFileInfo(stdout, dir, "trace-browser.json");
    try printFileInfo(stdout, dir, "trace-net.json");
    try printFileInfo(stdout, dir, "trace-renderer.json");
    try printFileInfo(stdout, dir, "trace-gpu.json");
    try printFileInfo(stdout, dir, "net_stdout.log");
    try printFileInfo(stdout, dir, "net_stderr.log");
    try printFileInfo(stdout, dir, "renderer_stdout.log");
    try printFileInfo(stdout, dir, "renderer_stderr.log");
    try printFileInfo(stdout, dir, "gpu_stdout.log");
    try printFileInfo(stdout, dir, "gpu_stderr.log");
    try printFileInfo(stdout, dir, "nav_last.json");
    try printFileInfo(stdout, dir, "renderer_dom.txt");
    try printFileInfo(stdout, dir, "renderer_layout.txt");
    try printFileInfo(stdout, dir, "renderer_scripts.txt");
    try printFileInfo(stdout, dir, "gpu_last_frame.txt");
    try printFileInfo(stdout, dir, "gpu_last_frame.ppm");
    try printFileInfo(stdout, dir, "gpu_last_display_list.txt");
    try printFileInfo(stdout, dir, "gpu_last_display_list.zbdl");
    try stdout.writeAll("\n");

    try printOptionalTextFile(alloc, stdout, dir, "net_stderr.log", 64 * 1024);
    try printOptionalTextFile(alloc, stdout, dir, "renderer_stderr.log", 64 * 1024);
    try printOptionalTextFile(alloc, stdout, dir, "gpu_stderr.log", 64 * 1024);
    try printOptionalNavMetrics(alloc, stdout, dir, "nav_last.json");

    if (verbose) {
        try printOptionalTextFile(alloc, stdout, dir, "renderer_dom.txt", 256 * 1024);
        try printOptionalTextFile(alloc, stdout, dir, "renderer_layout.txt", 256 * 1024);
        try printOptionalTextFile(alloc, stdout, dir, "renderer_scripts.txt", 256 * 1024);
        try printOptionalTextFile(alloc, stdout, dir, "gpu_last_frame.txt", 32 * 1024);
        try printOptionalTextFile(alloc, stdout, dir, "gpu_last_display_list.txt", 256 * 1024);
    } else {
        try stdout.writeAll("\n(render artifacts preview; pass --verbose for full dumps)\n\n");
        try printOptionalTextFilePreview(alloc, stdout, dir, "renderer_layout.txt", 8 * 1024);
        try printOptionalTextFilePreview(alloc, stdout, dir, "renderer_scripts.txt", 8 * 1024);
        try printOptionalTextFilePreview(alloc, stdout, dir, "gpu_last_frame.txt", 4 * 1024);
        try printOptionalTextFilePreview(alloc, stdout, dir, "gpu_last_display_list.txt", 16 * 1024);
    }

    if (ascii) blk: {
        try stdout.writeAll("ascii preview: gpu_last_frame.ppm\n");
        const ppm = dir.readFileAlloc(alloc, "gpu_last_frame.ppm", 64 * 1024 * 1024) catch |err| {
            try stdout.writeAll("missing or unreadable gpu_last_frame.ppm: ");
            try stdout.writeAll(@errorName(err));
            try stdout.writeAll("\n");
            if (!open) return;
            break :blk;
        };
        defer alloc.free(ppm);

        const parsed = try parsePpmP6(ppm);
        try stdout.writeAll("\n");
        try renderAscii(stdout, parsed);
    }

    if (open) {
        try openDefault(run_dir, dir);
    }
}

const NavMetrics = struct {
    url: []const u8,
    request_id: u32,
    canceled: bool,
    status_code: u32,
    net_source: u32 = 0,
    net_result: u32,
    total_sent: u32,
    net_begin_us: ?u64 = null,
    first_display_list_us: ?u64 = null,
    first_frame_ready_us: ?u64 = null,
    net_end_us: ?u64 = null,
    renderer_done_us: ?u64 = null,
    done_us: u64,
};

fn resolveLatestRunDir(alloc: std.mem.Allocator) ![]u8 {
    const latest_bytes = std.fs.cwd().readFileAlloc(alloc, "run/latest.txt", 4096) catch null;
    if (latest_bytes) |bytes| {
        defer alloc.free(bytes);
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len != 0) return try alloc.dupe(u8, trimmed);
    }
    return findLatestRunDirByMtime(alloc);
}

fn findLatestRunDirByMtime(alloc: std.mem.Allocator) ![]u8 {
    var run_dir = std.fs.cwd().openDir("run", .{ .iterate = true }) catch return error.MissingRunDir;
    defer run_dir.close();

    var it = run_dir.iterate();
    var best_mtime: i128 = -1;
    var best_name: ?[]u8 = null;
    defer if (best_name) |n| alloc.free(n);

    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Only consider directories that look like real browser runs.
        var candidate = run_dir.openDir(entry.name, .{}) catch continue;
        const has_trace = (candidate.statFile("trace-browser.json") catch null) != null;
        candidate.close();
        if (!has_trace) continue;

        const st = run_dir.statFile(entry.name) catch continue;
        if (st.mtime <= best_mtime) continue;
        best_mtime = st.mtime;

        if (best_name) |n| alloc.free(n);
        best_name = try alloc.dupe(u8, entry.name);
    }

    const name = best_name orelse return error.MissingRunDir;
    return std.fs.path.join(alloc, &.{ "run", name });
}

fn printOptionalNavMetrics(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    dir: std.fs.Dir,
    name: []const u8,
) !void {
    const bytes = dir.readFileAlloc(alloc, name, 64 * 1024) catch return;
    defer alloc.free(bytes);

    const parsed = std.json.parseFromSlice(NavMetrics, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    const m = parsed.value;

    try stdout.writeAll("\nnav_last.json:\n");
    try stdout.writeAll("url: ");
    try stdout.writeAll(m.url);
    try stdout.writeAll("\n");

    var buf: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "request_id={d} status={d} src={s} result={s} total_sent={d} canceled={}\n",
        .{ m.request_id, m.status_code, netSourceLabel(m.net_source), netResultLabel(m.net_result), m.total_sent, m.canceled },
    );
    try stdout.writeAll(line);

    try stdout.writeAll("timings_ms: ");
    try writeTimingMs(stdout, "net_begin", m.net_begin_us);
    try stdout.writeAll(" ");
    try writeTimingMs(stdout, "first_dl", m.first_display_list_us);
    try stdout.writeAll(" ");
    try writeTimingMs(stdout, "first_frame", m.first_frame_ready_us);
    try stdout.writeAll(" ");
    try writeTimingMs(stdout, "net_end", m.net_end_us);
    try stdout.writeAll(" ");
    try writeTimingMs(stdout, "renderer_done", m.renderer_done_us);
    try stdout.writeAll(" ");
    try writeTimingMs(stdout, "done", m.done_us);
    try stdout.writeAll("\n");
}

fn netResultLabel(code: u32) []const u8 {
    return switch (code) {
        0 => "ok",
        1 => "failed",
        2 => "truncated",
        else => "unknown",
    };
}

fn netSourceLabel(code: u32) []const u8 {
    return switch (code) {
        0 => "net",
        1 => "mem",
        2 => "disk",
        else => "unknown",
    };
}

fn writeTimingMs(stdout: std.fs.File, label: []const u8, us_opt: ?u64) !void {
    try stdout.writeAll(label);
    try stdout.writeAll("=");
    if (us_opt) |us| {
        var buf: [64]u8 = undefined;
        const ms = us / 1000;
        const s = try std.fmt.bufPrint(&buf, "{d}ms", .{ms});
        try stdout.writeAll(s);
    } else {
        try stdout.writeAll("n/a");
    }
}

fn printOptionalTextFile(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    dir: std.fs.Dir,
    name: []const u8,
    max_bytes: usize,
) !void {
    const bytes = dir.readFileAlloc(alloc, name, max_bytes) catch return;
    defer alloc.free(bytes);

    try stdout.writeAll(name);
    try stdout.writeAll(":\n");
    try stdout.writeAll(bytes);
    if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') try stdout.writeAll("\n");
    try stdout.writeAll("\n");
}

fn printOptionalTextFilePreview(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    dir: std.fs.Dir,
    name: []const u8,
    max_bytes: usize,
) !void {
    var file = dir.openFile(name, .{}) catch return;
    defer file.close();

    const st = file.stat() catch return;
    const want: usize = @min(@as(usize, @intCast(st.size)), max_bytes);

    const buf = try alloc.alloc(u8, want);
    defer alloc.free(buf);

    const got = file.readAll(buf) catch return;

    try stdout.writeAll(name);
    try stdout.writeAll(":\n");
    try stdout.writeAll(buf[0..got]);
    if (got != 0 and buf[got - 1] != '\n') try stdout.writeAll("\n");
    if (st.size > max_bytes) {
        var tmp: [96]u8 = undefined;
        const note = std.fmt.bufPrint(&tmp, "… (truncated; file is {d} bytes)\n", .{st.size}) catch "";
        try stdout.writeAll(note);
    }
    try stdout.writeAll("\n");
}

fn printFileInfo(stdout: std.fs.File, dir: std.fs.Dir, name: []const u8) !void {
    const st = dir.statFile(name) catch {
        try stdout.writeAll(name);
        try stdout.writeAll(": (missing)\n");
        return;
    };
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s}: {d} bytes\n", .{ name, st.size });
    try stdout.writeAll(line);
}

const Ppm = struct {
    width: usize,
    height: usize,
    rgb: []const u8,
};

fn parsePpmP6(bytes: []const u8) !Ppm {
    var idx: usize = 0;
    const magic = try nextToken(bytes, &idx);
    if (!std.mem.eql(u8, magic, "P6")) return error.UnsupportedPpm;

    const w_tok = try nextToken(bytes, &idx);
    const h_tok = try nextToken(bytes, &idx);
    const max_tok = try nextToken(bytes, &idx);

    const width = try std.fmt.parseInt(usize, w_tok, 10);
    const height = try std.fmt.parseInt(usize, h_tok, 10);
    const maxval = try std.fmt.parseInt(usize, max_tok, 10);
    if (maxval != 255) return error.UnsupportedPpm;

    while (idx < bytes.len and std.ascii.isWhitespace(bytes[idx])) idx += 1;
    const rgb = bytes[idx..];
    const expected = width * height * 3;
    if (rgb.len < expected) return error.TruncatedPpm;
    return .{ .width = width, .height = height, .rgb = rgb[0..expected] };
}

fn nextToken(bytes: []const u8, idx: *usize) ![]const u8 {
    while (idx.* < bytes.len) {
        const c = bytes[idx.*];
        if (std.ascii.isWhitespace(c)) {
            idx.* += 1;
            continue;
        }
        if (c == '#') {
            while (idx.* < bytes.len and bytes[idx.*] != '\n') idx.* += 1;
            continue;
        }
        break;
    }
    if (idx.* >= bytes.len) return error.UnexpectedEof;

    const start = idx.*;
    while (idx.* < bytes.len) {
        const c = bytes[idx.*];
        if (std.ascii.isWhitespace(c) or c == '#') break;
        idx.* += 1;
    }
    return bytes[start..idx.*];
}

fn renderAscii(stdout: std.fs.File, ppm: Ppm) !void {
    const ramp = " .:-=+*#%@";
    const out_w: usize = 80;
    const out_h: usize = 40;

    var buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "frame: {d}x{d} -> {d}x{d}\n\n", .{ ppm.width, ppm.height, out_w, out_h });
    try stdout.writeAll(header);

    var line: [out_w]u8 = undefined;
    for (0..out_h) |oy| {
        const y = (oy * ppm.height) / out_h;
        for (0..out_w) |ox| {
            const x = (ox * ppm.width) / out_w;
            const off = (y * ppm.width + x) * 3;
            const r: u32 = ppm.rgb[off + 0];
            const g: u32 = ppm.rgb[off + 1];
            const b: u32 = ppm.rgb[off + 2];
            const lum: u32 = (r * 30 + g * 59 + b * 11) / 100;
            const ri: usize = @intCast((lum * (ramp.len - 1)) / 255);
            line[ox] = ramp[ri];
        }
        try stdout.writeAll(&line);
        try stdout.writeAll("\n");
    }
}

fn openDefault(run_dir: []const u8, dir: std.fs.Dir) !void {
    if (builtin.target.os.tag != .macos) return;

    const frame_path = try std.fs.path.join(std.heap.page_allocator, &.{ run_dir, "gpu_last_frame.ppm" });
    defer std.heap.page_allocator.free(frame_path);

    const has_frame = blk: {
        dir.access("gpu_last_frame.ppm", .{ .mode = .read_only }) catch break :blk false;
        break :blk true;
    };
    const target = if (has_frame) frame_path else run_dir;

    var argv_buf: [2][]const u8 = .{ "open", target };
    var child = std.process.Child.init(argv_buf[0..], std.heap.page_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch {};
}
