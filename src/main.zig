const COUNT_NESTS: u32 = 24;
const COUNT_RESOURCES: @TypeOf(COUNT_NESTS) = COUNT_NESTS;
const COUNT_ANTS: u64 = 1022;
const COUNT_CURRENT_PATHS: @TypeOf(COUNT_ANTS) = COUNT_ANTS;
const COUNT_PATHS: u64 = COUNT_NESTS * (COUNT_NESTS - 1) / 2;

const Nest = struct {
    id: ID,
    resources: [COUNT_RESOURCES]u64,

    const ID = @TypeOf(COUNT_NESTS);
};

const Ant = struct {
    id: u64,
    orig: Nest.ID,
    dest: Nest.ID,
    steps: [COUNT_NESTS]Nest.ID,
    cur_step: @TypeOf(COUNT_NESTS),
    cur_dest: Nest.ID,
};

const Path = struct {
    from: Nest.ID,
    to: Nest.ID,
    strengths: [COUNT_RESOURCES]f32,
};

const State = struct {};

const std = @import("std");
const c = @import("c.zig");

fn errorCallback(err: c_int, description: [*c]const u8) callconv(.C) void {
    _ = err;
    std.log.err("GLFW Error: {s}", .{description});
}

// Function that creates a window using GLFW.
pub fn createWindow(width: i32, height: i32) !*c.GLFWwindow {
    var window: *c.GLFWwindow = undefined;

    _ = c.glfwSetErrorCallback(errorCallback);

    if (c.glfwInit() == c.GL_FALSE) {
        std.debug.panic("Failed to initialize GLFW", .{});
    }

    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);

    // MSAA.
    c.glfwWindowHint(c.GLFW_SAMPLES, 4);

    // Needed on MacOS.
    c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, c.GL_TRUE);

    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);

    window = c.glfwCreateWindow(width, height, "ant-sim", null, null) orelse {
        std.log.err("Failed to create window", .{});
        return error.FailedToCreateWindow;
    };

    c.glfwMakeContextCurrent(window);

    return window;
}

pub fn main() !void {
    const width = 800;
    const height = 600;

    const window_handler = try createWindow(width, height);

    while (c.glfwWindowShouldClose(window_handler) == c.GL_FALSE) {
        c.glfwSetTime(0);

        c.glViewport(0, 0, width, height);
        c.glClearColor(1, 1, 1, 1);
        c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);

        c.glfwSwapBuffers(window_handler);
        c.glfwPollEvents();
    }
}
