const std = @import("std");
const gl = @import("gl");

const c = @import("c.zig");
const bmp = @import("bmp.zig");

const COUNT_NESTS: u32 = 4;
const COUNT_RESOURCES: @TypeOf(COUNT_NESTS) = COUNT_NESTS;
const COUNT_ANTS: u64 = 1022;
const COUNT_CURRENT_PATHS: @TypeOf(COUNT_ANTS) = COUNT_ANTS;
const COUNT_PATHS: u64 = COUNT_NESTS * (COUNT_NESTS - 1) / 2;

const Nest = struct {
    location: [2]f32, // [x, y]
    color: [3]u8, // [r, g, b]

    const ID = @TypeOf(COUNT_NESTS);
};

const Ant = struct {
    id: ID,
    orig: Nest.ID,
    dest: Nest.ID,
    steps: [COUNT_NESTS]Nest.ID,
    cur_step: @TypeOf(COUNT_NESTS),
    cur_dest: Nest.ID,

    const ID = u64;
};

const Path = struct {
    from: Nest.ID,
    to: Nest.ID,
    strengths: [COUNT_RESOURCES]f32,
};

const State = struct {};

fn errorCallback(err: c_int, description: [*c]const u8) callconv(.C) void {
    _ = err;
    std.log.err("GLFW Error: {s}", .{description});
}

