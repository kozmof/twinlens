const std = @import("std");
pub const identity = @import("identity.zig");
pub const SubjectId = identity.SubjectId;
pub const SymbolId = identity.SymbolId;
pub const ObservationId = identity.ObservationId;
pub const RelationId = identity.RelationId;

pub const Source = struct {
    path: []const u8,
    language: []const u8,
    span: struct { start: u32, end: u32 },
    producer: []const u8,
    confidence: enum { high, medium, low },
};
pub const SubjectKey = struct {
    project: []const u8,
    language: []const u8,
    path: []const u8,
    kind: []const u8,
    name: []const u8,
    discriminator: []const u8,

    pub fn id(self: SubjectKey, allocator: std.mem.Allocator) !SubjectId {
        return identity.make(allocator, SubjectId, "sub_", &.{ "subject", self.project, self.language, self.path, self.kind, self.name, self.discriminator });
    }
};
pub const Subject = struct { id: SubjectId, key: SubjectKey, source: Source };
pub const Symbol = struct { id: SymbolId, subject: SubjectId, name: []const u8 };
pub const Measurement = struct {
    status: enum { measured, unknown, unsupported },
    value: ?f64,
    reason: ?[]const u8,
};
pub const Observation = struct {
    id: ObservationId,
    subject: SubjectId,
    metric: []const u8,
    measurement: Measurement,
    source: Source,
    revision: []const u8,
};
pub const RelationTarget = struct {
    status: enum { resolved, unresolved },
    subject: ?SubjectId,
    reason: ?[]const u8,
};
pub const Relation = struct {
    id: RelationId,
    from: SubjectId,
    kind: []const u8,
    target: RelationTarget,
    source: Source,
    revision: []const u8,
};
pub const Document = struct {
    schema_version: u32,
    revision: []const u8,
    subjects: []const Subject,
    symbols: []const Symbol,
    observations: []const Observation,
    relations: []const Relation,
};

pub fn symbolId(allocator: std.mem.Allocator, subject: SubjectId) !SymbolId {
    return identity.make(allocator, SymbolId, "sym_", &.{ "symbol", subject.bytes });
}
pub fn observationId(allocator: std.mem.Allocator, observation: Observation) !ObservationId {
    return identity.make(allocator, ObservationId, "obs_", &.{ "observation", observation.revision, observation.subject.bytes, observation.metric, observation.source.producer });
}
pub fn relationId(allocator: std.mem.Allocator, relation: Relation) !RelationId {
    return identity.make(allocator, RelationId, "rel_", &.{ "relation", relation.revision, relation.from.bytes, relation.kind, @tagName(relation.target.status), if (relation.target.subject) |id| id.bytes else relation.target.reason orelse "", relation.source.producer });
}

pub fn nonempty(value: []const u8) bool {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |c| if (c < 32 or c == 127) return false;
    return true;
}
pub fn validPath(path: []const u8) bool {
    if (!nonempty(path) or std.mem.indexOfAny(u8, path, "\\:") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}
fn validateSource(source: Source) !void {
    if (!validPath(source.path) or !nonempty(source.language) or !nonempty(source.producer) or source.span.end < source.span.start) return error.InvalidSource;
}
fn equalId(allocator: std.mem.Allocator, actual: anytype, expected: @TypeOf(actual)) !void {
    defer allocator.free(expected.bytes);
    if (!std.mem.eql(u8, actual.bytes, expected.bytes)) return error.IdentityMismatch;
}
fn insertId(allocator: std.mem.Allocator, ids: *std.StringHashMapUnmanaged(void), id: []const u8) !void {
    const entry = try ids.getOrPut(allocator, id);
    if (entry.found_existing) return error.DuplicateId;
}

/// Validation happens before a document is admitted to the core store.
pub fn validate(allocator: std.mem.Allocator, doc: Document) !void {
    if (doc.schema_version != 1) return error.UnsupportedSchemaVersion;
    if (!nonempty(doc.revision)) return error.InvalidRevision;
    var subjects: std.StringHashMapUnmanaged(void) = .empty;
    defer subjects.deinit(allocator);
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(allocator);
    for (doc.subjects) |subject| {
        const key = subject.key;
        if (!nonempty(key.project) or !nonempty(key.language) or !validPath(key.path) or !nonempty(key.kind) or !nonempty(key.name) or !nonempty(key.discriminator)) return error.InvalidSubjectKey;
        try validateSource(subject.source);
        if (!std.mem.eql(u8, key.path, subject.source.path) or !std.mem.eql(u8, key.language, subject.source.language)) return error.SourceMismatch;
        try equalId(allocator, subject.id, try key.id(allocator));
        try insertId(allocator, &subjects, subject.id.bytes);
    }
    for (doc.symbols) |symbol| {
        if (!subjects.contains(symbol.subject.bytes)) return error.DanglingReference;
        if (!nonempty(symbol.name)) return error.InvalidSymbol;
        try equalId(allocator, symbol.id, try symbolId(allocator, symbol.subject));
        try insertId(allocator, &ids, symbol.id.bytes);
    }
    for (doc.observations) |observation| {
        if (!subjects.contains(observation.subject.bytes)) return error.DanglingReference;
        if (!nonempty(observation.metric)) return error.InvalidMetric;
        if (!std.mem.eql(u8, doc.revision, observation.revision)) return error.RevisionMismatch;
        try validateSource(observation.source);
        const measurement = observation.measurement;
        switch (measurement.status) {
            .measured => if (measurement.value == null or !std.math.isFinite(measurement.value.?) or measurement.reason != null) return error.InvalidMeasurement,
            .unknown, .unsupported => if (measurement.value != null or measurement.reason == null or !nonempty(measurement.reason.?)) return error.InvalidMeasurement,
        }
        try equalId(allocator, observation.id, try observationId(allocator, observation));
        try insertId(allocator, &ids, observation.id.bytes);
    }
    for (doc.relations) |relation| {
        if (!subjects.contains(relation.from.bytes)) return error.DanglingReference;
        if (!nonempty(relation.kind)) return error.InvalidRelation;
        if (!std.mem.eql(u8, doc.revision, relation.revision)) return error.RevisionMismatch;
        try validateSource(relation.source);
        switch (relation.target.status) {
            .resolved => {
                if (relation.target.subject == null or relation.target.reason != null) return error.InvalidRelationTarget;
                if (!subjects.contains(relation.target.subject.?.bytes)) return error.DanglingReference;
            },
            .unresolved => if (relation.target.subject != null or relation.target.reason == null or !nonempty(relation.target.reason.?)) return error.InvalidRelationTarget,
        }
        try equalId(allocator, relation.id, try relationId(allocator, relation));
        try insertId(allocator, &ids, relation.id.bytes);
    }
}

test "canonical source paths" {
    try std.testing.expect(validPath("src/café.ts"));
    for ([_][]const u8{ "", "/a", "a/../b", "./a", "a//b", "a/", "C:/a", "a\\b" }) |path| {
        try std.testing.expect(!validPath(path));
    }
}
