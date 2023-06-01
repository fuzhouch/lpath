const std = @import("std");
const clap = @import("clap");
const tomlz = @import("tomlz");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-p, --profile <str>    Profile definition TOML file.
        );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    // .profile is an optional type (?[]u8).
    if (res.args.profile) |filepath| {
        std.debug.print("{s}, {any}\n", .{ filepath, @TypeOf(filepath) });

        var file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();

        const file_content = try file.readToEndAlloc(allocator, 1024 * 1024);
        var table = try tomlz.parse(allocator, file_content);
        _ = table;
    }
}
