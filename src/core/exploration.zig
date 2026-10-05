//! Finite source-world exploration using the real Store replacement API.
const std = @import("std");
const ir = @import("ir.zig");
const identity = @import("identity.zig");
const snapshot = @import("snapshot.zig");
const specification = @import("specification.zig");
const challenge = @import("challenge.zig");
const Store = @import("store.zig").Store;
pub const Bounds = struct { max_depth: u32, max_objects: u32, max_executions: u32, max_time_ms: u32 };
pub const Adapter = enum { native_store, test_stale_delete };
pub const World = struct { name: []const u8, snapshot: snapshot.Snapshot };
pub const Model = struct { exploration_version: u32, specification: specification.Specification, operation: ir.SubjectId, worlds: []const World, initial_states: []const u32, bounds: Bounds, adapter: Adapter };
pub const Action = struct { kind: enum { add, modify, delete, scan, rescan }, path: ?[]const u8, world: u32 };
pub const State = struct { id: []const u8, world: u32, store_digest: []const u8, document: ir.Document, freshness: enum { fresh, stale }, scanned: enum { never, previously }, depth: u32, initial_world: u32, incoming: ?u32 };
pub const ValueReference = struct { phase: enum { old, new, current, historical }, state: []const u8, slot: enum { source, store }, value: []const u8 };
pub const Event = struct { operation: ir.SubjectId, actor: []const u8, subject: ?[]const u8, affected_values: []const ValueReference, timestamp: u32, clock: enum { logical }, evidence: []const ir.Source };
pub const Transition = struct { id: []const u8, before: []const u8, after: []const u8, action: Action, event: Event, judgment: challenge.Judgment };
pub const Trace = struct { model_digest: []const u8, initial_world: u32, actions: []const Action, failing_transition: ?[]const u8 };
pub const Replay = struct { replay_version: u32, model: Model, trace: Trace };
pub const Report = struct {
    exploration_version: u32 = 1,
    model_digest: []const u8,
    adapter: Adapter,
    bounds: Bounds,
    coverage: struct { executions: u32, initial_states: u32, distinct_states: u32, excluded_worlds: []const u32, stop: enum { exhausted, depth_limit, execution_limit, time_limit, object_limit, replay_complete }, scope: []const u8 },
    states: []const State,
    transitions: []const Transition,
    counterexamples: []const Trace,
    unknown_transitions: []const []const u8,
};
fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn digest(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
    return std.fmt.allocPrint(allocator, "{x}", .{&sum});
}
fn copyDocument(allocator: std.mem.Allocator, document: ir.Document) !ir.Document {
    const bytes = try std.json.Stringify.valueAlloc(allocator, document, .{});
    return std.json.parseFromSliceLeaky(ir.Document, allocator, bytes, .{ .allocate = .alloc_always });
}
/// Compare stored record semantics, excluding only revision identity and array ordering.
/// Source spans, measurements, resolution uncertainty and extractor provenance remain significant.
pub fn semanticDigest(allocator: std.mem.Allocator, document: ir.Document) ![]const u8 {
    const subjects = try allocator.dupe(ir.Subject, document.subjects);
    const symbols = try allocator.dupe(ir.Symbol, document.symbols);
    const observations = try allocator.dupe(ir.Observation, document.observations);
    const relations = try allocator.dupe(ir.Relation, document.relations);
    for (observations) |*observation| {
        observation.revision = "semantic";
        observation.id = try ir.observationId(allocator, observation.*);
    }
    for (relations) |*relation| {
        relation.revision = "semantic";
        relation.id = try ir.relationId(allocator, relation.*);
    }
    inline for (.{ subjects, symbols, observations, relations }) |records| std.mem.sort(@TypeOf(records[0]), records, {}, struct {
        fn less(_: void, left: @TypeOf(records[0]), right: @TypeOf(records[0])) bool {
            return std.mem.lessThan(u8, left.id.bytes, right.id.bytes);
        }
    }.less);
    return digest(allocator, ir.Document{ .schema_version = 1, .revision = "semantic", .subjects = subjects, .symbols = symbols, .observations = observations, .relations = relations });
}
fn fileHash(world: World, path: []const u8) ?[]const u8 {
    for (world.snapshot.files) |file| if (equal(path, file.path)) return file.sha256;
    return null;
}
fn sameOptional(left: ?[]const u8, right: ?[]const u8) bool {
    return if (left) |value| if (right) |other| equal(value, other) else false else right == null;
}
fn editBetween(before: World, after: World, world: u32) ?Action {
    var changed: ?[]const u8 = null;
    for (before.snapshot.files) |file| if (!sameOptional(file.sha256, fileHash(after, file.path))) {
        if (changed != null) return null;
        changed = file.path;
    };
    for (after.snapshot.files) |file| if (fileHash(before, file.path) == null) {
        if (changed != null) return null;
        changed = file.path;
    };
    const path = changed orelse return null;
    return .{ .kind = if (fileHash(before, path) == null) .add else if (fileHash(after, path) == null) .delete else .modify, .path = path, .world = world };
}
pub fn validate(allocator: std.mem.Allocator, model: Model) !void {
    if (model.exploration_version != 1 or model.worlds.len == 0 or model.worlds.len > 64 or model.initial_states.len == 0 or model.initial_states.len > 64) return error.InvalidExplorationModel;
    const bounds = model.bounds;
    if (bounds.max_depth == 0 or bounds.max_depth > 32 or bounds.max_objects == 0 or bounds.max_objects > 8 or bounds.max_executions == 0 or bounds.max_executions > 2000 or bounds.max_time_ms == 0 or bounds.max_time_ms > 60000) return error.InvalidExplorationBounds;
    try specification.validate(allocator, model.specification);
    for (model.specification.snapshot.diagnostics) |diagnostic| if (diagnostic.category == .@"error") return error.InvalidSpecification;
    var found_operation = false;
    for (model.specification.snapshot.document.subjects) |subject| if (equal(subject.id.bytes, model.operation.bytes) and equal(subject.key.kind, "operation")) {
        found_operation = true;
        break;
    };
    if (!found_operation) return error.MissingOperationMapping;
    const configuration_digest = try digest(allocator, model.worlds[0].snapshot.configuration);
    for (model.worlds, 0..) |world, index| {
        if (!ir.nonempty(world.name) or world.snapshot.files.len > 8) return error.InvalidWorld;
        try snapshot.validate(allocator, world.snapshot);
        if (!equal(world.snapshot.project, model.specification.snapshot.project)) return error.ProjectMismatch;
        for (world.snapshot.diagnostics) |diagnostic| if (diagnostic.category == .@"error") return error.InvalidWorldDiagnostics;
        if (!equal(configuration_digest, try digest(allocator, world.snapshot.configuration))) return error.ConfigurationMismatch;
        for (model.worlds[0..index]) |previous| if (equal(world.name, previous.name)) return error.DuplicateWorld;
    }
    for (model.initial_states, 0..) |world, index| {
        if (world >= model.worlds.len) return error.InvalidInitialState;
        for (model.initial_states[0..index]) |previous| if (world == previous) return error.DuplicateInitialState;
    }
}
/// Bounds are execution controls, so a trace may be replayed with a larger budget.
/// Adapter choice is intentionally excluded so the same witness tests the correction.
pub fn modelDigest(allocator: std.mem.Allocator, model: Model) ![]const u8 {
    return digest(allocator, .{ model.specification, model.operation, model.worlds });
}
const Engine = struct {
    allocator: std.mem.Allocator,
    model: Model,
    model_digest: []const u8,
    states: std.ArrayList(State) = .empty,
    transitions: std.ArrayList(Transition) = .empty,
    counterexamples: std.ArrayList(Trace) = .empty,
    unknown_transitions: std.ArrayList([]const u8) = .empty,
    expected_digests: []const []const u8,
    fn sourceOrigin(_: Engine) ir.Source {
        return .{ .path = "src/core/store.zig", .language = "zig", .span = .{ .start = 0, .end = 0 }, .producer = "store-history/1", .confidence = .medium };
    }
    fn state(self: *Engine, world: u32, document: ir.Document, scanned: @FieldType(State, "scanned"), depth: u32, initial_world: u32, incoming: ?u32) !State {
        const store_digest = try semanticDigest(self.allocator, document);
        return .{ .id = try digest(self.allocator, .{ self.model_digest, self.states.items.len, world, store_digest, depth }), .world = world, .store_digest = store_digest, .document = document, .freshness = if (equal(store_digest, self.expected_digests[world])) .fresh else .stale, .scanned = scanned, .depth = depth, .initial_world = initial_world, .incoming = incoming };
    }
    fn initial(self: *Engine, world: u32) !u32 {
        const document: ir.Document = .{ .schema_version = 1, .revision = "initial", .subjects = &.{}, .symbols = &.{}, .observations = &.{}, .relations = &.{} };
        const index: u32 = @intCast(self.states.items.len);
        try self.states.append(self.allocator, try self.state(world, document, .never, 0, world, null));
        return index;
    }
    fn refresh(self: *Engine, previous: State, world: World) !ir.Document {
        var store = try Store.fromDocument(self.allocator, previous.document);
        defer store.deinit();
        var paths: std.StringHashMapUnmanaged(void) = .empty;
        for (world.snapshot.files) |file| try paths.put(self.allocator, file.path, {});
        if (self.model.adapter == .native_store) for (previous.document.subjects) |subject| try paths.put(self.allocator, subject.key.path, {});
        // The negative adapter deliberately forgets deleted paths. Production refresh does not.
        if (paths.count() == 0) return if (self.model.adapter == .test_stale_delete) previous.document else copyDocument(self.allocator, world.snapshot.document);
        const path_list = try self.allocator.alloc([]const u8, paths.count());
        var iterator = paths.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |path| : (index += 1) path_list[index] = path.*;
        std.mem.sort([]const u8, path_list, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.less);
        var updated = try store.replaceFiles(self.allocator, world.snapshot.document, path_list);
        defer updated.deinit();
        return copyDocument(self.allocator, updated.document());
    }
    fn booleanFact(self: Engine, name: []const u8, value: bool) specification.Fact {
        return .{ .name = name, .status = .known, .value = .{ .kind = .boolean, .value = if (value) "true" else "false" }, .reason = null, .source = self.sourceOrigin(), .origin = .trace };
    }
    fn makeTrace(self: Engine, previous_index: u32, action: Action, transition_id: []const u8) !Trace {
        var actions: std.ArrayList(Action) = .empty;
        try actions.append(self.allocator, action);
        var current = self.states.items[previous_index];
        while (current.incoming) |incoming| {
            const transition = self.transitions.items[incoming];
            try actions.append(self.allocator, transition.action);
            for (self.states.items) |candidate| if (equal(candidate.id, transition.before)) {
                current = candidate;
                break;
            };
        }
        std.mem.reverse(Action, actions.items);
        return .{ .model_digest = self.model_digest, .initial_world = current.initial_world, .actions = actions.items, .failing_transition = transition_id };
    }
    fn step(self: *Engine, previous_index: u32, action: Action) !u32 {
        const previous = self.states.items[previous_index];
        if (action.world >= self.model.worlds.len) return error.InvalidAction;
        const world = self.model.worlds[action.world];
        if (world.snapshot.files.len > self.model.bounds.max_objects) return error.ObjectLimit;
        const refreshed = action.kind == .scan or action.kind == .rescan;
        if (refreshed) {
            if (action.world != previous.world or action.path != null or (action.kind == .scan) != (previous.scanned == .never)) return error.InvalidAction;
        } else {
            const expected = editBetween(self.model.worlds[previous.world], world, action.world) orelse return error.InvalidAction;
            if (action.kind != expected.kind or !sameOptional(action.path, expected.path)) return error.InvalidAction;
        }
        const document = if (refreshed) try self.refresh(previous, world) else previous.document;
        const transition_index: u32 = @intCast(self.transitions.items.len);
        const next = try self.state(action.world, document, if (refreshed) .previously else previous.scanned, previous.depth + 1, previous.initial_world, transition_index);
        var no_stale_files = true;
        for (document.subjects) |subject| if (fileHash(world, subject.key.path) == null) {
            no_stale_files = false;
            break;
        };
        var continuity = true;
        for (previous.document.subjects) |old_subject| for (document.subjects) |new_subject| {
            if (equal(old_subject.key.path, new_subject.key.path) and equal(old_subject.key.language, new_subject.key.language) and equal(old_subject.key.kind, new_subject.key.kind) and equal(old_subject.key.name, new_subject.key.name) and equal(old_subject.key.discriminator, new_subject.key.discriminator) and !equal(old_subject.id.bytes, new_subject.id.bytes)) continuity = false;
        };
        const facts = try self.allocator.dupe(specification.Fact, &.{ self.booleanFact("store.refreshed", refreshed), self.booleanFact("store.equivalent", next.freshness == .fresh), self.booleanFact("store.no_stale_files", no_stale_files), self.booleanFact("store.identity_continuity", continuity) });
        var constraints: std.ArrayList(specification.ConstraintId) = .empty;
        for (self.model.specification.claims) |claim| if (equal(claim.subject.bytes, self.model.operation.bytes)) if (claim.constraint) |identifier| {
            var selected = false;
            for (constraints.items) |existing| if (equal(existing.bytes, identifier.bytes)) {
                selected = true;
                break;
            };
            if (!selected) try constraints.append(self.allocator, identifier);
        };
        const origin = self.sourceOrigin();
        var effects: std.ArrayList(challenge.Effect) = .empty;
        var expectations: std.ArrayList(challenge.Expectation) = .empty;
        const effect_names = [_][]const u8{ "result", "store", "transition", "observations" };
        const effect_kinds = [_]challenge.EffectKind{ .return_value, .state_change, .event, .observation };
        for (effect_names, effect_kinds, 0..) |default_name, kind, index| {
            const name = if (index == 1 and !refreshed) "source" else default_name;
            if (index == 3 and !refreshed) continue;
            try effects.append(self.allocator, .{ .name = name, .kind = kind, .subject = null, .value = .{ .kind = .string, .value = if (kind == .state_change) (if (refreshed) next.store_digest else world.snapshot.document.revision) else @tagName(action.kind) }, .source = origin, .origin = .simulation });
            try expectations.append(self.allocator, .{ .name = name, .kind = kind, .classification = .required, .source = origin });
        }
        const question: challenge.Challenge = .{ .id = try identity.make(self.allocator, challenge.ChallengeId, "cha_", &.{ "store-history", self.model_digest, previous.id, @tagName(action.kind), world.name }), .target = self.model.operation, .target_operation = self.model.operation, .assumptions = &.{}, .constraints = constraints.items, .question = "Does this reachable transition preserve the declared Store history constraints?", .suspicious_condition = "A refreshed store differs from a fresh full scan, retains deleted records, or violates structural identity/ownership", .expectation = .required, .execution = .simulation, .generated_from = .{ .claim = null, .finding = null, .evidence = try self.allocator.dupe(ir.Source, &.{origin}) } };
        const judgment = try challenge.judge(self.allocator, self.model.specification, .{ .oracle_version = 1, .challenge = question, .response = .{ .operation = self.model.operation, .origin = .simulation, .coverage = .complete, .effects = effects.items, .evidence = .{ .input_version = 1, .project = world.snapshot.project, .facts = facts, .graph = document, .coverage = .complete } }, .expectations = expectations.items, .policy = .enforced });
        const transition_id = try digest(self.allocator, .{ previous.id, next.id, action });
        const values = try self.allocator.dupe(ValueReference, &.{
            .{ .phase = .old, .state = previous.id, .slot = .store, .value = previous.store_digest },
            .{ .phase = .new, .state = next.id, .slot = .store, .value = next.store_digest },
            .{ .phase = .current, .state = next.id, .slot = .source, .value = world.snapshot.document.revision },
            .{ .phase = .historical, .state = previous.id, .slot = .source, .value = self.model.worlds[previous.world].snapshot.document.revision },
        });
        if (judgment.outcome == .defect) try self.counterexamples.append(self.allocator, try self.makeTrace(previous_index, action, transition_id));
        if (judgment.outcome == .unknown or judgment.outcome == .domain_dependent) try self.unknown_transitions.append(self.allocator, transition_id);
        try self.transitions.append(self.allocator, .{ .id = transition_id, .before = previous.id, .after = next.id, .action = action, .event = .{ .operation = self.model.operation, .actor = "finite-store-explorer", .subject = action.path, .affected_values = values, .timestamp = previous.depth + 1, .clock = .logical, .evidence = try self.allocator.dupe(ir.Source, &.{origin}) }, .judgment = judgment });
        const index: u32 = @intCast(self.states.items.len);
        try self.states.append(self.allocator, next);
        return index;
    }
};
/// All report storage is arena-owned. Time is checked between bounded native operations.
pub fn run(allocator: std.mem.Allocator, io: std.Io, model: Model, replay: ?Trace) !Report {
    const started = std.Io.Clock.awake.now(io);
    try validate(allocator, model);
    const model_digest = try modelDigest(allocator, model);
    const expected_digests = try allocator.alloc([]const u8, model.worlds.len);
    for (model.worlds, 0..) |world, index| expected_digests[index] = try semanticDigest(allocator, world.snapshot.document);
    var engine: Engine = .{ .allocator = allocator, .model = model, .model_digest = model_digest, .expected_digests = expected_digests };
    var queue: std.ArrayList(u32) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    var excluded: std.ArrayList(u32) = .empty;
    var stop: @FieldType(@FieldType(Report, "coverage"), "stop") = if (replay != null) .replay_complete else .exhausted;
    for (model.worlds, 0..) |world, index| if (world.snapshot.files.len > model.bounds.max_objects) try excluded.append(allocator, @intCast(index));
    if (replay) |trace| {
        if (!equal(trace.model_digest, model_digest) or trace.initial_world >= model.worlds.len or trace.actions.len > model.bounds.max_depth or trace.actions.len > model.bounds.max_executions) return error.InvalidReplay;
        if (model.worlds[trace.initial_world].snapshot.files.len > model.bounds.max_objects) return error.ObjectLimit;
        var current = try engine.initial(trace.initial_world);
        for (trace.actions) |action| {
            if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= model.bounds.max_time_ms) {
                stop = .time_limit;
                break;
            }
            current = try engine.step(current, action);
        }
    } else {
        for (model.initial_states) |world| {
            if (model.worlds[world].snapshot.files.len > model.bounds.max_objects) continue;
            const index = try engine.initial(world);
            try queue.append(allocator, index);
            const state = engine.states.items[index];
            try visited.put(allocator, try digest(allocator, .{ state.world, state.store_digest, state.scanned }), {});
        }
        var cursor: usize = 0;
        exploration: while (cursor < queue.items.len) : (cursor += 1) {
            const current_index = queue.items[cursor];
            const current = engine.states.items[current_index];
            if (current.depth >= model.bounds.max_depth) {
                if (stop == .exhausted) stop = .depth_limit;
                continue;
            }
            var actions: std.ArrayList(Action) = .empty;
            try actions.append(allocator, .{ .kind = if (current.scanned == .never) .scan else .rescan, .path = null, .world = current.world });
            for (model.worlds, 0..) |world, index| {
                if (world.snapshot.files.len > model.bounds.max_objects) continue;
                if (editBetween(model.worlds[current.world], world, @intCast(index))) |action| try actions.append(allocator, action);
            }
            for (actions.items) |action| {
                if (engine.transitions.items.len >= model.bounds.max_executions) {
                    stop = .execution_limit;
                    break :exploration;
                }
                if (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= model.bounds.max_time_ms) {
                    stop = .time_limit;
                    break :exploration;
                }
                const next_index = try engine.step(current_index, action);
                const state = engine.states.items[next_index];
                const key = try digest(allocator, .{ state.world, state.store_digest, state.scanned });
                const entry = try visited.getOrPut(allocator, key);
                if (!entry.found_existing) try queue.append(allocator, next_index);
            }
        }
        if (excluded.items.len > 0 and stop == .exhausted) stop = .object_limit;
    }
    var initial_count: u32 = 0;
    for (engine.states.items) |state| if (state.incoming == null) {
        initial_count += 1;
    };
    return .{ .model_digest = model_digest, .adapter = model.adapter, .bounds = model.bounds, .coverage = .{ .executions = @intCast(engine.transitions.items.len), .initial_states = initial_count, .distinct_states = if (replay != null) @intCast(engine.states.items.len) else visited.count(), .excluded_worlds = excluded.items, .stop = stop, .scope = "Finite supplied source worlds and native Store replacement; all reachable dirty and clean states within bounds. No universal proof or runtime external-effect coverage." }, .states = engine.states.items, .transitions = engine.transitions.items, .counterexamples = engine.counterexamples.items, .unknown_transitions = engine.unknown_transitions.items };
}

