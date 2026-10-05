//! Challenges are questions; only observed responses can support an oracle judgment.
const std = @import("std");
const ir = @import("ir.zig");
const identity = @import("identity.zig");
const specification = @import("specification.zig");
const wire = @import("wire.zig");
pub const ChallengeId = identity.Id("cha_");
pub const Execution = enum { solver_supported, simulation, runtime_execution, human_policy, unknown };
pub const ExpectationKind = enum { required, possible, forbidden, unknown };
pub const EffectKind = enum { return_value, state_change, database_change, log, event, observation, external_effect, unknown_effect };
pub const Origin = enum { simulation, runtime, code, @"test" };
pub const Challenge = struct {
    id: ChallengeId,
    target: ir.SubjectId,
    target_operation: ?ir.SubjectId,
    assumptions: []const specification.Fact,
    constraints: []const specification.ConstraintId,
    question: []const u8,
    suspicious_condition: []const u8,
    expectation: ExpectationKind,
    execution: Execution,
    generated_from: struct { claim: ?specification.ClaimId, finding: ?[]const u8, evidence: []const ir.Source },
};
pub const Set = struct { challenge_version: u32 = 1, project: []const u8, revision: []const u8, challenges: []const Challenge };
pub const Effect = struct { name: []const u8, kind: EffectKind, subject: ?ir.SubjectId, value: ?specification.Scalar, source: ir.Source, origin: Origin };
pub const ResponseSet = struct { operation: ir.SubjectId, origin: Origin, coverage: enum { complete, partial }, effects: []const Effect, evidence: specification.Input };
pub const Expectation = struct { name: []const u8, kind: EffectKind, classification: ExpectationKind, source: ir.Source };
pub const Request = struct { oracle_version: u32, challenge: Challenge, response: ResponseSet, expectations: []const Expectation, policy: enum { enforced, domain_dependent, unknown } };
pub const Outcome = enum { acceptable, defect, unknown, domain_dependent };
pub const EffectCheck = struct { expectation: Expectation, outcome: specification.Outcome, reason: []const u8 };
pub const Judgment = struct { oracle_version: u32 = 1, challenge: Challenge, response: ResponseSet, outcome: Outcome, reason: []const u8, effects: []const EffectCheck, constraints: specification.Report };
fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    const shape = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer shape.deinit();
    try wire.validateShape(T, shape.value);
    return std.json.parseFromSlice(T, allocator, bytes, .{ .allocate = .alloc_always });
}
/// Results live in the caller's arena; borrowed specification strings must remain alive.
pub fn generate(allocator: std.mem.Allocator, model: specification.Specification) !Set {
    try specification.validate(allocator, model);
    var challenges: std.ArrayList(Challenge) = .empty;
    for (model.claims) |claim| {
        if (claim.state == .specified and claim.kind != .forbidden) continue;
        var operation: ?ir.SubjectId = null;
        for (model.snapshot.document.subjects) |subject| if (equal(subject.id.bytes, claim.subject.bytes) and equal(subject.key.kind, "operation")) {
            operation = subject.id;
            break;
        };
        var execution: Execution = .unknown;
        if (operation) |target_operation| for (model.functions) |function| if (equal(function.subject.bytes, target_operation.bytes)) {
            execution = switch (function.mode) {
                .executable, .observed => .runtime_execution,
                .axiomatized, .mocked => .simulation,
                .@"opaque", .uninterpreted => .unknown,
            };
            break;
        };
        if (claim.kind == .policy) execution = .human_policy;
        const constraints = try allocator.alloc(specification.ConstraintId, if (claim.constraint == null) 0 else 1);
        if (claim.constraint) |constraint| constraints[0] = constraint;
        const evidence = try allocator.dupe(ir.Source, &.{claim.source});
        try challenges.append(allocator, .{
            .id = try identity.make(allocator, ChallengeId, "cha_", &.{ "challenge", claim.id.bytes }),
            .target = claim.subject,
            .target_operation = operation,
            .assumptions = &.{},
            .constraints = constraints,
            .question = if (claim.kind == .forbidden and claim.state == .specified) "Can this operation produce the explicitly forbidden behavior?" else "What behavior is permitted while this constraint is unspecified?",
            .suspicious_condition = claim.reason,
            .expectation = if (claim.state == .specified) .forbidden else .unknown,
            .execution = execution,
            .generated_from = .{ .claim = claim.id, .finding = null, .evidence = evidence },
        });
    }
    return .{ .project = model.snapshot.project, .revision = model.snapshot.document.revision, .challenges = challenges.items };
}
fn validateSource(source: ir.Source) !void {
    if (!ir.validPath(source.path) or !ir.nonempty(source.language) or !ir.nonempty(source.producer) or source.span.end < source.span.start) return error.InvalidSource;
}
fn hasSubject(model: specification.Specification, identifier: ir.SubjectId, operation_only: bool) bool {
    for (model.snapshot.document.subjects) |subject| if (equal(subject.id.bytes, identifier.bytes) and (!operation_only or equal(subject.key.kind, "operation"))) return true;
    return false;
}
pub fn judge(allocator: std.mem.Allocator, model: specification.Specification, request: Request) !Judgment {
    try specification.validate(allocator, model);
    try specification.validateInput(allocator, request.response.evidence);
    const challenge = request.challenge;
    if (request.oracle_version != 1 or !identity.valid(challenge.id.bytes, "cha_") or !ir.nonempty(challenge.question) or !ir.nonempty(challenge.suspicious_condition)) return error.InvalidChallenge;
    if (!equal(model.snapshot.project, request.response.evidence.project)) return error.ProjectMismatch;
    if (!hasSubject(model, challenge.target, false)) return error.DanglingReference;
    if (challenge.target_operation) |operation| {
        if (!hasSubject(model, operation, true) or !equal(operation.bytes, request.response.operation.bytes)) return error.OperationMismatch;
    } else return error.MissingOperationMapping;
    try specification.validateInput(allocator, .{ .input_version = 1, .project = model.snapshot.project, .facts = challenge.assumptions, .graph = null, .coverage = .absent });
    if (challenge.generated_from.claim) |identifier| {
        var found = false;
        for (model.claims) |claim| if (equal(identifier.bytes, claim.id.bytes) and equal(claim.subject.bytes, challenge.target.bytes)) {
            found = true;
            break;
        };
        if (!found) return error.DanglingClaim;
    }
    if (challenge.generated_from.finding) |identifier| if (!identity.valid(identifier, "fnd_")) return error.InvalidFinding;
    for (challenge.generated_from.evidence) |source| try validateSource(source);
    for (challenge.constraints, 0..) |identifier, index| {
        for (challenge.constraints[0..index]) |previous| if (equal(identifier.bytes, previous.bytes)) return error.DuplicateConstraint;
        var found = false;
        for (model.constraints) |constraint| if (equal(identifier.bytes, constraint.id.bytes) and equal(constraint.subject.bytes, challenge.target.bytes)) {
            found = true;
            break;
        };
        if (!found) return error.DanglingConstraint;
        var governed = false;
        for (model.claims) |claim| if (claim.constraint) |constraint| if (equal(constraint.bytes, identifier.bytes) and equal(claim.subject.bytes, challenge.target.bytes)) {
            governed = true;
            break;
        };
        if (!governed) return error.UngovernedConstraint;
    }
    var complete_effects = request.response.coverage == .complete;
    var incomplete = !complete_effects or challenge.expectation == .unknown or challenge.constraints.len == 0;
    for (request.response.effects, 0..) |effect, index| {
        if (!ir.nonempty(effect.name)) return error.InvalidEffect;
        try validateSource(effect.source);
        if (effect.subject) |identifier| {
            var found = hasSubject(model, identifier, false);
            if (request.response.evidence.graph) |graph| for (graph.subjects) |subject| if (equal(subject.id.bytes, identifier.bytes)) {
                found = true;
                break;
            };
            if (!found) return error.DanglingEffectSubject;
        }
        for (request.response.effects[0..index]) |previous| if (equal(effect.name, previous.name) and effect.kind == previous.kind) return error.DuplicateEffect;
        if (effect.kind == .unknown_effect) {
            incomplete = true;
            complete_effects = false;
        }
        if (effect.value) |value| try specification.validateInput(allocator, .{ .input_version = 1, .project = model.snapshot.project, .facts = &.{.{ .name = effect.name, .status = .known, .value = value, .reason = null, .source = effect.source, .origin = .trace }}, .graph = null, .coverage = .absent });
    }
    var violated = false;
    var checks: std.ArrayList(EffectCheck) = .empty;
    for (request.expectations, 0..) |expectation, index| {
        if (!ir.nonempty(expectation.name)) return error.InvalidExpectation;
        try validateSource(expectation.source);
        for (request.expectations[0..index]) |previous| if (equal(expectation.name, previous.name) and expectation.kind == previous.kind) return error.DuplicateExpectation;
        var present = false;
        for (request.response.effects) |effect| if (equal(effect.name, expectation.name) and effect.kind == expectation.kind) {
            present = true;
            break;
        };
        const outcome: specification.Outcome = switch (expectation.classification) {
            .required => if (present) .satisfied else if (complete_effects) .violated else .unknown,
            .forbidden => if (present) .violated else if (complete_effects) .satisfied else .unknown,
            .possible => .satisfied,
            .unknown => .unknown,
        };
        violated = violated or outcome == .violated;
        incomplete = incomplete or outcome == .unknown;
        try checks.append(allocator, .{ .expectation = expectation, .outcome = outcome, .reason = if (outcome == .unknown) "Response coverage or expectation is unknown" else if (outcome == .violated) "Observed response contradicts the explicit effect expectation" else "Effect expectation permits this response" });
    }
    var selected_claims: std.ArrayList(specification.Claim) = .empty;
    for (model.claims) |claim| if (claim.constraint) |identifier| {
        for (challenge.constraints) |selected| if (equal(identifier.bytes, selected.bytes)) {
            try selected_claims.append(allocator, claim);
            break;
        };
    };
    var selected_model = model;
    selected_model.claims = selected_claims.items;
    var evaluation = try specification.evaluate(allocator, selected_model, request.response.evidence);
    defer evaluation.deinit();
    for (evaluation.report.results) |result| {
        violated = violated or result.outcome == .violated;
        incomplete = incomplete or result.outcome == .unknown or result.outcome == .unsupported;
    }
    // Copy nested evaluation storage into the caller's arena before releasing it.
    const evaluation_bytes = try std.json.Stringify.valueAlloc(allocator, evaluation.report, .{});
    const report = try std.json.parseFromSliceLeaky(specification.Report, allocator, evaluation_bytes, .{ .allocate = .alloc_always });
    const outcome: Outcome = if (request.policy == .domain_dependent) .domain_dependent else if (request.policy == .unknown) .unknown else if (violated) .defect else if (incomplete) .unknown else .acceptable;
    return .{ .challenge = challenge, .response = request.response, .outcome = outcome, .reason = switch (outcome) {
        .acceptable => "Observed responses satisfy selected constraints and effect expectations",
        .defect => "Observed response violates an explicitly enforced constraint or expectation",
        .unknown => "Evidence, constraint coverage, or enforcement policy is incomplete",
        .domain_dependent => "Judgment depends on an unresolved domain policy",
    }, .effects = checks.items, .constraints = report };
}
