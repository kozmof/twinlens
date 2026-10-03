const std = @import("std");
const ir = @import("ir.zig");
const wire = @import("wire.zig");
const snapshots = @import("snapshot.zig");
const Index = @import("index.zig").Index;

pub const Filter = struct {
    subject: ?[]const u8 = null,
    metric: ?[]const u8 = null,
    symbol: ?[]const u8 = null,
    relation: ?[]const u8 = null,
    path: ?[]const u8 = null,
    start: ?u32 = null,
    end: ?u32 = null,
    revision: ?[]const u8 = null,
};
/// Owns a validated document and indexes. Query records borrow its strings.
pub const Store = struct {
    parsed: std.json.Parsed(ir.Document),
    allocator: std.mem.Allocator,
    index: Index,

    pub fn decode(allocator: std.mem.Allocator, input: []const u8) !Store {
        const shape = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
        defer shape.deinit();
        if (shape.value == .object and shape.value.object.contains("snapshot_version")) {
            const snapshot = try snapshots.decode(allocator, input);
            defer snapshot.deinit();
            return fromDocument(allocator, snapshot.value.document);
        }
        try wire.validateShape(ir.Document, shape.value);
        const parsed = try std.json.parseFromSlice(ir.Document, allocator, input, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        try ir.validate(allocator, parsed.value);
        const index = try Index.build(allocator, parsed.value);
        return .{ .parsed = parsed, .allocator = allocator, .index = index };
    }
    pub fn fromDocument(allocator: std.mem.Allocator, doc: ir.Document) !Store {
        const bytes = try std.json.Stringify.valueAlloc(allocator, doc, .{});
        defer allocator.free(bytes);
        return decode(allocator, bytes);
    }
    pub fn deinit(self: *Store) void {
        self.index.deinit(self.allocator);
        self.parsed.deinit();
        self.* = undefined;
    }
    pub fn document(self: Store) ir.Document {
        return self.parsed.value;
    }
    pub fn encode(self: Store, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self.document(), .{ .whitespace = .indent_2 });
    }
    fn subjectMatches(self: Store, id: ir.SubjectId, filter: Filter) bool {
        if (filter.subject) |subject| if (!std.mem.eql(u8, id.bytes, subject)) return false;
        if (filter.symbol) |symbol| {
            var matches = false;
            for (self.index.symbols.get(symbol)) |i| if (std.mem.eql(u8, self.document().symbols[i].subject.bytes, id.bytes)) {
                matches = true;
                break;
            };
            if (!matches) return false;
        }
        if (filter.relation) |kind| {
            var matches = false;
            for (self.index.relation_subject.get(id.bytes)) |i| if (std.mem.eql(u8, self.document().relations[i].kind, kind)) {
                matches = true;
                break;
            };
            if (!matches) return false;
        }
        return true;
    }
    fn sourceMatches(source: ir.Source, filter: Filter) bool {
        if (filter.path) |path| if (!std.mem.eql(u8, source.path, path)) return false;
        if (filter.start) |start| if (source.span.end <= start) return false;
        if (filter.end) |end| if (source.span.start >= end) return false;
        return true;
    }
    fn Sort(comptime T: type) type {
        return struct {
            fn less(_: void, a: T, b: T) bool {
                return std.mem.lessThan(u8, a.id.bytes, b.id.bytes);
            }
        };
    }
    pub fn query(self: Store, allocator: std.mem.Allocator, subject: ?[]const u8, metric: ?[]const u8) ![]const ir.Observation {
        return self.queryFiltered(allocator, .{ .subject = subject, .metric = metric });
    }
    pub fn queryFiltered(self: Store, allocator: std.mem.Allocator, filter: Filter) ![]const ir.Observation {
        var found: std.ArrayList(ir.Observation) = .empty;
        errdefer found.deinit(allocator);
        const candidates: ?[]const usize = if (filter.metric) |key| self.index.metrics.get(key) else if (filter.subject) |key| self.index.observation_subject.get(key) else if (filter.path) |key| self.index.sources.get(key) else if (filter.revision) |key| self.index.revisions.get(key) else null;
        const length = if (candidates) |items| items.len else self.document().observations.len;
        for (0..length) |j| {
            const i = if (candidates) |items| items[j] else j;
            const row = self.document().observations[i];
            if (!self.subjectMatches(row.subject, filter) or !sourceMatches(row.source, filter)) continue;
            if (filter.metric) |metric| if (!std.mem.eql(u8, row.metric, metric)) continue;
            if (filter.revision) |revision| if (!std.mem.eql(u8, row.revision, revision)) continue;
            try found.append(allocator, row);
        }
        std.mem.sort(ir.Observation, found.items, {}, Sort(ir.Observation).less);
        return found.toOwnedSlice(allocator);
    }
    pub fn queryRelations(self: Store, allocator: std.mem.Allocator, filter: Filter) ![]const ir.Relation {
        var found: std.ArrayList(ir.Relation) = .empty;
        errdefer found.deinit(allocator);
        const candidates: ?[]const usize = if (filter.relation) |kind| self.index.relation_kinds.get(kind) else if (filter.subject) |id| self.index.relation_subject.get(id) else null;
        const length = if (candidates) |items| items.len else self.document().relations.len;
        for (0..length) |j| {
            const row = self.document().relations[if (candidates) |items| items[j] else j];
            if (!sourceMatches(row.source, filter)) continue;
            if (filter.revision) |revision| if (!std.mem.eql(u8, row.revision, revision)) continue;
            if (filter.relation) |kind| if (!std.mem.eql(u8, row.kind, kind)) continue;
            var endpoint_filter = filter;
            endpoint_filter.relation = null;
            if (!self.subjectMatches(row.from, endpoint_filter) and !(if (row.target.subject) |id| self.subjectMatches(id, endpoint_filter) else false)) continue;
            try found.append(allocator, row);
        }
        std.mem.sort(ir.Relation, found.items, {}, Sort(ir.Relation).less);
        return found.toOwnedSlice(allocator);
    }
    /// Atomically build a new store. An empty replacement document removes selected files.
    /// Unchanged callers of removed declarations become unresolved until they are rescanned.
    pub fn replaceFiles(self: Store, allocator: std.mem.Allocator, replacement: ir.Document, paths: []const []const u8) !Store {
        try ir.validate(allocator, replacement);
        if (paths.len == 0) return error.NoReplacementFiles;
        var project: ?[]const u8 = null;
        for ([_]ir.Document{ self.document(), replacement }) |doc| for (doc.subjects) |subject| {
            if (project) |name| {
                if (!std.mem.eql(u8, name, subject.key.project)) return error.ProjectMismatch;
            } else project = subject.key.project;
        };
        for (paths) |path| if (!ir.validPath(path)) return error.InvalidSource;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var subjects: std.ArrayList(ir.Subject) = .empty;
        var symbols: std.ArrayList(ir.Symbol) = .empty;
        var observations: std.ArrayList(ir.Observation) = .empty;
        var relations: std.ArrayList(ir.Relation) = .empty;
        var retained: std.StringHashMapUnmanaged(void) = .empty;
        for ([_]ir.Document{ self.document(), replacement }, 0..) |doc, side| for (doc.subjects) |row| {
            if (contains(paths, row.key.path) != (side == 1)) continue;
            try subjects.append(a, row);
            try retained.put(a, row.id.bytes, {});
        };
        for ([_]ir.Document{ self.document(), replacement }, 0..) |doc, side| {
            for (doc.symbols) |row| {
                const subject = findSubject(doc, row.subject) orelse return error.DanglingReference;
                if (contains(paths, subject.key.path) == (side == 1)) try symbols.append(a, row);
            }
            for (doc.observations) |row| {
                if (contains(paths, row.source.path) != (side == 1) or !retained.contains(row.subject.bytes)) continue;
                var next = row;
                next.revision = replacement.revision;
                next.id = try ir.observationId(a, next);
                try observations.append(a, next);
            }
            for (doc.relations) |row| {
                if (contains(paths, row.source.path) != (side == 1) or !retained.contains(row.from.bytes)) continue;
                var next = row;
                if (next.target.subject) |id| if (!retained.contains(id.bytes)) {
                    next.target = .{ .status = .unresolved, .subject = null, .reason = "Target removed by file update; caller requires rescan" };
                };
                next.revision = replacement.revision;
                next.id = try ir.relationId(a, next);
                // Several removed targets can collapse to one unresolved semantic edge.
                var duplicate = false;
                for (relations.items) |existing| if (std.mem.eql(u8, existing.id.bytes, next.id.bytes)) {
                    duplicate = true;
                    break;
                };
                if (!duplicate) try relations.append(a, next);
            }
        }
        // Usage and call counts depend on the complete project. Retained observations
        // cannot be certified by a file-only update; never keep stale measured values.
        var partial = false;
        for (subjects.items) |subject| if (!contains(paths, subject.key.path)) {
            partial = true;
            break;
        };
        if (partial) for (observations.items) |*observation| {
            for ([_][]const u8{ "function.callers", "function.callees", "function.calls.unresolved.count", "value.read_count", "value.write_count", "property.read_count", "property.write_count" }) |metric| {
                if (std.mem.eql(u8, metric, observation.metric) and observation.measurement.status == .measured) observation.measurement = .{ .status = .unknown, .value = null, .reason = "Project-wide counts invalidated by partial update; full rescan required" };
            }
        };
        std.mem.sort(ir.Subject, subjects.items, {}, Sort(ir.Subject).less);
        std.mem.sort(ir.Symbol, symbols.items, {}, Sort(ir.Symbol).less);
        std.mem.sort(ir.Observation, observations.items, {}, Sort(ir.Observation).less);
        std.mem.sort(ir.Relation, relations.items, {}, Sort(ir.Relation).less);
        return fromDocument(allocator, .{ .schema_version = 1, .revision = replacement.revision, .subjects = subjects.items, .symbols = symbols.items, .observations = observations.items, .relations = relations.items });
    }
};
fn contains(paths: []const []const u8, path: []const u8) bool {
    for (paths) |item| if (std.mem.eql(u8, item, path)) return true;
    return false;
}
fn findSubject(doc: ir.Document, id: ir.SubjectId) ?ir.Subject {
    for (doc.subjects) |subject| if (std.mem.eql(u8, subject.id.bytes, id.bytes)) return subject;
    return null;
}

