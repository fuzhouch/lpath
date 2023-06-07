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

// LevelInfo represents static information of a given stage. It's a
// support data structure to help transition logic design whether player
// can move to next stage.
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
    stages: []LevelInfo,
    stagesNameIDMap: std.StringHashMap(usize),
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
        for (0..self.stages.len) |i| {
            self.stages[i].deinit(self.allocator);
        }
        self.allocator.free(self.stages);
        self.stagesNameIDMap.deinit();
        self.allocator.free(self.transitionGraph);
    }

    pub fn printInfo(self: *Self) void {
        for (0..self.stages.len) |i| {
            std.debug.print("{} = {s}\n", .{i, self.stages[i].id});
        }

        const dim: usize = self.stages.len;
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

    pub fn analyzePath(self: *Self) !usize {
        return analyzePathImpl(self);
    }
};

fn initFromTOMLImpl(allocator: std.mem.Allocator,
                    tomlContent: []const u8) !GameDef {

    var table = try tomlz.parse(allocator, tomlContent);
    defer table.deinit(allocator);

    var gamedef = GameDef {
        .version = undefined,
        .skills = undefined,
        .stages = undefined,
        .stagesNameIDMap = undefined,
        .transitionGraph = undefined,
        .allocator = allocator,
    };
    try loadBasicInfo(&gamedef, &table);
    try loadLevels(&gamedef, &table);
    return gamedef;
}

