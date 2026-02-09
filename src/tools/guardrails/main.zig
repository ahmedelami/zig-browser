const std = @import("std");
const shared = @import("shared");

const util = shared.util;

const Limits = struct {
    max_bytes: usize = 64 * 1024,
    max_lines: usize = 600,
    max_pub_decls: usize = 80,
    max_imports: usize = 25,
};

const Override = struct {
    path: []const u8,
    max_bytes: ?usize = null,
    max_lines: ?usize = null,
    max_pub_decls: ?usize = null,
    max_imports: ?usize = null,
};

const Config = struct {
    defaults: Limits = .{},
    overrides: []const Override = &.{},
    ignore_prefixes: []const []const u8 = &.{},
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const root = (try util.argValue("--root")) orelse "src";
    const config_path = (try util.argValue("--config")) orelse "guardrails.json";

    const config_file_bytes = std.fs.cwd().readFileAlloc(alloc, config_path, 1 << 20) catch null;
    defer if (config_file_bytes) |bytes| alloc.free(bytes);

    var parsed_config: ?std.json.Parsed(Config) = null;
    defer if (parsed_config) |*p| p.deinit();

    const config: Config = if (config_file_bytes) |bytes| blk: {
        const parsed = try std.json.parseFromSlice(Config, alloc, bytes, .{ .ignore_unknown_fields = true });
        parsed_config = parsed;
        break :blk parsed.value;
    } else Config{};

    var root_dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer root_dir.close();

    var walker = try root_dir.walk(alloc);
    defer walker.deinit();

    var violations: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const rel_path = try std.fs.path.join(alloc, &.{ root, entry.path });
        defer alloc.free(rel_path);

        if (shouldIgnore(rel_path, config.ignore_prefixes)) continue;

        const limits = effectiveLimits(rel_path, config);
        const metrics = try measureFile(alloc, rel_path, limits);

        var file_bad = false;
        if (metrics.bytes > limits.max_bytes) {
            std.debug.print("guardrails: FAIL {s}: bytes {d} > {d}\n", .{ rel_path, metrics.bytes, limits.max_bytes });
            file_bad = true;
        }
        if (metrics.lines > limits.max_lines) {
            std.debug.print("guardrails: FAIL {s}: lines {d} > {d}\n", .{ rel_path, metrics.lines, limits.max_lines });
            file_bad = true;
        }
        if (metrics.pub_decls > limits.max_pub_decls) {
            std.debug.print("guardrails: FAIL {s}: pub_decls {d} > {d}\n", .{ rel_path, metrics.pub_decls, limits.max_pub_decls });
            file_bad = true;
        }
        if (metrics.imports > limits.max_imports) {
            std.debug.print("guardrails: FAIL {s}: imports {d} > {d}\n", .{ rel_path, metrics.imports, limits.max_imports });
            file_bad = true;
        }

        if (file_bad) violations += 1;
    }

    if (violations != 0) return error.GuardrailsViolated;
}

fn shouldIgnore(path: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, path, p)) return true;
    }
    return false;
}

fn effectiveLimits(path: []const u8, config: Config) Limits {
    var limits = config.defaults;
    for (config.overrides) |ov| {
        if (!std.mem.eql(u8, path, ov.path)) continue;
        if (ov.max_bytes) |v| limits.max_bytes = v;
        if (ov.max_lines) |v| limits.max_lines = v;
        if (ov.max_pub_decls) |v| limits.max_pub_decls = v;
        if (ov.max_imports) |v| limits.max_imports = v;
    }
    return limits;
}

const Metrics = struct {
    bytes: usize,
    lines: usize,
    pub_decls: usize,
    imports: usize,
};

fn measureFile(alloc: std.mem.Allocator, path: []const u8, limits: Limits) !Metrics {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const st = try file.stat();
    const size_u64 = st.size;
    const size: usize = std.math.lossyCast(usize, size_u64);

    if (size > limits.max_bytes) {
        // Fast-path: avoid reading giant files into memory.
        return .{ .bytes = size, .lines = 0, .pub_decls = 0, .imports = 0 };
    }

    const bytes = try file.readToEndAlloc(alloc, limits.max_bytes);
    defer alloc.free(bytes);

    var lines: usize = 0;
    for (bytes) |b| {
        if (b == '\n') lines += 1;
    }
    if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') lines += 1;

    var pub_decls: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "pub ")) pub_decls += 1;
    }

    var imports: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, "@import(")) |idx| {
        imports += 1;
        pos = idx + 1;
    }

    return .{ .bytes = bytes.len, .lines = lines, .pub_decls = pub_decls, .imports = imports };
}
