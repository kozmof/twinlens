//! Explicit SA/BT mappings and policy-aware consequence rules. Gaps are not defects.
const std = @import("std");
const ir = @import("ir.zig");
const identity = @import("identity.zig");
const snapshots = @import("snapshot.zig");
const specification = @import("specification.zig");
const analysis = @import("analysis.zig");
const challenge = @import("challenge.zig");
const exploration = @import("exploration.zig");
const symbolic = @import("symbolic.zig");
pub const MappingId = identity.Id("map_");
pub const Rule = enum { authority, old_lifecycle, identity_policy, dependency, derived_backing, provenance_trust, resource_lifecycle };
pub const PolicyLevel = enum { required, recommended, domain_dependent, optional, unknown };
pub const RuleDefinition = struct { rule: Rule, label: []const u8, facet: ?[]const u8, required_edges: []const []const u8 };
pub const rules = [_]RuleDefinition{
    .{ .rule = .authority, .label = "Owned writes need a declared authority policy", .facet = "owned", .required_edges = &.{"authorizes"} },
    .{ .rule = .old_lifecycle, .label = "Verified credentials need an old-value lifecycle after mutation", .facet = "credential", .required_edges = &.{"old_value_policy"} },
    .{ .rule = .identity_policy, .label = "Identity mutation needs old identity, verification, and uniqueness policies", .facet = "identity", .required_edges = &.{ "old_identity_policy", "verifies", "uniqueness" } },
    .{ .rule = .dependency, .label = "Mutated dependencies need a consequence policy", .facet = null, .required_edges = &.{"consequence_policy"} },
    .{ .rule = .derived_backing, .label = "Derived facts need an explicit backing function", .facet = "derived", .required_edges = &.{"derived_from"} },
    .{ .rule = .provenance_trust, .label = "Generated values need provenance, trust, and verification", .facet = "generated", .required_edges = &.{ "provenance", "trust", "verification" } },
    .{ .rule = .resource_lifecycle, .label = "Resource use needs consumption, sharing, and release policies", .facet = "resource", .required_edges = &.{ "consumption_policy", "sharing_policy", "release_policy" } },
};
pub const Mapping = struct { id: MappingId, name: []const u8, subject: ir.SubjectId, implementation: ?ir.SubjectId, observations: []const ir.ObservationId, relations: []const ir.RelationId, effects: []const []const u8, source: ir.Source, confidence: @FieldType(ir.Source, "confidence"), reason: []const u8 };
pub const Policy = struct { subject: ir.SubjectId, rule: Rule, level: PolicyLevel, constraints: []const specification.ConstraintId, reason: []const u8, source: ir.Source };
pub const Execution = struct { name: []const u8, finding: analysis.FindingId, challenge: challenge.ChallengeId, replay: ?exploration.Replay, response: ?challenge.Request };
pub const Input = struct { cross_version: u32, specification: specification.Specification, snapshot: snapshots.Snapshot, mappings: []const Mapping, policies: []const Policy, reviews: []const analysis.Review, symbolic_results: []const symbolic.Report, executions: []const Execution };
pub const Coverage = struct { subject: ir.SubjectId, state: enum { specified_observed, specified_unobserved, unspecified_observed, unspecified_unobserved }, mapping: enum { mapped, unmapped }, behavior: enum { static_only, unobserved }, mappings: []const MappingId, reason: []const u8 };
pub const Evidence = struct { id: analysis.EvidenceId, subject: ir.SubjectId, origin: enum { inference, trace }, confidence: @FieldType(ir.Source, "confidence"), specification_sources: []const ir.Source, implementation_sources: []const ir.Source, observations: []const ir.ObservationId, relations: []const ir.RelationId };
pub const Suggestion = struct { target: ir.SubjectId, kind: specification.ClaimKind, constraint: []const specification.Expression, governing_constraint: ?specification.ConstraintId, generated_from: analysis.FindingId, origin: enum { inference, trace }, confidence: @FieldType(ir.Source, "confidence"), severity: enum { info, warning, @"error" } };
pub const Finding = struct { id: analysis.FindingId, subject: ir.SubjectId, affected: ir.SubjectId, rule: Rule, category: enum { policy_gap }, level: PolicyLevel, status: analysis.Status, reason: []const u8, evidence: analysis.EvidenceId, challenge: challenge.Challenge, suggestion: Suggestion };
pub const Uncertainty = struct { subject: ir.SubjectId, reason: []const u8, source: ir.Source };
pub const Verification = struct { name: []const u8, finding: analysis.FindingId, challenge: challenge.ChallengeId, origin: challenge.Origin, classification: enum { acceptable, simulated_counterexample, observed_violation, inconclusive }, judgment: challenge.Judgment, exploration: ?exploration.Report };
pub const Contradiction = struct { finding: analysis.FindingId, verification: []const u8, specification_sources: []const ir.Source, implementation_sources: []const ir.Source, explanations: []const []const u8 };
pub const Report = struct { cross_version: u32 = 1, revision: []const u8, input: Input, coverage: []const Coverage, evidence: []const Evidence, findings: []const Finding, uncertainties: []const Uncertainty, verifications: []const Verification, contradictions: []const Contradiction, confirmed_violations: []const []const u8, reviews: []const analysis.Review };
fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn same(left: anytype, right: @TypeOf(left)) bool {
    return equal(left.bytes, right.bytes);
}
fn subject(document: ir.Document, identifier: ir.SubjectId) ?ir.Subject {
    for (document.subjects) |record| if (same(record.id, identifier)) return record;
    return null;
}
fn sourceValid(source: ir.Source) !void {
    if (!ir.validPath(source.path) or !ir.nonempty(source.language) or !ir.nonempty(source.producer) or source.span.end < source.span.start) return error.InvalidSource;
}
pub fn mappingId(allocator: std.mem.Allocator, mapping: Mapping) !MappingId {
    return identity.make(allocator, MappingId, "map_", &.{ "mapping", mapping.name, mapping.subject.bytes, if (mapping.implementation) |implementation| implementation.bytes else "" });
}
fn findingId(allocator: std.mem.Allocator, operation: ir.SubjectId, affected: ir.SubjectId, rule: Rule) !analysis.FindingId {
    return identity.make(allocator, analysis.FindingId, "fnd_", &.{ "cross-gap", operation.bytes, affected.bytes, @tagName(rule) });
}
pub fn validate(allocator: std.mem.Allocator, input: Input) !void {
    if (input.cross_version != 1 or input.mappings.len > 10000 or input.policies.len > 4096 or input.executions.len > 64 or input.symbolic_results.len > 64) return error.InvalidCrossLensInput;
    try specification.validate(allocator, input.specification);
    try snapshots.validate(allocator, input.snapshot);
    for (input.specification.snapshot.diagnostics) |diagnostic| if (diagnostic.category == .@"error") return error.InvalidSpecification;
    if (!equal(input.specification.snapshot.project, input.snapshot.project)) return error.ProjectMismatch;
    for (input.mappings, 0..) |mapping, index| {
        if (!ir.nonempty(mapping.name) or !ir.nonempty(mapping.reason) or !same(mapping.id, try mappingId(allocator, mapping)) or subject(input.specification.snapshot.document, mapping.subject) == null) return error.InvalidMapping;
        try sourceValid(mapping.source);
        for (input.mappings[0..index]) |previous| if (same(previous.id, mapping.id)) return error.DuplicateMapping;
        if (mapping.implementation) |implementation| {
            if (subject(input.snapshot.document, implementation) == null) return error.DanglingImplementation;
        } else if (mapping.observations.len > 0 or mapping.relations.len > 0) return error.UnmappedEvidence;
        for (mapping.observations) |identifier| {
            var found = false;
            for (input.snapshot.document.observations) |observation| if (same(observation.id, identifier) and same(observation.subject, mapping.implementation.?)) {
                found = true;
                break;
            };
            if (!found) return error.DanglingMappingObservation;
        }
        for (mapping.relations) |identifier| {
            var found = false;
            for (input.snapshot.document.relations) |relation| if (same(relation.id, identifier) and (same(relation.from, mapping.implementation.?) or if (relation.target.subject) |target| same(target, mapping.implementation.?) else false)) {
                found = true;
                break;
            };
            if (!found) return error.DanglingMappingRelation;
        }
        for (mapping.effects) |effect| if (!ir.nonempty(effect)) return error.InvalidMappingEffect;
    }
    for (input.policies, 0..) |policy, index| {
        if (!ir.nonempty(policy.reason) or subject(input.specification.snapshot.document, policy.subject) == null) return error.InvalidPolicy;
        try sourceValid(policy.source);
        for (input.policies[0..index]) |previous| if (same(previous.subject, policy.subject) and previous.rule == policy.rule) return error.DuplicatePolicy;
        for (policy.constraints) |identifier| {
            var found = false;
            for (input.specification.claims) |claim| if (same(claim.subject, policy.subject) and claim.state == .specified) if (claim.constraint) |constraint| if (same(identifier, constraint)) {
                found = true;
                break;
            };
            if (!found) return error.UngovernedPolicy;
        }
    }
    for (input.reviews) |review| if (!identity.valid(review.finding.bytes, "fnd_") or !ir.nonempty(review.note) or !ir.nonempty(review.revision)) return error.InvalidReview;
    for (input.symbolic_results) |result| {
        if (result.solver_version != 1) return error.InvalidSymbolicReport;
        try symbolic.validate(allocator, result.query);
        if (!equal(result.query.specification.snapshot.project, input.snapshot.project)) return error.ProjectMismatch;
    }
    for (input.executions, 0..) |execution, index| {
        if (!ir.nonempty(execution.name) or (execution.replay == null) == (execution.response == null)) return error.InvalidExecution;
        for (input.executions[0..index]) |previous| if (equal(previous.name, execution.name)) return error.DuplicateExecution;
    }
}
fn edge(document: ir.Document, from: ?ir.SubjectId, kind: []const u8, target: ?ir.SubjectId) bool {
    for (document.relations) |relation| if (equal(relation.kind, kind) and (from == null or same(relation.from, from.?)) and relation.target.status == .resolved and (target == null or same(relation.target.subject.?, target.?))) return true;
    return false;
}
fn facet(input: Input, target: ir.SubjectId, name: []const u8) bool {
    for (input.specification.snapshot.document.relations) |relation| if (same(relation.from, target) and relation.target.status == .resolved and same(relation.target.subject.?, target) and std.mem.startsWith(u8, relation.kind, "perspective.") and equal(relation.kind[12..], name)) return true;
    if (equal(name, "owned")) {
        for (input.specification.domains) |domain| if (same(domain.subject, target) and domain.ownership == .owned) return true;
        return edge(input.specification.snapshot.document, null, "owns", target);
    }
    return false;
}
fn policyFor(input: Input, operation: ir.SubjectId, rule: Rule) ?Policy {
    for (input.policies) |policy| if (same(policy.subject, operation) and policy.rule == rule) return policy;
    return null;
}
fn declared(input: Input, definition: RuleDefinition, operation: ir.SubjectId, affected: ir.SubjectId) bool {
    if (policyFor(input, operation, definition.rule)) |policy| if (policy.constraints.len > 0) return true;
    const document = input.specification.snapshot.document;
    if (definition.rule == .derived_backing) for (input.specification.functions) |function| if (same(function.subject, operation) and function.backing != null) return true;
    if (definition.rule == .authority) {
        if (edge(document, operation, "authorizes", affected)) return true;
        var has_owner = false;
        for (document.relations) |relation| if (equal(relation.kind, "owns") and relation.target.subject != null and same(relation.target.subject.?, affected)) {
            has_owner = true;
            if (!edge(document, operation, "authorizes", relation.from)) return false;
        };
        return has_owner;
    }
    const from = if (definition.rule == .provenance_trust or definition.rule == .resource_lifecycle) affected else operation;
    const target: ?ir.SubjectId = if (definition.rule == .derived_backing or definition.rule == .provenance_trust or definition.rule == .resource_lifecycle) null else affected;
    for (definition.required_edges) |kind| if (!edge(document, from, kind, target)) return false;
    return true;
}
fn buildEvidence(allocator: std.mem.Allocator, input: Input, operation: ir.SubjectId, affected: ir.SubjectId, finding: analysis.FindingId) !Evidence {
    var specification_sources: std.ArrayList(ir.Source) = .empty;
    var implementation_sources: std.ArrayList(ir.Source) = .empty;
    var observations: std.ArrayList(ir.ObservationId) = .empty;
    var relations: std.ArrayList(ir.RelationId) = .empty;
    try specification_sources.append(allocator, (subject(input.specification.snapshot.document, operation) orelse return error.DanglingFinding).source);
    if (!same(operation, affected)) try specification_sources.append(allocator, (subject(input.specification.snapshot.document, affected) orelse return error.DanglingFinding).source);
    var confidence: @FieldType(ir.Source, "confidence") = .medium;
    for (input.mappings) |mapping| if (same(mapping.subject, operation)) {
        if (mapping.confidence == .low) confidence = .low;
        if (mapping.implementation) |implementation| try implementation_sources.append(allocator, subject(input.snapshot.document, implementation).?.source);
        try implementation_sources.append(allocator, mapping.source);
        try observations.appendSlice(allocator, mapping.observations);
        try relations.appendSlice(allocator, mapping.relations);
    };
    return .{ .id = try identity.make(allocator, analysis.EvidenceId, "evd_", &.{ "cross-evidence", finding.bytes }), .subject = operation, .origin = .inference, .confidence = confidence, .specification_sources = specification_sources.items, .implementation_sources = implementation_sources.items, .observations = observations.items, .relations = relations.items };
}
fn createFinding(allocator: std.mem.Allocator, input: Input, definition: RuleDefinition, operation: ir.SubjectId, affected: ir.SubjectId) !Finding {
    const identifier = try findingId(allocator, operation, affected, definition.rule);
    const evidence = try buildEvidence(allocator, input, operation, affected, identifier);
    const policy = policyFor(input, operation, definition.rule);
    const level: PolicyLevel = if (policy) |declaration| declaration.level else .unknown;
    const target = subject(input.specification.snapshot.document, operation).?;
    var constraints: std.ArrayList(specification.ConstraintId) = .empty;
    for (input.specification.claims) |claim| if (same(claim.subject, operation)) if (claim.constraint) |constraint| {
        var present = false;
        for (constraints.items) |existing| if (same(existing, constraint)) {
            present = true;
            break;
        };
        if (!present) try constraints.append(allocator, constraint);
    };
    const question: challenge.Challenge = .{ .id = try identity.make(allocator, challenge.ChallengeId, "cha_", &.{ "cross-challenge", identifier.bytes }), .target = operation, .target_operation = if (equal(target.key.kind, "operation")) operation else null, .assumptions = &.{}, .constraints = constraints.items, .question = try std.fmt.allocPrint(allocator, "Can this operation violate the intended {s} policy in a reachable state?", .{@tagName(definition.rule)}), .suspicious_condition = definition.label, .expectation = if (level == .required) .required else .unknown, .execution = if (level == .domain_dependent or level == .unknown) .human_policy else .simulation, .generated_from = .{ .claim = null, .finding = identifier.bytes, .evidence = evidence.specification_sources } };
    const expression = try allocator.dupe(specification.Expression, &.{.{ .op = .fact, .args = &.{}, .name = try std.fmt.allocPrint(allocator, "policy.{s}.satisfied", .{@tagName(definition.rule)}), .value = null }});
    return .{ .id = identifier, .subject = operation, .affected = affected, .rule = definition.rule, .category = .policy_gap, .level = level, .status = .open, .reason = definition.label, .evidence = evidence.id, .challenge = question, .suggestion = .{ .target = operation, .kind = .policy, .constraint = expression, .governing_constraint = null, .generated_from = identifier, .origin = .inference, .confidence = evidence.confidence, .severity = if (level == .required or level == .recommended) .warning else .info } };
}
fn appendGap(allocator: std.mem.Allocator, findings: *std.ArrayList(Finding), input: Input, definition: RuleDefinition, operation: ir.SubjectId, affected: ir.SubjectId) !void {
    if (declared(input, definition, operation, affected)) return;
    const identifier = try findingId(allocator, operation, affected, definition.rule);
    for (findings.items) |finding| if (same(finding.id, identifier)) return;
    try findings.append(allocator, try createFinding(allocator, input, definition, operation, affected));
}
fn reportRevision(allocator: std.mem.Allocator, input: Input) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, input, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(allocator, "{x}", .{&digest});
}
pub fn analyze(allocator: std.mem.Allocator, io: std.Io, input: Input, previous: ?Report) !Report {
    try validate(allocator, input);
    if (previous) |report| {
        try validateReport(allocator, report);
        if (!equal(report.input.snapshot.project, input.snapshot.project)) return error.ProjectMismatch;
    }
    var coverage: std.ArrayList(Coverage) = .empty;
    var uncertainties: std.ArrayList(Uncertainty) = .empty;
    const document = input.specification.snapshot.document;
    for (document.subjects) |target| {
        var specified = false;
        var observed = false;
        var mapped = false;
        var mappings: std.ArrayList(MappingId) = .empty;
        for (input.specification.claims) |claim| if (same(claim.subject, target.id) and claim.state == .specified) {
            specified = true;
            break;
        };
        for (input.mappings) |mapping| if (same(mapping.subject, target.id)) {
            try mappings.append(allocator, mapping.id);
            mapped = mapped or mapping.implementation != null;
            observed = observed or mapping.observations.len > 0 or mapping.relations.len > 0;
        };
        try coverage.append(allocator, .{ .subject = target.id, .state = if (specified) (if (observed) .specified_observed else .specified_unobserved) else (if (observed) .unspecified_observed else .unspecified_unobserved), .mapping = if (mapped) .mapped else .unmapped, .behavior = if (observed) .static_only else .unobserved, .mappings = mappings.items, .reason = if (!mapped) "No explicit implementation mapping; behavior remains unknown" else if (!observed) "Mapped declaration has no selected telemetry; execution is unproven" else "Selected static telemetry exists; this is not runtime behavioral coverage" });
    }
    for (document.relations) |relation| if (relation.target.status == .unresolved) try uncertainties.append(allocator, .{ .subject = relation.from, .reason = relation.target.reason.?, .source = relation.source });
    var findings: std.ArrayList(Finding) = .empty;
    for (rules) |definition| {
        if (definition.rule == .derived_backing) {
            for (document.subjects) |target| if (facet(input, target.id, "derived")) try appendGap(allocator, &findings, input, definition, target.id, target.id);
            continue;
        }
        for (document.relations) |relation| {
            const affected = relation.target.subject orelse continue;
            const write = equal(relation.kind, "writes");
            const triggered = switch (definition.rule) {
                .authority => write and facet(input, affected, "owned"),
                .old_lifecycle => write and facet(input, affected, "credential") and edge(document, null, "verifies", affected),
                .identity_policy => write and facet(input, affected, "identity"),
                .dependency => write and edge(document, null, "depends_on", affected),
                .provenance_trust => (equal(relation.kind, "creates") or equal(relation.kind, "produces")) and facet(input, affected, "generated"),
                .resource_lifecycle => (equal(relation.kind, "consumes") or equal(relation.kind, "reserves")) and facet(input, affected, "resource"),
                .derived_backing => unreachable,
            };
            if (triggered) try appendGap(allocator, &findings, input, definition, relation.from, affected);
        }
    }
    var reviews: std.ArrayList(analysis.Review) = .empty;
    if (previous) |report| try reviews.appendSlice(allocator, report.reviews);
    for (input.reviews) |review| {
        var replaced = false;
        for (reviews.items) |*existing| if (same(existing.finding, review.finding)) {
            existing.* = review;
            replaced = true;
            break;
        };
        if (!replaced) try reviews.append(allocator, review);
    }
    for (findings.items) |*finding| for (reviews.items) |review| if (same(finding.id, review.finding)) {
        finding.status = review.status;
        break;
    };
    var evidence: std.ArrayList(Evidence) = .empty;
    for (findings.items) |finding| try evidence.append(allocator, try buildEvidence(allocator, input, finding.subject, finding.affected, finding.id));
    var verifications: std.ArrayList(Verification) = .empty;
    var contradictions: std.ArrayList(Contradiction) = .empty;
    var confirmed: std.ArrayList([]const u8) = .empty;
    for (input.executions) |execution| {
        var selected: ?Finding = null;
        for (findings.items) |finding| if (same(finding.id, execution.finding)) {
            selected = finding;
            break;
        };
        if (selected == null) if (previous) |report| for (report.findings) |finding| if (same(finding.id, execution.finding)) {
            selected = finding;
            break;
        };
        const finding = selected orelse return error.DanglingFinding;
        if (!same(execution.challenge, finding.challenge.id)) return error.ChallengeMismatch;
        var replay_report: ?exploration.Report = null;
        var judgment: challenge.Judgment = undefined;
        if (execution.replay) |replay| {
            if (replay.replay_version != 1 or replay.trace.actions.len == 0 or !same(replay.model.operation, finding.subject)) return error.InvalidReplay;
            const expected = try std.json.Stringify.valueAlloc(allocator, input.specification, .{});
            const actual = try std.json.Stringify.valueAlloc(allocator, replay.model.specification, .{});
            if (!equal(expected, actual)) return error.SimulationSpecificationMismatch;
            replay_report = try exploration.run(allocator, io, replay.model, replay.trace);
            if (replay_report.?.transitions.len != replay.trace.actions.len or replay_report.?.coverage.stop != .replay_complete) return error.IncompleteReplay;
            judgment = replay_report.?.transitions[replay_report.?.transitions.len - 1].judgment;
            for (replay_report.?.transitions) |transition| if (transition.judgment.outcome == .defect) {
                judgment = transition.judgment;
                break;
            };
            // Link actual replay evidence to the originating question; do not relabel simulation as runtime.
            // The verification links the originating question separately; retain the actual replay challenge.
        } else if (execution.response) |response| {
            if (!same(response.challenge.id, finding.challenge.id) or !same(response.challenge.target, finding.subject) or response.challenge.generated_from.finding == null or !equal(response.challenge.generated_from.finding.?, finding.id.bytes)) return error.ChallengeMismatch;
            const expected_question = try std.json.Stringify.valueAlloc(allocator, finding.challenge, .{});
            const actual_question = try std.json.Stringify.valueAlloc(allocator, response.challenge, .{});
            if (!equal(expected_question, actual_question)) return error.ChallengeMismatch;
            judgment = try challenge.judge(allocator, input.specification, response);
        } else unreachable;
        var mapping_confident = false;
        for (input.mappings) |mapping| if (same(mapping.subject, finding.subject) and mapping.implementation != null and mapping.confidence == .high) {
            mapping_confident = true;
            break;
        };
        var runtime_evidence = judgment.response.origin == .runtime and judgment.response.effects.len > 0;
        for (judgment.response.evidence.facts) |fact| if (fact.origin == .inference or fact.origin == .specification or fact.origin == .@"test") {
            runtime_evidence = false;
            break;
        };
        for (judgment.response.effects) |effect| if (effect.origin != .runtime and effect.origin != .code) {
            runtime_evidence = false;
            break;
        };
        const classification: @FieldType(Verification, "classification") = if (judgment.outcome == .acceptable) .acceptable else if (judgment.outcome != .defect) .inconclusive else if (judgment.response.origin == .simulation or judgment.response.origin == .@"test") .simulated_counterexample else if (runtime_evidence and mapping_confident) .observed_violation else .inconclusive;
        if (classification == .observed_violation) try confirmed.append(allocator, execution.name);
        try verifications.append(allocator, .{ .name = execution.name, .finding = finding.id, .challenge = finding.challenge.id, .origin = judgment.response.origin, .classification = classification, .judgment = judgment, .exploration = replay_report });
        if (judgment.outcome == .defect) {
            const chain = try buildEvidence(allocator, input, finding.subject, finding.affected, finding.id);
            try contradictions.append(allocator, .{ .finding = finding.id, .verification = execution.name, .specification_sources = chain.specification_sources, .implementation_sources = chain.implementation_sources, .explanations = &.{ "The specification may be incorrect or incomplete", "The symbolic or simulation model may differ from the implementation", "The implementation may violate the constraint", "The observation or trace may be incomplete or inaccurate", "The specification-to-implementation mapping may be wrong" } });
            for (findings.items) |*current| if (same(current.id, finding.id)) {
                for (judgment.constraints.results) |result| if (result.outcome == .violated) if (result.constraint) |constraint| {
                    current.suggestion.constraint = constraint.expression;
                    current.suggestion.kind = result.claim.kind;
                    current.suggestion.governing_constraint = constraint.id;
                    current.suggestion.origin = .trace;
                    current.suggestion.severity = if (classification == .observed_violation) .@"error" else .warning;
                    break;
                };
            };
        }
    }
    return .{ .revision = try reportRevision(allocator, input), .input = input, .coverage = coverage.items, .evidence = evidence.items, .findings = findings.items, .uncertainties = uncertainties.items, .verifications = verifications.items, .contradictions = contradictions.items, .confirmed_violations = confirmed.items, .reviews = reviews.items };
}

