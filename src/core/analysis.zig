//! Evidence-based hypotheses over language-independent records.
const std = @import("std");
const ir = @import("ir.zig");
const snapshots = @import("snapshot.zig");
const identity = @import("identity.zig");
const Index = @import("index.zig").Index;
const wire = @import("wire.zig");
pub const generator = "bt-analysis/1";
pub const EvidenceId = identity.Id("evd_");
pub const FindingId = identity.Id("fnd_");
pub const ClusterId = identity.Id("clu_");
pub const Status = enum { open, confirmed, false_positive, accepted_risk, fixed, ignored, deferred };
pub const Review = struct { finding: FindingId, status: Status, note: []const u8, revision: []const u8 };
pub const Evidence = struct {
    id: EvidenceId,
    subject: ir.SubjectId,
    kind: enum { cluster, responsibility, caller_significance },
    key: []const u8,
    origin: enum { code, specification, inference, @"test", trace },
    extractor: []const u8,
    confidence: @FieldType(ir.Source, "confidence"),
    observations: []const ir.ObservationId,
    relations: []const ir.RelationId,
    parents: []const EvidenceId,
    sources: []const ir.Source,
    summary: []const u8,
};
pub const Cluster = struct { id: ClusterId, subject: ir.SubjectId, members: []const ir.SubjectId, events: []const ir.SubjectId, evidence: EvidenceId };
pub const Finding = struct {
    id: FindingId,
    subject: ir.SubjectId,
    kind: enum { responsibility_split },
    category: enum { hypothesis, constraint_violation },
    severity: enum { info, warning, @"error" },
    status: Status,
    hypothesis: []const u8,
    evidence: []const EvidenceId,
    generator: []const u8,
    challenges: []const []const u8,
    traces: []const []const u8,
    suggestions: []const []const u8,
    reviewed_revision: ?[]const u8,
};
pub const Significance = struct {
    caller: ir.SubjectId,
    callee: ir.SubjectId,
    relation: ir.RelationId,
    evidence: EvidenceId,
    function_population: u32,
    caller_out_degree: u32,
    callee_in_degree: u32,
    edge_count: u32,
    local_share: f64,
    inverse_prevalence: f64,
    normalization: f64,
    score: f64,
};
pub const Report = struct {
    analysis_version: u32,
    generator: []const u8,
    snapshot: snapshots.Snapshot,
    evidence: []const Evidence,
    clusters: []const Cluster,
    findings: []const Finding,
    significance: []const Significance,
    reviews: []const Review,
};
/// Derived records are arena-owned; snapshot strings borrow the input snapshot.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    report: Report,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn same(a: anytype, b: @TypeOf(a)) bool {
    return eq(a.bytes, b.bytes);
}
fn findSubject(doc: ir.Document, id: ir.SubjectId) ?ir.Subject {
    for (doc.subjects) |s| if (same(s.id, id)) return s;
    return null;
}
fn has(comptime T: type, rows: []const T, id: T) bool {
    for (rows) |r| if (same(r, id)) return true;
    return false;
}
fn appendUnique(comptime T: type, a: std.mem.Allocator, rows: *std.ArrayList(T), id: T) !void {
    if (!has(T, rows.items, id)) try rows.append(a, id);
}
fn sortIds(comptime T: type, rows: []T) void {
    std.mem.sort(T, rows, {}, struct {
        fn less(_: void, l: T, r: T) bool {
            return std.mem.lessThan(u8, l.bytes, r.bytes);
        }
    }.less);
}
fn evidenceId(a: std.mem.Allocator, revision: []const u8, e: Evidence) !EvidenceId {
    return identity.make(a, EvidenceId, "evd_", &.{ "evidence", revision, e.subject.bytes, @tagName(e.kind), e.key });
}
fn findingId(a: std.mem.Allocator, subject: ir.SubjectId) !FindingId {
    return identity.make(a, FindingId, "fnd_", &.{ "finding", generator, subject.bytes, "responsibility_split" });
}
fn clusterId(a: std.mem.Allocator, subject: ir.SubjectId, members: []const ir.SubjectId) !ClusterId {
    const bytes = try std.json.Stringify.valueAlloc(a, members, .{});
    defer a.free(bytes);
    return identity.make(a, ClusterId, "clu_", &.{ "cluster", subject.bytes, bytes });
}
fn flowKind(kind: []const u8) bool {
    return eq(kind, "argument") or eq(kind, "controls") or eq(kind, "returns") or eq(kind, "input");
}
fn root(parents: []usize, i: usize) usize {
    var n = i;
    while (parents[n] != n) n = parents[n];
    return n;
}
const Builder = struct {
    a: std.mem.Allocator,
    doc: ir.Document,
    index: Index,
    evidence: std.ArrayList(Evidence) = .empty,
    clusters: std.ArrayList(Cluster) = .empty,
    findings: std.ArrayList(Finding) = .empty,
    significance: std.ArrayList(Significance) = .empty,
    fn linked(self: Builder, from: ir.SubjectId, kind: []const u8, to: ir.SubjectId) bool {
        for (self.index.relation_subject.get(from.bytes)) |i| {
            const r = self.doc.relations[i];
            if (eq(r.kind, kind) and same(r.from, from) and r.target.subject != null and same(r.target.subject.?, to)) return true;
        }
        return false;
    }
    fn getSubject(self: Builder, id: ir.SubjectId) ir.Subject {
        return self.doc.subjects[self.index.subjects.get(id.bytes).?];
    }
    fn addEvidence(self: *Builder, subject: ir.SubjectId, kind: @FieldType(Evidence, "kind"), key: []const u8, relations: []const ir.RelationId, parents: []const EvidenceId, summary: []const u8) !EvidenceId {
        var observations: std.ArrayList(ir.ObservationId) = .empty;
        var sources: std.ArrayList(ir.Source) = .empty;
        for (self.doc.observations) |o| if (same(o.subject, subject)) {
            try observations.append(self.a, o.id);
            try sources.append(self.a, o.source);
        };
        for (relations) |id| for (self.doc.relations) |r| if (same(id, r.id)) {
            try sources.append(self.a, r.source);
            break;
        };
        if (sources.items.len == 0) try sources.append(self.a, findSubject(self.doc, subject).?.source);
        sortIds(ir.ObservationId, observations.items);
        var e: Evidence = .{ .id = undefined, .subject = subject, .kind = kind, .key = key, .origin = if (kind == .cluster) .code else .inference, .extractor = if (kind == .cluster) findSubject(self.doc, subject).?.source.producer else generator, .confidence = if (kind == .cluster) .medium else .low, .observations = observations.items, .relations = relations, .parents = parents, .sources = sources.items, .summary = summary };
        e.id = try evidenceId(self.a, self.doc.revision, e);
        try self.evidence.append(self.a, e);
        return e.id;
    }
    fn responsibilities(self: *Builder, function: ir.Subject) !void {
        var parameters: std.ArrayList(ir.SubjectId) = .empty;
        for (self.index.relation_subject.get(function.id.bytes)) |i| {
            const r = self.doc.relations[i];
            if (!eq(r.kind, "contains") or !same(r.from, function.id) or r.target.subject == null) continue;
            const s = self.getSubject(r.target.subject.?);
            if (eq(s.key.kind, "parameter")) try appendUnique(ir.SubjectId, self.a, &parameters, s.id);
        }
        sortIds(ir.SubjectId, parameters.items);
        const n = parameters.items.len;
        if (n < 2) return;
        const groups = try self.a.alloc(usize, n);
        for (groups, 0..) |*p, i| p.* = i;
        const used = try self.a.alloc(bool, n);
        @memset(used, false);
        for (self.index.relation_subject.get(function.id.bytes)) |ri| {
            const containment = self.doc.relations[ri];
            if (!eq(containment.kind, "contains") or !same(containment.from, function.id) or containment.target.subject == null) continue;
            const event = self.getSubject(containment.target.subject.?);
            var first: ?usize = null;
            for (parameters.items, 0..) |param, i| {
                var present = false;
                for (self.index.relation_subject.get(event.id.bytes)) |rj| {
                    const r = self.doc.relations[rj];
                    if (flowKind(r.kind) and same(r.from, param) and r.target.subject != null and same(r.target.subject.?, event.id)) {
                        present = true;
                        break;
                    }
                }
                if (!present) continue;
                used[i] = true;
                if (first) |j| {
                    groups[root(groups, i)] = root(groups, j);
                } else first = i;
            }
        }
        var supporting: std.ArrayList(EvidenceId) = .empty;
        for (parameters.items, 0..) |_, i| {
            if (!used[i] or root(groups, i) != i) continue;
            var members: std.ArrayList(ir.SubjectId) = .empty;
            for (parameters.items, 0..) |p, j| if (used[j] and root(groups, j) == i) {
                try members.append(self.a, p);
            };
            var events: std.ArrayList(ir.SubjectId) = .empty;
            var relations: std.ArrayList(ir.RelationId) = .empty;
            for (self.doc.relations) |r| if (flowKind(r.kind) and has(ir.SubjectId, members.items, r.from)) {
                if (r.target.subject) |target| if (self.linked(function.id, "contains", target)) {
                    try appendUnique(ir.SubjectId, self.a, &events, target);
                    try relations.append(self.a, r.id);
                };
            };
            sortIds(ir.SubjectId, events.items);
            sortIds(ir.RelationId, relations.items);
            const id = try clusterId(self.a, function.id, members.items);
            const ev = try self.addEvidence(function.id, .cluster, id.bytes, relations.items, &.{}, "Parameters share syntactic usage events; this is not proof of a cohesive responsibility");
            try supporting.append(self.a, ev);
            try self.clusters.append(self.a, .{ .id = id, .subject = function.id, .members = members.items, .events = events.items, .evidence = ev });
        }
        if (supporting.items.len < 2) return;
        sortIds(EvidenceId, supporting.items);
        const ev = try self.addEvidence(function.id, .responsibility, "split", &.{}, supporting.items, "At least two disconnected groups of used parameters; aliases, paths, and hidden dependencies may connect them");
        try self.findings.append(self.a, .{ .id = try findingId(self.a, function.id), .subject = function.id, .kind = .responsibility_split, .category = .hypothesis, .severity = .info, .status = .open, .hypothesis = "Possible responsibility split: parameter groups participate in separate observed usage events", .evidence = try self.a.dupe(EvidenceId, &.{ev}), .generator = generator, .challenges = &.{}, .traces = &.{}, .suggestions = &.{"Inspect the linked clusters and unresolved flow before extracting a responsibility; add tests for shared invariants"}, .reviewed_revision = null });
    }
    fn callers(self: *Builder) !void {
        var population: u32 = 0;
        for (self.doc.subjects) |s| if (eq(s.key.kind, "function")) {
            population += 1;
        };
        var edges: std.ArrayList(ir.Relation) = .empty;
        for (self.doc.relations) |r| if (eq(r.kind, "calls") and r.target.subject != null) {
            if (!eq(findSubject(self.doc, r.from).?.key.kind, "function") or !eq(findSubject(self.doc, r.target.subject.?).?.key.kind, "function")) continue;
            var duplicate = false;
            for (edges.items) |existing| if (same(existing.from, r.from) and same(existing.target.subject.?, r.target.subject.?)) {
                duplicate = true;
                break;
            };
            if (!duplicate) try edges.append(self.a, r);
        };
        for (edges.items) |r| {
            var out: u32 = 0;
            var in: u32 = 0;
            for (edges.items) |other| {
                if (same(other.from, r.from)) out += 1;
                if (same(other.target.subject.?, r.target.subject.?)) in += 1;
            }
            const local = 1.0 / @as(f64, @floatFromInt(out));
            const inverse = @log((@as(f64, @floatFromInt(population)) + 1) / (@as(f64, @floatFromInt(in)) + 1)) + 1;
            const normalization = @log(@as(f64, @floatFromInt(population)) + 1) + 1;
            const key = try std.fmt.allocPrint(self.a, "{s}->{s}", .{ r.from.bytes, r.target.subject.?.bytes });
            const ev = try self.addEvidence(r.from, .caller_significance, key, try self.a.dupe(ir.RelationId, &.{r.id}), &.{}, "Score weights one unique outgoing call by inverse prevalence among all function subjects in this snapshot");
            try self.significance.append(self.a, .{ .caller = r.from, .callee = r.target.subject.?, .relation = r.id, .evidence = ev, .function_population = population, .caller_out_degree = out, .callee_in_degree = in, .edge_count = 1, .local_share = local, .inverse_prevalence = inverse, .normalization = normalization, .score = local * inverse / normalization });
        }
    }
};
pub fn analyze(gpa: std.mem.Allocator, snapshot: snapshots.Snapshot, previous: ?Report) !Result {
    try snapshots.validate(gpa, snapshot);
    if (previous) |old| {
        try validate(gpa, old);
        if (!eq(snapshot.project, old.snapshot.project)) return error.ProjectMismatch;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var b: Builder = .{ .a = a, .doc = snapshot.document, .index = try Index.build(a, snapshot.document) };
    for (snapshot.document.subjects) |s| if (eq(s.key.kind, "function")) {
        try b.responsibilities(s);
    };
    try b.callers();
    const reviews = if (previous) |old| try a.dupe(Review, old.reviews) else try a.alloc(Review, 0);
    for (reviews) |*decision| {
        decision.finding.bytes = try a.dupe(u8, decision.finding.bytes);
        decision.note = try a.dupe(u8, decision.note);
        decision.revision = try a.dupe(u8, decision.revision);
    }
    for (b.findings.items) |*f| for (reviews) |decision| if (same(f.id, decision.finding)) {
        f.status = decision.status;
        f.reviewed_revision = decision.revision;
    };
    inline for (.{ b.evidence.items, b.clusters.items, b.findings.items }) |rows| std.mem.sort(@TypeOf(rows[0]), rows, {}, struct {
        fn less(_: void, l: @TypeOf(rows[0]), r: @TypeOf(rows[0])) bool {
            return std.mem.lessThan(u8, l.id.bytes, r.id.bytes);
        }
    }.less);
    std.mem.sort(Significance, b.significance.items, {}, struct {
        fn less(_: void, l: Significance, r: Significance) bool {
            const order = std.mem.order(u8, l.caller.bytes, r.caller.bytes);
            return order == .lt or (order == .eq and std.mem.lessThan(u8, l.callee.bytes, r.callee.bytes));
        }
    }.less);
    const report: Report = .{ .analysis_version = 1, .generator = generator, .snapshot = snapshot, .evidence = b.evidence.items, .clusters = b.clusters.items, .findings = b.findings.items, .significance = b.significance.items, .reviews = reviews };
    try validate(a, report);
    return .{ .arena = arena, .report = report };
}
fn checkId(a: std.mem.Allocator, actual: anytype, expected: @TypeOf(actual)) !void {
    defer a.free(expected.bytes);
    if (!same(actual, expected)) return error.IdentityMismatch;
}
fn insert(a: std.mem.Allocator, map: *std.StringHashMapUnmanaged(void), id: []const u8) !void {
    const entry = try map.getOrPut(a, id);
    if (entry.found_existing) return error.DuplicateId;
}
pub fn validate(gpa: std.mem.Allocator, report: Report) !void {
    if (report.analysis_version != 1 or !eq(report.generator, generator)) return error.UnsupportedAnalysisVersion;
    try snapshots.validate(gpa, report.snapshot);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = report.snapshot.document;
    var evidence: std.StringHashMapUnmanaged(void) = .empty;
    var observations: std.StringHashMapUnmanaged(void) = .empty;
    var relations: std.StringHashMapUnmanaged(void) = .empty;
    for (doc.observations) |o| try observations.put(a, o.id.bytes, {});
    for (doc.relations) |r| try relations.put(a, r.id.bytes, {});
    for (report.evidence) |e| {
        try insert(a, &evidence, e.id.bytes);
        try checkId(a, e.id, try evidenceId(a, doc.revision, e));
    }
    for (report.evidence) |e| {
        if (findSubject(doc, e.subject) == null or !ir.nonempty(e.key) or !ir.nonempty(e.extractor) or !ir.nonempty(e.summary) or e.sources.len == 0) return error.InvalidEvidence;
        for (e.observations) |id| if (!observations.contains(id.bytes)) return error.DanglingEvidence;
        for (e.relations) |id| if (!relations.contains(id.bytes)) return error.DanglingEvidence;
        for (e.parents) |id| if (!evidence.contains(id.bytes) or same(id, e.id)) return error.DanglingEvidence;
        for (e.sources) |s| {
            if (!ir.validPath(s.path) or !ir.nonempty(s.language) or !ir.nonempty(s.producer) or s.span.end < s.span.start) return error.InvalidEvidence;
            var found = false;
            for (report.snapshot.files) |f| if (eq(f.path, s.path)) {
                found = true;
                break;
            };
            if (!found) return error.InvalidEvidence;
        }
    }
    // Generated aggregate parents are leaves; enforce acyclicity without recursive traversal.
    for (report.evidence) |e| for (e.parents) |parent| for (report.evidence) |p| if (same(p.id, parent) and p.parents.len != 0) {
        return error.InvalidEvidenceHierarchy;
    };
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    for (report.clusters) |c| {
        try insert(a, &ids, c.id.bytes);
        try checkId(a, c.id, try clusterId(a, c.subject, c.members));
        if (findSubject(doc, c.subject) == null or c.members.len == 0 or c.events.len == 0 or !evidence.contains(c.evidence.bytes)) return error.InvalidCluster;
        for (c.members) |id| if (findSubject(doc, id) == null) return error.DanglingEvidence;
        for (c.events) |id| if (findSubject(doc, id) == null) return error.DanglingEvidence;
    }
    for (report.findings) |f| {
        try insert(a, &ids, f.id.bytes);
        try checkId(a, f.id, try findingId(a, f.subject));
        if (findSubject(doc, f.subject) == null or !eq(f.generator, generator) or !ir.nonempty(f.hypothesis) or f.evidence.len == 0 or f.category != .hypothesis) return error.InvalidFinding;
        for (f.evidence) |id| if (!evidence.contains(id.bytes)) return error.DanglingEvidence;
        inline for (.{ f.challenges, f.traces, f.suggestions }) |items| for (items) |item| if (!ir.nonempty(item)) return error.InvalidFinding;
        var reviewed = false;
        for (report.reviews) |r| if (same(r.finding, f.id)) {
            if (r.status != f.status or f.reviewed_revision == null or !eq(r.revision, f.reviewed_revision.?)) return error.InvalidReview;
            reviewed = true;
        };
        if (!reviewed and (f.status != .open or f.reviewed_revision != null)) return error.InvalidReview;
    }
    const index = try Index.build(a, doc);
    var population: u32 = 0;
    for (doc.subjects) |sub| if (eq(sub.key.kind, "function")) {
        population += 1;
    };
    var scored: std.StringHashMapUnmanaged(void) = .empty;
    for (report.significance) |s| {
        if (findSubject(doc, s.caller) == null or findSubject(doc, s.callee) == null or !relations.contains(s.relation.bytes) or !evidence.contains(s.evidence.bytes)) return error.DanglingEvidence;
        if (s.function_population == 0 or s.caller_out_degree == 0 or s.callee_in_degree == 0 or s.edge_count != 1 or s.callee_in_degree > s.function_population) return error.InvalidSignificance;
        const pair = try std.fmt.allocPrint(a, "{s}/{s}", .{ s.caller.bytes, s.callee.bytes });
        try insert(a, &scored, pair);
        var outgoing: std.StringHashMapUnmanaged(void) = .empty;
        var incoming: std.StringHashMapUnmanaged(void) = .empty;
        var supporting_call = false;
        for (index.relation_subject.get(s.caller.bytes)) |i| {
            const r = doc.relations[i];
            if (!eq(r.kind, "calls") or r.target.subject == null or !same(r.from, s.caller)) continue;
            if (!eq(doc.subjects[index.subjects.get(r.target.subject.?.bytes).?].key.kind, "function")) continue;
            try outgoing.put(a, r.target.subject.?.bytes, {});
            if (same(r.id, s.relation) and same(r.target.subject.?, s.callee)) supporting_call = true;
        }
        for (index.relation_subject.get(s.callee.bytes)) |i| {
            const r = doc.relations[i];
            if (!eq(r.kind, "calls") or r.target.subject == null or !same(r.target.subject.?, s.callee)) continue;
            if (!eq(doc.subjects[index.subjects.get(r.from.bytes).?].key.kind, "function")) continue;
            try incoming.put(a, r.from.bytes, {});
        }
        if (!supporting_call or s.function_population != population or s.caller_out_degree != outgoing.count() or s.callee_in_degree != incoming.count()) return error.InvalidSignificance;
        const local = 1.0 / @as(f64, @floatFromInt(s.caller_out_degree));
        const inverse = @log((@as(f64, @floatFromInt(s.function_population)) + 1) / (@as(f64, @floatFromInt(s.callee_in_degree)) + 1)) + 1;
        const normalization = @log(@as(f64, @floatFromInt(s.function_population)) + 1) + 1;
        if (!std.math.isFinite(s.score) or @abs(s.local_share - local) > 1e-12 or @abs(s.inverse_prevalence - inverse) > 1e-12 or @abs(s.normalization - normalization) > 1e-12 or @abs(s.score - local * inverse / normalization) > 1e-12) return error.InvalidSignificance;
    }
    var reviewed: std.StringHashMapUnmanaged(void) = .empty;
    for (report.reviews) |r| {
        try insert(a, &reviewed, r.finding.bytes);
        if (!identity.valid(r.finding.bytes, "fnd_") or !ir.nonempty(r.note) or !ir.nonempty(r.revision)) return error.InvalidReview;
    }
}
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Report) {
    const shape = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer shape.deinit();
    try wire.validateShape(Report, shape.value);
    const parsed = try std.json.parseFromSlice(Report, a, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(a, parsed.value);
    return parsed;
}
/// Mutates only derived review state; callers persist via the CLI's atomic writer.
pub fn review(a: std.mem.Allocator, report: *Report, id: []const u8, status: Status, note: []const u8) !void {
    if (!ir.nonempty(note)) return error.InvalidReview;
    const findings = try a.dupe(Finding, report.findings);
    var selected: ?*Finding = null;
    for (findings) |*f| if (eq(f.id.bytes, id)) {
        selected = f;
        break;
    };
    const f = selected orelse return error.UnknownFinding;
    var reviews: std.ArrayList(Review) = .empty;
    try reviews.appendSlice(a, report.reviews);
    const row: Review = .{ .finding = f.id, .status = status, .note = note, .revision = report.snapshot.document.revision };
    var replaced = false;
    for (reviews.items) |*r| if (same(r.finding, f.id)) {
        r.* = row;
        replaced = true;
        break;
    };
    if (!replaced) try reviews.append(a, row);
    f.status = status;
    f.reviewed_revision = row.revision;
    std.mem.sort(Review, reviews.items, {}, struct {
        fn less(_: void, l: Review, r: Review) bool {
            return std.mem.lessThan(u8, l.finding.bytes, r.finding.bytes);
        }
    }.less);
    var updated = report.*;
    updated.findings = findings;
    updated.reviews = reviews.items;
    try validate(a, updated);
    report.* = updated;
}

fn exerciseAnalysisOwnership(a: std.mem.Allocator, bytes: []const u8) !void {
    const snapshot = try snapshots.decode(a, bytes);
    defer snapshot.deinit();
    var result = try analyze(a, snapshot.value, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.report.findings.len);
    const encoded = try std.json.Stringify.valueAlloc(a, result.report, .{});
    defer a.free(encoded);
    var parsed = try decode(a, encoded);
    defer parsed.deinit();
    var changes = std.heap.ArenaAllocator.init(a);
    defer changes.deinit();
    try review(changes.allocator(), &parsed.value, parsed.value.findings[0].id.bytes, .deferred, "Inspect alias relationships");
    var rescanned = try analyze(a, snapshot.value, parsed.value);
    defer rescanned.deinit();
    try std.testing.expectEqual(Status.deferred, rescanned.report.findings[0].status);
}
test "analysis, decoding and review cleanup survive allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: ir.Source = .{ .path = "a.zig", .language = "zig", .span = .{ .start = 0, .end = 10 }, .producer = "fixture", .confidence = .high };
    var subjects: [5]ir.Subject = undefined;
    const names = [_][]const u8{ "f", "p", "q", "call-p", "call-q" };
    const kinds = [_][]const u8{ "function", "parameter", "parameter", "call", "call" };
    for (&subjects, names, kinds) |*s, name, kind| {
        const key: ir.SubjectKey = .{ .project = "fixture", .language = "zig", .path = "a.zig", .kind = kind, .name = name, .discriminator = "0" };
        s.* = .{ .id = try key.id(a), .key = key, .source = source };
    }
    var relations: [7]ir.Relation = undefined;
    const from = [_]usize{ 0, 0, 0, 0, 1, 2, 0 };
    const to = [_]usize{ 1, 2, 3, 4, 3, 4, 0 };
    const relation_kinds = [_][]const u8{ "contains", "contains", "contains", "contains", "argument", "argument", "calls" };
    for (&relations, from, to, relation_kinds) |*r, f, t, kind| {
        r.* = .{ .id = undefined, .from = subjects[f].id, .kind = kind, .target = .{ .status = .resolved, .subject = subjects[t].id, .reason = null }, .source = source, .revision = "r1" };
        r.id = try ir.relationId(a, r.*);
    }
    const snapshot: snapshots.Snapshot = .{
        .snapshot_version = 1,
        .project = "fixture",
        .configuration = .{ .adapter = "fixture", .compiler = "0", .options_sha256 = "0" ** 64, .configs = &.{} },
        .files = &.{.{ .path = "a.zig", .sha256 = "0" ** 64 }},
        .diagnostics = &.{},
        .coverage = .{ .unresolved_calls = 0, .unresolved_accesses = 0 },
        .document = .{ .schema_version = 1, .revision = "r1", .subjects = &subjects, .symbols = &.{}, .observations = &.{}, .relations = &relations },
    };
    const bytes = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAnalysisOwnership, .{bytes});
}
