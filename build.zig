const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared_mod = b.addModule("shared", .{
        .root_source_file = b.path("src/shared/shared.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zb_tls_mod = b.addModule("zb_tls", .{
        .root_source_file = b.path("src/net/tls/client.zig"),
        .target = target,
        .optimize = optimize,
    });

    const browser = b.addExecutable(.{
        .name = "zb_browser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    if (target.result.os.tag == .macos) {
        browser.linkSystemLibrary("objc");
        browser.linkFramework("AppKit");
        browser.linkFramework("Carbon");
        browser.linkFramework("CoreFoundation");
        browser.linkFramework("Foundation");
        browser.linkFramework("IOSurface");
        browser.linkFramework("QuartzCore");
        browser.linkFramework("Metal");
    }
    b.installArtifact(browser);

    const net = b.addExecutable(.{
        .name = "zb_net",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/net/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    b.installArtifact(net);

    const renderer = b.addExecutable(.{
        .name = "zb_renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/renderer/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    b.installArtifact(renderer);

    const gpu = b.addExecutable(.{
        .name = "zb_gpu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    if (target.result.os.tag == .macos) {
        gpu.linkFramework("CoreFoundation");
        gpu.linkFramework("IOSurface");
    }
    b.installArtifact(gpu);

    const run_cmd = b.addRunArtifact(browser);
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the browser bootstrap process");
    run_step.dependOn(&run_cmd.step);

    const bench = b.addExecutable(.{
        .name = "zb_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    b.installArtifact(bench);

    const bench_cmd = b.addRunArtifact(bench);
    if (b.args) |args| bench_cmd.addArgs(args);
    bench_cmd.step.dependOn(b.getInstallStep());

    const bench_step = b.step("bench", "Run the M0 performance bench harness");
    bench_step.dependOn(&bench_cmd.step);

    const navbench = b.addExecutable(.{
        .name = "zb_navbench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/navbench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    b.installArtifact(navbench);

    const navbench_cmd = b.addRunArtifact(navbench);
    if (b.args) |args| navbench_cmd.addArgs(args);
    navbench_cmd.step.dependOn(b.getInstallStep());

    const navbench_step = b.step("navbench", "Benchmark headless navigation timings");
    navbench_step.dependOn(&navbench_cmd.step);

    const guardrails = b.addExecutable(.{
        .name = "zb_guardrails",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/guardrails/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    b.installArtifact(guardrails);

    const guardrails_cmd = b.addRunArtifact(guardrails);
    if (b.args) |args| guardrails_cmd.addArgs(args);

    const guardrails_step = b.step("guardrails", "Enforce source code guardrails");
    guardrails_step.dependOn(&guardrails_cmd.step);

    const check_step = b.step("check", "Run guardrails + build");
    check_step.dependOn(&guardrails_cmd.step);
    check_step.dependOn(b.getInstallStep());

    const inspect = b.addExecutable(.{
        .name = "zb_inspect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/inspect/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    b.installArtifact(inspect);

    const inspect_cmd = b.addRunArtifact(inspect);
    if (b.args) |args| inspect_cmd.addArgs(args);
    inspect_cmd.step.dependOn(b.getInstallStep());

    const inspect_step = b.step("inspect", "Inspect run/* artifacts (optionally ASCII preview)");
    inspect_step.dependOn(&inspect_cmd.step);

    const tlsprobe = b.addExecutable(.{
        .name = "zb_tlsprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/tlsprobe/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zb_tls", .module = zb_tls_mod },
            },
        }),
    });
    b.installArtifact(tlsprobe);

    const tlsprobe_cmd = b.addRunArtifact(tlsprobe);
    if (b.args) |args| tlsprobe_cmd.addArgs(args);
    tlsprobe_cmd.step.dependOn(b.getInstallStep());

    const tlsprobe_step = b.step("tlsprobe", "Probe TLS handshakes");
    tlsprobe_step.dependOn(&tlsprobe_cmd.step);

    // Always enforce guardrails before installing artifacts.
    b.getInstallStep().dependOn(&guardrails_cmd.step);
}