pub const Change = struct { category: []const u8, key: []const u8, kind: enum { added, removed, changed }, before: ?[]const u8, after: ?[]const u8 };
pub const Diff = struct { cross_diff_version: u32 = 1, before: []const u8, after: []const u8, changes: []const Change };
const HistoryRow = struct { category: []const u8, key: []const u8, value: []const u8 };
fn history(allocator: std.mem.Allocator, report: Report) ![]const HistoryRow {
    var rows: std.ArrayList(HistoryRow) = .empty;
    inline for (.{ report.input.snapshot.document.observations, report.input.specification.snapshot.document.observations }) |observations| for (observations) |observation| {
        var normalized = observation;
        normalized.revision = "history";
        normalized.id = try ir.observationId(allocator, normalized);
        try rows.append(allocator, .{ .category = "observations", .key = normalized.id.bytes, .value = try std.json.Stringify.valueAlloc(allocator, normalized, .{}) });
    };
    inline for (.{ report.input.snapshot.document.relations, report.input.specification.snapshot.document.relations }) |relations| for (relations) |relation| {
        var normalized = relation;
        normalized.revision = "history";
        normalized.id = try ir.relationId(allocator, normalized);
        try rows.append(allocator, .{ .category = "relations", .key = normalized.id.bytes, .value = try std.json.Stringify.valueAlloc(allocator, normalized, .{}) });
    };
    inline for (.{ .{ "evidence", report.evidence }, .{ "findings", report.findings }, .{ "mappings", report.input.mappings } }) |group| for (group[1]) |record| try rows.append(allocator, .{ .category = group[0], .key = record.id.bytes, .value = try std.json.Stringify.valueAlloc(allocator, record, .{}) });
    for (report.input.specification.claims) |claim| {
        var constraint: ?specification.Constraint = null;
        if (claim.constraint) |identifier| for (report.input.specification.constraints) |candidate| if (same(candidate.id, identifier)) {
            constraint = candidate;
            break;
        };
        try rows.append(allocator, .{ .category = "claims", .key = claim.id.bytes, .value = try std.json.Stringify.valueAlloc(allocator, .{ .claim = claim, .constraint = constraint }, .{}) });
    }
    for (report.verifications) |verification| try rows.append(allocator, .{ .category = "verification_results", .key = verification.name, .value = try std.json.Stringify.valueAlloc(allocator, verification, .{}) });
    for (report.input.symbolic_results, 0..) |result, index| try rows.append(allocator, .{ .category = "symbolic_results", .key = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ result.query.claim.bytes, index }), .value = try std.json.Stringify.valueAlloc(allocator, result, .{}) });
    for (report.reviews) |review| try rows.append(allocator, .{ .category = "reviews", .key = review.finding.bytes, .value = try std.json.Stringify.valueAlloc(allocator, review, .{}) });
    for (report.input.policies) |policy| try rows.append(allocator, .{ .category = "policies", .key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ policy.subject.bytes, @tagName(policy.rule) }), .value = try std.json.Stringify.valueAlloc(allocator, policy, .{}) });
    return rows.items;
}
pub fn diff(allocator: std.mem.Allocator, before: Report, after: Report) !Diff {
    if (before.cross_version != 1 or after.cross_version != 1) return error.UnsupportedCrossVersion;
    try validateReport(allocator, before);
    try validateReport(allocator, after);
    if (!equal(before.input.snapshot.project, after.input.snapshot.project)) return error.ProjectMismatch;
    const previous = try history(allocator, before);
    const current = try history(allocator, after);
    var changes: std.ArrayList(Change) = .empty;
    var previous_index: std.StringHashMapUnmanaged(HistoryRow) = .empty;
    var current_index: std.StringHashMapUnmanaged(HistoryRow) = .empty;
    for (previous) |row| try previous_index.put(allocator, try std.mem.concat(allocator, u8, &.{ row.category, "\x00", row.key }), row);
    for (current) |row| try current_index.put(allocator, try std.mem.concat(allocator, u8, &.{ row.category, "\x00", row.key }), row);
    for (previous) |old| {
        const key = try std.mem.concat(allocator, u8, &.{ old.category, "\x00", old.key });
        if (current_index.get(key)) |new| {
            if (!equal(old.value, new.value)) try changes.append(allocator, .{ .category = old.category, .key = old.key, .kind = .changed, .before = old.value, .after = new.value });
        } else try changes.append(allocator, .{ .category = old.category, .key = old.key, .kind = .removed, .before = old.value, .after = null });
    }
    for (current) |new| {
        const key = try std.mem.concat(allocator, u8, &.{ new.category, "\x00", new.key });
        if (!previous_index.contains(key)) try changes.append(allocator, .{ .category = new.category, .key = new.key, .kind = .added, .before = null, .after = new.value });
    }
    return .{ .before = before.revision, .after = after.revision, .changes = changes.items };
}

