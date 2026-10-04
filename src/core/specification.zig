const std = @import("std");
const ir = @import("ir.zig");
const snapshot = @import("snapshot.zig");
const identity = @import("identity.zig");
const wire = @import("wire.zig");
pub const ClaimId = identity.Id("clm_");
pub const ConstraintId = identity.Id("con_");
pub const Scalar = struct { kind: enum { null, boolean, number, string }, value: []const u8 };
pub const Expression = struct {
    op: enum { literal, fact, eq, ne, lt, le, gt, ge, @"and", @"or", not, implies, call, graph, unsupported },
    args: []const u32,
    name: ?[]const u8,
    value: ?Scalar,
};
pub const ClaimKind = enum { requirement, postcondition, invariant, forbidden, policy };
pub const Claim = struct { id: ClaimId, subject: ir.SubjectId, name: []const u8, kind: ClaimKind, state: enum { specified, unspecified, intentionally_unspecified, deferred, out_of_scope, unknown }, reason: []const u8, constraint: ?ConstraintId, source: ir.Source };
pub const Constraint = struct { id: ConstraintId, subject: ir.SubjectId, name: []const u8, expression: []const Expression, source: ir.Source };
pub const Function = struct { subject: ir.SubjectId, name: []const u8, mode: enum { @"opaque", uninterpreted, axiomatized, executable, mocked, observed }, arity: u32, definition: []const Expression, backing: ?ir.SubjectId };
pub const Domain = struct { subject: ir.SubjectId, ownership: enum { unknown, owned, shared }, nullability: enum { unknown, nullable, nonnull }, values: []const Scalar, constraints: []const ConstraintId, reason: []const u8 };
pub const Specification = struct { specification_version: u32, snapshot: snapshot.Snapshot, claims: []const Claim, constraints: []const Constraint, functions: []const Function, domains: []const Domain };
pub const Fact = struct { name: []const u8, status: enum { known, unknown, unsupported }, value: ?Scalar, reason: ?[]const u8, source: ir.Source, origin: enum { code, specification, inference, @"test", trace } };
pub const Input = struct { input_version: u32, project: []const u8, facts: []const Fact, graph: ?ir.Document, coverage: enum { complete, partial, absent } };
pub const Outcome = enum { satisfied, violated, unknown, unsupported };
pub const Evaluation = struct { claim: Claim, constraint: ?Constraint, outcome: Outcome, reason: []const u8, evidence: []const ir.Source, facts: []const []const u8, records: []const []const u8 };
pub const Report = struct { evaluation_version: u32, project: []const u8, revision: []const u8, results: []const Evaluation };
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
fn source(s: ir.Source) !void {
    if (!ir.validPath(s.path) or !ir.nonempty(s.language) or !ir.nonempty(s.producer) or s.span.end < s.span.start) return error.InvalidSource;
}
fn scalar(s: Scalar) !void {
    if (!std.unicode.utf8ValidateSlice(s.value)) return error.InvalidScalar;
    switch (s.kind) {
        .null => if (s.value.len != 0) return error.InvalidScalar,
        .boolean => if (!eq(s.value, "true") and !eq(s.value, "false")) return error.InvalidScalar,
        .number => {
            const n = std.fmt.parseFloat(f64, s.value) catch return error.InvalidScalar;
            if (!std.math.isFinite(n) or s.value.len == 0 or std.mem.indexOfAny(u8, s.value, " \t\n\r") != null) return error.InvalidScalar;
        },
        .string => {},
    }
}
pub fn claimId(a: std.mem.Allocator, c: Claim) !ClaimId {
    return identity.make(a, ClaimId, "clm_", &.{ "claim", c.subject.bytes, c.name, @tagName(c.kind) });
}
pub fn constraintId(a: std.mem.Allocator, c: Constraint) !ConstraintId {
    return identity.make(a, ConstraintId, "con_", &.{ "constraint", c.subject.bytes, c.name });
}
fn expressions(rows: []const Expression, allow_empty: bool) !void {
    if ((!allow_empty and rows.len == 0) or rows.len > 1024) return error.InvalidExpression;
    for (rows, 0..) |e, i| {
        for (e.args) |arg| if (arg >= i) return error.InvalidExpressionReference;
        const arity: usize = switch (e.op) {
            .literal, .fact, .graph, .unsupported => 0,
            .not => 1,
            .call => e.args.len,
            else => 2,
        };
        if (e.args.len != arity or e.args.len > 64) return error.InvalidExpression;
        switch (e.op) {
            .literal => {
                if (e.value == null or e.name != null) return error.InvalidExpression;
                try scalar(e.value.?);
            },
            .fact, .graph, .call, .unsupported => {
                if (e.name == null or !ir.nonempty(e.name.?) or e.value != null) return error.InvalidExpression;
            },
            else => if (e.name != null or e.value != null) return error.InvalidExpression,
        }
    }
}
fn insert(a: std.mem.Allocator, m: *std.StringHashMapUnmanaged(void), key: []const u8) !void {
    const e = try m.getOrPut(a, key);
    if (e.found_existing) return error.DuplicateId;
}
pub fn validate(gpa: std.mem.Allocator, s: Specification) !void {
    if (s.specification_version != 1) return error.UnsupportedSpecificationVersion;
    try snapshot.validate(gpa, s.snapshot);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var subjects: std.StringHashMapUnmanaged(void) = .empty;
    var constraints: std.StringHashMapUnmanaged(ir.SubjectId) = .empty;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    for (s.snapshot.document.subjects) |sub| try subjects.put(a, sub.id.bytes, {});
    for (s.constraints) |c| {
        try insert(a, &ids, c.id.bytes);
        try source(c.source);
        try expressions(c.expression, false);
        if (!subjects.contains(c.subject.bytes) or !ir.nonempty(c.name) or !eq(c.id.bytes, (try constraintId(a, c)).bytes)) return error.InvalidConstraint;
        try constraints.put(a, c.id.bytes, c.subject);
    }
    for (s.claims) |c| {
        try insert(a, &ids, c.id.bytes);
        try source(c.source);
        if (!subjects.contains(c.subject.bytes) or !ir.nonempty(c.name) or !ir.nonempty(c.reason) or !eq(c.id.bytes, (try claimId(a, c)).bytes)) return error.InvalidClaim;
        if (c.state == .specified) {
            const id = c.constraint orelse return error.MissingConstraint;
            const owner = constraints.get(id.bytes) orelse return error.DanglingConstraint;
            if (!eq(owner.bytes, c.subject.bytes)) return error.ConstraintTargetMismatch;
        } else if (c.constraint != null) return error.InvalidClaim;
    }
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (s.functions) |f| {
        if (!subjects.contains(f.subject.bytes) or !ir.nonempty(f.name) or f.arity > 64) return error.InvalidFunction;
        try insert(a, &names, f.name);
        try expressions(f.definition, true);
        if (f.backing) |id| if (!subjects.contains(id.bytes)) return error.DanglingReference;
    }
    var domains: std.StringHashMapUnmanaged(void) = .empty;
    for (s.domains) |d| {
        if (!subjects.contains(d.subject.bytes) or !ir.nonempty(d.reason)) return error.InvalidDomain;
        try insert(a, &domains, d.subject.bytes);
        for (d.values) |v| try scalar(v);
        for (d.constraints) |id| {
            const owner = constraints.get(id.bytes) orelse return error.DanglingConstraint;
            if (!eq(owner.bytes, d.subject.bytes)) return error.ConstraintTargetMismatch;
        }
        if ((d.ownership != .unknown or d.nullability != .unknown or d.values.len > 0) and d.constraints.len == 0) return error.UnjustifiedDomainNarrowing;
    }
    inline for (.{ s.claims, s.constraints }) |rows| for (rows) |row| {
        var found = false;
        for (s.snapshot.files) |f| if (eq(f.path, row.source.path)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidSource;
    };
}
pub fn validateInput(a: std.mem.Allocator, input: Input) !void {
    if (input.input_version != 1 or !ir.nonempty(input.project)) return error.InvalidEvaluationInput;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(a);
    for (input.facts) |f| {
        if (!ir.nonempty(f.name)) return error.InvalidFact;
        try insert(a, &names, f.name);
        try source(f.source);
        if (f.status == .known) {
            if (f.value == null or f.reason != null) return error.InvalidFact;
            try scalar(f.value.?);
        } else if (f.value != null or f.reason == null or !ir.nonempty(f.reason.?)) return error.InvalidFact;
    }
    if ((input.graph == null) != (input.coverage == .absent)) return error.InvalidCoverage;
    if (input.graph) |g| {
        if (g.schema_version != 1 or !ir.nonempty(g.revision)) return error.InvalidEvaluationInput;
        for (g.subjects) |s| if (!eq(s.key.project, input.project)) return error.ProjectMismatch;
    }
}
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Specification) {
    const shape = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer shape.deinit();
    try wire.validateShape(Specification, shape.value);
    const parsed = try std.json.parseFromSlice(Specification, a, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(a, parsed.value);
    return parsed;
}
pub fn decodeInput(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Input) {
    const shape = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer shape.deinit();
    try wire.validateShape(Input, shape.value);
    const parsed = try std.json.parseFromSlice(Input, a, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validateInput(a, parsed.value);
    return parsed;
}
const Value = struct { status: enum { known, unknown, unsupported }, value: ?Scalar, reason: []const u8 };
fn unknown(reason: []const u8) Value {
    return .{ .status = .unknown, .value = null, .reason = reason };
}
fn unsupported(reason: []const u8) Value {
    return .{ .status = .unsupported, .value = null, .reason = reason };
}
fn boolean(value: bool) Value {
    return .{ .status = .known, .value = .{ .kind = .boolean, .value = if (value) "true" else "false" }, .reason = "Evaluated supported expression" };
}
fn truth(v: Value) ?bool {
    if (v.status != .known or v.value.?.kind != .boolean) return null;
    return eq(v.value.?.value, "true");
}
const Evaluator = struct {
    a: std.mem.Allocator,
    spec: Specification,
    input: Input,
    evidence: std.ArrayList(ir.Source) = .empty,
    facts: std.ArrayList([]const u8) = .empty,
    records: std.ArrayList([]const u8) = .empty,
    remaining_nodes: usize = 10000,
    fn graph(self: *Evaluator, name: []const u8) !Value {
        const doc = self.input.graph orelse return unknown("No graph evidence supplied");
        if (!eq(name, "identity") and !eq(name, "ownership") and !eq(name, "references")) return unsupported("Unknown structural graph predicate");
        var subjects: std.StringHashMapUnmanaged(void) = .empty;
        var ids: std.StringHashMapUnmanaged(void) = .empty;
        var bad = false;
        for (doc.subjects) |s| {
            if (eq(name, "identity")) {
                const expected = try s.key.id(self.a);
                if (!eq(expected.bytes, s.id.bytes) or ids.contains(s.id.bytes)) {
                    bad = true;
                    try self.evidence.append(self.a, s.source);
                    try self.records.append(self.a, s.id.bytes);
                }
                try ids.put(self.a, s.id.bytes, {});
            }
            try subjects.put(self.a, s.id.bytes, {});
        }
        if (eq(name, "identity")) {
            for (doc.symbols) |s| {
                if (!eq((try ir.symbolId(self.a, s.subject)).bytes, s.id.bytes) or ids.contains(s.id.bytes)) {
                    bad = true;
                    try self.records.append(self.a, s.id.bytes);
                }
                try ids.put(self.a, s.id.bytes, {});
            }
            for (doc.observations) |o| {
                if (!eq((try ir.observationId(self.a, o)).bytes, o.id.bytes) or ids.contains(o.id.bytes)) {
                    bad = true;
                    try self.evidence.append(self.a, o.source);
                    try self.records.append(self.a, o.id.bytes);
                }
                try ids.put(self.a, o.id.bytes, {});
            }
            for (doc.relations) |r| {
                if (!eq((try ir.relationId(self.a, r)).bytes, r.id.bytes) or ids.contains(r.id.bytes)) {
                    bad = true;
                    try self.evidence.append(self.a, r.source);
                    try self.records.append(self.a, r.id.bytes);
                }
                try ids.put(self.a, r.id.bytes, {});
            }
        } else if (eq(name, "ownership")) {
            for (doc.observations) |o| if (!subjects.contains(o.subject.bytes) or !eq(o.revision, doc.revision)) {
                bad = true;
                try self.evidence.append(self.a, o.source);
                try self.records.append(self.a, o.id.bytes);
            };
        } else {
            for (doc.symbols) |s| if (!subjects.contains(s.subject.bytes)) {
                bad = true;
                try self.records.append(self.a, s.id.bytes);
            };
            for (doc.observations) |o| if (!subjects.contains(o.subject.bytes)) {
                bad = true;
                try self.evidence.append(self.a, o.source);
                try self.records.append(self.a, o.id.bytes);
            };
            for (doc.relations) |r| if (!subjects.contains(r.from.bytes) or (r.target.status == .resolved and (r.target.subject == null or !subjects.contains(r.target.subject.?.bytes) or r.target.reason != null)) or (r.target.status == .unresolved and (r.target.subject != null or r.target.reason == null or !ir.nonempty(r.target.reason.?)))) {
                bad = true;
                try self.evidence.append(self.a, r.source);
                try self.records.append(self.a, r.id.bytes);
            };
        }
        if (bad) {
            var result = boolean(false);
            result.reason = "Structural predicate failed for the supplied graph; inspect supporting record sources";
            return result;
        }
        if (self.input.coverage != .complete) return unknown("Graph inventory is incomplete; absence of violations is not proof");
        for (doc.subjects) |s| {
            try self.evidence.append(self.a, s.source);
            try self.records.append(self.a, s.id.bytes);
        }
        return boolean(true);
    }
    fn eval(self: *Evaluator, expr: []const Expression, bindings: []const Value, depth: u32) anyerror!Value {
        if (depth > 16) return unknown("Domain function recursion limit reached");
        if (expr.len == 0) return unknown("Function has no declared evaluable definition");
        if (expr.len > self.remaining_nodes) return unknown("Expression work limit reached");
        self.remaining_nodes -= expr.len;
        const values = try self.a.alloc(Value, expr.len);
        for (expr, 0..) |e, i| {
            values[i] = switch (e.op) {
                .literal => .{ .status = .known, .value = e.value, .reason = "Literal" },
                .unsupported => unsupported(e.name.?),
                .graph => try self.graph(e.name.?),
                .fact => blk: {
                    const name = e.name.?;
                    if (std.mem.startsWith(u8, name, "$")) {
                        const n = std.fmt.parseInt(usize, name[1..], 10) catch break :blk unknown("Unknown function argument binding");
                        break :blk if (n < bindings.len) bindings[n] else unknown("Missing function argument");
                    }
                    for (self.input.facts) |f| if (eq(f.name, name)) {
                        try self.facts.append(self.a, name);
                        try self.evidence.append(self.a, f.source);
                        break :blk switch (f.status) {
                            .known => .{ .status = .known, .value = f.value, .reason = "Explicit fact" },
                            .unknown => unknown(f.reason.?),
                            .unsupported => unsupported(f.reason.?),
                        };
                    };
                    break :blk unknown("Required fact is absent");
                },
                .call => blk: {
                    for (self.spec.functions) |f| if (eq(f.name, e.name.?)) {
                        if (e.args.len != f.arity) break :blk unsupported("Domain function arity mismatch");
                        if (f.mode == .@"opaque" or f.mode == .uninterpreted) break :blk unknown("Function semantics are not defined");
                        if (f.mode != .axiomatized) break :blk unsupported("Execution, mocking, and observed-code evaluation require an explicit runtime adapter");
                        const args = try self.a.alloc(Value, e.args.len);
                        for (e.args, 0..) |index, j| args[j] = values[index];
                        break :blk try self.eval(f.definition, args, depth + 1);
                    };
                    break :blk unknown("Domain function is not declared");
                },
                else => blk: {
                    const lhs = values[e.args[0]];
                    if (e.op == .not) {
                        if (truth(lhs)) |b| break :blk boolean(!b);
                        break :blk if (lhs.status != .known) lhs else unsupported("Boolean operand required");
                    }
                    const rhs = values[e.args[1]];
                    if ((e.op == .@"and" or e.op == .@"or" or e.op == .implies) and ((lhs.status == .known and lhs.value.?.kind != .boolean) or (rhs.status == .known and rhs.value.?.kind != .boolean))) break :blk unsupported("Boolean operands required");
                    const l = truth(lhs);
                    const r = truth(rhs);
                    if (e.op == .@"and" and (l == false or r == false)) break :blk boolean(false);
                    if (e.op == .@"or" and (l == true or r == true)) break :blk boolean(true);
                    if (e.op == .implies and (l == false or r == true)) break :blk boolean(true);
                    if (lhs.status == .unsupported) break :blk lhs;
                    if (rhs.status == .unsupported) break :blk rhs;
                    if (lhs.status == .unknown) break :blk lhs;
                    if (rhs.status == .unknown) break :blk rhs;
                    if (e.op == .@"and" or e.op == .@"or" or e.op == .implies) {
                        if (l == null or r == null) break :blk unsupported("Boolean operands required");
                        break :blk boolean(if (e.op == .@"and") l.? and r.? else if (e.op == .@"or") l.? or r.? else !l.? or r.?);
                    }
                    const a = lhs.value.?;
                    const b = rhs.value.?;
                    if (e.op == .eq or e.op == .ne) {
                        const equal = a.kind == b.kind and (if (a.kind == .number) (try std.fmt.parseFloat(f64, a.value)) == (try std.fmt.parseFloat(f64, b.value)) else eq(a.value, b.value));
                        break :blk boolean(if (e.op == .eq) equal else !equal);
                    }
                    if (a.kind != .number or b.kind != .number) break :blk unsupported("Ordered comparisons require numeric scalars");
                    const x = try std.fmt.parseFloat(f64, a.value);
                    const y = try std.fmt.parseFloat(f64, b.value);
                    break :blk boolean(switch (e.op) {
                        .lt => x < y,
                        .le => x <= y,
                        .gt => x > y,
                        .ge => x >= y,
                        else => unreachable,
                    });
                },
            };
        }
        return values[values.len - 1];
    }
};
pub fn evaluate(gpa: std.mem.Allocator, spec: Specification, input: Input) !Result {
    try validate(gpa, spec);
    try validateInput(gpa, input);
    if (!eq(spec.snapshot.project, input.project)) return error.ProjectMismatch;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var results: std.ArrayList(Evaluation) = .empty;
    var compiler_error = false;
    for (spec.snapshot.diagnostics) |d| if (d.category == .@"error") {
        compiler_error = true;
    };
    for (spec.claims) |claim| {
        var engine: Evaluator = .{ .a = a, .spec = spec, .input = input };
        try engine.evidence.append(a, claim.source);
        var constraint: ?Constraint = null;
        if (claim.constraint) |id| for (spec.constraints) |c| if (eq(c.id.bytes, id.bytes)) {
            constraint = c;
            break;
        };
        const value = if (compiler_error) unknown("Specification has compiler errors; repair them before evaluation") else if (claim.state != .specified) unknown(claim.reason) else try engine.eval(constraint.?.expression, &.{}, 0);
        const outcome: Outcome = if (value.status == .unsupported) .unsupported else if (truth(value)) |b| if (b != (claim.kind == .forbidden)) .satisfied else .violated else if (value.status == .known) .unsupported else .unknown;
        try results.append(a, .{ .claim = claim, .constraint = constraint, .outcome = outcome, .reason = if (value.status == .known and truth(value) == null) "Constraint did not evaluate to a boolean" else value.reason, .evidence = engine.evidence.items, .facts = engine.facts.items, .records = engine.records.items });
    }
    const report: Report = .{ .evaluation_version = 1, .project = spec.snapshot.project, .revision = spec.snapshot.document.revision, .results = results.items };
    return .{ .arena = arena, .report = report };
}

fn exerciseEvaluation(a: std.mem.Allocator, spec_bytes: []const u8, input_bytes: []const u8) !void {
    const spec = try decode(a, spec_bytes);
    defer spec.deinit();
    const input = try decodeInput(a, input_bytes);
    defer input.deinit();
    var result = try evaluate(a, spec.value, input.value);
    defer result.deinit();
    try std.testing.expectEqual(Outcome.satisfied, result.report.results[0].outcome);
    try std.testing.expect(result.report.results[0].evidence.len > 0);
}
test "specification decoding and evaluation clean up after allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const origin: ir.Source = .{ .path = "main.tsp", .language = "typespec", .span = .{ .start = 0, .end = 1 }, .producer = "fixture", .confidence = .high };
    const key: ir.SubjectKey = .{ .project = "fixture", .language = "typespec", .path = "main.tsp", .kind = "model", .name = "Store", .discriminator = "0" };
    const id = try key.id(a);
    var constraint: Constraint = .{ .id = undefined, .subject = id, .name = "valid", .expression = &.{.{ .op = .fact, .args = &.{}, .name = "valid", .value = null }}, .source = origin };
    constraint.id = try constraintId(a, constraint);
    var claim: Claim = .{ .id = undefined, .subject = id, .name = "valid", .kind = .invariant, .state = .specified, .reason = "Explicit test constraint", .constraint = constraint.id, .source = origin };
    claim.id = try claimId(a, claim);
    const spec: Specification = .{
        .specification_version = 1,
        .snapshot = .{
            .snapshot_version = 1,
            .project = "fixture",
            .configuration = .{ .adapter = "fixture", .compiler = "0", .options_sha256 = "0" ** 64, .configs = &.{} },
            .files = &.{.{ .path = "main.tsp", .sha256 = "0" ** 64 }},
            .diagnostics = &.{},
            .coverage = .{ .unresolved_calls = 0, .unresolved_accesses = 0 },
            .document = .{ .schema_version = 1, .revision = "r1", .subjects = &.{.{ .id = id, .key = key, .source = origin }}, .symbols = &.{}, .observations = &.{}, .relations = &.{} },
        },
        .claims = &.{claim},
        .constraints = &.{constraint},
        .functions = &.{},
        .domains = &.{},
    };
    const input: Input = .{ .input_version = 1, .project = "fixture", .facts = &.{.{ .name = "valid", .status = .known, .value = .{ .kind = .boolean, .value = "true" }, .reason = null, .source = origin, .origin = .@"test" }}, .graph = null, .coverage = .absent };
    const spec_bytes = try std.json.Stringify.valueAlloc(a, spec, .{});
    const input_bytes = try std.json.Stringify.valueAlloc(a, input, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseEvaluation, .{ spec_bytes, input_bytes });
}
