const std = @import("std");
const tomlz = @import("tomlz");

pub const GameError = error {
    UnsupportedVersion,
    MissingLPathSection,
    SkillNameMustBeString,
    NoLevelDefined,
    MissingLevelID,
    LevelIDUnmatch,
    BadLevelDefinition,
    DuplicatedLevelID,
    NotImplemented,
};

// LevelInfo represents static information of a given level. It's a
// support data structure to help transition logic design whether player
// can move to next level.
const LevelInfo = struct {
    id: []const u8,
    description: []const u8,
    beginGame: bool,
    endGame: bool,

    // Key = skill ID, Value = None
    unlockSkills: std.AutoHashMap(usize, void),
    toNextRequiredSkills: std.AutoHashMap(usize, std.AutoHashMap(usize, void)),

    const Self = @This();
    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        self.unlockSkills.deinit();

        var iter = self.toNextRequiredSkills.iterator();
        while (iter.next()) |kvp| {
            kvp.value_ptr.deinit();
        }
        self.toNextRequiredSkills.deinit();

        allocator.destroy(self);
        self.* = undefined;
    }
};

pub const LevelLayout = struct {
    version: i64,
    skills: std.StringHashMap(usize),
    levels: []LevelInfo,
    levelsNameIDMap: std.StringHashMap(usize),
    transitionGraph: []bool, // 2D array for transition
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.skills.deinit();
        for (0..self.levels.len) |i| {
            self.levels[i].deinit(self.allocator);
        }
        self.allocator.free(self.levels);
        self.levelsNameIDMap.deinit();
        self.allocator.free(self.transitionGraph);
        self.allocator.destroy(self);
        self.* = undefined;
    }

    pub fn printInfo(self: *Self) void {
        for (0..self.levels.len) |i| {
            std.debug.print("{} = {s}\n", .{i, self.levels[i].id});
        }

        const dim: usize = self.levels.len;
        for (0..dim) |x| {
            for (0..dim) |y| {
                if (self.transitionGraph[x*dim+y]) {
                    std.debug.print("{} ", .{1});
                } else {
                    std.debug.print("{} ", .{0});
                }
            }
            std.debug.print("\n", .{});
        }
    }

    pub fn detectLoop(self: *Self) !usize {
        return detectLoopImpl(self);
    }
};

pub fn initFromTOML(allocator: std.mem.Allocator,
                    tomlContent: []const u8) !*LevelLayout {

    var table = try tomlz.parse(allocator, tomlContent);
    defer table.deinit(allocator);

    var layout = try allocator.create(LevelLayout);
    layout.allocator = allocator;

    try loadBasicInfo(layout, &table);
    try loadLevels(layout, &table);
    return layout;
}

// ==================================================================
// Private functions
// ==================================================================

fn loadBasicInfo(self: *LevelLayout, table: *tomlz.Table) !void {
    const lpath = table.getTable("lpath") orelse {
        return GameError.MissingLPathSection;
    };
    self.version = lpath.getInteger("version") orelse 1;
    if (self.version != 1) {
        return GameError.UnsupportedVersion;
    }

    try loadSkills(self, &lpath);
}

fn loadSkills(self: *LevelLayout, toplevel: *const tomlz.Table) !void {
    self.skills = std.StringHashMap(usize).init(self.allocator);

    var skillList = toplevel.getArray("skills");
    if (skillList) |skillNameArray| {
        var skillID: usize = 0;
        for (0..skillNameArray.items().len) |i| {
            var skillName = skillNameArray.getString(i);
            if (skillName) |nameID| {
                if (nameID.len > 0) {
                    try self.skills.put(nameID, skillID);
                    skillID += 1;
                }
                // Empty string is valid but ignored. It's used
                // as a placeholder, meaning "player does not need any
                // skill". This is required because toml does not allow
                // empty list.
            } else {
                // Let's do a strong validation: If a skill is not
                // defien as string, we throw an error.
                return GameError.SkillNameMustBeString;
            }
        }
    }
}