fn testModel(allocator: std.mem.Allocator) !Model {
    const source: ir.Source = .{ .path = "history.tsp", .language = "typespec", .span = .{ .start = 0, .end = 1 }, .producer = "fixture", .confidence = .high };
    const key: ir.SubjectKey = .{ .project = "fixture", .language = "typespec", .path = source.path, .kind = "operation", .name = "refresh", .discriminator = "0" };
    const operation = try key.id(allocator);
    const document: ir.Document = .{ .schema_version = 1, .revision = "initial", .subjects = &.{}, .symbols = &.{}, .observations = &.{}, .relations = &.{} };
    const world_snapshot: snapshot.Snapshot = .{ .snapshot_version = 1, .project = "fixture", .configuration = .{ .adapter = "fixture", .compiler = "1", .options_sha256 = "0" ** 64, .configs = &.{} }, .files = &.{}, .diagnostics = &.{}, .coverage = .{ .unresolved_calls = 0, .unresolved_accesses = 0 }, .document = document };
    var specification_snapshot = world_snapshot;
    specification_snapshot.files = try allocator.dupe(snapshot.FileDigest, &.{.{ .path = source.path, .sha256 = "0" ** 64 }});
    specification_snapshot.document.subjects = try allocator.dupe(ir.Subject, &.{.{ .id = operation, .key = key, .source = source }});
    var constraint: specification.Constraint = .{ .id = .{ .bytes = "" }, .subject = operation, .name = "valid", .expression = &.{.{ .op = .literal, .args = &.{}, .name = null, .value = .{ .kind = .boolean, .value = "true" } }}, .source = source };
    constraint.id = try specification.constraintId(allocator, constraint);
    var claim: specification.Claim = .{ .id = .{ .bytes = "" }, .subject = operation, .name = constraint.name, .kind = .invariant, .state = .specified, .reason = "Explicit test constraint", .constraint = constraint.id, .source = source };
    claim.id = try specification.claimId(allocator, claim);
    return .{ .exploration_version = 1, .specification = .{ .specification_version = 1, .snapshot = specification_snapshot, .claims = try allocator.dupe(specification.Claim, &.{claim}), .constraints = try allocator.dupe(specification.Constraint, &.{constraint}), .functions = &.{}, .domains = &.{} }, .operation = operation, .worlds = try allocator.dupe(World, &.{.{ .name = "empty", .snapshot = world_snapshot }}), .initial_states = &.{0}, .bounds = .{ .max_depth = 2, .max_objects = 1, .max_executions = 2, .max_time_ms = 60000 }, .adapter = .native_store };
}
fn exerciseAllocationFailures(backing_allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const model = try testModel(allocator);
    const report = try run(allocator, std.testing.io, model, null);
    try std.testing.expectEqual(@as(u32, 2), report.coverage.executions);
    try std.testing.expectEqual(@as(usize, 0), report.counterexamples.len);
}
test "exploration and oracle release every allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}
test "exploration reports the monotonic time limit before executing another transition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var model = try testModel(allocator);
    model.bounds.max_time_ms = 1;
    var calls: u32 = 0;
    var table = std.testing.io.vtable.*;
    table.now = struct {
        fn now(context: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const counter: *u32 = @ptrCast(@alignCast(context.?));
            counter.* += 1;
            return .{ .nanoseconds = @as(i96, counter.*) * 2 * std.time.ns_per_ms };
        }
    }.now;
    const report = try run(allocator, .{ .userdata = &calls, .vtable = &table }, model, null);
    try std.testing.expectEqual(.time_limit, report.coverage.stop);
    try std.testing.expectEqual(@as(u32, 0), report.coverage.executions);
}
test "semantic comparison excludes revision but retains measurement and source semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const model = try testModel(allocator);
    const baseline = model.specification.snapshot.document;
    var revised = baseline;
    revised.revision = "different";
    try std.testing.expectEqualStrings(try semanticDigest(allocator, baseline), try semanticDigest(allocator, revised));
    const subjects = try allocator.dupe(ir.Subject, revised.subjects);
    subjects[0].source.span.end += 1;
    revised.subjects = subjects;
    try std.testing.expect(!equal(try semanticDigest(allocator, baseline), try semanticDigest(allocator, revised)));
}
