const std = @import("std");
const shared = @import("shared");

const input_queue = @import("input_queue.zig");
const headless_nav = @import("headless.zig");
const nav_thread = @import("nav_thread.zig");
const ui_macos = @import("ui_macos.zig");

const ProcessKind = shared.process_kind.ProcessKind;
const ipc = shared.ipc;
const machine = shared.machine;
const TraceWriter = shared.trace.TraceWriter;
const util = shared.util;

const LogMirror = enum { none, stdout, stderr };

const TeeArgs = struct {
    src: std.fs.File,
    dst: std.fs.File,
    mirror: LogMirror,
};

const ChildLogs = struct {
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,

    fn join(self: *ChildLogs) void {
        if (self.stdout_thread) |t| t.join();
        if (self.stderr_thread) |t| t.join();
        self.* = .{};
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const run_dir_arg = try util.argValue("--run-dir");
    const run_dir_rel = if (run_dir_arg) |p| try alloc.dupe(u8, p) else try util.makeRunDir(alloc, "run");
    defer alloc.free(run_dir_rel);

    try std.fs.cwd().makePath(run_dir_rel);
    var run_dir = try std.fs.cwd().openDir(run_dir_rel, .{});
    defer run_dir.close();

    try machine.writeJson(run_dir, "machine.json", alloc);

    const pid: u32 = @intCast(std.c.getpid());
    const tid: u32 = 0;

    var trace = try TraceWriter.init(alloc, run_dir, "trace-browser.json", pid, tid);
    errdefer trace.deinit();
    try trace.metaProcessName("zb_browser");
    try trace.metaThreadName("main");
    try trace.instant("browser_start", "lifecycle");

    // Track the latest auto-generated run dir so tooling can inspect without needing an explicit `--run-dir`.
    // Best-effort only; ignore errors (e.g. permissions).
    if (run_dir_arg == null) {
        std.fs.cwd().makePath("run") catch {};
        if (std.fs.cwd().createFile("run/latest.txt", .{ .truncate = true })) |file| {
            defer file.close();
            file.writeAll(run_dir_rel) catch {};
            file.writeAll("\n") catch {};
        } else |_| {}
    }

    const net_sock = try std.fs.path.join(alloc, &.{ run_dir_rel, "ipc-net.sock" });
    defer alloc.free(net_sock);
    const renderer_sock = try std.fs.path.join(alloc, &.{ run_dir_rel, "ipc-renderer.sock" });
    defer alloc.free(renderer_sock);
    const gpu_sock = try std.fs.path.join(alloc, &.{ run_dir_rel, "ipc-gpu.sock" });
    defer alloc.free(gpu_sock);

    // Ensure no stale socket paths exist.
    std.fs.cwd().deleteFile(net_sock) catch {};
    std.fs.cwd().deleteFile(renderer_sock) catch {};
    std.fs.cwd().deleteFile(gpu_sock) catch {};

    var net_server = try ipc.listenUnix(net_sock);
    defer net_server.deinit();
    var renderer_server = try ipc.listenUnix(renderer_sock);
    defer renderer_server.deinit();
    var gpu_server = try ipc.listenUnix(gpu_sock);
    defer gpu_server.deinit();

    try trace.instant("ipc_listen_ready", "ipc");

    const artifacts = util.hasArg("--artifacts") or (run_dir_arg == null and !util.hasArg("--no-artifacts"));
    const capture_logs = !util.hasArg("--no-logs");

    const net_exe = try util.siblingExePath(alloc, "zb_net");
    defer alloc.free(net_exe);
    const renderer_exe = try util.siblingExePath(alloc, "zb_renderer");
    defer alloc.free(renderer_exe);
    const gpu_exe = try util.siblingExePath(alloc, "zb_gpu");
    defer alloc.free(gpu_exe);

    var net_child_args: [6][]const u8 = .{ net_exe, "--connect", net_sock, "--run-dir", run_dir_rel, "--artifacts" };
    const net_child_argv = net_child_args[0..if (artifacts) 6 else 5];
    var net_child = std.process.Child.init(net_child_argv, alloc);
    net_child.stdout_behavior = if (capture_logs) .Pipe else .Inherit;
    net_child.stderr_behavior = if (capture_logs) .Pipe else .Inherit;

    var renderer_child_args: [6][]const u8 = .{ renderer_exe, "--connect", renderer_sock, "--run-dir", run_dir_rel, "--artifacts" };
    const renderer_child_argv = renderer_child_args[0..if (artifacts) 6 else 5];
    var renderer_child = std.process.Child.init(renderer_child_argv, alloc);
    renderer_child.stdout_behavior = if (capture_logs) .Pipe else .Inherit;
    renderer_child.stderr_behavior = if (capture_logs) .Pipe else .Inherit;

    var gpu_child_args: [6][]const u8 = .{ gpu_exe, "--connect", gpu_sock, "--run-dir", run_dir_rel, "--artifacts" };
    const gpu_child_argv = gpu_child_args[0..if (artifacts) 6 else 5];
    var gpu_child = std.process.Child.init(gpu_child_argv, alloc);
    gpu_child.stdout_behavior = if (capture_logs) .Pipe else .Inherit;
    gpu_child.stderr_behavior = if (capture_logs) .Pipe else .Inherit;

    try net_child.spawn();
    var net_logs: ChildLogs = .{};
    var renderer_logs: ChildLogs = .{};
    var gpu_logs: ChildLogs = .{};
    if (capture_logs) net_logs = try captureChildLogs(&net_child, run_dir, "net");

    try renderer_child.spawn();
    if (capture_logs) renderer_logs = try captureChildLogs(&renderer_child, run_dir, "renderer");

    try gpu_child.spawn();
    if (capture_logs) gpu_logs = try captureChildLogs(&gpu_child, run_dir, "gpu");

    try trace.instant("children_spawned", "proc");

    const net_conn = try net_server.accept();
    var net_ipc: ipc.Connection = .{ .stream = net_conn.stream };
    try handshake(alloc, &trace, &net_ipc, .net);

    const renderer_conn = try renderer_server.accept();
    var renderer_ipc: ipc.Connection = .{ .stream = renderer_conn.stream };
    try handshake(alloc, &trace, &renderer_ipc, .renderer);

    const gpu_conn = try gpu_server.accept();
    var gpu_ipc: ipc.Connection = .{ .stream = gpu_conn.stream };
    try handshake(alloc, &trace, &gpu_ipc, .gpu);

    try trace.instant("all_children_connected", "ipc");

    const oneshot = util.hasArg("--oneshot");
    const headless = util.hasArg("--headless");
    if (!oneshot) {
        const width: u32 = 1024;
        const height: u32 = 768;
        const quit_after_ms_ui = if (try util.argValue("--quit-after-ms")) |s| try std.fmt.parseInt(u64, s, 10) else null;
        const headless_timeout_ms: u64 = quit_after_ms_ui orelse 15_000;

        const surface = try gpuCreateSurface(alloc, &trace, &gpu_ipc, width, height);
        try trace.instant("gpu_surface_ready", "ui");

        const url = (try util.argValue("--url")) orelse if (!headless and quit_after_ms_ui != null) "about:blank" else "https://example.com";

        if (headless) {
            try trace.instant("headless_run_start", "ui");
            var nav_timer = try std.time.Timer.start();
            const res = try headless_nav.run(
                alloc,
                &run_dir,
                &nav_timer,
                run_dir_rel,
                url,
                @intCast(surface.width),
                @intCast(surface.height),
                &net_ipc,
                &renderer_ipc,
                &gpu_ipc,
                headless_timeout_ms,
            );
            try trace.instant(switch (res) {
                .nav_complete => "headless_nav_complete",
                .timeout => "headless_timeout",
                .end_of_stream => "headless_end_of_stream",
            }, "ui");
            try trace.instant("headless_run_end", "ui");

            // Don't attempt a graceful shutdown frame here: headless uses buffered
            // browser→renderer writes and we want to avoid any chance of interleaving
            // protocol frames. Closing the streams reliably unblocks children via EOF.
            net_ipc.stream.close();
            renderer_ipc.stream.close();
            gpu_ipc.stream.close();
            try trace.instant("shutdown_closed", "ipc");
        } else {
            var input: input_queue.Queue = .{};
            try input.init();
            defer input.deinit();
            const net_handle = net_ipc.stream.handle;
            const renderer_handle = renderer_ipc.stream.handle;
            const gpu_handle = gpu_ipc.stream.handle;

            const nav_worker = try std.Thread.spawn(.{}, nav_thread.main, .{nav_thread.Args{
                .alloc = alloc,
                .run_dir_rel = run_dir_rel,
                .initial_url = url,
                .surface_width = surface.width,
                .surface_height = surface.height,
                .net = net_ipc,
                .renderer = renderer_ipc,
                .gpu = gpu_ipc,
                .input = &input,
                .request_repaint = ui_macos.requestRepaint,
            }});
            errdefer {
                input.close();
                // Force-cancel any in-flight IPC and ensure children exit.
                std.posix.close(net_handle);
                std.posix.close(renderer_handle);
                std.posix.close(gpu_handle);
                nav_worker.join();
            }
            // Ownership transferred to worker thread; don't use these in the UI thread.
            net_ipc = undefined;
            renderer_ipc = undefined;
            gpu_ipc = undefined;

            try trace.instant("ui_run_start", "ui");
            try ui_macos.run("zig-browser", @floatFromInt(width), @floatFromInt(height), quit_after_ms_ui, &trace, surface.id, &input);
            try trace.instant("ui_run_end", "ui");

            input.close();
            // Force-cancel any in-flight IPC and ensure children exit.
            std.posix.close(net_handle);
            std.posix.close(renderer_handle);
            std.posix.close(gpu_handle);
            nav_worker.join();
        }
    }

    if (oneshot) {
        // Shut down all children cleanly.
        try net_ipc.send(.shutdown, "");
        try renderer_ipc.send(.shutdown, "");
        try gpu_ipc.send(.shutdown, "");
        try trace.instant("shutdown_sent", "ipc");
    }

    _ = try net_child.wait();
    _ = try renderer_child.wait();
    _ = try gpu_child.wait();
    net_logs.join();
    renderer_logs.join();
    gpu_logs.join();
    try trace.instant("children_exited", "proc");

    try trace.instant("browser_exit", "lifecycle");
    trace.deinit();

    var buf: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "run dir: {s}\n", .{run_dir_rel});
    try std.fs.File.stdout().writeAll(line);

    if (run_dir_arg == null and !oneshot) {
        // Produce a human-friendly summary + ASCII preview automatically (no extra commands needed).
        const inspect_exe = try util.siblingExePath(alloc, "zb_inspect");
        defer alloc.free(inspect_exe);

        const open_after = util.hasArg("--open");
        var inspect_args: [5][]const u8 = undefined;
        inspect_args[0] = inspect_exe;
        inspect_args[1] = "--run-dir";
        inspect_args[2] = run_dir_rel;
        var inspect_len: usize = 3;
        if (artifacts) {
            inspect_args[inspect_len] = "--ascii";
            inspect_len += 1;
        }
        if (open_after) {
            inspect_args[inspect_len] = "--open";
            inspect_len += 1;
        }
        const inspect_argv = inspect_args[0..inspect_len];
        var child = std.process.Child.init(inspect_argv, alloc);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        _ = child.spawnAndWait() catch {};
    }
}

