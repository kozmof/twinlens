//! Combine independently validated language snapshots in caller-owned storage.
const std = @import("std");
const ir = @import("ir.zig");
const snapshot = @import("snapshot.zig");

fn concat(comptime T: type, a: std.mem.Allocator, left: []const T, right: []const T) ![]T {
    const rows = try a.alloc(T, left.len + right.len);
    @memcpy(rows[0..left.len], left);
    @memcpy(rows[left.len..], right);
    return rows;
}
fn digest(a: std.mem.Allocator, value: anytype) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
    return std.fmt.allocPrint(a, "{x}", .{&sum});
}
/// Returned slices belong to `a`; strings may also borrow from both inputs.
/// Use an arena and retain both input snapshots through serialization.
pub fn combine(a: std.mem.Allocator, left: snapshot.Snapshot, right: snapshot.Snapshot, revision: ?[]const u8) !snapshot.Snapshot {
    try snapshot.validate(a, left);
    try snapshot.validate(a, right);
    if (!std.mem.eql(u8, left.project, right.project)) return error.ProjectMismatch;
    const files = try concat(snapshot.FileDigest, a, left.files, right.files);
    std.mem.sort(snapshot.FileDigest, files, {}, struct {
        fn less(_: void, l: snapshot.FileDigest, r: snapshot.FileDigest) bool {
            return std.mem.lessThan(u8, l.path, r.path);
        }
    }.less);
    var configs: std.ArrayList(snapshot.FileDigest) = .empty;
    for (left.configuration.configs) |c| try configs.append(a, c);
    for (right.configuration.configs) |c| {
        var found = false;
        for (configs.items) |existing| if (std.mem.eql(u8, c.path, existing.path)) {
            if (!std.mem.eql(u8, c.sha256, existing.sha256)) return error.ConfigurationConflict;
            found = true;
            break;
        };
        if (!found) try configs.append(a, c);
    }
    const rev = revision orelse try digest(a, .{ left.document.revision, right.document.revision });
    const observations = try concat(ir.Observation, a, left.document.observations, right.document.observations);
    for (observations) |*o| {
        o.revision = rev;
        o.id = try ir.observationId(a, o.*);
    }
    const relations = try concat(ir.Relation, a, left.document.relations, right.document.relations);
    for (relations) |*r| {
        r.revision = rev;
        r.id = try ir.relationId(a, r.*);
    }
    const subjects = try concat(ir.Subject, a, left.document.subjects, right.document.subjects);
    const symbols = try concat(ir.Symbol, a, left.document.symbols, right.document.symbols);
    inline for (.{ subjects, symbols, observations, relations }) |rows| std.mem.sort(@TypeOf(rows[0]), rows, {}, struct {
        fn less(_: void, l: @TypeOf(rows[0]), r: @TypeOf(rows[0])) bool {
            return std.mem.lessThan(u8, l.id.bytes, r.id.bytes);
        }
    }.less);
    const result: snapshot.Snapshot = .{
        .snapshot_version = 1,
        .project = left.project,
        .configuration = .{
            .adapter = try std.fmt.allocPrint(a, "{s}+{s}", .{ left.configuration.adapter, right.configuration.adapter }),
            .compiler = try std.fmt.allocPrint(a, "{s}+{s}", .{ left.configuration.compiler, right.configuration.compiler }),
            .options_sha256 = try digest(a, .{ left.configuration.options_sha256, right.configuration.options_sha256 }),
            .configs = configs.items,
        },
        .files = files,
        .diagnostics = try concat(snapshot.Diagnostic, a, left.diagnostics, right.diagnostics),
        .coverage = .{ .unresolved_calls = try std.math.add(u32, left.coverage.unresolved_calls, right.coverage.unresolved_calls), .unresolved_accesses = try std.math.add(u32, left.coverage.unresolved_accesses, right.coverage.unresolved_accesses) },
        .document = .{ .schema_version = 1, .revision = rev, .subjects = subjects, .symbols = symbols, .observations = observations, .relations = relations },
    };
    try snapshot.validate(a, result);
    return result;
}

test "merge rejects inventory conflicts and preserves configuration provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zero = "0" ** 64;
    const one = "1" ** 64;
    const left: snapshot.Snapshot = .{
        .snapshot_version = 1,
        .project = "fixture",
        .configuration = .{ .adapter = "a", .compiler = "1", .options_sha256 = zero, .configs = &.{.{ .path = "config.json", .sha256 = zero }} },
        .files = &.{.{ .path = "main.a", .sha256 = zero }},
        .diagnostics = &.{},
        .coverage = .{ .unresolved_calls = 1, .unresolved_accesses = 2 },
        .document = .{ .schema_version = 1, .revision = "a", .subjects = &.{}, .symbols = &.{}, .observations = &.{}, .relations = &.{} },
    };
    var right = left;
    right.files = &.{.{ .path = "main.b", .sha256 = one }};
    right.configuration.adapter = "b";
    right.document.revision = "b";
    const result = try combine(a, left, right, "together");
    try std.testing.expectEqualStrings("together", result.document.revision);
    try std.testing.expectEqualStrings("a+b", result.configuration.adapter);
    try std.testing.expectEqual(@as(usize, 1), result.configuration.configs.len);
    try std.testing.expectEqual(@as(u32, 2), result.coverage.unresolved_calls);
    try std.testing.expectEqual(@as(u32, 4), result.coverage.unresolved_accesses);
    right.project = "other";
    try std.testing.expectError(error.ProjectMismatch, combine(a, left, right, null));
    right.project = "fixture";
    right.configuration.configs = &.{.{ .path = "config.json", .sha256 = one }};
    try std.testing.expectError(error.ConfigurationConflict, combine(a, left, right, null));
    right.configuration.configs = left.configuration.configs;
    right.files = left.files;
    try std.testing.expectError(error.DuplicateFile, combine(a, left, right, null));
    right.files = &.{};
    right.coverage.unresolved_calls = std.math.maxInt(u32);
    try std.testing.expectError(error.Overflow, combine(a, left, right, null));
}
