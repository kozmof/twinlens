const std = @import("std");
const ir = @import("ir.zig");
const wire = @import("wire.zig");

/// Owns the parsed document and all strings. No caller-owned JSON or AST survives import.
pub const Store = struct {
    parsed: std.json.Parsed(ir.Document),

    pub fn decode(allocator: std.mem.Allocator, input: []const u8) !Store {
        const shape = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
        defer shape.deinit();
        try wire.validateShape(ir.Document, shape.value);
        const parsed = try std.json.parseFromSlice(ir.Document, allocator, input, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = false,
            .duplicate_field_behavior = .@"error",
        });
        errdefer parsed.deinit();
        try ir.validate(allocator, parsed.value);
        return .{ .parsed = parsed };
    }
    pub fn deinit(self: *Store) void {
        self.parsed.deinit();
        self.* = undefined;
    }
    pub fn document(self: Store) ir.Document {
        return self.parsed.value;
    }
    pub fn encode(self: Store, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self.document(), .{ .whitespace = .indent_2 });
    }
    pub fn query(self: Store, allocator: std.mem.Allocator, subject: ?[]const u8, metric: ?[]const u8) ![]const ir.Observation {
        var found: std.ArrayList(ir.Observation) = .empty;
        errdefer found.deinit(allocator);
        for (self.document().observations) |observation| {
            if (subject) |id| if (!std.mem.eql(u8, id, observation.subject.bytes)) continue;
            if (metric) |name| if (!std.mem.eql(u8, name, observation.metric)) continue;
            try found.append(allocator, observation);
        }
        return found.toOwnedSlice(allocator);
    }
};

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
