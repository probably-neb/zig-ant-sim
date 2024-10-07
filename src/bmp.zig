const std = @import("std");

const ant_simple = @embedFile("./assets/ant-simple.bmp");

pub fn read_ant_simple(alloc: std.mem.Allocator) ![]const f32 {
    const bytes = ant_simple;
    const header = bytes[0..54];
    std.debug.assert(std.mem.eql(u8, header[0..2], "BM"));
    const length = std.mem.readInt(i32, header[2..6], .little);
    const offset = std.mem.readInt(i32, header[10..14], .little);

    const width = std.mem.readInt(i32, header[18..22], .little);
    const height = std.mem.readInt(i32, header[22..26], .little);
    std.debug.assert(width == height);
    std.debug.assert(width == 512);

    std.debug.print("length: {}, offset: {}, width: {}, height: {}\n", .{ length, offset, width, height });

    const pixel_bit_count = std.mem.readInt(i16, header[28..30], .little);
    std.debug.assert(@divExact(pixel_bit_count, 8) == 4);

    const row_size = @divFloor((width * pixel_bit_count + 31), 32) * 4;
    const padding = row_size - @divExact(width * pixel_bit_count, 8);

    var data = try alloc.alloc(f32, @intCast(width * height * 4));

    const pixels = bytes[@intCast(offset)..];
    var pixel_index: usize = 0;

    var y: i32 = height - 1;
    while (y >= 0) : (y -= 1) {
        var x: i32 = 0;
        while (x < width) : (x += 1) {
            const index: usize = @intCast((y * width + x) * 4);
            data[index + 0] = @as(f32, @floatFromInt(pixels[pixel_index + 0])) / 255;
            data[index + 1] = @as(f32, @floatFromInt(pixels[pixel_index + 1])) / 255;
            data[index + 2] = @as(f32, @floatFromInt(pixels[pixel_index + 2])) / 255;
            data[index + 3] = @as(f32, @floatFromInt(pixels[pixel_index + 3])) / 255;

            pixel_index += 4;
        }
        pixel_index += @intCast(padding);
    }

    return data;
}
