const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // Required for @cImport
    });

    // Add site config as an importable module
    root_module.addImport("site.config", b.createModule(.{
        .root_source_file = b.path("site.config.zig"),
    }));

    // Define the executable
    const exe = b.addExecutable(.{
        .name = "ssg",
        .root_module = root_module,
    });

    // Link against system-installed cmark-gfm
    exe.linkSystemLibrary("cmark-gfm");

    // Install the executable
    b.installArtifact(exe);

    // Create a run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the static site generator");
    run_step.dependOn(&run_cmd.step);
}
