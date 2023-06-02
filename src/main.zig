const std = @import("std");
const clap = @import("clap");
const tomlz = @import("tomlz");

fn analyzeTable(table: *tomlz.Table) ?usize {
    const toplevel = table.getTable("lpath") orelse return null;
    const version = toplevel.getInteger("version") orelse 1;
    std.debug.print("version = {}\n", .{version});
    const levels = table.getArray("level") orelse return null;
    std.debug.print("Lengths: {}\n", .{ levels.items().len });
    return levels.items().len;
}

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

    if (res.args.profile) |filepath| {
        var file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();

        const file_content = try file.readToEndAlloc(allocator, 1024 * 1024);
        var table = try tomlz.parse(allocator, file_content);
        defer table.deinit(allocator);

        _ = analyzeTable(&table);
    }
}