test "empty document round trip and strict schema boundary" {
    const allocator = std.testing.allocator;
    const valid = "{\"schema_version\":1,\"revision\":\"r1\",\"subjects\":[],\"symbols\":[],\"observations\":[],\"relations\":[]}";
    var store = try Store.decode(allocator, valid);
    defer store.deinit();
    const output = try store.encode(allocator);
    defer allocator.free(output);
    var restored = try Store.decode(allocator, output);
    defer restored.deinit();
    try std.testing.expectEqualStrings("r1", restored.document().revision);
    try std.testing.expectError(error.UnsupportedSchemaVersion, Store.decode(allocator, "{\"schema_version\":2,\"revision\":\"r1\",\"subjects\":[],\"symbols\":[],\"observations\":[],\"relations\":[]}"));
    try std.testing.expectError(error.UnknownField, Store.decode(allocator, "{\"schema_version\":1,\"revision\":\"r1\",\"subjects\":[],\"symbols\":[],\"observations\":[],\"relations\":[],\"ast\":{}}"));
    try std.testing.expectError(error.DuplicateField, Store.decode(allocator, "{\"schema_version\":1,\"schema_version\":1,\"revision\":\"r1\",\"subjects\":[],\"symbols\":[],\"observations\":[],\"relations\":[]}"));
}

