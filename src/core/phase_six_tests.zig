const std = @import("std");
const ir = @import("ir.zig");
const specification = @import("specification.zig");
const symbolic = @import("symbolic.zig");
const crosslens = @import("crosslens.zig");

fn fixture(allocator: std.mem.Allocator) !specification.Specification {
    const source: ir.Source = .{ .path = "main.tsp", .language = "typespec", .span = .{ .start = 0, .end = 1 }, .producer = "fixture", .confidence = .high };
    const key: ir.SubjectKey = .{ .project = "fixture", .language = "typespec", .path = "main.tsp", .kind = "operation", .name = "write", .discriminator = "0" };
    const subject = try key.id(allocator);
    var constraint: specification.Constraint = .{ .id = undefined, .subject = subject, .name = "allowed", .expression = &.{.{ .op = .fact, .args = &.{}, .name = "allowed", .value = null }}, .source = source };
    constraint.id = try specification.constraintId(allocator, constraint);
    var claim: specification.Claim = .{ .id = undefined, .subject = subject, .name = "allowed", .kind = .invariant, .state = .specified, .reason = "Test", .constraint = constraint.id, .source = source };
    claim.id = try specification.claimId(allocator, claim);
    var relation: ir.Relation = .{ .id = undefined, .from = subject, .kind = "writes", .target = .{ .status = .resolved, .subject = subject, .reason = null }, .source = source, .revision = "r1" };
    relation.id = try ir.relationId(allocator, relation);
    return .{
        .specification_version = 1,
        .snapshot = .{
            .snapshot_version = 1,
            .project = "fixture",
            .configuration = .{ .adapter = "fixture", .compiler = "0", .options_sha256 = "0" ** 64, .configs = &.{} },
            .files = &.{.{ .path = "main.tsp", .sha256 = "0" ** 64 }},
            .diagnostics = &.{},
            .coverage = .{ .unresolved_calls = 0, .unresolved_accesses = 0 },
            .document = .{ .schema_version = 1, .revision = "r1", .subjects = try allocator.dupe(ir.Subject, &.{.{ .id = subject, .key = key, .source = source }}), .symbols = &.{}, .observations = &.{}, .relations = try allocator.dupe(ir.Relation, &.{relation}) },
        },
        .claims = try allocator.dupe(specification.Claim, &.{claim}),
        .constraints = try allocator.dupe(specification.Constraint, &.{constraint}),
        .functions = &.{},
        .domains = try allocator.dupe(specification.Domain, &.{.{ .subject = subject, .ownership = .owned, .nullability = .nonnull, .values = &.{}, .constraints = try allocator.dupe(specification.ConstraintId, &.{constraint.id}), .reason = "Explicit ownership" }}),
    };
}
fn exerciseSymbolic(backing: std.mem.Allocator, model: specification.Specification) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const query: symbolic.Query = .{ .solver_version = 1, .specification = model, .claim = model.claims[0].id, .goal = .violation, .assumptions = &.{}, .evidence = .{ .input_version = 1, .project = "fixture", .facts = &.{}, .graph = null, .coverage = .absent }, .sorts = &.{}, .variables = &.{.{ .name = "allowed", .sort = "Bool", .domain = &.{.{ .kind = .boolean, .value = "false" }}, .source = model.claims[0].source }}, .functions = &.{}, .bounds = .{ .max_objects = 1, .timeout_ms = 1000, .resource_limit = 10000 }, .simulation = null };
    const encoding = try symbolic.encode(allocator, query);
    try std.testing.expect(encoding.packet != null);
    const report = try symbolic.finish(allocator, std.testing.io, query, encoding, .{ .backend_version = 1, .backend = "test", .status = .sat, .reason = "Fixture", .model = "(model)", .bindings = &.{.{ .name = "allowed", .sort = "Bool", .value = .{ .kind = .boolean, .value = "false" }, .symbolic_value = "false" }} });
    try std.testing.expectEqual(specification.Outcome.violated, report.direct_evaluation.?.results[0].outcome);
}
fn exerciseCross(backing: std.mem.Allocator, model: specification.Specification) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    var input: crosslens.Input = .{ .cross_version = 1, .specification = model, .snapshot = model.snapshot, .mappings = &.{}, .policies = &.{}, .reviews = &.{}, .symbolic_results = &.{}, .executions = &.{} };
    const before = try crosslens.analyze(allocator, std.testing.io, input, null);
    try std.testing.expectEqual(@as(usize, 1), before.findings.len);
    input.policies = &.{.{ .subject = model.claims[0].subject, .rule = .authority, .level = .required, .constraints = &.{model.constraints[0].id}, .reason = "Explicit policy", .source = model.claims[0].source }};
    const after = try crosslens.analyze(allocator, std.testing.io, input, before);
    try std.testing.expectEqual(@as(usize, 0), after.findings.len);
    const difference = try crosslens.diff(allocator, before, after);
    try std.testing.expect(difference.changes.len > 0);
}
test "solver encoding and witness evaluation clean up after allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = try fixture(arena.allocator());
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSymbolic, .{model});
}
test "cross-lens findings, policy correction, and diff clean up after allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = try fixture(arena.allocator());
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseCross, .{model});
}
