const std = @import("std");
const ir = @import("ir.zig");
const snapshot = @import("snapshot.zig");
pub fn Changes(comptime T: type) type {
    return struct { added: []const T, removed: []const T, changed: []const struct { before: T, after: T } };
}
pub const Report = struct {
    diff_version: u32 = 1,
    project: []const u8,
    from_revision: []const u8,
    to_revision: []const u8,
    configuration_changed: bool,
    files: Changes(snapshot.FileDigest),
    subjects: Changes(ir.Subject),
    symbols: Changes(ir.Symbol),
    observations: Changes(ir.Observation),
    relations: Changes(ir.Relation),
};
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    report: Report,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};
fn key(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const T = @TypeOf(value);
    if (T == snapshot.FileDigest) return value.path;
    if (T == ir.Observation) {
        var copy = value;
        copy.revision = "";
        return (try ir.observationId(allocator, copy)).bytes;
    }
    if (T == ir.Relation) {
        var copy = value;
        copy.revision = "";
        return (try ir.relationId(allocator, copy)).bytes;
    }
    return value.id.bytes;
}
fn content(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const T = @TypeOf(value);
    if (T == ir.Observation) return std.json.Stringify.valueAlloc(allocator, .{ value.subject, value.metric, value.measurement, value.source }, .{});
    if (T == ir.Relation) return std.json.Stringify.valueAlloc(allocator, .{ value.from, value.kind, value.target, value.source }, .{});
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}
fn compareRows(comptime T: type, a: std.mem.Allocator, before: []const T, after: []const T) !Changes(T) {
    const Row = struct { key: []const u8, value: T };
    const Sort = struct {
        fn less(_: void, x: Row, y: Row) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    };
    const left = try a.alloc(Row, before.len);
    for (before, left) |item, *row| row.* = .{ .key = try key(a, item), .value = item };
    const right = try a.alloc(Row, after.len);
    for (after, right) |item, *row| row.* = .{ .key = try key(a, item), .value = item };
    std.mem.sort(Row, left, {}, Sort.less);
    std.mem.sort(Row, right, {}, Sort.less);
    var added: std.ArrayList(T) = .empty;
    var removed: std.ArrayList(T) = .empty;
    var changed: std.ArrayList(std.meta.Child(@FieldType(Changes(T), "changed"))) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len or j < right.len) {
        if (i == left.len) {
            try added.append(a, right[j].value);
            j += 1;
            continue;
        }
        if (j == right.len) {
            try removed.append(a, left[i].value);
            i += 1;
            continue;
        }
        switch (std.mem.order(u8, left[i].key, right[j].key)) {
            .lt => {
                try removed.append(a, left[i].value);
                i += 1;
            },
            .gt => {
                try added.append(a, right[j].value);
                j += 1;
            },
            .eq => {
                if (!std.mem.eql(u8, try content(a, left[i].value), try content(a, right[j].value))) try changed.append(a, .{ .before = left[i].value, .after = right[j].value });
                i += 1;
                j += 1;
            },
        }
    }
    return .{ .added = added.items, .removed = removed.items, .changed = changed.items };
}
pub fn compare(allocator: std.mem.Allocator, before: snapshot.Snapshot, after: snapshot.Snapshot) !Result {
    if (!std.mem.eql(u8, before.project, after.project)) return error.ProjectMismatch;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const report: Report = .{
        .project = before.project,
        .from_revision = before.document.revision,
        .to_revision = after.document.revision,
        .configuration_changed = !std.mem.eql(u8, try content(a, before.configuration), try content(a, after.configuration)),
        .files = try compareRows(snapshot.FileDigest, a, before.files, after.files),
        .subjects = try compareRows(ir.Subject, a, before.document.subjects, after.document.subjects),
        .symbols = try compareRows(ir.Symbol, a, before.document.symbols, after.document.symbols),
        .observations = try compareRows(ir.Observation, a, before.document.observations, after.document.observations),
        .relations = try compareRows(ir.Relation, a, before.document.relations, after.document.relations),
    };
    return .{ .arena = arena, .report = report };
}
