const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zig-ant-sim",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zig-ant-sim",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    {
        const glfw_dep = b.dependency("glfw", .{});

        const glfw_lib = b.addStaticLibrary(.{
            .name = "glfw",
            .target = target,
            .optimize = optimize,
        });
        glfw_lib.linkLibC();
        glfw_lib.linkSystemLibrary("X11");
        const src_dir_path = glfw_dep.path("src").getPath(b);
        const src_dir = std.fs.cwd().openDir(src_dir_path, .{ .iterate = true }) catch std.debug.panic("failed to open GLFW source directory: {s}", .{src_dir_path});
        var c_paths = std.ArrayList([]const u8).init(b.allocator);
        {
            var src_dir_iter = src_dir.iterate();
            while (src_dir_iter.next() catch unreachable) |entry| {
                if (std.mem.eql(u8, std.fs.path.extension(entry.name), ".c")) {
                    const name = b.allocator.dupe(u8, std.fs.path.basename(entry.name)) catch @panic("OOM");
                    c_paths.append(name) catch @panic("OOM");
                }
            }
        }

        glfw_lib.addCSourceFiles(.{
            .root = glfw_dep.path("src"),
            .files = c_paths.items,
            .flags = &.{"-D_GLFW_X11"},
        });
        exe.linkLibrary(glfw_lib);
        exe.addIncludePath(glfw_dep.path("include"));
    }
    exe.linkLibC();
    exe.linkSystemLibrary("X11");
    exe.linkSystemLibrary("OpenGL");

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
