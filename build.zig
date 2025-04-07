const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "gameboy",
        .root_module = exe_mod,
    });

    exe.addIncludePath(b.path("SDL2/include"));
    exe.addLibraryPath(b.path("SDL2/lib"));

    if (target.result.os.tag == .macos) {
        exe.addObjectFile(b.path("sdl2.a"));

        exe.addSystemFrameworkPath(.{ .cwd_relative = "/System/Library/Frameworks/" });
        const frameworks = .{
            "Cocoa",
            "CoreVideo",
            "IOKit",
            "CoreFoundation",
            "Carbon",
            "ForceFeedback",
            "GameController",
            "Metal",
            "CoreAudio",
            "CoreHaptics",
            "AudioToolbox",
        };
        // Add framework search path
        exe.addFrameworkPath(.{ .cwd_relative = "/System/Library/Frameworks" });

        // Link each framework
        inline for (frameworks) |framework| {
            exe.linkFramework(framework);
        }
    }

    if(target.os.result.tag == .linux) {
      exe.linkSystemLibrary("SDL2");
      exe.linkLibC();
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