fn analyzePathImpl(self: *GameDef) !usize {
    var entries: usize = 0;
    _ = entries;
    for (self.stages, 0..) |lvl, id| {
        if (lvl.beginGame) {
            std.debug.print("Begin from {s}\n", .{lvl.id});
            var transversal = Traversal.init(self.allocator);
            defer transversal.deinit();

            var result = try transversal.visit(self, id);
            defer result.deinit();

            for(result.paths().items) |path| {
                if (path.deadEnd()) {
                    std.debug.print("[dead]: ", .{});
                } else if (path.loop()) {
                    std.debug.print("[loop]: ", .{});
                } else {
                    std.debug.print("[good]: ", .{});
                }
                std.debug.print("entry = {s}, track = ", .{lvl.id});

                for(path.track()) |eachLvl| {
                    std.debug.print("{s} => ", .{self.stages[eachLvl].id});
                }
                std.debug.print("[done]\n", .{});
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

fn loadSkills(self: *GameDef, topstage: *const tomlz.Table) !void {
    self.skills = std.StringHashMap(usize).init(self.allocator);

    var skillList = topstage.getArray("skills");
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
    const stages = table.getArray("stages") orelse {
        return GameError.NoLevelDefined;
    };
    const stageCount: usize = stages.items().len;
    const graphCount: usize = stageCount * stageCount;
    _ = graphCount;

    self.stages = try self.allocator.alloc(LevelInfo, stageCount);
    self.stagesNameIDMap = std.StringHashMap(usize).init(self.allocator);

    for (stages.items(), 0..) |lvl, i| {
        switch(lvl) {
            .table => |stageDef| {
                try loadSingleLevelInfo(self, &stageDef, i);
            },
            else => {
                return GameError.BadLevelDefinition;
            },
        }
    }

    // Loading next-stage list must be a separated from
    // loadSingleLevelInfo() because TomlZ does not allow we enumerate
    // keys in a table. We have to build a full list of stages so we can
    // try the keys in next-stage table.
    const graph2DLen = self.stages.len * self.stages.len;
    self.transitionGraph = try self.allocator.alloc(bool, graph2DLen);
    for (stages.items(), 0..) |lvl, i| {
        switch (lvl) {
            .table => |stageDef| {
                try loadLevelTransition(self, &stageDef, i);
            },
            else => {
                return GameError.BadLevelDefinition;
            },
        }
    }
}

fn loadLevelTransition(self: *GameDef, stageDef: *const tomlz.Table, idx: usize) !void {
    self.stages[idx].toNextRequiredSkills = std.AutoHashMap(
        usize,
        std.AutoHashMap(usize, void)
    ).init(self.allocator);

    if (stageDef.getTable("next-stage")) |nextLevelPrerequisites| {
        // As tomlz does not provide iterator, we have to use
        // GameDef.stagesNameIDMap to enumerate stage names.
        var iter = self.stagesNameIDMap.iterator();
        while (iter.next()) |kvp| {
            const toLevelName = kvp.key_ptr.*;
            const toLevelID = kvp.value_ptr.*;

            if (nextLevelPrerequisites.getArray(toLevelName)) |requiredSkills| {
                // Now we see a path btw idx to toLevelID.
                self.transitionGraph[idx * self.stages.len + toLevelID] = true;
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
                try self.stages[idx].toNextRequiredSkills.put(toLevelID, skillset);
            }
        }
    }
}

fn loadSingleLevelInfo(self: *GameDef, stageDef: *const tomlz.Table, idx: usize) !void {
    // Level ID is required and unique, or we can't build transition
    // graph correctly.
    var idVal = stageDef.getString("id") orelse return GameError.MissingLevelID;
    self.stages[idx].id = try self.allocator.dupeZ(u8, idVal);
    if (self.stagesNameIDMap.contains(self.stages[idx].id)) {
        return GameError.DuplicatedLevelID;
    } else {
        try self.stagesNameIDMap.put(idVal, idx);
    }

    // Below are optional. They have default values.
    self.stages[idx].beginGame = stageDef.getBool("begin") orelse false;
    self.stages[idx].endGame = stageDef.getBool("end") orelse false;

    // Below are optional. They are for readability only.
    var despVal = stageDef.getString("description") orelse "";
    self.stages[idx].description = try self.allocator.dupeZ(u8, despVal);

    // Now, load unlocked skills (players get a new sill when
    // clearing a stage), or required skills (player must be unlock a
    // skill before entering a stage, or they are very likely to get
    // blocked).
    self.stages[idx].unlockableSkills = std.AutoHashMap(usize, void).init(self.allocator);
    if (stageDef.getArray("unlock-skills")) |skillsToAdd| {
        for (skillsToAdd.items()) |skill| {
            switch(skill) {
                .string => |skillName| {
                    if (skillName.len > 0) {
                        if (self.skills.get(skillName)) |skillID| {
                            try self.stages[idx].unlockableSkills.put(skillID, {});
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
    visitingPath: std.ArrayList(Path),
    allocator: std.mem.Allocator,

    const Self = @This();
    pub fn deinit(self: *Self) void {
        self.visitingPath.deinit();
    }

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self {
            .visitingPath = std.ArrayList(Path).init(allocator),
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
    // Assumption: Given a direct next stage B, a stage A should have
    // no more than one exit there. Thus, we just need to mark stage ID
    // in track. No need to care about which door it moves to.
    stageTrack: std.ArrayList(usize),
    unlockedSkills: std.AutoHashMap(usize, void),
    visited: std.AutoHashMap(usize, void), // For loop detection.
    isFinished: bool,
    isDeadEnd: bool,
    isLoop: bool,

    const Self = @This();
    fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .isFinished = false,
            .isDeadEnd = false,
            .isLoop = false,
            .stageTrack = std.ArrayList(usize).init(allocator),
            .unlockedSkills = std.AutoHashMap(usize, void).init(allocator),
            .visited = std.AutoHashMap(usize, void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stageTrack.deinit();
        self.unlockedSkills.deinit();
        self.visited.deinit();
    }

    pub fn deadEnd(self: *const Self) bool {
        return self.isDeadEnd;
    }

    pub fn loop(self: *const Self) bool {
        return self.isLoop;
    }

    pub fn finished(self: *const Self) bool {
        return self.isFinished;
    }

    pub fn track(self: *const Self) []usize {
        return self.stageTrack.items;
    }
};

fn visitImpl(self: *Traversal, gamedef: *const GameDef, entryID: usize) !TraversalResult {
    var result = TraversalResult.init(self.allocator);
    self.visitingPath.clearAndFree();
    try self.visitingPath.append(Path.init(self.allocator));
    try self.visitingPath.items[self.visitingPath.items.len-1].stageTrack.append(entryID);

    var currentPath: Path = undefined;
    while (self.visitingPath.items.len > 0) {
        currentPath = self.visitingPath.pop();
        var currentLevelID = currentPath.stageTrack.items[currentPath.stageTrack.items.len-1];
        if (!currentPath.visited.contains(currentLevelID)) {
            try currentPath.visited.put(currentLevelID, {});
        } else {
            // A circular path is detected. This path should stop, or we
            // fall into an endless loop.
            currentPath.isFinished = false;
            currentPath.isDeadEnd = false;
            currentPath.isLoop = true;
            try result.detectedPaths.append(currentPath);
            continue;
        }

        if (gamedef.stages[currentLevelID].endGame) {
            // We reached an end-game. One path finished.
            currentPath.isFinished = true;
            currentPath.isDeadEnd = false;
            currentPath.isLoop = false;
            try result.detectedPaths.append(currentPath);
            continue;
        }

        // If it's not end-game, let's see how many branches we can
        // get. Note we expect at least one next step found. If
        // nothing found, it means it's a dead-end.

        // Update unlocked skills in this stage.
        var si = gamedef.stages[currentLevelID].unlockableSkills.iterator();
        while (si.next()) |kvp| {
            const skillToUnlockID = (kvp.key_ptr).*;
            if (!currentPath.unlockedSkills.contains(skillToUnlockID)) {
                try currentPath.unlockedSkills.put(skillToUnlockID, {});
            }
        }
        // Decide next stage to go. A successful move happens only
        // when a) an exit exists, and b) all required skills have
        // been unlocked.
        var nextStepBranches: usize = 0;
        var li = gamedef.stages[currentLevelID].toNextRequiredSkills.iterator();
        while (li.next()) |kvp| {
            var nextLevelID: usize = (kvp.key_ptr).*;
            var skillsRequiredToNextLevel: *const std.AutoHashMap(usize, void) = kvp.value_ptr;
            if (allSkillMatched(skillsRequiredToNextLevel, &currentPath.unlockedSkills)) {
                if (nextStepBranches == 0) {
                    try currentPath.stageTrack.append(nextLevelID);
                    try self.visitingPath.append(currentPath);
                    nextStepBranches += 1;
                } else {
                    // There's a new branch here.
                    // Let's keep it in stack. Note that given we
                    // use stack here, we apply a deep-first search.
                    var newBranchPath = Path.init(self.allocator);
                    try clonePath(&currentPath, &newBranchPath);
                    // Remove next step added on nextStepBranches == 0
                    _ = newBranchPath.stageTrack.pop();
                    // Now add true next stage
                    try newBranchPath.stageTrack.append(nextLevelID);
                    try self.visitingPath.append(newBranchPath);
                    nextStepBranches += 1;
                }
            }
        }

        if (nextStepBranches == 0) {
            // It's not end-game, while all next stage can't reach
            // over. It means there something wrong in game
            // settings.
            currentPath.isFinished = false;
            currentPath.isDeadEnd = true;
            currentPath.isLoop = false;
            try result.detectedPaths.append(currentPath);
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
    toPath.stageTrack = try fromPath.stageTrack.clone();
    toPath.unlockedSkills = try fromPath.unlockedSkills.clone();
    toPath.isDeadEnd = fromPath.isDeadEnd;
    toPath.isLoop = fromPath.isLoop;
}

fn printPath(path: *const Path) void {
    for (path.stageTrack.items) |id| {
        std.debug.print("{} -> ", .{id});
    }
    std.debug.print("\n", .{});
}