fn noopRepaint() void {}

const SurfaceInfo = struct {
    id: u32,
    width: u32,
    height: u32,
    stride: u32,
};

fn gpuCreateSurface(
    alloc: std.mem.Allocator,
    trace: ?*TraceWriter,
    gpu: *ipc.Connection,
    width: u32,
    height: u32,
) !SurfaceInfo {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], width, .little);
    std.mem.writeInt(u32, payload[4..8], height, .little);
    try gpu.send(.gpu_create_surface, payload[0..]);
    if (trace) |t| try t.instant("gpu_create_surface_sent", "ipc");

    const frame = try gpu.recvAlloc(alloc);
    defer alloc.free(frame.payload);
    if (frame.header.msg_type != .gpu_surface_created) return error.ExpectedGpuSurfaceCreated;

    var idx: usize = 0;
    const id = try ipc.readInt(frame.payload, &idx, u32);
    const w = try ipc.readInt(frame.payload, &idx, u32);
    const h = try ipc.readInt(frame.payload, &idx, u32);
    const stride = try ipc.readInt(frame.payload, &idx, u32);
    return .{ .id = id, .width = w, .height = h, .stride = stride };
}

fn handshake(
    alloc: std.mem.Allocator,
    trace: *TraceWriter,
    conn: *ipc.Connection,
    expected: ProcessKind,
) !void {
    const frame = try conn.recvAlloc(alloc);
    defer alloc.free(frame.payload);
    if (frame.header.msg_type != .hello) return error.ExpectedHello;

    const hello = try ipc.decodeHello(frame.payload);
    if (hello.kind != expected) return error.UnexpectedProcessKind;

    try trace.instant("child_hello", expected.label());

    try conn.send(.ping, "");

    const reply = try conn.recvAlloc(alloc);
    defer alloc.free(reply.payload);
    if (reply.header.msg_type != .pong) return error.ExpectedPong;

    try trace.instant("child_pong", expected.label());
}

