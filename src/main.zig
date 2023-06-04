const std = @import("std");
const clap = @import("clap");
const tomlz = @import("tomlz");
const loader = @import("./loader.zig");
const level = @import("./level.zig");

const LevelInfo = struct {
    id: []const u8,
    description: []const u8,
    beginGame: bool,
    endGame: bool,
    newSkills: std.AutoHashMap(usize, void),
    requireSkills: std.AutoHashMap(usize, void),
};

const GameLevelError = error {
    UnsupportedVersion,
    MissingLPathSection,
    NoLevelDefined,
    MissingLevelID,
    LevelIDUnmatch,
};

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
        const fileContent = try loader.loadProfileContent(allocator, filepath);
        defer allocator.free(fileContent);

        var gameDef = try level.initFromTOML(allocator, fileContent);
        defer gameDef.deinit();

        gameDef.printInfo();
    }
}

// TODO I noticed zigmod's deps.addAllTo() does not add deppendencies to
// zig test (see build.zig). It means, there's no way to reference
// external dependencies (esp. tomlz) in unit test code. I haven't found
// a reason on this.
