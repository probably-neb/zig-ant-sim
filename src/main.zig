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
const gl = @import("gl");

const vertex_shader_source =
    \\#version 330 core
    \\in vec4 a_position;
    \\
    \\void main() {
    \\    gl_Position = a_position;
    \\}
;
const fragment_shader_source =
    \\#version 330 core
    \\
    \\precision highp float;
    \\out vec4 outColor;
    \\
    \\void main() {
    \\    outColor = vec4(1.0, 0.0, 1.0, 1.0);
    \\}
;

fn errorCallback(err: c_int, description: [*c]const u8) callconv(.C) void {
    _ = err;
    std.log.err("GLFW Error: {s}", .{description});
}

var procs: gl.ProcTable = undefined;

// Function that creates a window using GLFW.
pub fn createWindow(width: i32, height: i32) !*c.GLFWwindow {
    var window: *c.GLFWwindow = undefined;

    _ = c.glfwSetErrorCallback(errorCallback);

    if (c.glfwInit() == gl.FALSE) {
        std.debug.panic("Failed to initialize GLFW", .{});
    }

    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);

    // MSAA.
    c.glfwWindowHint(c.GLFW_SAMPLES, 4);

    // Needed on MacOS.
    c.glfwWindowHint(c.GLFW_OPENGL_FORWARD_COMPAT, gl.TRUE);

    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);

    window = c.glfwCreateWindow(width, height, "ant-sim", null, null) orelse {
        std.log.err("Failed to create window", .{});
        return error.FailedToCreateWindow;
    };

    c.glfwMakeContextCurrent(window);

    if (!procs.init(c.glfwGetProcAddress)) {
        return error.ProcTableInitFailed;
    }
    gl.makeProcTableCurrent(&procs);

    return window;
}

pub fn main() !void {
    // if (gl.adLoadGL() == 0) {
    //     return error.GladLoadGLFailed;
    // }
    const width = 800;
    const height = 600;

    const window_handler = try createWindow(width, height);
    var framebuffer_width: i32 = undefined;
    var framebuffer_height: i32 = undefined;
    c.glfwGetFramebufferSize(window_handler, &framebuffer_width, &framebuffer_height);

    const vertex_shader = compile_shader(vertex_shader_source, gl.VERTEX_SHADER);
    const fragment_shader = compile_shader(fragment_shader_source, gl.FRAGMENT_SHADER);
    const program = program_id: {
        var program_id: c_uint = undefined;
        program_id = gl.CreateProgram();

        gl.AttachShader(program_id, vertex_shader);
        gl.AttachShader(program_id, fragment_shader);
        gl.LinkProgram(program_id);

        if (!c.is_wasm) {
            var success: i32 = undefined;
            gl.GetProgramiv(program_id, gl.LINK_STATUS, &success);

            if (success != gl.TRUE) {
                var log: [512]u8 = undefined;
                @memset(&log, 0);
                gl.GetProgramInfoLog(program_id, 512, null, @ptrCast(&log));
                // TODO: figure out how to set text error and return error here.
                std.debug.panic("Program linking failed: {s}", .{@as([*:0]u8, @ptrCast(&log))});
            }
        }

        break :program_id program_id;
    };
    gl.DeleteShader(vertex_shader);
    gl.DeleteShader(fragment_shader);

    gl.UseProgram(program);

    var vao: c_uint = undefined;
    gl.GenVertexArrays(1, @ptrCast(&vao));
    defer gl.DeleteVertexArrays(1, @ptrCast(&vao)); // Clean up in the end of main().

    var position_buffer: c_uint = undefined;
    gl.GenBuffers(1, @ptrCast(&position_buffer));
    defer gl.DeleteBuffers(1, @ptrCast(&position_buffer)); // Clean up in the end of main().

    gl.BindVertexArray(vao);

    const vertices = [_]f32{
        // zig fmt: off
        -1.0, -1.0,
        1.0, -1.0,
        0.0, 1.0,
        // zig fmt: on
    };
    gl.BindBuffer(gl.ARRAY_BUFFER, position_buffer);
    gl.BufferData(gl.ARRAY_BUFFER, (@as(isize, @intCast(@sizeOf(c.GLfloat))) * vertices.len), &vertices[0], gl.STATIC_DRAW);
    _ = get_attribute_location(program, 2, "a_position");

    while (c.glfwWindowShouldClose(window_handler) == gl.FALSE) {
        gl.Viewport(0, 0, framebuffer_width, framebuffer_height);
        gl.ClearColor(0, 0, 0, 1);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        gl.BindVertexArray(vao);
        gl.DrawArrays(gl.TRIANGLES, 0, 3);
        gl.BindVertexArray(0);

        c.glfwSwapBuffers(window_handler);
        c.glfwPollEvents();
    }
}

/// Compile shader from string.
pub fn compile_shader(shader_source: []const u8, shader_type: u32) u32 {
    var shader_id: c_uint = undefined;
    shader_id = gl.CreateShader(shader_type);

    if (c.is_wasm) {
        gl.ShaderSource(shader_id, shader_source.ptr, shader_source.len);
    } else {
        gl.ShaderSource(shader_id, 1, @ptrCast(&shader_source.ptr), null);
    }
    gl.CompileShader(shader_id);

    if (!c.is_wasm) {
        var success: c_int = undefined;
        gl.GetShaderiv(shader_id, gl.COMPILE_STATUS, &success);

        if (success != gl.TRUE) {
            var log: [512]u8 = undefined;
            @memset(&log, 0);
            gl.GetShaderInfoLog(shader_id, 512, null, @ptrCast(&log[0]));
            // TODO: figure out how to set text error and return error here.
            std.debug.panic("Shader compilation failed: {s}", .{@as([*:0]u8, @ptrCast(&log))});
        }
    } else {
        const success = gl.GetShaderParameter(shader_id, gl._COMPILE_STATUS);

        if (success != gl._TRUE) {
            var log: [512]u8 = undefined;
            @memset(&log, 0);
            gl.GetShaderInfoLog(shader_id, 512, 0, @ptrCast(&log));
            std.debug.panic("Shader compilation failed: {s}", .{@as([*:0]u8, @ptrCast(&log))});
        }
    }

    return shader_id;
}

pub inline fn get_attribute_location(program: u32, size: i32, name: []const u8) i32 {
    const location = if (c.is_wasm) gl.GetAttribLocation(program, name.ptr, name.len) else gl.GetAttribLocation(program, @ptrCast(name));

    if (location == -1) {
        // TODO: figure out how to set text error and return error here.
        std.debug.panic("Failed to get a uniform location \"{s}\".", .{name});
    }

    gl.EnableVertexAttribArray(@as(u32, @intCast(location)));
    gl.VertexAttribPointer(@as(u32, @intCast(location)), size, gl.FLOAT, gl.FALSE, 0, 0);

    return location;
}

pub inline fn get_uniform_location(program: u32, name: []const u8) i32 {
    const location = if (c.is_wasm) gl.GetUniformLocation(program, name.ptr, name.len) else gl.GetUniformLocation(program, @as([*c]const u8, @ptrCast(name)));

    if (location == -1) {
        // TODO: figure out how to set text error and return error here.
        std.debug.panic("Failed to get a uniform location \"{s}\". Make sure it is _used_ in the shader.", .{name});
    }

    return location;
}
