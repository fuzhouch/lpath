const std = @import("std");
const tomlz = @import("tomlz");

pub fn loadProfileContent(allocator: std.mem.Allocator, filepath: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 1024 * 1024);
}