pub fn validateReport(allocator: std.mem.Allocator, report: Report) !void {
    if (report.cross_version != 1) return error.UnsupportedCrossVersion;
    try validate(allocator, report.input);
    if (!equal(report.revision, try reportRevision(allocator, report.input))) return error.InvalidReportRevision;
    for (report.reviews) |review| if (!identity.valid(review.finding.bytes, "fnd_") or !ir.nonempty(review.note) or !ir.nonempty(review.revision)) return error.InvalidReview;
    for (report.findings) |finding| {
        if (subject(report.input.specification.snapshot.document, finding.subject) == null or subject(report.input.specification.snapshot.document, finding.affected) == null) return error.DanglingFinding;
        if (!same(finding.id, try findingId(allocator, finding.subject, finding.affected, finding.rule))) return error.InvalidFinding;
        if (!same(finding.challenge.id, try identity.make(allocator, challenge.ChallengeId, "cha_", &.{ "cross-challenge", finding.id.bytes })) or !same(finding.challenge.target, finding.subject) or finding.challenge.generated_from.finding == null or !equal(finding.challenge.generated_from.finding.?, finding.id.bytes)) return error.ChallengeMismatch;
        if (!same(finding.suggestion.generated_from, finding.id)) return error.InvalidSuggestion;
        try specification.validateExpressions(finding.suggestion.constraint, false);
    }
}
