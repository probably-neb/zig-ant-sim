const std = @import("std");
const gl = @import("gl");

const c = @import("c.zig");
const bmp = @import("bmp.zig");

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

const vertex_shader_basic_source =
    \\#version 330 core
    \\in vec4 a_position;
    \\
    \\void main() {
    \\    gl_Position = a_position;
    \\}
;
const fragment_shader_basic_source =
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
    const screen_w = 800;
    const screen_h = 600;

    const window_handler = try createWindow(screen_w, screen_h);
    var framebuffer_width: i32 = undefined;
    var framebuffer_height: i32 = undefined;
    c.glfwGetFramebufferSize(window_handler, &framebuffer_width, &framebuffer_height);

    const program_basic = compile_shader_program(vertex_shader_basic_source, fragment_shader_basic_source);

    const circle_segment_count = 25;
    const circles_count = 4;

    var circles_vertices_buf: [circles_count][circle_segment_count * 2]f32 = undefined;

    const circles_info: [circles_count]struct { x: f32, y: f32, r: f32 } = .{
        .{ .x = 0.5, .y = 0.5, .r = 0.02 },
        .{ .x = 0.5, .y = -0.5, .r = 0.02 },
        .{ .x = -0.5, .y = 0.5, .r = 0.02 },
        .{ .x = -0.5, .y = -0.5, .r = 0.02 },
    };

    var circles_ver_buf_gl_id: [circles_count]c_uint = undefined;
    var circles_pos_buf_gl_id: [circles_count]c_uint = undefined;

    // fill circle_vertices_buf
    for (0..circles_count) |circle_index| {
        const circle_info = circles_info[circle_index];

        for (0..circle_segment_count) |i| {
            const i_f32: f32 = @floatFromInt(i);
            const angle = i_f32 * std.math.tau / circle_segment_count;
            circles_vertices_buf[circle_index][i * 2] = circle_info.x + std.math.cos(angle) * circle_info.r;
            circles_vertices_buf[circle_index][i * 2 + 1] = circle_info.y + std.math.sin(angle) * circle_info.r;
        }
    }
    gl.GenVertexArrays(circles_count, @ptrCast(&circles_ver_buf_gl_id[0]));
    defer gl.DeleteVertexArrays(circles_count, @ptrCast(&circles_ver_buf_gl_id[0]));

    gl.GenBuffers(circles_count, @ptrCast(&circles_pos_buf_gl_id[0]));
    defer gl.DeleteBuffers(circles_count, @ptrCast(&circles_pos_buf_gl_id[0]));

    for (circles_ver_buf_gl_id, circles_pos_buf_gl_id, 0..) |circle_ver_buf_gl_id, circle_pos_buf_gl_id, circle_index| {
        gl.BindVertexArray(circle_ver_buf_gl_id);

        gl.BindBuffer(gl.ARRAY_BUFFER, circle_pos_buf_gl_id);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(circle_segment_count * 2 * @sizeOf(c.GLfloat)), &circles_vertices_buf[circle_index], gl.STATIC_DRAW);
        {
            const attribute_name: *const [10:0]u8 = "a_position";
            const attribute_size: c_int = 2;

            const location = gl.GetAttribLocation(program_basic, @ptrCast(attribute_name));

            if (location == -1) {
                // TODO: figure out how to set text error and return error here.
                std.debug.panic("Failed to get a uniform location \"{s}\".", .{attribute_name});
            }

            gl.EnableVertexAttribArray(@as(u32, @intCast(location)));
            gl.VertexAttribPointer(@as(u32, @intCast(location)), attribute_size, gl.FLOAT, gl.FALSE, 0, 0);
        }
    }

    var ant_texture_id: c_uint = undefined;
    var ant_texture_program: c_uint = undefined;
    var ant_texture_vao: c_uint = undefined;
    var ant_textrue_ebo: c_uint = undefined;
    {
        const ant_texture_vert_shader_source =
            \\ #version 330 core
            \\
            \\ layout (location = 0) in vec2 aPos;
            \\ layout (location = 1) in vec2 aTexCoord;
            \\
            \\ out vec2 TexCoord;
            \\
            \\ void main()
            \\ {
            \\     gl_Position = vec4(aPos, 1.0, 1.0);
            \\     TexCoord = aTexCoord;
            \\ }
        ;
        const ant_texture_frag_shader_source =
            \\ #version 330 core
            \\
            \\ out vec4 FragColor;
            \\ in vec2 TexCoord;
            \\
            \\ uniform sampler2D texture1;
            \\
            \\ void main()
            \\ {
            \\     FragColor = texture(texture1, TexCoord);
            \\ }
        ;

        // Compile and link shaders (omitted for brevity)
        ant_texture_program = compile_shader_program(
            ant_texture_vert_shader_source,
            ant_texture_frag_shader_source,
        );

        const alloc = std.heap.page_allocator;
        // const ant_texture_contents = bmp.read_ant_simple(alloc) catch |err| {
        //     std.debug.panic("Failed to read ant BMP: {any}", .{err});
        // };
        // defer alloc.free(ant_texture_contents);

        // const zigimg = @import("zigimg");

        var image = try @import("zigimg").Image.fromMemory(alloc, @embedFile("./assets/ant-simple.bmp"));
        const ant_texture_contents = image.pixels.bgra32;
        defer image.deinit();

        gl.GenTextures(1, @ptrCast(&ant_texture_id));
        gl.BindTexture(gl.TEXTURE_2D, ant_texture_id);

        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

        gl.TexImage2D(gl.TEXTURE_2D, 0, gl.BGRA, 512, 512, 0, gl.BGRA, gl.UNSIGNED_BYTE, ant_texture_contents.ptr);
        gl.GenerateMipmap(ant_texture_id);

        const ant_texture_vertices = [2 * 4 + 2 * 4]f32{
            // zig fmt: off
            // positions // texture coords
            -0.5, -0.5,  0.0, 0.0, // bottom left
             0.5, -0.5,  1.0, 0.0, // bottom right
             0.5,  0.5,  1.0, 1.0, // top right
            -0.5,  0.5,  0.0, 1.0, // top left
            // zig fmt: on
        };

        const ant_texture_indices = [6]u32{ 0, 1, 3, 1, 2, 3 };

        gl.GenBuffers(1, @ptrCast(&ant_textrue_ebo));
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ant_textrue_ebo);
        gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, ant_texture_indices.len * @sizeOf(u32), @ptrCast(&ant_texture_indices[0]), gl.STATIC_DRAW);

        var ant_vbo_id: c_uint = undefined;
        var ant_vao_id: c_uint = undefined;

        gl.GenVertexArrays(1, @ptrCast(&ant_vao_id));
        gl.GenBuffers(1, @ptrCast(&ant_vbo_id));

        ant_texture_vao = ant_vao_id;


        gl.BindBuffer(gl.ARRAY_BUFFER, ant_vbo_id);
        gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(ant_texture_vertices)), @ptrCast(&ant_texture_vertices[0]), gl.STATIC_DRAW);

        gl.BindVertexArray(ant_vao_id);

        gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 4 * @sizeOf(f32), 0);
        gl.EnableVertexAttribArray(0);

        gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 4 * @sizeOf(f32), 2 * @sizeOf(f32));
        gl.EnableVertexAttribArray(1);

    }

    while (c.glfwWindowShouldClose(window_handler) == gl.FALSE) {
        const start = std.time.nanoTimestamp();
        defer {
            std.debug.print("frame time: {}ms\r", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start)) / std.time.ns_per_ms});
        }
        gl.Viewport(0, 0, framebuffer_width, framebuffer_height);
        gl.ClearColor(1, 1, 1, 1);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        gl.UseProgram(program_basic);
        // draw circles
        for (circles_ver_buf_gl_id) |circle_ver_buf_gl_id| {
            gl.BindVertexArray(circle_ver_buf_gl_id);
            gl.DrawArrays(gl.TRIANGLE_FAN, 0, @intCast(circle_segment_count));

            gl.BindVertexArray(0);
            gl.BindBuffer(gl.ARRAY_BUFFER, 0);
        }

        gl.UseProgram(ant_texture_program);
        {
            gl.BindTexture(gl.TEXTURE_2D, ant_texture_id);
            gl.Uniform1i(gl.GetUniformLocation(ant_texture_program, "texture1"), 0);
            gl.BindVertexArray(ant_texture_vao);
            // gl.DrawArrays(gl.TRIANGLE_FAN, 0, 8);
            gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ant_textrue_ebo);
            gl.DrawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, 0);
        }

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

pub fn compile_shader_program(vertex_shader_source: []const u8, fragment_shader_source: []const u8) c_uint {
    const fragment_shader = compile_shader(fragment_shader_source, gl.FRAGMENT_SHADER);
    const vertex_shader = compile_shader(vertex_shader_source, gl.VERTEX_SHADER);

    defer gl.DeleteShader(vertex_shader);
    defer gl.DeleteShader(fragment_shader);

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

    return program_id;
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
