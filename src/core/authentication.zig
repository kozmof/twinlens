//! Bounded synthetic authentication histories. This module never handles real credentials.
const std = @import("std");
const ir = @import("ir.zig");
const identity = @import("identity.zig");
const specification = @import("specification.zig");
const challenge = @import("challenge.zig");
pub const Operation = enum { Register, Login, Logout, ChangePassword, ResetPassword, ChangeEmail, VerifyEmail, CreateSession, DeleteUser };
pub const Family = enum { null_value, wrong_owner, old_value, missing_relation, many_relation, expired_value, unauthorized_caller, deleted_entity, unverified_identity, shared_ownership, stale_identity, single_use, session_policy, lifecycle };
pub const Rule = enum { inputs_present, credential_binding, current_credential, authority, unique_identity, exclusive_credential, token_expiry, token_single_use, account_active, identity_verified, identity_current, session_ownership, old_credential_revoked, session_invalidation, rejection_atomic };
pub const Policy = struct { rule: Rule, level: enum { required, optional, domain_dependent, unknown }, reason: []const u8 };
pub const Profile = struct { name: []const u8, policies: []const Policy, sessions_after_change: enum { revoke, preserve, domain_dependent } };
pub const User = struct { id: []const u8, email: ?[]const u8, current_credential: ?[]const u8, status: enum { active, deleted }, verification: enum { verified, unverified } };
pub const Credential = struct { id: []const u8, owners: []const []const u8, secret: ?[]const u8, status: enum { active, revoked } };
pub const Session = struct { id: []const u8, owner: []const u8, email: ?[]const u8, status: enum { active, revoked } };
pub const Token = struct { id: []const u8, owner: []const u8, email: ?[]const u8, expires_at: u32, status: enum { fresh, used } };
pub const State = struct { users: []const User, credentials: []const Credential, sessions: []const Session, tokens: []const Token };
pub const Action = struct { operation: Operation, actor: ?[]const u8, user: []const u8, email: ?[]const u8, secret: ?[]const u8, token: ?[]const u8, session: ?[]const u8, at: u32 };
pub const Scenario = struct { name: []const u8, family: Family, initial: State, actions: []const Action };
pub const Bounds = struct { max_scenarios: u32, max_steps: u32, max_objects: u32, max_time_ms: u32 };
pub const Model = struct { authentication_version: u32, specification: specification.Specification, profile: Profile, adapter: enum { deliberately_weak, policy_enforced }, scenarios: []const Scenario, bounds: Bounds };
pub const Trace = struct { model_digest: []const u8, scenario: []const u8, actions: []const Action };
pub const Replay = struct { authentication_replay_version: u32, model: Model, trace: Trace };
pub const Suggestion = struct { target: ir.SubjectId, kind: specification.ClaimKind, constraint: []const specification.Expression, rule: Rule, source: ir.Source, origin: enum { simulation }, confidence: enum { high }, severity: enum { warning } };
pub const Check = struct { rule: Rule, judgment: challenge.Judgment, suggestion: ?Suggestion };
pub const Transition = struct { id: []const u8, scenario: []const u8, step: u32, action: Action, before: State, after: State, result: enum { accepted, rejected }, checks: []const Check };
pub const Report = struct { authentication_version: u32 = 1, model_digest: []const u8, model: Model, transitions: []const Transition, counterexamples: []const Trace, coverage: struct { executed_scenarios: u32, executed_steps: u32, supplied_scenarios: usize, excluded_scenarios: []const []const u8, stop: enum { catalog_exhausted, scenario_limit, step_limit, object_limit, time_limit, replay_complete }, scope: []const u8 }, classification: enum { simulation_only } = .simulation_only };
const rule_count = @typeInfo(Rule).@"enum".fields.len;
const Flags = struct {
    values: [rule_count]bool = @splat(true),
    fn get(self: Flags, rule: Rule) bool {
        return self.values[@intFromEnum(rule)];
    }
    fn set(self: *Flags, rule: Rule, value: bool) void {
        self.values[@intFromEnum(rule)] = value;
    }
};
fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    return if (left) |value| if (right) |other| equal(value, other) else false else right == null;
}
fn present(value: ?[]const u8) bool {
    return if (value) |text| ir.nonempty(text) else false;
}
fn contains(owners: []const []const u8, owner: []const u8) bool {
    for (owners) |candidate| if (equal(candidate, owner)) return true;
    return false;
}
fn userIndex(state: State, name: []const u8) ?usize {
    for (state.users, 0..) |user, index| if (equal(user.id, name)) return index;
    return null;
}
fn objects(state: State) usize {
    return state.users.len + state.credentials.len + state.sessions.len + state.tokens.len;
}
fn level(profile: Profile, rule: Rule) @FieldType(Policy, "level") {
    for (profile.policies) |policy| if (policy.rule == rule) return policy.level;
    return .unknown;
}
pub fn applies(rule: Rule, operation: Operation) bool {
    return switch (rule) {
        .inputs_present, .rejection_atomic => true,
        .credential_binding, .current_credential, .exclusive_credential => operation == .Login,
        .authority => switch (operation) {
            .Register, .Login, .ResetPassword => false,
            else => true,
        },
        .unique_identity => operation == .Register or operation == .Login or operation == .ChangeEmail,
        .token_expiry, .token_single_use => operation == .ResetPassword,
        .account_active => operation != .Register,
        .identity_verified => operation == .Login or operation == .ResetPassword or operation == .CreateSession,
        .identity_current => operation == .ResetPassword or operation == .VerifyEmail,
        .session_ownership => operation == .Logout,
        .old_credential_revoked, .session_invalidation => operation == .ChangePassword or operation == .ResetPassword,
    };
}
fn postcondition(rule: Rule) bool {
    return rule == .old_credential_revoked or rule == .session_invalidation or rule == .rejection_atomic;
}
fn validAtom(value: []const u8) bool {
    return ir.nonempty(value) and value.len <= 128;
}
fn validateState(state: State) !void {
    if (objects(state) > 64) return error.AuthenticationObjectLimit;
    inline for (.{ state.users, state.credentials, state.sessions, state.tokens }) |records| for (records, 0..) |record, index| {
        if (!validAtom(record.id)) return error.InvalidAuthenticationIdentity;
        for (records[0..index]) |previous| if (equal(previous.id, record.id)) return error.DuplicateAuthenticationIdentity;
    };
    for (state.users) |user| if (user.id.len > 96) return error.InvalidAuthenticationIdentity;
    for (state.users) |user| if (user.current_credential) |identifier| if (!validAtom(identifier)) return error.InvalidAuthenticationIdentity;
    for (state.users) |user| if (user.email) |email| if (email.len > 128) return error.InvalidAuthenticationValue;
    for (state.credentials) |credential| {
        if (credential.owners.len > 8) return error.InvalidAuthenticationOwners;
        if (credential.secret) |secret| if (secret.len > 128) return error.InvalidAuthenticationValue;
        for (credential.owners, 0..) |owner, index| {
            if (userIndex(state, owner) == null) return error.DanglingAuthenticationOwner;
            for (credential.owners[0..index]) |previous| if (equal(previous, owner)) return error.DuplicateAuthenticationOwner;
        }
    }
    inline for (.{ state.sessions, state.tokens }) |records| for (records) |record| {
        if (userIndex(state, record.owner) == null) return error.DanglingAuthenticationOwner;
        if (record.email) |email| if (email.len > 128) return error.InvalidAuthenticationValue;
    };
}
fn operationSubject(model: specification.Specification, operation: Operation) ?ir.Subject {
    for (model.snapshot.document.subjects) |subject| if (equal(subject.key.kind, "operation") and equal(subject.key.name, @tagName(operation))) return subject;
    return null;
}
pub fn validate(allocator: std.mem.Allocator, model: Model) !void {
    if (model.authentication_version != 1 or model.scenarios.len == 0 or model.scenarios.len > 64 or !validAtom(model.profile.name)) return error.InvalidAuthenticationModel;
    const bounds = model.bounds;
    if (bounds.max_scenarios == 0 or bounds.max_scenarios > 64 or bounds.max_steps == 0 or bounds.max_steps > 1024 or bounds.max_objects == 0 or bounds.max_objects > 64 or bounds.max_time_ms == 0 or bounds.max_time_ms > 60000) return error.InvalidAuthenticationBounds;
    try specification.validate(allocator, model.specification);
    for (model.specification.snapshot.diagnostics) |diagnostic| if (diagnostic.category == .@"error") return error.InvalidSpecification;
    inline for (@typeInfo(Operation).@"enum".fields) |field| if (operationSubject(model.specification, @enumFromInt(field.value)) == null) return error.MissingAuthenticationOperation;
    for (model.profile.policies, 0..) |policy, index| {
        if (!ir.nonempty(policy.reason)) return error.InvalidAuthenticationPolicy;
        for (model.profile.policies[0..index]) |previous| if (previous.rule == policy.rule) return error.DuplicateAuthenticationPolicy;
    }
    for (model.scenarios, 0..) |scenario, index| {
        if (!validAtom(scenario.name) or scenario.actions.len == 0 or scenario.actions.len > 32) return error.InvalidAuthenticationScenario;
        for (model.scenarios[0..index]) |previous| if (equal(previous.name, scenario.name)) return error.DuplicateAuthenticationScenario;
        try validateState(scenario.initial);
        var previous_time: u32 = 0;
        for (scenario.actions) |action| {
            if (!validAtom(action.user) or action.user.len > 96 or action.at < previous_time) return error.InvalidAuthenticationAction;
            inline for (.{ action.actor, action.email, action.secret, action.token, action.session }) |value| if (value) |text| if (text.len > 128) return error.InvalidAuthenticationValue;
            previous_time = action.at;
        }
    }
}
pub fn modelDigest(allocator: std.mem.Allocator, model: Model) ![]const u8 {
    // Adapter and resource bounds can change when replaying the same contract/catalog.
    return digest(allocator, .{ model.specification, model.profile, model.scenarios });
}
fn digest(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.allocPrint(allocator, "{x}", .{&hash});
}
const Applied = struct { state: State, accepted: bool, changed: bool = false, flags: Flags };
fn apply(allocator: std.mem.Allocator, model: Model, before: State, action: Action, step: usize) !Applied {
    var flags: Flags = .{};
    const selected = userIndex(before, action.user);
    const user: ?User = if (selected) |index| before.users[index] else null;
    var credential: ?Credential = null;
    // Weak login intentionally accepts another owner's, revoked, or missing credential.
    for (before.credentials) |candidate| if (optionalEqual(candidate.secret, action.secret)) {
        if (credential == null) credential = candidate;
        if (contains(candidate.owners, action.user) and candidate.status == .active and candidate.owners.len == 1) {
            credential = candidate;
            break;
        }
    };
    var token: ?Token = null;
    for (before.tokens) |candidate| if (optionalEqual(candidate.id, action.token)) {
        token = candidate;
        break;
    };
    var session: ?Session = null;
    for (before.sessions) |candidate| if (optionalEqual(candidate.id, action.session)) {
        session = candidate;
        break;
    };
    const needs_email = action.operation == .Register or action.operation == .Login or action.operation == .ChangeEmail or action.operation == .VerifyEmail;
    const needs_secret = action.operation == .Register or action.operation == .Login or action.operation == .ChangePassword or action.operation == .ResetPassword;
    flags.set(.inputs_present, (!needs_email or present(action.email)) and (!needs_secret or present(action.secret)));
    flags.set(.credential_binding, if (credential) |record| contains(record.owners, action.user) else false);
    flags.set(.current_credential, if (credential) |record| record.status == .active and (if (user) |owner| optionalEqual(owner.current_credential, record.id) else false) else false);
    flags.set(.exclusive_credential, if (credential) |record| record.owners.len == 1 else false);
    flags.set(.authority, optionalEqual(action.actor, action.user));
    flags.set(.account_active, if (user) |record| record.status == .active else false);
    flags.set(.identity_verified, if (user) |record| record.verification == .verified else false);
    flags.set(.token_expiry, if (token) |record| record.expires_at > action.at and equal(record.owner, action.user) else false);
    flags.set(.token_single_use, if (token) |record| record.status == .fresh else false);
    flags.set(.identity_current, if (user) |record| if (action.operation == .ResetPassword) (if (token) |issued| optionalEqual(issued.email, record.email) else false) else optionalEqual(action.email, record.email) else false);
    flags.set(.session_ownership, if (session) |record| optionalEqual(action.actor, record.owner) and equal(action.user, record.owner) else false);
    var matches: usize = 0;
    for (before.users) |record| if (record.status == .active and optionalEqual(record.email, action.email) and (action.operation != .ChangeEmail or !equal(record.id, action.user))) {
        matches += 1;
    };
    flags.set(.unique_identity, if (action.operation == .Login) matches == 1 and (if (user) |record| optionalEqual(action.email, record.email) else false) else matches == 0);
    var accepted = if (action.operation == .Register) selected == null else selected != null;
    if (action.operation == .Logout) accepted = accepted and session != null;
    if (action.operation == .ResetPassword) accepted = accepted and token != null;
    if (model.adapter == .policy_enforced) inline for (@typeInfo(Rule).@"enum".fields) |field| {
        const rule: Rule = @enumFromInt(field.value);
        if (applies(rule, action.operation) and !postcondition(rule) and level(model.profile, rule) == .required and !flags.get(rule)) accepted = false;
    };
    if (!accepted) return .{ .state = before, .accepted = false, .flags = flags };
    var users: std.ArrayList(User) = .empty;
    try users.appendSlice(allocator, before.users);
    var credentials: std.ArrayList(Credential) = .empty;
    try credentials.appendSlice(allocator, before.credentials);
    var sessions: std.ArrayList(Session) = .empty;
    try sessions.appendSlice(allocator, before.sessions);
    const tokens = try allocator.dupe(Token, before.tokens);
    const generated = try std.fmt.allocPrint(allocator, "created:{s}:{d}", .{ action.user, step });
    const enforced = model.adapter == .policy_enforced;
    switch (action.operation) {
        .Register => {
            try users.append(allocator, .{ .id = action.user, .email = action.email, .current_credential = generated, .status = .active, .verification = .unverified });
            try credentials.append(allocator, .{ .id = generated, .owners = try allocator.dupe([]const u8, &.{action.user}), .secret = action.secret, .status = .active });
        },
        .Login, .CreateSession => try sessions.append(allocator, .{ .id = generated, .owner = action.user, .email = user.?.email, .status = .active }),
        .Logout => {
            for (sessions.items) |*record| if (optionalEqual(record.id, action.session)) {
                record.status = .revoked;
            };
        },
        .ChangePassword, .ResetPassword => {
            users.items[selected.?].current_credential = generated;
            if (enforced and level(model.profile, .old_credential_revoked) == .required) for (credentials.items) |*record| if (contains(record.owners, action.user)) {
                record.status = .revoked;
            };
            try credentials.append(allocator, .{ .id = generated, .owners = try allocator.dupe([]const u8, &.{action.user}), .secret = action.secret, .status = .active });
            if (enforced and action.operation == .ResetPassword and level(model.profile, .token_single_use) == .required) for (tokens) |*record| if (optionalEqual(record.id, action.token)) {
                record.status = .used;
            };
            if (enforced and level(model.profile, .session_invalidation) == .required and model.profile.sessions_after_change == .revoke) for (sessions.items) |*record| if (equal(record.owner, action.user)) {
                record.status = .revoked;
            };
        },
        .ChangeEmail => {
            users.items[selected.?].email = action.email;
            users.items[selected.?].verification = .unverified;
        },
        .VerifyEmail => {
            users.items[selected.?].verification = .verified;
        },
        .DeleteUser => {
            users.items[selected.?].status = .deleted;
            if (enforced) for (sessions.items) |*record| if (equal(record.owner, action.user)) {
                record.status = .revoked;
            };
        },
    }
    var revoked = true;
    for (before.credentials) |old| if (contains(old.owners, action.user) and old.status == .active) {
        for (credentials.items) |current| if (equal(current.id, old.id) and current.status == .active) {
            revoked = false;
        };
    };
    flags.set(.old_credential_revoked, revoked);
    if (action.operation == .ResetPassword) for (tokens) |record| if (optionalEqual(record.id, action.token)) {
        flags.set(.token_single_use, flags.get(.token_single_use) and record.status == .used);
    };
    var session_policy = true;
    for (before.sessions) |old| if (equal(old.owner, action.user) and old.status == .active) {
        for (sessions.items) |current| if (equal(current.id, old.id)) {
            if (model.profile.sessions_after_change == .revoke and current.status != .revoked) session_policy = false;
            if (model.profile.sessions_after_change == .preserve and current.status != .active) session_policy = false;
        };
    };
    flags.set(.session_invalidation, session_policy);
    // Initial states may contain arbitrary labels, including a generated-looking ID.
    const after: State = .{ .users = users.items, .credentials = credentials.items, .sessions = sessions.items, .tokens = tokens };
    validateState(after) catch |failure| {
        if (failure == error.DuplicateAuthenticationIdentity) return .{ .state = before, .accepted = false, .flags = flags };
        return failure;
    };
    return .{ .state = after, .accepted = true, .changed = !equal(try digest(allocator, before), try digest(allocator, after)), .flags = flags };
}
fn boolean(value: bool) specification.Scalar {
    return .{ .kind = .boolean, .value = if (value) "true" else "false" };
}
fn checks(allocator: std.mem.Allocator, model: Model, scenario: Scenario, action: Action, applied: Applied) ![]const Check {
    const target = operationSubject(model.specification, action.operation).?;
    const origin: ir.Source = .{ .path = "src/core/authentication.zig", .language = "zig", .span = .{ .start = 0, .end = 0 }, .producer = "authentication-simulation/1", .confidence = .high };
    var facts: std.ArrayList(specification.Fact) = .empty;
    try facts.append(allocator, .{ .name = "response.success", .status = .known, .value = boolean(applied.accepted), .reason = null, .source = origin, .origin = .trace });
    inline for (@typeInfo(Rule).@"enum".fields) |field| try facts.append(allocator, .{ .name = "auth." ++ field.name, .status = .known, .value = boolean(applied.flags.get(@enumFromInt(field.value))), .reason = null, .source = origin, .origin = .trace });
    const effects = try allocator.dupe(challenge.Effect, if (applied.changed) &.{ .{ .name = "result", .kind = .return_value, .subject = target.id, .value = boolean(true), .source = origin, .origin = .simulation }, .{ .name = "state", .kind = .state_change, .subject = target.id, .value = null, .source = origin, .origin = .simulation } } else &.{.{ .name = "result", .kind = .return_value, .subject = target.id, .value = boolean(applied.accepted), .source = origin, .origin = .simulation }});
    var results: std.ArrayList(Check) = .empty;
    inline for (@typeInfo(Rule).@"enum".fields) |field| {
        const rule: Rule = @enumFromInt(field.value);
        if (applies(rule, action.operation)) {
            var selected: ?specification.Claim = null;
            for (model.specification.claims) |claim| if (equal(claim.subject.bytes, target.id.bytes) and equal(claim.name, field.name)) {
                selected = claim;
                break;
            };
            const constraints = if (selected) |claim| if (claim.constraint) |constraint| try allocator.dupe(specification.ConstraintId, &.{constraint}) else &.{} else &.{};
            const question: challenge.Challenge = .{ .id = try identity.make(allocator, challenge.ChallengeId, "cha_", &.{ "authentication", scenario.name, @tagName(scenario.family), target.id.bytes, field.name }), .target = target.id, .target_operation = target.id, .assumptions = &.{}, .constraints = constraints, .question = try std.fmt.allocPrint(allocator, "Can {s} violate {s} during the {s} scenario?", .{ @tagName(action.operation), field.name, @tagName(scenario.family) }), .suspicious_condition = scenario.name, .expectation = if (constraints.len > 0) .required else .unknown, .execution = .simulation, .generated_from = .{ .claim = if (selected) |claim| claim.id else null, .finding = null, .evidence = try allocator.dupe(ir.Source, &.{target.source}) } };
            const policy = level(model.profile, rule);
            const judgment = try challenge.judge(allocator, model.specification, .{ .oracle_version = 1, .challenge = question, .response = .{ .operation = target.id, .origin = .simulation, .coverage = .complete, .effects = effects, .evidence = .{ .input_version = 1, .project = model.specification.snapshot.project, .facts = facts.items, .graph = null, .coverage = .absent } }, .expectations = &.{ .{ .name = "result", .kind = .return_value, .classification = .required, .source = origin }, .{ .name = "state", .kind = .state_change, .classification = if (applied.accepted) .possible else .forbidden, .source = origin } }, .policy = if (policy == .unknown) .unknown else if (policy == .domain_dependent or policy == .optional or (rule == .session_invalidation and model.profile.sessions_after_change == .domain_dependent)) .domain_dependent else .enforced });
            var suggestion: ?Suggestion = null;
            for (judgment.constraints.results) |result| if (result.outcome == .violated and judgment.outcome == .defect) if (result.constraint) |constraint| {
                suggestion = .{ .target = target.id, .kind = result.claim.kind, .constraint = constraint.expression, .rule = rule, .source = constraint.source, .origin = .simulation, .confidence = .high, .severity = .warning };
                break;
            };
            try results.append(allocator, .{ .rule = rule, .judgment = judgment, .suggestion = suggestion });
        }
    }
    return results.items;
}
pub fn run(allocator: std.mem.Allocator, io: std.Io, model: Model, replay: ?Trace) !Report {
    try validate(allocator, model);
    const model_digest = try modelDigest(allocator, model);
    var replay_found = replay == null;
    if (replay) |trace| {
        if (!equal(trace.model_digest, model_digest)) return error.AuthenticationReplayMismatch;
        for (model.scenarios) |scenario| if (equal(scenario.name, trace.scenario)) {
            if (trace.actions.len == 0 or trace.actions.len > scenario.actions.len) return error.InvalidAuthenticationReplay;
            if (!equal(try digest(allocator, trace.actions), try digest(allocator, scenario.actions[0..trace.actions.len]))) return error.InvalidAuthenticationReplay;
            replay_found = true;
            break;
        };
    }
    if (!replay_found) return error.InvalidAuthenticationReplay;
    var transitions: std.ArrayList(Transition) = .empty;
    var counterexamples: std.ArrayList(Trace) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    var coverage: @FieldType(Report, "coverage") = .{ .executed_scenarios = 0, .executed_steps = 0, .supplied_scenarios = model.scenarios.len, .excluded_scenarios = &.{}, .stop = if (replay != null) .replay_complete else .catalog_exhausted, .scope = "Finite supplied synthetic authentication histories; simulation evidence only. No runtime authentication, cryptography, network, concurrency, or universal state-space coverage." };
    const started = std.Io.Clock.awake.now(io);
    var stopped = false;
    for (model.scenarios) |scenario| {
        if (replay) |trace| if (!equal(scenario.name, trace.scenario)) continue;
        if (coverage.executed_scenarios >= model.bounds.max_scenarios and !stopped) {
            coverage.stop = .scenario_limit;
            stopped = true;
        }
        if (stopped) {
            try excluded.append(allocator, scenario.name);
            continue;
        }
        var state = scenario.initial;
        if (objects(state) > model.bounds.max_objects) {
            coverage.stop = .object_limit;
            try excluded.append(allocator, scenario.name);
            continue;
        }
        coverage.executed_scenarios += 1;
        const actions = if (replay) |trace| trace.actions else scenario.actions;
        for (actions, 0..) |action, index| {
            if (coverage.executed_steps >= model.bounds.max_steps) {
                coverage.stop = .step_limit;
                stopped = true;
                break;
            }
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= model.bounds.max_time_ms) {
                coverage.stop = .time_limit;
                stopped = true;
                break;
            }
            var applied = apply(allocator, model, state, action, index) catch |failure| {
                if (failure == error.AuthenticationObjectLimit) {
                    coverage.stop = .object_limit;
                    stopped = true;
                    break;
                }
                return failure;
            };
            if (objects(applied.state) > model.bounds.max_objects) {
                coverage.stop = .object_limit;
                stopped = true;
                break;
            }
            applied.flags.set(.rejection_atomic, applied.accepted or equal(try digest(allocator, state), try digest(allocator, applied.state)));
            const results = try checks(allocator, model, scenario, action, applied);
            const identifier = try digest(allocator, .{ scenario.name, index, action, state, applied.state });
            try transitions.append(allocator, .{ .id = identifier, .scenario = scenario.name, .step = @intCast(index), .action = action, .before = state, .after = applied.state, .result = if (applied.accepted) .accepted else .rejected, .checks = results });
            coverage.executed_steps += 1;
            for (results) |check| if (check.judgment.outcome == .defect) {
                try counterexamples.append(allocator, .{ .model_digest = model_digest, .scenario = scenario.name, .actions = actions[0 .. index + 1] });
                break;
            };
            state = applied.state;
        }
        if (stopped) try excluded.append(allocator, scenario.name);
    }
    coverage.excluded_scenarios = excluded.items;
    return .{ .model_digest = model_digest, .model = model, .transitions = transitions.items, .counterexamples = counterexamples.items, .coverage = coverage };
}

