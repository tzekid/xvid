const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app_module = applicationModule(b, target, optimize, "src/main.zig");
    const executable = b.addExecutable(.{
        .name = "xvid",
        .root_module = app_module,
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    run_command.addPassthruArgs();
    b.step("run", "Run xvid").dependOn(&run_command.step);

    const tests = b.addTest(.{
        .root_module = applicationModule(b, target, optimize, "src/root.zig"),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run focused parser, validation, state, and rendering tests").dependOn(&run_tests.step);

    const fixture_ffmpeg = b.addExecutable(.{
        .name = "fixture-ffmpeg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixture_ffmpeg.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const fixture_ffprobe = b.addExecutable(.{
        .name = "fixture-ffprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixture_ffprobe.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const fixture_x_server = b.addExecutable(.{
        .name = "fixture-x-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixture_x_server.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    fixture_x_server.root_module.addAnonymousImport("fixture_poster", .{ .root_source_file = b.path("assets/icon-180.png") });
    const e2e = b.addSystemCommand(&.{ "bash", "tests/e2e.sh" });
    e2e.addArtifactArg(executable);
    e2e.addArtifactArg(fixture_ffmpeg);
    e2e.addArtifactArg(fixture_ffprobe);
    e2e.addArtifactArg(fixture_x_server);
    b.step("e2e", "Run native-X real-process end-to-end journeys").dependOn(&e2e.step);
}

fn applicationModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_path: []const u8,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.linkSystemLibrary("sqlite3", .{});
    module.addAnonymousImport("app_css", .{ .root_source_file = b.path("assets/app.css") });
    module.addAnonymousImport("app_js", .{ .root_source_file = b.path("assets/app.js") });
    module.addAnonymousImport("retire_sw", .{ .root_source_file = b.path("assets/retire-sw.js") });
    module.addAnonymousImport("manifest", .{ .root_source_file = b.path("assets/manifest.webmanifest") });
    module.addAnonymousImport("icon", .{ .root_source_file = b.path("assets/icon.svg") });
    module.addAnonymousImport("icon_180", .{ .root_source_file = b.path("assets/icon-180.png") });
    module.addAnonymousImport("icon_192", .{ .root_source_file = b.path("assets/icon-192.png") });
    module.addAnonymousImport("icon_512", .{ .root_source_file = b.path("assets/icon-512.png") });
    return module;
}
