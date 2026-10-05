//! Backend-neutral symbolic queries. Only the adapter runs Z3; core semantics stay here.
const std = @import("std");
const ir = @import("ir.zig");
const specification = @import("specification.zig");
const exploration = @import("exploration.zig");
pub const Sort = struct { name: []const u8, scope: enum { finite, unbounded }, members: []const []const u8 };
pub const Variable = struct { name: []const u8, sort: []const u8, domain: []const specification.Scalar, source: ir.Source };
pub const Function = struct { name: []const u8, parameters: []const []const u8, result: []const u8 };
pub const Bounds = struct { timeout_ms: u32, resource_limit: u32, max_objects: u32 };
pub const Simulation = struct { selector: []const u8, model: exploration.Model, traces: []const exploration.Trace };
pub const Query = struct {
    solver_version: u32,
    specification: specification.Specification,
    claim: specification.ClaimId,
    goal: enum { violation, satisfaction },
    assumptions: []const specification.Expression,
    evidence: specification.Input,
    sorts: []const Sort,
    variables: []const Variable,
    functions: []const Function,
    bounds: Bounds,
    simulation: ?Simulation,
};
pub const SortSymbol = struct { name: []const u8, symbol: []const u8, members: []const struct { name: []const u8, symbol: []const u8 } };
pub const VariableSymbol = struct { name: []const u8, symbol: []const u8, sort: []const u8 };
pub const Packet = struct { backend_version: u32 = 1, smt: []const u8, sorts: []const SortSymbol, variables: []const VariableSymbol, bounds: Bounds };
pub const Status = enum { sat, unsat, unknown, unsupported, timeout };
pub const Binding = struct { name: []const u8, sort: []const u8, value: ?specification.Scalar, symbolic_value: []const u8 };
pub const BackendResult = struct { backend_version: u32, backend: []const u8, status: Status, reason: []const u8, model: ?[]const u8, bindings: []const Binding };
pub const Encoding = struct { packet: ?Packet, reason: []const u8 };
pub const Report = struct {
    solver_version: u32 = 1,
    query: Query,
    status: Status,
    backend: []const u8,
    reason: []const u8,
    smt: ?[]const u8,
    model: ?[]const u8,
    bindings: []const Binding,
    witness: ?specification.Input,
    direct_evaluation: ?specification.Report,
    execution: ?exploration.Report,
    interpretation: []const u8,
};
fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn builtinSort(name: []const u8) bool {
    return equal(name, "Bool") or equal(name, "Int") or equal(name, "Real") or equal(name, "String");
}
fn knownSort(query: Query, name: []const u8) bool {
    if (builtinSort(name)) return true;
    for (query.sorts) |sort| if (equal(sort.name, name)) return true;
    return false;
}
pub fn validate(allocator: std.mem.Allocator, query: Query) !void {
    if (query.solver_version != 1 or query.sorts.len > 16 or query.variables.len > 64 or query.functions.len > 64) return error.InvalidSymbolicQuery;
    if (query.bounds.timeout_ms == 0 or query.bounds.timeout_ms > 30000 or query.bounds.resource_limit == 0 or query.bounds.resource_limit > 10000000 or query.bounds.max_objects == 0 or query.bounds.max_objects > 64) return error.InvalidSolverBounds;
    try specification.validate(allocator, query.specification);
    try specification.validateInput(allocator, query.evidence);
    if (!equal(query.specification.snapshot.project, query.evidence.project)) return error.ProjectMismatch;
    try specification.validateExpressions(query.assumptions, true);
    var found_claim = false;
    for (query.specification.claims) |claim| if (equal(claim.id.bytes, query.claim.bytes)) {
        found_claim = true;
        break;
    };
    if (!found_claim) return error.DanglingClaim;
    var objects: usize = 0;
    for (query.sorts, 0..) |sort, index| {
        if (!ir.nonempty(sort.name) or builtinSort(sort.name) or (sort.scope == .finite and sort.members.len == 0)) return error.InvalidSort;
        objects += sort.members.len;
        for (query.sorts[0..index]) |previous| if (equal(sort.name, previous.name)) return error.DuplicateSort;
        for (sort.members, 0..) |member, member_index| {
            if (!ir.nonempty(member)) return error.InvalidSortMember;
            for (sort.members[0..member_index]) |previous| if (equal(member, previous)) return error.DuplicateSortMember;
        }
    }
    if (objects > query.bounds.max_objects) return error.ObjectLimit;
    for (query.variables, 0..) |variable, index| {
        if (!ir.nonempty(variable.name) or std.mem.startsWith(u8, variable.name, "$") or !knownSort(query, variable.sort) or variable.domain.len > 64) return error.InvalidVariable;
        for (query.variables[0..index]) |previous| if (equal(variable.name, previous.name)) return error.DuplicateVariable;
        // Reuse core scalar/source validation without interpreting domain values as observed facts.
        for (variable.domain) |value| try specification.validateInput(allocator, .{ .input_version = 1, .project = query.evidence.project, .facts = &.{.{ .name = variable.name, .status = .known, .value = value, .reason = null, .source = variable.source, .origin = .specification }}, .graph = null, .coverage = .absent });
        if (!ir.validPath(variable.source.path) or !ir.nonempty(variable.source.language) or !ir.nonempty(variable.source.producer) or variable.source.span.end < variable.source.span.start) return error.InvalidSource;
    }
    for (query.functions, 0..) |function, index| {
        if (!ir.nonempty(function.name) or !knownSort(query, function.result)) return error.InvalidFunction;
        for (query.functions[0..index]) |previous| if (equal(function.name, previous.name)) return error.DuplicateFunction;
        for (function.parameters) |parameter| if (!knownSort(query, parameter)) return error.InvalidSort;
        var declared = false;
        for (query.specification.functions) |definition| if (equal(definition.name, function.name) and definition.arity == function.parameters.len) {
            declared = true;
            break;
        };
        if (!declared) return error.UndeclaredFunction;
    }
    if (query.simulation) |simulation| {
        try exploration.validate(allocator, simulation.model);
        if (simulation.traces.len == 0 or simulation.traces.len > 64) return error.InvalidSimulation;
        var selector_found = false;
        for (query.variables) |variable| if (equal(variable.name, simulation.selector) and equal(variable.sort, "Int")) {
            selector_found = true;
            break;
        };
        if (!selector_found) return error.InvalidSimulationSelector;
        const expected = try std.json.Stringify.valueAlloc(allocator, query.specification, .{});
        const actual = try std.json.Stringify.valueAlloc(allocator, simulation.model.specification, .{});
        if (!equal(expected, actual)) return error.SimulationSpecificationMismatch;
        const digest = try exploration.modelDigest(allocator, simulation.model);
        for (simulation.traces) |trace| if (!equal(trace.model_digest, digest)) return error.InvalidReplay;
    }
}
const Term = struct { sort: []const u8, text: []const u8, literal: ?specification.Scalar = null };
const Encoder = struct {
    allocator: std.mem.Allocator,
    query: Query,
    commands: std.ArrayList([]const u8) = .empty,
    sorts: []SortSymbol,
    variables: []VariableSymbol,
    remaining: usize = 10000,
    fn sortName(self: Encoder, name: []const u8) ![]const u8 {
        if (builtinSort(name)) return name;
        for (self.sorts) |sort| if (equal(sort.name, name)) return sort.symbol;
        return error.UnsupportedSort;
    }
    fn literal(self: Encoder, value: specification.Scalar, expected: ?[]const u8) !Term {
        const sort = expected orelse switch (value.kind) {
            .boolean => "Bool",
            .number => "Real",
            .string => "String",
            .null => return error.UnsupportedNull,
        };
        if (equal(sort, "Bool") and value.kind == .boolean) return .{ .sort = sort, .text = value.value, .literal = value };
        if (equal(sort, "Int") and value.kind == .number) {
            const number = std.fmt.parseInt(i64, value.value, 10) catch return error.UnsupportedInteger;
            if (@abs(number) > 9007199254740991) return error.UnsupportedInteger;
            return .{ .sort = sort, .text = if (number < 0) try std.fmt.allocPrint(self.allocator, "(- {d})", .{@abs(number)}) else value.value, .literal = value };
        }
        if (equal(sort, "Real") and value.kind == .number) {
            const number = std.fmt.parseFloat(f64, value.value) catch return error.UnsupportedNumber;
            if (!std.math.isFinite(number)) return error.UnsupportedNumber;
            const magnitude = try std.fmt.allocPrint(self.allocator, "{d}", .{@abs(number)});
            return .{ .sort = sort, .text = if (number < 0) try std.fmt.allocPrint(self.allocator, "(- {s})", .{magnitude}) else magnitude, .literal = value };
        }
        if (equal(sort, "String") and value.kind == .string) {
            // Quote each Unicode code point using SMT-LIB escapes; never insert source text as syntax.
            var parts: std.ArrayList([]const u8) = .empty;
            try parts.append(self.allocator, "\"");
            var iterator = (try std.unicode.Utf8View.init(value.value)).iterator();
            while (iterator.nextCodepoint()) |codepoint| try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "\\u{{{x}}}", .{codepoint}));
            try parts.append(self.allocator, "\"");
            return .{ .sort = sort, .text = try std.mem.concat(self.allocator, u8, parts.items), .literal = value };
        }
        if (value.kind == .string) for (self.sorts) |declaration| if (equal(declaration.name, sort)) {
            for (declaration.members) |member| if (equal(member.name, value.value)) return .{ .sort = sort, .text = member.symbol, .literal = value };
        };
        return error.UnsupportedLiteralSort;
    }
    fn castLiteral(self: Encoder, term: Term, expected: []const u8) !Term {
        if (equal(term.sort, expected)) return term;
        if (term.literal) |value| return self.literal(value, expected);
        return error.UnsupportedSortMismatch;
    }
    fn expression(self: *Encoder, nodes: []const specification.Expression, bindings: []const Term, depth: u32) anyerror!Term {
        if (depth > 16 or nodes.len == 0 or nodes.len > self.remaining) return error.UnsupportedExpressionLimit;
        self.remaining -= nodes.len;
        const terms = try self.allocator.alloc(Term, nodes.len);
        for (nodes, 0..) |node, index| {
            terms[index] = switch (node.op) {
                .literal => try self.literal(node.value.?, null),
                .fact => fact: {
                    const name = node.name.?;
                    if (std.mem.startsWith(u8, name, "$")) {
                        const position = std.fmt.parseInt(usize, name[1..], 10) catch return error.UnsupportedArgument;
                        if (position >= bindings.len) return error.UnsupportedArgument;
                        break :fact bindings[position];
                    }
                    for (self.variables) |variable| if (equal(variable.name, name)) break :fact .{ .sort = variable.sort, .text = variable.symbol };
                    for (self.query.evidence.facts) |evidence| if (equal(evidence.name, name) and evidence.status == .known) break :fact try self.literal(evidence.value.?, null);
                    return error.UnsupportedUndeclaredFact;
                },
                .graph => graph: {
                    // Evaluate only this fixed graph primitive using the existing direct semantics.
                    var model = self.query.specification;
                    var claim = model.claims[0];
                    claim.kind = .invariant;
                    claim.state = .specified;
                    claim.name = "symbolic-graph";
                    claim.id = try specification.claimId(self.allocator, claim);
                    var constraint: specification.Constraint = .{ .id = .{ .bytes = "" }, .subject = claim.subject, .name = claim.name, .expression = &.{node}, .source = claim.source };
                    constraint.id = try specification.constraintId(self.allocator, constraint);
                    claim.constraint = constraint.id;
                    model.claims = &.{claim};
                    model.constraints = try std.mem.concat(self.allocator, specification.Constraint, &.{ model.constraints, &.{constraint} });
                    var evaluated = try specification.evaluate(self.allocator, model, self.query.evidence);
                    defer evaluated.deinit();
                    const result = evaluated.report.results[0];
                    if (result.outcome != .satisfied and result.outcome != .violated) return error.UnsupportedGraphCoverage;
                    break :graph .{ .sort = "Bool", .text = if (result.outcome == .satisfied) "true" else "false" };
                },
                .unsupported => return error.UnsupportedExpression,
                .call => call: {
                    for (self.query.functions, 0..) |function, function_index| if (equal(function.name, node.name.?)) {
                        if (function.parameters.len != node.args.len) return error.UnsupportedFunctionArity;
                        const arguments = try self.allocator.alloc(Term, node.args.len);
                        for (node.args, function.parameters, 0..) |argument, sort, argument_index| arguments[argument_index] = try self.castLiteral(terms[argument], sort);
                        for (self.query.specification.functions) |definition| if (equal(definition.name, function.name)) {
                            if (definition.mode == .axiomatized) break :call try self.castLiteral(try self.expression(definition.definition, arguments, depth + 1), function.result);
                            if (definition.mode != .uninterpreted) return error.UnsupportedFunctionMode;
                            var parts: std.ArrayList([]const u8) = .empty;
                            try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "f{d}", .{function_index}));
                            for (arguments) |argument| try parts.append(self.allocator, argument.text);
                            const joined = try std.mem.join(self.allocator, " ", parts.items);
                            break :call .{ .sort = function.result, .text = if (arguments.len == 0) joined else try std.fmt.allocPrint(self.allocator, "({s})", .{joined}) };
                        };
                    };
                    return error.UnsupportedUndeclaredFunction;
                },
                .count => count: {
                    var parts: std.ArrayList([]const u8) = .empty;
                    for (node.args) |argument| {
                        const predicate = try self.castLiteral(terms[argument], "Bool");
                        try parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "(ite {s} 1 0)", .{predicate.text}));
                    }
                    break :count .{ .sort = "Int", .text = if (parts.items.len == 0) "0" else try std.fmt.allocPrint(self.allocator, "(+ {s})", .{try std.mem.join(self.allocator, " ", parts.items)}) };
                },
                .not => .{ .sort = "Bool", .text = try std.fmt.allocPrint(self.allocator, "(not {s})", .{(try self.castLiteral(terms[node.args[0]], "Bool")).text}) },
                else => binary: {
                    var left = terms[node.args[0]];
                    var right = terms[node.args[1]];
                    const boolean = node.op == .@"and" or node.op == .@"or" or node.op == .implies;
                    if (boolean) {
                        left = try self.castLiteral(left, "Bool");
                        right = try self.castLiteral(right, "Bool");
                    } else if (!equal(left.sort, right.sort)) {
                        if (left.literal != null and right.literal == null) left = try self.castLiteral(left, right.sort) else right = try self.castLiteral(right, left.sort);
                    }
                    if (node.op != .eq and node.op != .ne and !boolean and !equal(left.sort, "Int") and !equal(left.sort, "Real")) return error.UnsupportedComparison;
                    const operator: []const u8 = switch (node.op) {
                        .eq => "=",
                        .ne => "distinct",
                        .lt => "<",
                        .le => "<=",
                        .gt => ">",
                        .ge => ">=",
                        .@"and" => "and",
                        .@"or" => "or",
                        .implies => "=>",
                        else => unreachable,
                    };
                    break :binary .{ .sort = "Bool", .text = try std.fmt.allocPrint(self.allocator, "({s} {s} {s})", .{ operator, left.text, right.text }) };
                },
            };
        }
        return terms[terms.len - 1];
    }
};
fn encodeSupported(allocator: std.mem.Allocator, query: Query) !Packet {
    var selected: ?specification.Claim = null;
    for (query.specification.claims) |claim| if (equal(claim.id.bytes, query.claim.bytes)) {
        selected = claim;
        break;
    };
    const claim = selected.?;
    if (claim.state != .specified) return error.UnsupportedPartialClaim;
    for (query.specification.snapshot.diagnostics) |diagnostic| if (diagnostic.category == .@"error") return error.UnsupportedCompilerErrors;
    var encoder: Encoder = .{ .allocator = allocator, .query = query, .sorts = try allocator.alloc(SortSymbol, query.sorts.len), .variables = try allocator.alloc(VariableSymbol, query.variables.len) };
    try encoder.commands.append(allocator, "(set-logic ALL)");
    for (query.sorts, 0..) |sort, index| {
        const symbol = try std.fmt.allocPrint(allocator, "s{d}", .{index});
        const members = try allocator.alloc(@typeInfo(@FieldType(SortSymbol, "members")).pointer.child, sort.members.len);
        for (sort.members, 0..) |name, member_index| members[member_index] = .{ .name = name, .symbol = try std.fmt.allocPrint(allocator, "d{d}_{d}", .{ index, member_index }) };
        encoder.sorts[index] = .{ .name = sort.name, .symbol = symbol, .members = members };
        try encoder.commands.append(allocator, try std.fmt.allocPrint(allocator, "(declare-sort {s} 0)", .{symbol}));
        var symbols: std.ArrayList([]const u8) = .empty;
        var alternatives: std.ArrayList([]const u8) = .empty;
        for (members) |member| {
            try encoder.commands.append(allocator, try std.fmt.allocPrint(allocator, "(declare-const {s} {s})", .{ member.symbol, symbol }));
            try symbols.append(allocator, member.symbol);
            try alternatives.append(allocator, try std.fmt.allocPrint(allocator, "(= x {s})", .{member.symbol}));
        }
        if (members.len > 1) try encoder.commands.append(allocator, try std.fmt.allocPrint(allocator, "(assert (distinct {s}))", .{try std.mem.join(allocator, " ", symbols.items)}));
        if (sort.scope == .finite) try encoder.commands.append(allocator, try std.fmt.allocPrint(allocator, "(assert (forall ((x {s})) (or {s})))", .{ symbol, try std.mem.join(allocator, " ", alternatives.items) }));
    }
    for (query.variables, 0..) |variable, index| {
        const symbol = try std.fmt.allocPrint(allocator, "v{d}", .{index});
        encoder.variables[index] = .{ .name = variable.name, .symbol = symbol, .sort = variable.sort };
        try encoder.commands.append(allocator, try std.fmt.allocPrint(allocator, "(declare-const {s} {s})", .{ symbol, try encoder.sortName(variable.sort) }));
        var alternatives: std.ArrayList([]const u8) = .empty;
        for (variable.domain) |value| try alternatives.append(allocator, try std.fmt.allocPrint(allocator, "(= {s} {s})", .{ symbol, (try encoder.literal(value, variable.sort)).text }));
        if (alternatives.items.len > 0) try encoder.commands.append(allocator, try std.fmt.allocPrint(allocator, "(assert (or {s}))", .{try std.mem.join(allocator, " ", alternatives.items)}));
        for (query.evidence.facts) |fact| if (equal(variable.name, fact.name) and fact.status == .known) try encoder.commands.append(allocator, try std.fmt.allocPrint(allocator, "(assert (= {s} {s}))", .{ symbol, (try encoder.literal(fact.value.?, variable.sort)).text }));
    }
    for (query.functions, 0..) |function, index| {
        const sorts = try allocator.alloc([]const u8, function.parameters.len);
        for (function.parameters, 0..) |sort, parameter_index| sorts[parameter_index] = try encoder.sortName(sort);
        try encoder.commands.append(allocator, try std.fmt.allocPrint(allocator, "(declare-fun f{d} ({s}) {s})", .{ index, try std.mem.join(allocator, " ", sorts), try encoder.sortName(function.result) }));
    }
    if (query.assumptions.len > 0) {
        const assumption = try encoder.castLiteral(try encoder.expression(query.assumptions, &.{}, 0), "Bool");
        try encoder.commands.append(allocator, try std.fmt.allocPrint(allocator, "(assert {s})", .{assumption.text}));
    }
    for (query.specification.constraints) |constraint| if (equal(constraint.id.bytes, claim.constraint.?.bytes)) {
        const predicate = try encoder.castLiteral(try encoder.expression(constraint.expression, &.{}, 0), "Bool");
        const negate = (query.goal == .violation) != (claim.kind == .forbidden);
        try encoder.commands.append(allocator, if (negate) try std.fmt.allocPrint(allocator, "(assert (not {s}))", .{predicate.text}) else try std.fmt.allocPrint(allocator, "(assert {s})", .{predicate.text}));
        break;
    };
    const smt = try std.mem.join(allocator, "\n", encoder.commands.items);
    if (smt.len > 32768) return error.UnsupportedEncodingSize;
    return .{ .smt = smt, .sorts = encoder.sorts, .variables = encoder.variables, .bounds = query.bounds };
}
pub fn encode(allocator: std.mem.Allocator, query: Query) !Encoding {
    try validate(allocator, query);
    const packet = encodeSupported(allocator, query) catch |failure| {
        if (failure == error.OutOfMemory) return failure;
        return .{ .packet = null, .reason = @errorName(failure) };
    };
    return .{ .packet = packet, .reason = "Encoded selected constraint and explicit assumptions" };
}
pub fn finish(allocator: std.mem.Allocator, io: std.Io, query: Query, encoding: Encoding, backend: ?BackendResult) !Report {
    var report: Report = .{ .query = query, .status = .unsupported, .backend = "none", .reason = encoding.reason, .smt = if (encoding.packet) |packet| packet.smt else null, .model = null, .bindings = &.{}, .witness = null, .direct_evaluation = null, .execution = null, .interpretation = "Symbolic witnesses describe permitted models under explicit assumptions and bounds. SAT is not observed implementation behavior; UNSAT is scoped to this query." };
    const result = backend orelse return report;
    if (result.backend_version != 1 or !ir.nonempty(result.backend) or !ir.nonempty(result.reason)) return error.InvalidBackendResult;
    if (result.status != .sat and (result.bindings.len > 0 or result.model != null)) return error.InvalidBackendResult;
    report.status = result.status;
    report.backend = result.backend;
    report.reason = result.reason;
    report.model = result.model;
    report.bindings = result.bindings;
    if (result.status != .sat) return report;
    if (result.model == null) return error.InvalidBackendResult;
    if (result.bindings.len != query.variables.len) return error.InvalidBackendBindings;
    var facts: std.ArrayList(specification.Fact) = .empty;
    for (query.evidence.facts) |fact| {
        var replaced = false;
        for (query.variables) |variable| if (equal(variable.name, fact.name)) {
            replaced = true;
            break;
        };
        if (!replaced) try facts.append(allocator, fact);
    }
    for (query.variables, 0..) |variable, index| {
        const binding = result.bindings[index];
        if (!equal(binding.name, variable.name) or !equal(binding.sort, variable.sort)) return error.InvalidBackendBindings;
        if (binding.value) |value| {
            var checker: Encoder = .{ .allocator = allocator, .query = query, .sorts = try allocator.dupe(SortSymbol, encoding.packet.?.sorts), .variables = &.{} };
            _ = checker.literal(value, variable.sort) catch |failure| {
                if (failure == error.OutOfMemory) return failure;
                return error.InvalidBackendBindings;
            };
            if (variable.domain.len > 0) {
                var included = false;
                for (variable.domain) |allowed| if (scalarEqual(value, allowed)) {
                    included = true;
                    break;
                };
                if (!included) return error.InvalidBackendBindings;
            }
            for (query.evidence.facts) |fixed| if (equal(fixed.name, variable.name) and fixed.status == .known and !scalarEqual(value, fixed.value.?)) return error.InvalidBackendBindings;
        }
        try facts.append(allocator, .{ .name = variable.name, .status = if (binding.value != null) .known else .unknown, .value = binding.value, .reason = if (binding.value == null) "Symbolic value has no supported concrete scalar decoding" else null, .source = variable.source, .origin = .inference });
    }
    const witness: specification.Input = .{ .input_version = 1, .project = query.evidence.project, .facts = facts.items, .graph = query.evidence.graph, .coverage = query.evidence.coverage };
    try specification.validateInput(allocator, witness);
    report.witness = witness;
    var selected_model = query.specification;
    for (query.specification.claims) |claim| if (equal(claim.id.bytes, query.claim.bytes)) {
        selected_model.claims = try allocator.dupe(specification.Claim, &.{claim});
        break;
    };
    var direct = try specification.evaluate(allocator, selected_model, witness);
    defer direct.deinit();
    const outcome = direct.report.results[0].outcome;
    if ((query.goal == .violation and outcome == .satisfied) or (query.goal == .satisfaction and outcome == .violated)) return error.InvalidBackendWitness;
    if (query.assumptions.len > 0) {
        var assumed_model = selected_model;
        var assumed_claim = selected_model.claims[0];
        assumed_claim.kind = .invariant;
        assumed_claim.id = try specification.claimId(allocator, assumed_claim);
        const constraints = try allocator.dupe(specification.Constraint, selected_model.constraints);
        for (constraints) |*constraint| if (equal(constraint.id.bytes, assumed_claim.constraint.?.bytes)) {
            constraint.expression = query.assumptions;
            break;
        };
        assumed_model.claims = &.{assumed_claim};
        assumed_model.constraints = constraints;
        var assumed = try specification.evaluate(allocator, assumed_model, witness);
        defer assumed.deinit();
        if (assumed.report.results[0].outcome == .violated) return error.InvalidBackendWitness;
    }
    const bytes = try std.json.Stringify.valueAlloc(allocator, direct.report, .{});
    report.direct_evaluation = try std.json.parseFromSliceLeaky(specification.Report, allocator, bytes, .{ .allocate = .alloc_always });
    if (query.simulation) |simulation| {
        for (result.bindings) |binding| if (equal(binding.name, simulation.selector)) {
            const value = binding.value orelse break;
            if (value.kind != .number) break;
            const index = std.fmt.parseInt(usize, value.value, 10) catch break;
            if (index >= simulation.traces.len) break;
            report.execution = try exploration.run(allocator, io, simulation.model, simulation.traces[index]);
            break;
        };
    }
    return report;
}

fn scalarEqual(left: specification.Scalar, right: specification.Scalar) bool {
    if (left.kind != right.kind) return false;
    if (left.kind == .number) {
        const left_number = std.fmt.parseFloat(f64, left.value) catch return false;
        const right_number = std.fmt.parseFloat(f64, right.value) catch return false;
        return left_number == right_number;
    }
    return equal(left.value, right.value);
}
