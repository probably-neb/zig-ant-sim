pub const is_wasm = false;
pub usingnamespace @cImport({
    @cInclude("GLFW/glfw3.h");
    @cInclude(if (@import("builtin").target.os.tag == .macos) "OpenGL/gl3.h" else "GL/gl.h");
});