fn testModel(allocator: std.mem.Allocator) !Model {
    const origin: ir.Source = .{ .path = "auth.tsp", .language = "typespec", .span = .{ .start = 0, .end = 1 }, .producer = "fixture", .confidence = .high };
    var subjects: std.ArrayList(ir.Subject) = .empty;
    inline for (@typeInfo(Operation).@"enum".fields) |field| {
        const key: ir.SubjectKey = .{ .project = "fixture", .language = "typespec", .path = "auth.tsp", .kind = "operation", .name = field.name, .discriminator = "0" };
        try subjects.append(allocator, .{ .id = try key.id(allocator), .key = key, .source = origin });
    }
    const target = subjects.items[0].id;
    var constraint: specification.Constraint = .{ .id = undefined, .subject = target, .name = "inputs_present", .expression = &.{ .{ .op = .fact, .args = &.{}, .name = "response.success", .value = null }, .{ .op = .fact, .args = &.{}, .name = "auth.inputs_present", .value = null }, .{ .op = .implies, .args = &.{ 0, 1 }, .name = null, .value = null } }, .source = origin };
    constraint.id = try specification.constraintId(allocator, constraint);
    var claim: specification.Claim = .{ .id = undefined, .subject = target, .name = constraint.name, .kind = .invariant, .state = .specified, .reason = "Explicit test requirement", .constraint = constraint.id, .source = origin };
    claim.id = try specification.claimId(allocator, claim);
    return .{
        .authentication_version = 1,
        .specification = .{
            .specification_version = 1,
            .snapshot = .{ .snapshot_version = 1, .project = "fixture", .configuration = .{ .adapter = "fixture", .compiler = "0", .options_sha256 = "0" ** 64, .configs = &.{} }, .files = &.{.{ .path = "auth.tsp", .sha256 = "0" ** 64 }}, .diagnostics = &.{}, .coverage = .{ .unresolved_calls = 0, .unresolved_accesses = 0 }, .document = .{ .schema_version = 1, .revision = "r1", .subjects = subjects.items, .symbols = &.{}, .observations = &.{}, .relations = &.{} } },
            .claims = try allocator.dupe(specification.Claim, &.{claim}),
            .constraints = try allocator.dupe(specification.Constraint, &.{constraint}),
            .functions = &.{},
            .domains = &.{},
        },
        .profile = .{ .name = "fixture", .policies = &.{.{ .rule = .inputs_present, .level = .required, .reason = "Null input is forbidden" }}, .sessions_after_change = .domain_dependent },
        .adapter = .deliberately_weak,
        .scenarios = &.{.{ .name = "null-input", .family = .null_value, .initial = .{ .users = &.{}, .credentials = &.{}, .sessions = &.{}, .tokens = &.{} }, .actions = &.{.{ .operation = .Register, .actor = null, .user = "alice", .email = null, .secret = null, .token = null, .session = null, .at = 0 }} }},
        .bounds = .{ .max_scenarios = 1, .max_steps = 2, .max_objects = 8, .max_time_ms = 60000 },
    };
}
fn exerciseAllocations(backing: std.mem.Allocator, model: Model) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const before = try run(allocator, std.testing.io, model, null);
    try std.testing.expectEqual(@as(usize, 1), before.counterexamples.len);
    var corrected = model;
    corrected.adapter = .policy_enforced;
    const after = try run(allocator, std.testing.io, corrected, before.counterexamples[0]);
    try std.testing.expectEqual(@as(usize, 0), after.counterexamples.len);
    try std.testing.expectEqual(@as(usize, 0), after.transitions[0].after.users.len);
    try std.testing.expectEqualStrings("replay_complete", @tagName(after.coverage.stop));
}
test "authentication execution, oracle, and corrected replay clean up after allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocations, .{try testModel(arena.allocator())});
}
test "authentication time budget stops before applying an action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var model = try testModel(arena.allocator());
    model.bounds.max_time_ms = 1;
    const FakeClock = struct {
        fn now(context: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const counter: *u32 = @ptrCast(@alignCast(context.?));
            counter.* += 1;
            return .{ .nanoseconds = @as(i96, counter.*) * 2 * std.time.ns_per_ms };
        }
    };
    var counter: u32 = 0;
    var vtable = std.testing.io.vtable.*;
    vtable.now = FakeClock.now;
    const io: std.Io = .{ .userdata = &counter, .vtable = &vtable };
    const report = try run(arena.allocator(), io, model, null);
    try std.testing.expectEqualStrings("time_limit", @tagName(report.coverage.stop));
    try std.testing.expectEqual(@as(usize, 0), report.transitions.len);
}