fn loadLevels(self: *LevelLayout, table: *const tomlz.Table) !void {
    const levels = table.getArray("levels") orelse {
        return GameError.NoLevelDefined;
    };
    const levelCount: usize = levels.items().len;
    const graphCount: usize = levelCount * levelCount;
    _ = graphCount;

    self.levels = try self.allocator.alloc(LevelInfo, levelCount);
    self.levelsNameIDMap = std.StringHashMap(usize).init(self.allocator);

    for (levels.items(), 0..) |lvl, i| {
        switch(lvl) {
            .table => |levelDef| {
                try loadSingleLevelInfo(self, &levelDef, i);
            },
            else => {
                return GameError.BadLevelDefinition;
            },
        }
    }

    // Loading next-level list must be a separated from
    // loadSingleLevelInfo() because TomlZ does not allow we enumerate
    // keys in a table. We have to build a full list of levels so we can
    // try the keys in next-level table.
    const graph2DLen = self.levels.len * self.levels.len;
    self.transitionGraph = try self.allocator.alloc(bool, graph2DLen);
    for (levels.items(), 0..) |lvl, i| {
        switch (lvl) {
            .table => |levelDef| {
                try loadLevelTransition(self, &levelDef, i);
            },
            else => {
                return GameError.BadLevelDefinition;
            },
        }
    }
}

fn loadLevelTransition(self: *LevelLayout, levelDef: *const tomlz.Table, idx: usize) !void {
    self.levels[idx].toNextRequiredSkills = std.AutoHashMap(
        usize,
        std.AutoHashMap(usize, void)
    ).init(self.allocator);

    if (levelDef.getTable("next-level")) |nextLevelPrerequisites| {
        // As tomlz does not provide iterator, we have to use
        // LevelLayout.levelsNameIDMap to enumerate level names.
        var iter = self.levelsNameIDMap.iterator();
        while (iter.next()) |kvp| {
            const toLevelName = kvp.key_ptr.*;
            const toLevelID = kvp.value_ptr.*;

            if (nextLevelPrerequisites.getArray(toLevelName)) |requiredSkills| {
                // Now we see a path btw idx to toLevelID.
                self.transitionGraph[idx * self.levels.len + toLevelID] = true;
                // And record required skills
                var skillset = std.AutoHashMap(usize, void).init(self.allocator);
                for (requiredSkills.items()) |skillName| {
                    switch(skillName) {
                        .string => |skillNameStr| {
                            if (self.skills.get(skillNameStr)) |skillID| {
                                try skillset.put(skillID, {});
                            }
                        },
                        else => {}, // Unknown skills can be ignored now.
                    }
                }
                try self.levels[idx].toNextRequiredSkills.put(toLevelID, skillset);
            }
        }
    }
}

fn loadSingleLevelInfo(self: *LevelLayout, levelDef: *const tomlz.Table, idx: usize) !void {
    // Level ID is required and unique, or we can't build transition
    // graph correctly.
    var idVal = levelDef.getString("id") orelse return GameError.MissingLevelID;
    self.levels[idx].id = try self.allocator.dupeZ(u8, idVal);
    if (self.levelsNameIDMap.contains(self.levels[idx].id)) {
        return GameError.DuplicatedLevelID;
    } else {
        try self.levelsNameIDMap.put(idVal, idx);
    }

    // Below are optional. They have default values.
    self.levels[idx].beginGame = levelDef.getBool("begin") orelse false;
    self.levels[idx].endGame = levelDef.getBool("end") orelse false;

    // Below are optional. They are for readability only.
    var despVal = levelDef.getString("description") orelse "";
    self.levels[idx].description = try self.allocator.dupeZ(u8, despVal);

    // Now, load unlocked skills (players get a new sill when
    // clearing a level), or required skills (player must be unlock a
    // skill before entering a level, or they are very likely to get
    // blocked).
    self.levels[idx].unlockSkills = std.AutoHashMap(usize, void).init(self.allocator);
    if (levelDef.getArray("unlock-skills")) |skillsToAdd| {
        for (skillsToAdd.items()) |skill| {
            switch(skill) {
                .string => |skillName| {
                    if (skillName.len > 0) {
                        if (self.skills.get(skillName)) |skillID| {
                            try self.levels[idx].unlockSkills.put(skillID, {});
                        }
                    }
                    // Empty skill is allowed here. It's for
                    // consistency reason. In general, all empty strings
                    // are ignored.
                },
                else => { return GameError.SkillNameMustBeString; }
            }
        }
    }
}

