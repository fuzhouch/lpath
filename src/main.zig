const std = @import("std");
const clap = @import("clap");
const tomlz = @import("tomlz");

const LevelInfo = struct {
    id: []const u8,
    description: []const u8,
    beginGame: bool,
    endGame: bool,
    newSkills: std.AutoHashMap(usize, void),
};

const GameLevelError = error {
    UnsupportedVersion,
    MissingLPathSection,
    NoLevelDefined,
    MissingLevelID,
};

fn analyzeTable(allocator: std.mem.Allocator, table: *tomlz.Table) !usize {
    const toplevel = table.getTable("lpath") orelse return GameLevelError.MissingLPathSection;
    const version = toplevel.getInteger("version") orelse 1;
    if (version != 1) {
        std.debug.print("ERROR: Unsupported version: {}\n", .{version});
        return GameLevelError.UnsupportedVersion;
    }
    const skills = toplevel.getArray("skill");
    const levels = table.getArray("level") orelse return GameLevelError.NoLevelDefined;
    const arraySize = levels.items().len;
    const graphSize = arraySize * arraySize;

    const transitionGraph = allocator.alloc(usize, graphSize) catch |err| {
        std.debug.print("ERROR: Allocating transitionGraph {any}\n", .{err});
        return err;
    };
    const levelInfoArray = allocator.alloc(LevelInfo, arraySize) catch |err| {
        std.debug.print("ERROR: Allocating levelInfoArray {any}\n", .{err});
        return err;
    };

    var skillLookup = std.StringHashMap(usize).init(allocator);
    defer skillLookup.deinit();

    // Load skills. Conver from string to ID.
    if (skills) |skillDefinition| {
        var skillId: usize = 0;
        for (skillDefinition.items()) |skill| {
            switch(skill) {
                .string => |skillName| {
                    if (!skillLookup.contains(skillName)) {
                        try skillLookup.put(skillName, skillId);
                    }
                },
                else => {}, // Ignore unexpected values are OK.
            }
        }
    }

    // Load information of each level
    for (levels.items(), 0..) |level, i| {
        switch(level) {
            .table => |tbl| {
                levelInfoArray[i].id = tbl.getString("id") orelse return GameLevelError.MissingLPathSection;
                levelInfoArray[i].description = tbl.getString("description") orelse "";
                levelInfoArray[i].beginGame = tbl.getBool("begin-game") orelse false;
                levelInfoArray[i].endGame = tbl.getBool("end-game") orelse false;
                levelInfoArray[i].newSkills = std.AutoHashMap(usize, void).init(allocator);
                // When passing a level, it's possible a player get
                // new skills. It should be saved in level info instead
                // of a transition context as it's a static data.
                if (tbl.getArray("new-skill")) |newSkills| {
                    for (newSkills.items()) |skill| {
                        switch(skill) {
                            .string => |skillName| {
                                if (skillLookup.get(skillName)) |id| {
                                    try levelInfoArray[i].newSkills.put(id, {});
                                }
                            },
                            else => {}, // Bad format, but ignore for now.
                        }
                    }
                } 
            },
            else => {}, // Ignore unexpected values are OK.
        }
    }

    _ = transitionGraph;
    return 0;
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

        const paths = analyzeTable(allocator, &table) catch |err| {
            std.debug.print("ERROR: {any}", .{err});
            return err;
        };
        std.debug.print("Paths = {}", .{ paths });
    }
}

// TODO I noticed zigmod's deps.addAllTo() does not add deppendencies to
// zig test (see build.zig). It means, there's no way to reference
// external dependencies (esp. tomlz) in unit test code. I haven't found
// a reason on this.
const expect = std.testing.expect;
test "Basic structure" { }
