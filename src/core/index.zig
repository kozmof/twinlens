const std = @import("std");
const ir = @import("ir.zig");
pub const MultiIndex = struct {
    map: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty,
    pub fn deinit(self: *MultiIndex, allocator: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.map.deinit(allocator);
    }
    pub fn add(self: *MultiIndex, allocator: std.mem.Allocator, key: []const u8, index: usize) !void {
        const entry = try self.map.getOrPut(allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, index);
    }
    pub fn get(self: MultiIndex, key: []const u8) []const usize {
        return if (self.map.get(key)) |list| list.items else &.{};
    }
};
pub const Index = struct {
    subjects: std.StringHashMapUnmanaged(usize) = .empty,
    symbols: MultiIndex = .{},
    observation_subject: MultiIndex = .{},
    metrics: MultiIndex = .{},
    sources: MultiIndex = .{},
    revisions: MultiIndex = .{},
    relation_kinds: MultiIndex = .{},
    relation_subject: MultiIndex = .{},
    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        self.subjects.deinit(allocator);
        inline for (.{ "symbols", "observation_subject", "metrics", "sources", "revisions", "relation_kinds", "relation_subject" }) |field| @field(self, field).deinit(allocator);
    }
    pub fn build(allocator: std.mem.Allocator, doc: ir.Document) !Index {
        var index: Index = .{};
        errdefer index.deinit(allocator);
        for (doc.subjects, 0..) |row, i| try index.subjects.put(allocator, row.id.bytes, i);
        for (doc.symbols, 0..) |row, i| {
            try index.symbols.add(allocator, row.id.bytes, i);
            try index.symbols.add(allocator, row.name, i);
        }
        for (doc.observations, 0..) |row, i| {
            try index.observation_subject.add(allocator, row.subject.bytes, i);
            try index.metrics.add(allocator, row.metric, i);
            try index.sources.add(allocator, row.source.path, i);
            try index.revisions.add(allocator, row.revision, i);
        }
        for (doc.relations, 0..) |row, i| {
            try index.relation_kinds.add(allocator, row.kind, i);
            try index.relation_subject.add(allocator, row.from.bytes, i);
            if (row.target.subject) |id| if (!std.mem.eql(u8, id.bytes, row.from.bytes)) {
                try index.relation_subject.add(allocator, id.bytes, i);
            };
        }
        return index;
    }
};