pub fn main() !void {
    const setup_start = std.time.nanoTimestamp();
    const screen_w = 800;
    const screen_h = 600;

    var rng_inner = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const rng = std.Random.init(&rng_inner, std.Random.DefaultPrng.fill);
    const alloc = std.heap.page_allocator;

    var gl_proc_table: gl.ProcTable = undefined;

    const window_handler = window: {
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

        window = c.glfwCreateWindow(screen_w, screen_h, "ant-sim", null, null) orelse {
            std.log.err("Failed to create window", .{});
            return error.FailedToCreateWindow;
        };

        c.glfwMakeContextCurrent(window);

        if (!gl_proc_table.init(c.glfwGetProcAddress)) {
            std.debug.panic("Failed to initialize OpenGL proc table", .{});
        }
        gl.makeProcTableCurrent(&gl_proc_table);

        break :window window;
    };

    var framebuffer_width: i32 = undefined;
    var framebuffer_height: i32 = undefined;
    c.glfwGetFramebufferSize(window_handler, &framebuffer_width, &framebuffer_height);

    const nest_program = program: {
        const nest_vert_shader_source =
            \\#version 330 core
            \\in vec4 a_position;
            \\
            \\void main() {
            \\    gl_Position = a_position;
            \\}
        ;
        const nest_frag_shader_source =
            \\#version 330 core
            \\
            \\precision highp float;
            \\out vec4 outColor;
            \\
            \\void main() {
            \\    outColor = vec4(1.0, 0.0, 1.0, 1.0);
            \\}
        ;
        break :program compile_shader_program(nest_vert_shader_source, nest_frag_shader_source);
    };

    const circle_segment_count = 25;
    const circle_radius = 0.02;

    var circles_vertices_buf: [COUNT_NESTS][circle_segment_count * 2]f32 = undefined;

    const nests = nests: {
        var nests = std.MultiArrayList(Nest){};
        nests.resize(alloc, COUNT_NESTS) catch unreachable;

        // generate nests
        {
            const locations = nests.items(.location);
            for (locations) |*location| {
                const x = rng.float(f32) - 0.5;
                const y = rng.float(f32) - 0.5;
                location.* = .{
                    x,
                    y,
                };
            }

            const colors = nests.items(.color);
            for (colors) |*color| {
                const r = rng.uintLessThanBiased(u8, 255);
                const g = rng.uintLessThanBiased(u8, 255);
                const b = rng.uintLessThanBiased(u8, 255);
                color.* = .{ r, g, b };
            }
        }

        break :nests nests;
    };

    var circles_ver_buf_gl_id: [COUNT_NESTS]c_uint = undefined;
    var circles_pos_buf_gl_id: [COUNT_NESTS]c_uint = undefined;

    const locations = nests.items(.location);

    // fill circle_vertices_buf
    for (locations, 0..COUNT_NESTS) |location, circle_index| {
        for (0..circle_segment_count) |i| {
            const i_f32: f32 = @floatFromInt(i);
            const angle = i_f32 * std.math.tau / circle_segment_count;
            circles_vertices_buf[circle_index][i * 2] = location[0] + std.math.cos(angle) * circle_radius;
            circles_vertices_buf[circle_index][i * 2 + 1] = location[1] + std.math.sin(angle) * circle_radius;
        }
    }
    gl.GenVertexArrays(COUNT_NESTS, @ptrCast(&circles_ver_buf_gl_id[0]));
    defer gl.DeleteVertexArrays(COUNT_NESTS, @ptrCast(&circles_ver_buf_gl_id[0]));

    gl.GenBuffers(COUNT_NESTS, @ptrCast(&circles_pos_buf_gl_id[0]));
    defer gl.DeleteBuffers(COUNT_NESTS, @ptrCast(&circles_pos_buf_gl_id[0]));

    for (circles_ver_buf_gl_id, circles_pos_buf_gl_id, 0..) |circle_ver_buf_gl_id, circle_pos_buf_gl_id, circle_index| {
        gl.BindVertexArray(circle_ver_buf_gl_id);

        gl.BindBuffer(gl.ARRAY_BUFFER, circle_pos_buf_gl_id);
        gl.BufferData(gl.ARRAY_BUFFER, @intCast(circle_segment_count * 2 * @sizeOf(c.GLfloat)), &circles_vertices_buf[circle_index], gl.STATIC_DRAW);
        {
            const attribute_name: *const [10:0]u8 = "a_position";
            const attribute_size: c_int = 2;

            const location = gl.GetAttribLocation(nest_program, @ptrCast(attribute_name));

            if (location == -1) {
                // TODO: figure out how to set text error and return error here.
                std.debug.panic("Failed to get a uniform location \"{s}\".", .{attribute_name});
            }

            gl.EnableVertexAttribArray(@as(u32, @intCast(location)));
            gl.VertexAttribPointer(@as(u32, @intCast(location)), attribute_size, gl.FLOAT, gl.FALSE, 0, 0);
        }
    }

    const ant_texture_program = program: {
        const ant_texture_vert_shader_source =
            \\#version 330 core
            \\
            \\layout (location = 0) in vec2 aPos;
            \\layout (location = 1) in vec2 aTexCoord;
            \\layout (location = 2) in vec3 aInstance; // x, y, rotation
            \\
            \\out vec2 TexCoord;
            \\
            \\uniform float uScale;
            \\
            \\void main()
            \\{
            \\    // Apply rotation
            \\    float cosR = cos(aInstance.z);
            \\    float sinR = sin(aInstance.z);
            \\    vec2 rotatedPos = vec2(
            \\        aPos.x * cosR - aPos.y * sinR,
            \\        aPos.x * sinR + aPos.y * cosR
            \\    );
            \\    
            \\    // Apply scaling
            \\    vec2 scaledPos = rotatedPos * uScale;
            \\    vec2 finalPos = scaledPos + aInstance.xy;
            \\    
            \\    gl_Position = vec4(finalPos, 0.0, 1.0);
            \\    TexCoord = aTexCoord;
            \\}
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
        break :program compile_shader_program(
            ant_texture_vert_shader_source,
            ant_texture_frag_shader_source,
        );
    };

    var ant_texture_id: c_uint = undefined;
    var ant_texture_vao: c_uint = undefined;
    var ant_texture_ebo: c_uint = undefined;
    var ant_texture_instance_vbo: c_uint = undefined;
    const ant_scale: f32 = 0.04; // This will scale the texture to half its size

    var ants = std.MultiArrayList(Ant){};
    ants.ensureTotalCapacity(alloc, COUNT_ANTS) catch unreachable;

    var ant_instances: [COUNT_ANTS * 3]f32 = undefined;
    {
        const ant_texture_contents = bmp.read_ant_simple(alloc) catch |err| {
            std.debug.panic("Failed to read ant BMP: {any}", .{err});
        };
        defer alloc.free(ant_texture_contents);

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

        gl.GenBuffers(1, @ptrCast(&ant_texture_ebo));
        gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ant_texture_ebo);
        gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, ant_texture_indices.len * @sizeOf(u32), @ptrCast(&ant_texture_indices[0]), gl.STATIC_DRAW);

        var ant_texture_vbo: c_uint = undefined;

        gl.GenVertexArrays(1, @ptrCast(&ant_texture_vao));
        gl.GenBuffers(1, @ptrCast(&ant_texture_vbo));
        gl.GenBuffers(1, @ptrCast(&ant_texture_instance_vbo));


        gl.BindBuffer(gl.ARRAY_BUFFER, ant_texture_vbo);
        gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(ant_texture_vertices)), @ptrCast(&ant_texture_vertices[0]), gl.STATIC_DRAW);

        gl.BindVertexArray(ant_texture_vao);
        {
            gl.EnableVertexAttribArray(0);
            gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 4 * @sizeOf(f32), 0);

            gl.EnableVertexAttribArray(1);
            gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 4 * @sizeOf(f32), 2 * @sizeOf(f32));


            gl.BindBuffer(gl.ARRAY_BUFFER, ant_texture_instance_vbo);
            gl.BufferData(gl.ARRAY_BUFFER, @sizeOf(@TypeOf(ant_instances)), null, gl.DYNAMIC_DRAW);

            // Set up the instance attribute
            gl.EnableVertexAttribArray(2);
            gl.VertexAttribPointer(2, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), 0);
            gl.VertexAttribDivisor(2, 1); // This makes it an instanced attribute
        }

        // Don't forget to unbind
        gl.BindBuffer(gl.ARRAY_BUFFER, 0);
        gl.BindVertexArray(0);
    }
    const ant_scale_location = gl.GetUniformLocation(ant_texture_program, "uScale");
    std.debug.print("setup time: {}ms\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - setup_start)) / std.time.ns_per_ms},);

    var ant_id_next: Ant.ID = 0;

    while (c.glfwWindowShouldClose(window_handler) == gl.FALSE) {
        const start = std.time.nanoTimestamp();
        defer {
            std.debug.print("frame time: {}ms\r", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - start)) / std.time.ns_per_ms});
        }
        gl.Viewport(0, 0, framebuffer_width, framebuffer_height);
        gl.ClearColor(1, 1, 1, 1);
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        gl.UseProgram(nest_program);
        // draw circles
        for (circles_ver_buf_gl_id) |circle_ver_buf_gl_id| {
            gl.BindVertexArray(circle_ver_buf_gl_id);
            gl.DrawArrays(gl.TRIANGLE_FAN, 0, @intCast(circle_segment_count));

            gl.BindVertexArray(0);
            gl.BindBuffer(gl.ARRAY_BUFFER, 0);
        }

        if (ants.len < COUNT_ANTS and rng.boolean()) {
            ants.appendAssumeCapacity(.{
                .id = ant_id_next,
                .steps = undefined,
                .cur_step = 0,
                .orig = 0,
                .dest = 1,
                .cur_dest = 1,
            });
            ant_id_next += 1;
        }

        const count_ants_cur = ants.len;

        for (0..count_ants_cur) |i| {
            ant_instances[i * 3 + 0] = @floatCast(std.math.sin(@as(f32, @floatFromInt(i)) * 0.1 + c.glfwGetTime()) * 0.5); // x
            ant_instances[i * 3 + 1] = @floatCast(std.math.cos(@as(f32, @floatFromInt(i)) * 0.1 + c.glfwGetTime()) * 0.5); // y
            ant_instances[i * 3 + 2] = @floatCast(c.glfwGetTime() + @as(f32, @floatFromInt(i)) * 0.5); // rotation
        }



        gl.UseProgram(ant_texture_program);
        {
            gl.BindBuffer(gl.ARRAY_BUFFER, ant_texture_instance_vbo);
            gl.BufferSubData(gl.ARRAY_BUFFER, 0, @intCast(count_ants_cur * 3 * @sizeOf(f32)), &ant_instances);
            gl.BindBuffer(gl.ARRAY_BUFFER, 0);

            gl.BindTexture(gl.TEXTURE_2D, ant_texture_id);
            gl.Uniform1f(ant_scale_location, ant_scale);
            gl.BindVertexArray(ant_texture_vao);
            // gl.DrawArrays(gl.TRIANGLE_FAN, 0, 8);
            gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ant_texture_ebo);
            gl.DrawElementsInstanced(gl.TRIANGLES, 6, gl.UNSIGNED_INT, null, @intCast(count_ants_cur));
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
