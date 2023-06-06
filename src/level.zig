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
    unlockableSkills: std.AutoHashMap(usize, void),
    toNextRequiredSkills: std.AutoHashMap(usize, std.AutoHashMap(usize, void)),

    const Self = @This();
    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        self.unlockableSkills.deinit();

        var iter = self.toNextRequiredSkills.iterator();
        while (iter.next()) |kvp| {
            kvp.value_ptr.deinit();
        }
        self.toNextRequiredSkills.deinit();
    }
};

pub const GameDef = struct {
    version: i64,
    skills: std.StringHashMap(usize),
    levels: []LevelInfo,
    levelsNameIDMap: std.StringHashMap(usize),
    transitionGraph: []bool, // 2D array for transition
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn initFromTOML(allocator: std.mem.Allocator,
                    tomlContent: []const u8) !GameDef
    {
        return initFromTOMLImpl(allocator, tomlContent);
    }

    pub fn deinit(self: *Self) void {
        self.skills.deinit();
        for (0..self.levels.len) |i| {
            self.levels[i].deinit(self.allocator);
        }
        self.allocator.free(self.levels);
        self.levelsNameIDMap.deinit();
        self.allocator.free(self.transitionGraph);
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

fn initFromTOMLImpl(allocator: std.mem.Allocator,
                    tomlContent: []const u8) !GameDef {

    var table = try tomlz.parse(allocator, tomlContent);
    defer table.deinit(allocator);

    var gamedef = GameDef {
        .version = undefined,
        .skills = undefined,
        .levels = undefined,
        .levelsNameIDMap = undefined,
        .transitionGraph = undefined,
        .allocator = allocator,
    };
    try loadBasicInfo(&gamedef, &table);
    try loadLevels(&gamedef, &table);
    return gamedef;
}

fn detectLoopImpl(self: *GameDef) !usize {
    var entries: usize = 0;
    _ = entries;
    for (self.levels, 0..) |lvl, id| {
        if (lvl.beginGame) {
            std.debug.print("Begin from {s}\n", .{lvl.id});
            var transversal = Traversal.init(self.allocator);
            defer transversal.deinit();

            var result = try transversal.visit(self, id);
            defer result.deinit();

            for(result.paths().items) |path| {
                if (path.deadEnd()) {
                    std.debug.print("[deadend]: ", .{});
                } else {
                    std.debug.print("[goodpath]: ", .{});
                }
                std.debug.print("entry = {s}, track = ", .{lvl.id});

                for(path.track()) |eachLvl| {
                    std.debug.print("{s} -> ", .{self.levels[eachLvl].id});
                }
                std.debug.print("-> [done]\n", .{});
            }
        }
    }
    return 0;
}

fn loadBasicInfo(self: *GameDef, table: *tomlz.Table) !void {
    const lpath = table.getTable("lpath") orelse {
        return GameError.MissingLPathSection;
    };
    self.version = lpath.getInteger("version") orelse 1;
    if (self.version != 1) {
        return GameError.UnsupportedVersion;
    }

    try loadSkills(self, &lpath);
}

fn loadSkills(self: *GameDef, toplevel: *const tomlz.Table) !void {
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

fn loadLevels(self: *GameDef, table: *const tomlz.Table) !void {
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

fn loadLevelTransition(self: *GameDef, levelDef: *const tomlz.Table, idx: usize) !void {
    self.levels[idx].toNextRequiredSkills = std.AutoHashMap(
        usize,
        std.AutoHashMap(usize, void)
    ).init(self.allocator);

    if (levelDef.getTable("next-level")) |nextLevelPrerequisites| {
        // As tomlz does not provide iterator, we have to use
        // GameDef.levelsNameIDMap to enumerate level names.
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

fn loadSingleLevelInfo(self: *GameDef, levelDef: *const tomlz.Table, idx: usize) !void {
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
    self.levels[idx].unlockableSkills = std.AutoHashMap(usize, void).init(self.allocator);
    if (levelDef.getArray("unlock-skills")) |skillsToAdd| {
        for (skillsToAdd.items()) |skill| {
            switch(skill) {
                .string => |skillName| {
                    if (skillName.len > 0) {
                        if (self.skills.get(skillName)) |skillID| {
                            try self.levels[idx].unlockableSkills.put(skillID, {});
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

// ==================================================================
// Traversal support objects.
// ==================================================================

// Traversal struct represents a transversal path from an entry to an
// end.
const Traversal = struct {
    visitStack: std.ArrayList(Path),
    visited: std.StringHashMap(bool), // Mark whether a node is visited.
    allocator: std.mem.Allocator,

    const Self = @This();
    pub fn deinit(self: *Self) void {
        self.visited.deinit();
        self.visitStack.deinit();
    }

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self {
            .visitStack = std.ArrayList(Path).init(allocator),
            .visited = std.StringHashMap(bool).init(allocator),
            .allocator = allocator, // For creating TraversalResult.
        };
    }

    pub fn visit(self: *Self,
        gamedef: *const GameDef,
        entry: usize) !TraversalResult {

        return visitImpl(self, gamedef, entry);
    }
};

pub const TraversalResult = struct {
    detectedPaths: std.ArrayList(Path),

    const Self = @This();
    fn init(allocator: std.mem.Allocator) Self {
        return Self {
            .detectedPaths = std.ArrayList(Path).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (0..self.detectedPaths.items.len) |i| {
            self.detectedPaths.items[i].deinit();
        }
        self.detectedPaths.deinit();
    }

    pub fn paths(self: *const Self) std.ArrayList(Path) {
        return self.detectedPaths;
    }
};

pub const Path = struct {
    // Assumption: Given a direct next level B, a level A should have
    // no more than one exit there. Thus, we just need to mark level ID
    // in track. No need to care about which door it moves to.
    levelTrack: std.ArrayList(usize),
    unlockedSkills: std.AutoHashMap(usize, void),
    isFinished: bool,
    isDeadEnd: bool,
    hasLoop: bool,

    const Self = @This();
    fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .isFinished = false,
            .isDeadEnd = false,
            .hasLoop = false,
            .levelTrack = std.ArrayList(usize).init(allocator),
            .unlockedSkills = std.AutoHashMap(usize, void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.levelTrack.deinit();
        self.unlockedSkills.deinit();
    }

    pub fn deadEnd(self: *const Self) bool {
        return self.isDeadEnd;
    }

    pub fn loop(self: *const Self) bool {
        return self.hasLoop;
    }

    pub fn finished(self: *const Self) bool {
        return self.isFinished;
    }

    pub fn track(self: *const Self) []usize {
        return self.levelTrack.items;
    }
};

fn visitImpl(self: *Traversal,
    gamedef: *const GameDef,
    entryID: usize) !TraversalResult {


    var result = TraversalResult.init(self.allocator);

    self.visitStack.clearAndFree();
    try self.visitStack.append(Path.init(self.allocator));
    try self.visitStack.items[self.visitStack.items.len-1].levelTrack.append(entryID);

    var currentPath: Path = undefined;
    while (self.visitStack.items.len > 0) {
        std.debug.print("new loop: {}\n", .{self.visitStack.items.len});
        currentPath = self.visitStack.pop();
        var stopTrackingCurrentPath: bool = false;
        while (!stopTrackingCurrentPath) {
            var currentLevelID = currentPath.levelTrack.items[currentPath.levelTrack.items.len-1];
            std.debug.print("tracking: {}\n", .{currentLevelID});
            printPath(&currentPath);

            if (gamedef.levels[currentLevelID].endGame) {
                // We reached an end-game. One path finished.
                currentPath.isFinished = true;
                currentPath.isDeadEnd = false;
                try result.detectedPaths.append(currentPath);
                stopTrackingCurrentPath = true;
                std.debug.print("endgame: {}, {}\n", .{currentLevelID, self.visitStack.items.len});
                printPath(&currentPath);
                continue;
            }

            // If it's not end-game, let's see how many branches we can
            // get. Note we expect at least one next step found. If
            // nothing found, it means it's a dead-end.

            // Update unlocked skills in this level.
            var si = gamedef.levels[currentLevelID].unlockableSkills.iterator();
            while (si.next()) |kvp| {
                const skillToUnlockID = (kvp.key_ptr).*;
                if (!currentPath.unlockedSkills.contains(skillToUnlockID)) {
                    try currentPath.unlockedSkills.put(skillToUnlockID, {});
                }
            }
            // Decide next level to go. A successful move happens only
            // when a) an exit exists, and b) all required skills have
            // been unlocked.
            var nextStepBranches: usize = 0;
            var li = gamedef.levels[currentLevelID].toNextRequiredSkills.iterator();
            while (li.next()) |kvp| {
                var nextLevelID: usize = (kvp.key_ptr).*;
                var skillsRequiredToNextLevel: *const std.AutoHashMap(usize, void) = kvp.value_ptr;
                if (allSkillMatched(skillsRequiredToNextLevel, &currentPath.unlockedSkills)) {
                    if (nextStepBranches == 0) {
                        try currentPath.levelTrack.append(nextLevelID);
                        try self.visitStack.append(currentPath);
                        nextStepBranches += 1;
                        std.debug.print("branch1: {}, {}\n", .{currentLevelID, nextLevelID});
                    } else {
                        // There's a new branch here.
                        // Let's keep it in stack. Note that given we
                        // use stack here, we apply a deep-first search.
                        var newBranchPath = Path.init(self.allocator);
                        try clonePath(&currentPath, &newBranchPath);
                        // Remove level added on nextStepBranches == 0
                        _ = newBranchPath.levelTrack.pop();
                        try newBranchPath.levelTrack.append(nextLevelID);
                        try self.visitStack.append(newBranchPath);
                        nextStepBranches += 1;
                        std.debug.print("branch2: {}, {}\n", .{currentLevelID, nextLevelID});
                        printPath(&currentPath);
                    }
                }
            }

            if (nextStepBranches == 0) {
                // It's not end-game, while all next level can't reach
                // over. It means there something wrong in game
                // settings.
                currentPath.isDeadEnd = true;
                currentPath.isFinished = false;
                try result.detectedPaths.append(currentPath);
                _ = self.visitStack.pop();
                stopTrackingCurrentPath = true;
            }
        }
    }
    return result;
}

fn allSkillMatched(required: *const std.AutoHashMap(usize, void),
                   unlocked: *const std.AutoHashMap(usize, void)) bool {

    var iter = required.iterator();
    while (iter.next()) |kvp| {
        const skillID = (kvp.key_ptr).*;
        if (!unlocked.contains(skillID)) {
            return false;
        }
    }
    return true;
}

fn clonePath(fromPath: *const Path, toPath: *Path) !void {
    toPath.levelTrack = try fromPath.levelTrack.clone();
    toPath.unlockedSkills = try fromPath.unlockedSkills.clone();
    toPath.isDeadEnd = fromPath.isDeadEnd;
    toPath.hasLoop = fromPath.hasLoop;
}

fn printPath(path: *const Path) void {
    for (path.levelTrack.items) |id| {
        std.debug.print("{} -> ", .{id});
    }
    std.debug.print("\n", .{});
}
