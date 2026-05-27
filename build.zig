const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    inline for (.{ "index.html", "style.css", "datastar.js" }) |name| {
        exe_mod.addAnonymousImport(name, .{
            .root_source_file = b.path("assets/" ++ name),
        });
    }

    const exe = b.addExecutable(.{
        .name = "heimdash",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run heimdash");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    inline for (.{ "health.zig", "format.zig", "credential.zig", "summary.zig" }) |name| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/" ++ name),
            .target = target,
            .optimize = optimize,
        });
        const unit_tests = b.addTest(.{ .root_module = test_mod });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
