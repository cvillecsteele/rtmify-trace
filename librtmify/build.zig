const std = @import("std");

// ---------------------------------------------------------------------------
// Release targets (used by `zig build release`)
// ---------------------------------------------------------------------------

const ReleaseTarget = struct {
    triple: []const u8,
    name: []const u8,
};

const release_targets = [_]ReleaseTarget{
    .{ .triple = "aarch64-macos", .name = "rtmify-trace-macos-arm64" },
    .{ .triple = "x86_64-macos", .name = "rtmify-trace-macos-x64" },
    .{ .triple = "x86_64-windows", .name = "rtmify-trace-windows-x64" },
    .{ .triple = "aarch64-windows", .name = "rtmify-trace-windows-arm64" },
    .{ .triple = "x86_64-linux-musl", .name = "rtmify-trace-linux-x64" },
    .{ .triple = "aarch64-linux-musl", .name = "rtmify-trace-linux-arm64" },
};

pub fn build(b: *std.Build) void {
    // -----------------------------------------------------------------------
    // Version: single source of truth — bump this before each release
    // Format: YYYYMMDD-[a-z]  e.g. "20260308-a"
    // -----------------------------------------------------------------------
    const version = "20260308-a";
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    const opts_mod = opts.createModule();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("rtmify", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "rtmify-trace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = lib_mod },
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const shared_lib = b.addLibrary(.{
        .name = "rtmify",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(shared_lib);

    const static_lib = b.addLibrary(.{
        .name = "rtmify",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(static_lib);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run rtmify-trace");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = lib_mod },
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_main_tests.step);

    // -----------------------------------------------------------------------
    // Release step: cross-compile for all distribution targets
    // Output goes to zig-out/release/
    // -----------------------------------------------------------------------

    const release_step = b.step("release", "Build release binaries for all targets");

    for (release_targets) |rt| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = rt.triple }) catch
            @panic("invalid release target triple");
        const cross_target = b.resolveTargetQuery(query);

        const cross_lib = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = cross_target,
            .optimize = .ReleaseSafe,
        });

        const cross_exe = b.addExecutable(.{
            .name = rt.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = cross_target,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "rtmify", .module = cross_lib },
                    .{ .name = "build_options", .module = opts_mod },
                },
            }),
        });

        const install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        });
        release_step.dependOn(&install.step);
    }
}
