//! Syntax-based Zig telemetry. No build execution or compiler type evaluation.
const std = @import("std");
const core = @import("twinlens");
const ir = core.ir;
const Ast = std.zig.Ast;
const Node = Ast.Node.Index;
const producer = "zig-bt/1";
const Entry = struct {
    file: usize,
    node: Node,
    token: u32,
    scope_start: u32,
    scope_end: u32,
    name: []const u8,
    kind: []const u8,
    subject: usize,
    type_node: ?Node = null,
    init_node: ?Node = null,
    reads: u32 = 0,
    writes: u32 = 0,
    args: u32 = 0,
    branches: u32 = 0,
    unresolved: u32 = 0,
    body: bool = true,
    variadic: bool = false,
};
const File = struct { path: []const u8, tree: Ast, subject: usize = 0 };
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: core.snapshot.Snapshot,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};
const Scanner = struct {
    a: std.mem.Allocator,
    project: []const u8,
    files: std.ArrayList(File) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    subjects: std.ArrayList(ir.Subject) = .empty,
    symbols: std.ArrayList(ir.Symbol) = .empty,
    observations: std.ArrayList(ir.Observation) = .empty,
    relations: std.ArrayList(ir.Relation) = .empty,
    diagnostics: std.ArrayList(core.snapshot.Diagnostic) = .empty,
    digests: std.ArrayList(core.snapshot.FileDigest) = .empty,
    relation_ids: std.StringHashMapUnmanaged(void) = .empty,
    unresolved_calls: u32 = 0,
    unresolved_accesses: u32 = 0,
    revision: []const u8 = "pending",

    fn source(self: *Scanner, fi: usize, start: u32, end: u32) ir.Source {
        return .{ .path = self.files.items[fi].path, .language = "zig", .span = .{ .start = start, .end = end }, .producer = producer, .confidence = .medium };
    }
    fn nodeSource(self: *Scanner, fi: usize, node: Node) ir.Source {
        const t = self.files.items[fi].tree;
        const last = t.lastToken(node);
        return self.source(fi, t.tokenStart(t.firstToken(node)), t.tokenStart(last) + @as(u32, @intCast(t.tokenSlice(last).len)));
    }
    fn subject(self: *Scanner, name: []const u8, kind: []const u8, source_info: ir.Source) !usize {
        var ordinal: usize = 0;
        for (self.subjects.items) |s| if (eq(s.key.name, name) and eq(s.key.kind, kind) and eq(s.key.path, source_info.path)) {
            ordinal += 1;
        };
        const key: ir.SubjectKey = .{ .project = self.project, .language = "zig", .path = source_info.path, .kind = kind, .name = name, .discriminator = try std.fmt.allocPrint(self.a, "{d}", .{ordinal}) };
        const id = try key.id(self.a);
        const result = self.subjects.items.len;
        try self.subjects.append(self.a, .{ .id = id, .key = key, .source = source_info });
        try self.symbols.append(self.a, .{ .id = try ir.symbolId(self.a, id), .subject = id, .name = name });
        return result;
    }
    fn owner(self: *Scanner, fi: usize, pos: u32) ?usize {
        var found: ?usize = null;
        var size: u32 = std.math.maxInt(u32);
        for (self.entries.items, 0..) |e, i| {
            const s = self.subjects.items[e.subject].source.span;
            if (e.file == fi and (eq(e.kind, "function") or eq(e.kind, "test")) and s.start <= pos and pos < s.end and s.end - s.start < size) {
                found = i;
                size = s.end - s.start;
            }
        }
        return found;
    }
    fn addEntry(self: *Scanner, fi: usize, node: Node, token: u32, kind: []const u8, scope_start: u32, scope_end: u32, source_info: ir.Source) !usize {
        const t = self.files.items[fi].tree;
        const name = t.tokenSlice(token);
        // Quoted identifiers remain escaped, so IR names never contain control characters.
        var full_name = name;
        var best: u32 = std.math.maxInt(u32);
        for (self.entries.items) |e| {
            const s = self.subjects.items[e.subject];
            if (e.file == fi and (eq(e.kind, "function") or eq(e.kind, "container") or eq(e.kind, "test")) and s.source.span.start < source_info.span.start and source_info.span.end <= s.source.span.end and s.source.span.end - s.source.span.start < best) {
                best = s.source.span.end - s.source.span.start;
                full_name = try std.fmt.allocPrint(self.a, "{s}[declaration:{s}]/{s}", .{ s.key.name, s.key.discriminator, name });
            }
        }
        const si = try self.subject(full_name, kind, source_info);
        const index = self.entries.items.len;
        try self.entries.append(self.a, .{ .file = fi, .node = node, .token = token, .name = name, .kind = kind, .subject = si, .scope_start = scope_start, .scope_end = scope_end });
        return index;
    }
    fn scope(self: *Scanner, fi: usize, node: Node) struct { start: u32, end: u32 } {
        const t = self.files.items[fi].tree;
        const s = self.nodeSource(fi, node).span;
        var result: struct { start: u32, end: u32 } = .{ .start = 0, .end = @intCast(t.source.len) };
        for (1..t.nodes.len) |i| {
            const n: Node = @enumFromInt(i);
            const tag = @tagName(t.nodeTag(n));
            var buffer: [2]Node = undefined;
            if (!std.mem.startsWith(u8, tag, "block") and t.fullContainerDecl(&buffer, n) == null) continue;
            const outer = self.nodeSource(fi, n).span;
            if (outer.start < s.start and s.end <= outer.end and outer.end - outer.start < result.end - result.start) result = .{ .start = outer.start, .end = outer.end };
        }
        return .{ .start = result.start, .end = result.end };
    }
    fn declarations(self: *Scanner, fi: usize) !void {
        const t = &self.files.items[fi].tree;
        self.files.items[fi].subject = try self.subject(self.files.items[fi].path, "file", self.source(fi, 0, @intCast(t.source.len)));
        if (t.errors.len > 0) {
            for (t.errors) |err| {
                const start = t.tokenStart(err.token);
                try self.diagnostics.append(self.a, .{ .category = .@"error", .code = 1, .message = try std.fmt.allocPrint(self.a, "Zig syntax error: {s}", .{@tagName(err.tag)}), .path = self.files.items[fi].path, .start = start, .end = start + @as(u32, @intCast(t.tokenSlice(err.token).len)) });
            }
            try self.measure(self.files.items[fi].subject, "file.syntax", missing(.unsupported, "Malformed Zig source; only file identity and diagnostics are available"));
            return;
        }
        // Source order makes enclosing declarations available before their children.
        const nodes = try self.a.alloc(Node, t.nodes.len - 1);
        for (nodes, 1..) |*n, i| n.* = @enumFromInt(i);
        std.mem.sort(Node, nodes, t, struct {
            fn less(tree: *const Ast, l: Node, r: Node) bool {
                const a = tree.firstToken(l);
                const b = tree.firstToken(r);
                return a < b or (a == b and tree.lastToken(l) > tree.lastToken(r));
            }
        }.less);
        var protos: std.AutoHashMapUnmanaged(Node, void) = .empty;
        for (nodes) |n| if (t.nodeTag(n) == .fn_decl) {
            try protos.put(self.a, t.nodeData(n).node_and_node[0], {});
        };
        for (nodes) |n| {
            const s = self.nodeSource(fi, n);
            const sc = self.scope(fi, n);
            var buffer: [1]Node = undefined;
            if (t.fullFnProto(&buffer, n)) |proto| {
                if (protos.contains(n)) continue;
                const name = proto.name_token orelse continue;
                const ei = try self.addEntry(fi, n, name, "function", sc.start, sc.end, s);
                self.entries.items[ei].body = t.nodeTag(n) == .fn_decl;
                var it = proto.iterate(t);
                while (it.next()) |param| {
                    if (param.anytype_ellipsis3) |tok| if (t.tokenTag(tok) == .ellipsis3) {
                        self.entries.items[ei].variadic = true;
                        continue;
                    };
                    self.entries.items[ei].args += 1;
                    if (param.name_token) |pt| {
                        const end = if (param.type_expr) |ty| self.nodeSource(fi, ty).span.end else t.tokenStart(pt) + @as(u32, @intCast(t.tokenSlice(pt).len));
                        const pi = try self.addEntry(fi, n, pt, "parameter", s.span.start, s.span.end, self.source(fi, t.tokenStart(pt), end));
                        self.entries.items[pi].type_node = param.type_expr;
                    }
                }
            } else if (t.fullVarDecl(n)) |v| {
                var cb: [2]Node = undefined;
                const is_container = if (v.ast.init_node.unwrap()) |init| t.fullContainerDecl(&cb, init) != null else false;
                const ei = try self.addEntry(fi, n, v.ast.mut_token + 1, if (is_container) "container" else "value", sc.start, sc.end, s);
                self.entries.items[ei].type_node = v.ast.type_node.unwrap();
                self.entries.items[ei].init_node = v.ast.init_node.unwrap();
                self.entries.items[ei].writes = if (v.ast.init_node.unwrap() != null) 1 else 0;
            } else if (t.fullContainerField(n)) |f| {
                if (f.ast.tuple_like) continue;
                const ei = try self.addEntry(fi, n, f.ast.main_token, if (f.ast.type_expr.unwrap() == null) "member" else "property", sc.start, sc.end, s);
                self.entries.items[ei].type_node = f.ast.type_expr.unwrap();
                self.entries.items[ei].writes = if (f.ast.value_expr.unwrap() != null) 1 else 0;
            } else if (t.nodeTag(n) == .test_decl) {
                _ = try self.addEntry(fi, n, t.nodeMainToken(n), "test", sc.start, sc.end, s);
            }
        }
        // Captures shadow outer bindings. Their types are intentionally unknown.
        for (nodes) |n| {
            if (t.fullIf(n)) |v| {
                if (v.payload_token) |tok| try self.capture(fi, tok, v.ast.then_expr);
                if (v.error_token) |tok| if (v.ast.else_expr.unwrap()) |body| {
                    try self.capture(fi, tok, body);
                };
            } else if (t.fullWhile(n)) |v| {
                if (v.payload_token) |tok| {
                    const before = self.entries.items.len;
                    try self.capture(fi, tok, v.ast.then_expr);
                    if (self.entries.items.len > before) if (v.ast.cont_expr.unwrap()) |cont| {
                        self.entries.items[before].scope_start = self.nodeSource(fi, cont).span.start;
                    };
                }
                if (v.error_token) |tok| if (v.ast.else_expr.unwrap()) |body| {
                    try self.capture(fi, tok, body);
                };
            } else if (t.fullFor(n)) |v| {
                var tok = v.payload_token;
                while (tok < t.tokens.len and t.tokenTag(tok) != .pipe) : (tok += 1) if (t.tokenTag(tok) == .identifier) {
                    try self.capture(fi, tok, v.ast.then_expr);
                };
            } else if (t.fullSwitchCase(n)) |v| {
                if (v.payload_token) |tok| try self.capture(fi, tok, v.ast.target_expr);
            } else if (t.nodeTag(n) == .@"catch") {
                const tok = t.nodeMainToken(n);
                if (t.tokenTag(tok + 1) == .pipe) try self.capture(fi, tok + 2, t.nodeData(n).node_and_node[1]);
            } else if (t.nodeTag(n) == .@"errdefer") {
                const data = t.nodeData(n).opt_token_and_node;
                if (data[0].unwrap()) |tok| try self.capture(fi, tok, data[1]);
            }
        }
    }
    fn capture(self: *Scanner, fi: usize, raw: u32, body: Node) !void {
        const t = self.files.items[fi].tree;
        const tok = if (t.tokenTag(raw) == .asterisk) raw + 1 else raw;
        if (t.tokenTag(tok) != .identifier) return;
        const s = self.nodeSource(fi, body).span;
        _ = try self.addEntry(fi, body, tok, "value", s.start, s.end, self.source(fi, t.tokenStart(tok), t.tokenStart(tok) + @as(u32, @intCast(t.tokenSlice(tok).len))));
    }
    fn lookup(self: *Scanner, fi: usize, name: []const u8, pos: u32) ?usize {
        if (eq(name, "_")) return null;
        var best: ?usize = null;
        var size: u32 = std.math.maxInt(u32);
        for (self.entries.items, 0..) |e, i| {
            if (e.file != fi or !eq(e.name, name) or pos < e.scope_start or pos >= e.scope_end) continue;
            const s = self.subjects.items[e.subject].source.span;
            if (eq(e.kind, "value") and self.owner(fi, s.start) != null and s.start >= pos) continue;
            if (e.scope_end - e.scope_start <= size) {
                best = i;
                size = e.scope_end - e.scope_start;
            }
        }
        return best;
    }
    fn resolve(self: *Scanner, fi: usize, n: Node, depth: u8) ?usize {
        if (depth > 12) return null;
        const t = self.files.items[fi].tree;
        switch (t.nodeTag(n)) {
            .identifier => return self.lookup(fi, t.tokenSlice(t.nodeMainToken(n)), t.tokenStart(t.nodeMainToken(n))),
            .grouped_expression => return self.resolve(fi, t.nodeData(n).node_and_token[0], depth + 1),
            .field_access => {
                const data = t.nodeData(n).node_and_token;
                const receiver = self.resolve(fi, data[0], depth + 1) orelse return null;
                const target = self.container(receiver, depth + 1) orelse return null;
                for (self.entries.items, 0..) |e, i| if (e.file == target.file and e.scope_start == target.start and e.scope_end == target.end and eq(e.name, t.tokenSlice(data[1]))) return i;
                return null;
            },
            else => return null,
        }
    }
    const Container = struct { file: usize, start: u32, end: u32, finite_fields: bool = false };
    fn container(self: *Scanner, ei: usize, depth: u8) ?Container {
        if (depth > 12) return null;
        const e = self.entries.items[ei];
        const t = self.files.items[e.file].tree;
        var n = e.type_node orelse e.init_node orelse return null;
        if (t.fullPtrType(n)) |p| {
            if (p.size != .one) return null;
            n = p.ast.child_type;
        }
        var buffer: [2]Node = undefined;
        if (t.fullContainerDecl(&buffer, n)) |c| {
            const s = self.nodeSource(e.file, n).span;
            var finite = t.tokenTag(c.ast.main_token) == .keyword_struct or t.tokenTag(c.ast.main_token) == .keyword_union;
            for (c.ast.members) |member| if (t.fullContainerField(member)) |field| {
                if (field.ast.tuple_like) finite = false;
            };
            return .{ .file = e.file, .start = s.start, .end = s.end, .finite_fields = finite };
        }
        if (t.fullStructInit(&buffer, n)) |v| n = v.ast.type_expr.unwrap() orelse return null;
        if (t.builtinCallParams(&buffer, n)) |params| {
            if (!eq(t.tokenSlice(t.nodeMainToken(n)), "@import") or params.len != 1 or t.nodeTag(params[0]) != .string_literal) return null;
            const raw = t.tokenSlice(t.nodeMainToken(params[0]));
            const path = std.zig.string_literal.parseAlloc(self.a, raw) catch return null;
            if (!std.mem.endsWith(u8, path, ".zig") or std.fs.path.isAbsolute(path)) return null;
            const full = std.fs.path.resolve(self.a, &.{ "/project", std.fs.path.dirname(self.files.items[e.file].path) orelse "", path }) catch return null;
            if (!std.mem.startsWith(u8, full, "/project/")) return null;
            for (self.files.items, 0..) |f, i| if (eq(f.path, full[9..])) return .{ .file = i, .start = 0, .end = @intCast(f.tree.source.len) };
            return null;
        }
        const other = self.resolve(e.file, n, depth + 1) orelse return null;
        if (other == ei) return null;
        return self.container(other, depth + 1);
    }
    fn measure(self: *Scanner, si: usize, metric: []const u8, measurement: ir.Measurement) !void {
        const s = self.subjects.items[si];
        var o: ir.Observation = .{ .id = undefined, .subject = s.id, .metric = metric, .measurement = measurement, .source = s.source, .revision = self.revision };
        o.id = try ir.observationId(self.a, o);
        try self.observations.append(self.a, o);
    }
    fn relation(self: *Scanner, from: usize, target: ?usize, kind: []const u8, source_info: ir.Source) !void {
        var r: ir.Relation = .{ .id = undefined, .from = self.subjects.items[from].id, .kind = kind, .target = if (target) |si| .{ .status = .resolved, .subject = self.subjects.items[si].id, .reason = null } else .{ .status = .unresolved, .subject = null, .reason = "Zig syntax cannot resolve this target (external, computed, generic, or builtin)" }, .source = source_info, .revision = self.revision };
        r.id = try ir.relationId(self.a, r);
        const slot = try self.relation_ids.getOrPut(self.a, r.id.bytes);
        if (!slot.found_existing) try self.relations.append(self.a, r);
    }
    fn inType(self: *Scanner, fi: usize, pos: u32) bool {
        for (self.entries.items) |e| if (e.file == fi) {
            if (e.type_node) |ty| {
                const s = self.nodeSource(fi, ty).span;
                if (s.start <= pos and pos < s.end) return true;
            }
            if (eq(e.kind, "function")) {
                var b: [1]Node = undefined;
                const p = self.files.items[fi].tree.fullFnProto(&b, e.node).?;
                if (p.ast.return_type.unwrap()) |ty| {
                    const s = self.nodeSource(fi, ty).span;
                    if (s.start <= pos and pos < s.end) return true;
                }
            }
        };
        return false;
    }
    fn telemetry(self: *Scanner, fi: usize) !void {
        const t = self.files.items[fi].tree;
        if (t.errors.len > 0) return;
        var writes: std.AutoHashMapUnmanaged(Node, bool) = .empty;
        for (1..t.nodes.len) |i| {
            const n: Node = @enumFromInt(i);
            const tag = t.nodeTag(n);
            if (tag == .assign_destructure) {
                for (t.assignDestructure(n).ast.variables) |variable| {
                    if (t.fullVarDecl(variable)) |_| {
                        for (self.entries.items) |*e| if (e.file == fi and e.node == variable) {
                            e.writes += 1;
                        };
                    } else try writes.put(self.a, variable, false);
                }
            }
            if (std.mem.startsWith(u8, @tagName(tag), "assign") and tag != .assign_destructure) try writes.put(self.a, t.nodeData(n).node_and_node[0], tag != .assign);
        }
        for (1..t.nodes.len) |i| {
            const n: Node = @enumFromInt(i);
            const tag = t.nodeTag(n);
            const s = self.nodeSource(fi, n);
            const owner_index = self.owner(fi, s.span.start);
            const from = if (owner_index) |o| self.entries.items[o].subject else self.files.items[fi].subject;
            var b: [1]Node = undefined;
            var bb: [2]Node = undefined;
            if (t.fullCall(&b, n)) |c| {
                var target = self.resolve(fi, c.ast.fn_expr, 0);
                if (target) |ei| if (!eq(self.entries.items[ei].kind, "function")) {
                    target = null;
                };
                if (target == null) {
                    self.unresolved_calls += 1;
                    if (owner_index) |o| {
                        self.entries.items[o].unresolved += 1;
                    }
                }
                try self.relation(from, if (target) |ei| self.entries.items[ei].subject else null, "calls", s);
            } else if (t.builtinCallParams(&bb, n) != null) {
                // Builtins are explicit unresolved calls, including compile-time operations.
                self.unresolved_calls += 1;
                if (owner_index) |o| {
                    self.entries.items[o].unresolved += 1;
                }
                try self.relation(from, null, "calls", s);
            }
            if (owner_index) |o| {
                const branch = t.fullIf(n) != null or t.fullWhile(n) != null or t.fullFor(n) != null or tag == .@"catch" or tag == .bool_and or tag == .bool_or or tag == .@"orelse" or (if (t.fullSwitchCase(n)) |c| c.ast.values.len > 0 else false);
                if (branch) self.entries.items[o].branches += 1;
            }
            if (t.fullStructInit(&bb, n)) |init| {
                var target: ?Container = null;
                if (init.ast.type_expr.unwrap()) |ty| {
                    if (self.resolve(fi, ty, 0)) |ei| target = self.container(ei, 0);
                } else {
                    for (self.entries.items, 0..) |e, ei| if (e.file == fi and e.init_node == n) {
                        target = self.container(ei, 0);
                        break;
                    };
                }
                for (init.ast.fields) |field| {
                    const name_token = t.firstToken(field) - 2;
                    var found = false;
                    if (target) |c| for (self.entries.items) |*e| {
                        if (e.file == c.file and e.scope_start == c.start and e.scope_end == c.end and eq(e.kind, "property") and eq(e.name, t.tokenSlice(name_token))) {
                            e.writes += 1;
                            try self.relation(from, e.subject, "writes", self.source(fi, t.tokenStart(name_token), self.nodeSource(fi, field).span.end));
                            found = true;
                            break;
                        }
                    };
                    if (!found) self.unresolved_accesses += 1;
                }
            }
            if (tag == .array_access or tag == .deref) self.unresolved_accesses += 1;
            if ((tag == .identifier or tag == .field_access) and !self.inType(fi, s.span.start)) {
                if (self.resolve(fi, n, 0)) |ei| {
                    const kind = self.entries.items[ei].kind;
                    if (!eq(kind, "value") and !eq(kind, "parameter") and !eq(kind, "property")) continue;
                    const write = writes.get(n);
                    const reads = write == null or write.?;
                    if (reads) {
                        self.entries.items[ei].reads += 1;
                        try self.relation(from, self.entries.items[ei].subject, "reads", s);
                    }
                    if (write != null) {
                        self.entries.items[ei].writes += 1;
                        try self.relation(from, self.entries.items[ei].subject, "writes", s);
                    }
                } else if (tag == .field_access) {
                    self.unresolved_accesses += 1;
                }
            }
        }
    }
    fn metrics(self: *Scanner) !void {
        for (self.entries.items, 0..) |e, ei| {
            if (eq(e.kind, "function")) {
                const s = self.subjects.items[e.subject];
                const source_text = self.files.items[e.file].tree.source[s.source.span.start..s.source.span.end];
                try self.measure(e.subject, "function.args.count", if (e.variadic) missing(.unknown, "Variadic declaration has no fixed argument count") else measured(e.args));
                try self.measure(e.subject, "function.lines", measured(std.mem.count(u8, source_text, "\n") + 1));
                try self.measure(e.subject, "function.branch.count", if (e.body) measured(e.branches) else missing(.unknown, "Declaration has no executable body"));
                var callers: u32 = 0;
                var callees: u32 = 0;
                for (self.relations.items) |r| if (eq(r.kind, "calls") and r.target.subject != null) {
                    if (eq(r.from.bytes, s.id.bytes)) callees += 1;
                    if (eq(r.target.subject.?.bytes, s.id.bytes)) callers += 1;
                };
                try self.measure(e.subject, "function.callers", measured(callers));
                try self.measure(e.subject, "function.callees", measured(callees));
                try self.measure(e.subject, "function.calls.unresolved.count", measured(e.unresolved));
            } else if (eq(e.kind, "value") or eq(e.kind, "parameter") or eq(e.kind, "property")) {
                const prefix = if (eq(e.kind, "property")) "property" else "value";
                try self.measure(e.subject, try std.fmt.allocPrint(self.a, "{s}.read_count", .{prefix}), measured(e.reads));
                try self.measure(e.subject, try std.fmt.allocPrint(self.a, "{s}.write_count", .{prefix}), measured(e.writes));
                if (eq(e.kind, "parameter")) {
                    var measurement = missing(.unknown, "Type requires compiler evaluation or is not a supported finite container");
                    if (self.container(ei, 0)) |c| {
                        var count: u32 = 0;
                        for (self.entries.items) |field| if (field.file == c.file and field.scope_start == c.start and field.scope_end == c.end and eq(field.kind, "property")) {
                            count += 1;
                        };
                        if (c.finite_fields) measurement = measured(count);
                    }
                    if (e.type_node) |ty| {
                        const t = self.files.items[e.file].tree;
                        if (t.nodeTag(ty) == .identifier) {
                            const name = t.tokenSlice(t.nodeMainToken(ty));
                            if (eq(name, "bool") or eq(name, "usize") or eq(name, "isize") or (name.len > 1 and (name[0] == 'u' or name[0] == 'i' or name[0] == 'f') and (std.fmt.parseInt(u16, name[1..], 10) catch 0) > 0)) measurement = measured(0);
                        }
                    }
                    try self.measure(e.subject, "function.parameter.property_count", measurement);
                }
            }
        }
        for (self.files.items) |f| if (f.tree.errors.len == 0) {
            try self.measure(f.subject, "file.semantics", missing(.unsupported, "Syntax-only Zig adapter: no build graph, comptime execution, alias analysis, or compiler type checking"));
        };
    }
};
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn measured(n: anytype) ir.Measurement {
    return .{ .status = .measured, .value = @floatFromInt(n), .reason = null };
}
fn missing(status: @FieldType(ir.Measurement, "status"), reason: []const u8) ir.Measurement {
    return .{ .status = status, .value = null, .reason = reason };
}
fn hash(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(a, "{x}", .{&digest});
}
fn collect(a: std.mem.Allocator, io: std.Io, root: []const u8, relative: []const u8, paths: *std.ArrayList([]const u8)) anyerror!void {
    const full = try std.fs.path.join(a, &.{ root, relative });
    var dir = try std.Io.Dir.cwd().openDir(io, full, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".") or eq(entry.name, "node_modules") or eq(entry.name, "zig-out") or eq(entry.name, "dist") or eq(entry.name, "tmp")) continue;
        const path = try std.fs.path.join(a, &.{ relative, entry.name });
        if (entry.kind == .directory) try collect(a, io, root, path, paths) else if (entry.kind == .file and std.mem.endsWith(u8, path, ".zig")) try paths.append(a, path);
    }
}
pub fn scan(gpa: std.mem.Allocator, io: std.Io, input: []const u8, project: ?[]const u8, revision: ?[]const u8, max_bytes: u32) !Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, input, a);
    const single = std.mem.endsWith(u8, absolute, ".zig");
    const root = if (single) std.fs.path.dirname(absolute).? else absolute;
    var paths: std.ArrayList([]const u8) = .empty;
    if (single) try paths.append(a, std.fs.path.basename(absolute)) else try collect(a, io, root, "", &paths);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.less);
    if (paths.items.len == 0) return error.NoZigSources;
    var s: Scanner = .{ .a = a, .project = try a.dupe(u8, project orelse std.fs.path.basename(root)) };
    for (paths.items) |path| {
        if (!ir.validPath(path)) return error.InvalidSourcePath;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ root, path }), a, .limited(max_bytes));
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const source_text = try a.dupeZ(u8, bytes);
        try s.files.append(a, .{ .path = path, .tree = try Ast.parse(a, source_text, .zig) });
        try s.digests.append(a, .{ .path = path, .sha256 = try hash(a, bytes) });
    }
    s.revision = try a.dupe(u8, revision orelse try hash(a, try std.json.Stringify.valueAlloc(a, .{ s.digests.items, producer, @import("builtin").zig_version_string }, .{})));
    for (0..s.files.items.len) |i| try s.declarations(i);
    for (0..s.files.items.len) |i| try s.telemetry(i);
    try s.metrics();
    inline for (.{ s.subjects.items, s.symbols.items, s.observations.items, s.relations.items }) |rows| std.mem.sort(@TypeOf(rows[0]), rows, {}, struct {
        fn less(_: void, l: @TypeOf(rows[0]), r: @TypeOf(rows[0])) bool {
            return std.mem.lessThan(u8, l.id.bytes, r.id.bytes);
        }
    }.less);
    const value: core.snapshot.Snapshot = .{ .snapshot_version = 1, .project = s.project, .configuration = .{ .adapter = producer, .compiler = @import("builtin").zig_version_string, .options_sha256 = try hash(a, "syntax-only/1;skip=dot,node_modules,zig-out,dist,tmp;symlinks=skip"), .configs = &.{} }, .files = s.digests.items, .diagnostics = s.diagnostics.items, .coverage = .{ .unresolved_calls = s.unresolved_calls, .unresolved_accesses = s.unresolved_accesses }, .document = .{ .schema_version = 1, .revision = s.revision, .subjects = s.subjects.items, .symbols = s.symbols.items, .observations = s.observations.items, .relations = s.relations.items } };
    try core.snapshot.validate(a, value);
    return .{ .arena = arena, .value = value };
}