fn exerciseOwnership(allocator: std.mem.Allocator) !void {
    var store = blk: {
        const input = try allocator.dupe(u8, "{\"schema_version\":1,\"revision\":\"owned-revision\",\"subjects\":[],\"symbols\":[],\"observations\":[],\"relations\":[]}");
        defer allocator.free(input);
        break :blk try Store.decode(allocator, input);
    };
    defer store.deinit();
    try std.testing.expectEqualStrings("owned-revision", store.document().revision);
    const output = try store.encode(allocator);
    defer allocator.free(output);
    const observations = try store.query(allocator, null, null);
    defer allocator.free(observations);
    try std.testing.expectEqual(@as(usize, 0), observations.len);
}

test "store owns input and releases partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseOwnership, .{});
}

fn exerciseIndexedLifecycle(allocator: std.mem.Allocator, input: []const u8) !void {
    var store = try Store.decode(allocator, input);
    defer store.deinit();
    const observations = try store.queryFiltered(allocator, .{ .symbol = "f", .metric = "function.args.count", .path = "a.ts" });
    defer allocator.free(observations);
    try std.testing.expectEqual(@as(usize, 1), observations.len);
    const relations = try store.queryRelations(allocator, .{ .relation = "calls" });
    defer allocator.free(relations);
    try std.testing.expectEqual(@as(usize, 1), relations.len);
    var updated = try store.replaceFiles(allocator, store.document(), &.{"a.ts"});
    defer updated.deinit();
    try std.testing.expectEqual(@as(usize, 1), updated.document().observations.len);
    const snapshot = snapshots.Snapshot{
        .snapshot_version = 1,
        .project = "test",
        .configuration = .{ .adapter = "test", .compiler = "test", .options_sha256 = "0" ** 64, .configs = &.{} },
        .files = &.{.{ .path = "a.ts", .sha256 = "0" ** 64 }},
        .diagnostics = &.{},
        .coverage = .{ .unresolved_calls = 0, .unresolved_accesses = 0 },
        .document = store.document(),
    };
    var result = try @import("diff.zig").compare(allocator, snapshot, snapshot);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.report.observations.changed.len);
}

test "indexes, file updates, and diffs release allocations on every failure path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key: ir.SubjectKey = .{ .project = "test", .language = "typescript", .path = "a.ts", .kind = "function", .name = "f", .discriminator = "0" };
    const id = try key.id(a);
    const source: ir.Source = .{ .path = "a.ts", .language = "typescript", .span = .{ .start = 0, .end = 10 }, .producer = "test", .confidence = .high };
    var observation: ir.Observation = .{ .id = undefined, .subject = id, .metric = "function.args.count", .measurement = .{ .status = .measured, .value = 0, .reason = null }, .source = source, .revision = "r1" };
    observation.id = try ir.observationId(a, observation);
    var relation: ir.Relation = .{ .id = undefined, .from = id, .kind = "calls", .target = .{ .status = .resolved, .subject = id, .reason = null }, .source = source, .revision = "r1" };
    relation.id = try ir.relationId(a, relation);
    const doc: ir.Document = .{ .schema_version = 1, .revision = "r1", .subjects = &.{.{ .id = id, .key = key, .source = source }}, .symbols = &.{.{ .id = try ir.symbolId(a, id), .subject = id, .name = "f" }}, .observations = &.{observation}, .relations = &.{relation} };
    const bytes = try std.json.Stringify.valueAlloc(a, doc, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseIndexedLifecycle, .{bytes});
}