fn captureChildLogs(child: *std.process.Child, run_dir: std.fs.Dir, label: []const u8) !ChildLogs {
    var out: ChildLogs = .{};

    if (child.stdout) |file| {
        child.stdout = null; // prevent `wait()` from closing the fd while the tee thread owns it
        var name_buf: [64]u8 = undefined;
        const log_name = try std.fmt.bufPrint(&name_buf, "{s}_stdout.log", .{label});
        const log_file = try run_dir.createFile(log_name, .{ .truncate = true });
        out.stdout_thread = try std.Thread.spawn(.{}, teeThreadMain, .{TeeArgs{
            .src = file,
            .dst = log_file,
            .mirror = .stdout,
        }});
    }

    if (child.stderr) |file| {
        child.stderr = null;
        var name_buf: [64]u8 = undefined;
        const log_name = try std.fmt.bufPrint(&name_buf, "{s}_stderr.log", .{label});
        const log_file = try run_dir.createFile(log_name, .{ .truncate = true });
        out.stderr_thread = try std.Thread.spawn(.{}, teeThreadMain, .{TeeArgs{
            .src = file,
            .dst = log_file,
            .mirror = .stderr,
        }});
    }

    return out;
}

fn teeThreadMain(args: TeeArgs) void {
    const max_log_bytes: usize = 2 * 1024 * 1024;
    var written: usize = 0;
    var truncated: bool = false;

    var buf: [8 * 1024]u8 = undefined;
    while (true) {
        const n = args.src.read(&buf) catch break;
        if (n == 0) break;

        if (written < max_log_bytes) {
            const remain = max_log_bytes - written;
            const to_write = @min(remain, n);
            args.dst.writeAll(buf[0..to_write]) catch {};
            written += to_write;
            if (to_write != n and !truncated) {
                args.dst.writeAll("\n... log truncated ...\n") catch {};
                truncated = true;
            }
        }
        switch (args.mirror) {
            .stdout => std.fs.File.stdout().writeAll(buf[0..n]) catch {},
            .stderr => std.fs.File.stderr().writeAll(buf[0..n]) catch {},
            .none => {},
        }
    }

    args.src.close();
    args.dst.close();
}