// Transversal struct represents a transversal path from an entry to an
// end.
const Transversal = struct {
    toBeVisitedLevelStack: std.ArrayList(usize),
    visited: std.StringHashMap(bool), // Mark whether a node is visited.

    const Self = @This();
    pub fn deinit(self: *Self) void {
        self.visited.deinit();
        self.toBeVisitedLevelStack.deinit();
    }

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .toBeVisitedLevelStack = std.ArrayList(usize).init(allocator),
            .visited = std.StringHashMap(bool).init(allocator),
        };
    }

    pub fn visit(self: *Self,
        layout: *const LevelLayout,
        entry: usize) !*TransversalResult {

        return visitImpl(self, layout, entry);
    }
};

fn detectLoopImpl(self: *LevelLayout) !usize {
    var entries: usize = 0;
    _ = entries;
    for (self.levels, 0..) |lvl, id| {
        if (lvl.beginGame) {
            std.debug.print("Begin from {s}\n", .{lvl.id});
            var transversal = Transversal.init(self.allocator);
            defer transversal.deinit();

            const result = try transversal.visit(self, id);
            defer result.deinit();

            for(result.paths().items) |path| {
                if (path.deadEnd()) {
                    // TODO: How to print path?
                    std.debug.print("[deadend]: entry={s}\n",
                        .{lvl.id});
                } else {
                    std.debug.print("[goodpath]: entry={s}\n",
                        .{lvl.id});
                }
            }
        }
    }
    return 0;
}

pub const TransversalResult = struct {
    detectedPaths: std.ArrayList(Path),
    allocator: std.mem.Allocator,

    const Self = @This();
    fn init(allocator: std.mem.Allocator) *Self {
        var obj = allocator.create(Self);
        obj.paths = std.ArrayList(Path).init(allocator);
        obj.allocator = allocator;
        return obj;
    }

    pub fn deinit(self: Self) void {
        for (0..self.detectedPaths.items.len) |i| {
            self.detectedPaths.items[i].deinit();
        }
        self.detectedPaths.deinit();
    }

    pub fn paths(self: *Self) std.ArrayList(Path) {
        return self.detectedPaths;
    }
};

pub const Path = struct {
    // Assumption: Given a direct next level B, a level A should have
    // no more than one exit there. Thus, we just need to mark level ID
    // in track. No need to care about which door it moves to.
    levelTrack: std.ArrayList(usize),
    isDeadEnd: bool,
    hasLoop: bool,

    const Self = @This();
    fn init(allocator: std.mem.Allocator) !*Self {
        return Self{
            .isDeadEnd = false,
            .hasLoop = false,
            .levelTrack = std.ArrayList(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.levelTrack.deinit();
    }

    pub fn deadEnd(self: *const Self) bool {
        return self.isDeadEnd;
    }

    pub fn loop(self: *const Self) bool {
        return self.hasLoop;
    }
};

fn visitImpl(self: *Transversal,
    layout: *const LevelLayout,
    entryID: usize) !*TransversalResult {

    _ = layout;
    _ = self;
    _ = entryID;
    return GameError.NotImplemented;
}
