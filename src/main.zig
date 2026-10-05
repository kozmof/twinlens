const std = @import("std");
const zig_adapter = @import("zig_adapter");
const core = @import("twinlens");
const help =
    \\Twinlens — specification analysis and behavioral telemetry
    \\Usage: twinlens [--config FILE] COMMAND
    \\  import FILE                         Validate IR/snapshot and emit IR JSON
    \\  scan INPUT [--language typescript|zig|both] [--project NAME]
    \\             [--revision ID] [--out FILE]
    \\                                      Scan source and emit/persist a snapshot
    \\  query FILE [--subject ID] [--metric NAME] [--symbol NAME_OR_ID]
    \\             [--relation KIND] [--path PATH] [--start BYTE] [--end BYTE]
    \\             [--revision ID] [--relations]
    \\                                      Query observations or relations as JSON
    \\  diff BEFORE AFTER [--out FILE]       Compare two snapshots
    \\  update BASE REPLACEMENT --file PATH [--out FILE]
    \\                                      Replace/remove one file in IR; emit new IR
    \\  inspect ROOT SNAPSHOT [--out FILE]    Collect bounded structural evidence
    \\  compile TYPESPEC [--project NAME] [--revision ID] [--out FILE]
    \\                                      Lower TypeSpec to specification IR
    \\  evaluate SPECIFICATION EVIDENCE [--out FILE]
    \\                                      Evaluate claims without executing user code
    \\  auth MODEL [--out FILE]              Run bounded synthetic authentication histories
    \\  auth-replay REQUEST [--out FILE]     Replay a synthetic authentication trace
    \\  cross INPUT [--previous REPORT] [--out FILE]  Combine specification and code evidence
    \\  cross-diff BEFORE AFTER [--out FILE]  Compare combined revision history
    \\  solve QUERY [--out FILE]             Solve a bounded symbolic constraint query
    \\  challenges SPECIFICATION [--out FILE] Generate suspicious-case questions
    \\  judge SPECIFICATION REQUEST [--out FILE] Judge a simultaneous response set
    \\  explore MODEL [--out FILE]           Explore bounded Store histories
    \\  replay REQUEST [--out FILE]          Replay a retained action trace
    \\  analyze SNAPSHOT [--previous REPORT] [--out FILE]
    \\                                      Generate evidence, hypotheses and caller scores
    \\  review REPORT --finding ID --status STATE --note TEXT [--out FILE]
    \\                                      Record a finding review decision
    \\  --help                              Show this help
    \\  --version                           Show version
    \\Config: max_input_bytes (16 MiB), typescript_adapter, typespec_adapter, solver_adapter (built package CLI paths).
    \\Paths are relative to cwd. Query/update source paths are project-relative.
    \\Exit: 0 success, 1 internal, 2 usage/config, 3 unsupported, 4 I/O/adapter, 5 invalid IR.
    \\
;
const Config = struct {
    max_input_bytes: u32 = 16 * 1024 * 1024,
    typescript_adapter: []const u8 = "packages/typescript/dist/cli.js",
    typespec_adapter: []const u8 = "packages/typespec/dist/cli.js",
    solver_adapter: []const u8 = "packages/solver/dist/cli.js",
};
const Options = struct {
    command: enum { help, version, import, query, scan, diff, update, analyze, review, compile, evaluate, inspect, challenges, judge, explore, replay, solve, cross, @"cross-diff", auth, @"auth-replay" },
    path: ?[]const u8 = null,
    second: ?[]const u8 = null,
    config: ?[]const u8 = null,
    out: ?[]const u8 = null,
    project: ?[]const u8 = null,
    file: ?[]const u8 = null,
    language: ?enum { typescript, zig, both } = null,
    previous: ?[]const u8 = null,
    finding: ?[]const u8 = null,
    status: ?core.analysis.Status = null,
    note: ?[]const u8 = null,
    relations: bool = false,
    filter: core.Filter = .{},
};
fn parseArgs(args: []const []const u8) !Options {
    var i: usize = 0;
    var config: ?[]const u8 = null;
    if (args.len > 0 and std.mem.eql(u8, args[0], "--config")) {
        if (args.len < 3) return error.ExpectedConfigAndCommand;
        config = args[1];
        i = 2;
    }
    if (i == args.len) return .{ .command = .help, .config = config };
    const command: @FieldType(Options, "command") = std.meta.stringToEnum(@FieldType(Options, "command"), args[i]) orelse blk: {
        if (std.mem.eql(u8, args[i], "--help")) break :blk .help;
        if (std.mem.eql(u8, args[i], "--version")) break :blk .version;
        return error.UnknownCommand;
    };
    i += 1;
    var options: Options = .{ .command = command, .config = config };
    if (command == .help or command == .version) {
        if (i != args.len) return error.UnexpectedArgument;
        return options;
    }
    if (i == args.len or std.mem.startsWith(u8, args[i], "--")) return error.ExpectedInputPath;
    options.path = args[i];
    i += 1;
    if (command == .diff or command == .update or command == .evaluate or command == .inspect or command == .judge or command == .@"cross-diff") {
        if (i == args.len or std.mem.startsWith(u8, args[i], "--")) return error.ExpectedSecondPath;
        options.second = args[i];
        i += 1;
    }
    while (i < args.len) {
        const option = args[i];
        i += 1;
        if (command == .query and std.mem.eql(u8, option, "--relations") and !options.relations) {
            options.relations = true;
            continue;
        }
        if (i == args.len) return error.UnexpectedArgument;
        const value = args[i];
        i += 1;
        if (!core.ir.nonempty(value)) return error.EmptyOptionValue;
        if ((command == .scan or command == .diff or command == .update or command == .analyze or command == .review or command == .compile or command == .evaluate or command == .inspect or command == .challenges or command == .judge or command == .explore or command == .replay or command == .auth or command == .@"auth-replay" or command == .solve or command == .cross or command == .@"cross-diff") and std.mem.eql(u8, option, "--out") and options.out == null) {
            options.out = value;
            continue;
        }
        if (command == .scan and std.mem.eql(u8, option, "--language") and options.language == null) {
            options.language = std.meta.stringToEnum(@typeInfo(@FieldType(Options, "language")).optional.child, value) orelse return error.InvalidLanguage;
            continue;
        }
        if ((command == .scan or command == .compile) and std.mem.eql(u8, option, "--project") and options.project == null) {
            options.project = value;
            continue;
        }
        if (command == .update and std.mem.eql(u8, option, "--file") and options.file == null) {
            if (!core.ir.validPath(value)) return error.InvalidSourcePath;
            options.file = value;
            continue;
        }
        if ((command == .scan or command == .query or command == .compile) and std.mem.eql(u8, option, "--revision") and options.filter.revision == null) {
            options.filter.revision = value;
            continue;
        }
        if ((command == .analyze or command == .cross) and std.mem.eql(u8, option, "--previous") and options.previous == null) {
            options.previous = value;
            continue;
        }
        if (command == .review) {
            if (std.mem.eql(u8, option, "--finding") and options.finding == null) {
                options.finding = value;
                continue;
            }
            if (std.mem.eql(u8, option, "--status") and options.status == null) {
                options.status = std.meta.stringToEnum(core.analysis.Status, value) orelse return error.InvalidReviewStatus;
                continue;
            }
            if (std.mem.eql(u8, option, "--note") and options.note == null) {
                options.note = value;
                continue;
            }
        }
        if (command != .query) return error.UnexpectedArgument;
        if (std.mem.eql(u8, option, "--subject") and options.filter.subject == null) {
            if (!core.identity.valid(value, "sub_")) return error.InvalidSubjectId;
            options.filter.subject = value;
        } else if (std.mem.eql(u8, option, "--metric") and options.filter.metric == null) {
            options.filter.metric = value;
        } else if (std.mem.eql(u8, option, "--symbol") and options.filter.symbol == null) {
            options.filter.symbol = value;
        } else if (std.mem.eql(u8, option, "--relation") and options.filter.relation == null) {
            options.filter.relation = value;
        } else if (std.mem.eql(u8, option, "--path") and options.filter.path == null) {
            if (!core.ir.validPath(value)) return error.InvalidSourcePath;
            options.filter.path = value;
        } else if (std.mem.eql(u8, option, "--start") and options.filter.start == null) {
            options.filter.start = std.fmt.parseInt(u32, value, 10) catch return error.InvalidOffset;
        } else if (std.mem.eql(u8, option, "--end") and options.filter.end == null) {
            options.filter.end = std.fmt.parseInt(u32, value, 10) catch return error.InvalidOffset;
        } else return error.UnexpectedArgument;
    }
    if (command == .review and (options.finding == null or options.status == null or options.note == null)) return error.ExpectedReviewFields;
    if (command == .update and options.file == null) return error.ExpectedReplacementFile;
    if (options.relations and options.filter.metric != null) return error.MetricFilterRequiresObservations;
    if ((options.filter.start != null or options.filter.end != null) and options.filter.path == null) return error.OffsetRequiresSourcePath;
    if (options.filter.start != null and options.filter.end != null and options.filter.end.? <= options.filter.start.?) return error.InvalidSpan;
    return options;
}
fn diagnostic(init: std.process.Init, status: u8, code: []const u8, message: []const u8, path: ?[]const u8) u8 {
    const bytes = std.json.Stringify.valueAlloc(init.arena.allocator(), .{ .code = code, .message = message, .path = path }, .{}) catch return 1;
    std.Io.File.stderr().writeStreamingAll(init.io, bytes) catch return 1;
    std.Io.File.stderr().writeStreamingAll(init.io, "\n") catch return 1;
    return status;
}
fn output(init: std.process.Init, value: anytype, path: ?[]const u8) !void {
    const bytes = try std.json.Stringify.valueAlloc(init.arena.allocator(), value, .{ .whitespace = .indent_2 });
    if (path) |target| {
        var file = try std.Io.Dir.cwd().createFileAtomic(init.io, target, .{ .replace = true });
        defer file.deinit(init.io);
        try file.file.writeStreamingAll(init.io, bytes);
        try file.file.writeStreamingAll(init.io, "\n");
        try file.replace(init.io);
    } else {
        try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
}
fn read(init: std.process.Init, path: []const u8, config: Config) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, init.arena.allocator(), .limited(config.max_input_bytes));
}
fn emit(init: std.process.Init, value: anytype, path: ?[]const u8) u8 {
    output(init, value, path) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot write output; check destination and permissions.", path);
    return 0;
}
fn run(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const options = parseArgs(args[1..]) catch |err| return diagnostic(init, 2, @errorName(err), "Invalid arguments; run twinlens --help for usage.", null);
    var config: Config = .{};
    if (options.config) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024)) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read config file; check its path and permissions.", path);
        const shape = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| return diagnostic(init, 2, @errorName(err), "Invalid config JSON.", path);
        defer shape.deinit();
        if (shape.value == .object) if (shape.value.object.get("max_input_bytes")) |limit| {
            if (limit != .integer and limit != .float) return diagnostic(init, 2, "InvalidInputLimit", "max_input_bytes must be a JSON number.", path);
        };
        const parsed = std.json.parseFromSlice(Config, allocator, bytes, .{ .allocate = .alloc_always }) catch |err| return diagnostic(init, 2, @errorName(err), "Invalid config; expected max_input_bytes, typescript_adapter, typespec_adapter, or solver_adapter.", path);
        // Config strings live in the process arena through command execution.
        config = parsed.value;
        if (config.max_input_bytes == 0 or config.max_input_bytes > 256 * 1024 * 1024 or !core.ir.nonempty(config.typescript_adapter) or !core.ir.nonempty(config.typespec_adapter) or !core.ir.nonempty(config.solver_adapter)) return diagnostic(init, 2, "InvalidConfig", "max_input_bytes must be 1..268435456 and adapter paths must be nonempty.", path);
    }
    switch (options.command) {
        .help => try std.Io.File.stdout().writeStreamingAll(init.io, help),
        .version => try std.Io.File.stdout().writeStreamingAll(init.io, "twinlens 0.1.0 (IR v1, snapshots v1)\n"),
        .scan => {
            if (options.language == .zig) {
                var result = zig_adapter.scan(allocator, init.io, options.path.?, options.project, options.filter.revision, config.max_input_bytes) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot scan Zig sources.", options.path);
                defer result.deinit();
                return emit(init, result.value, options.out);
            }
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(allocator, &.{ "node", config.typescript_adapter, options.path.? });
            if (options.project) |project| try argv.appendSlice(allocator, &.{ "--project", project });
            if (options.filter.revision) |revision| try argv.appendSlice(allocator, &.{ "--revision", revision });
            const result = std.process.run(allocator, init.io, .{ .argv = argv.items, .expand_arg0 = .expand, .stdout_limit = .limited(config.max_input_bytes), .stderr_limit = .limited(64 * 1024) }) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot run TypeScript adapter; build packages and check Node.js, adapter path, and input limit.", options.path);
            if (result.term != .exited or result.term.exited != 0) return diagnostic(init, 4, "AdapterFailed", if (result.stderr.len > 0) result.stderr else "TypeScript adapter failed.", options.path);
            const snapshot = core.snapshot.decode(allocator, result.stdout) catch |err| return diagnostic(init, 5, @errorName(err), "TypeScript adapter emitted an invalid snapshot.", options.path);
            defer snapshot.deinit();
            if (options.language == .both) {
                const input = options.path.?;
                const root = if (std.mem.endsWith(u8, input, ".json")) std.fs.path.dirname(input) orelse "." else input;
                var zig_result = zig_adapter.scan(allocator, init.io, root, snapshot.value.project, options.filter.revision, config.max_input_bytes) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot scan Zig sources.", options.path);
                defer zig_result.deinit();
                const combined = core.merge.combine(allocator, snapshot.value, zig_result.value, options.filter.revision) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot combine language snapshots.", options.path);
                return emit(init, combined, options.out);
            }
            return emit(init, snapshot.value, options.out);
        },
        .inspect => {
            const bytes = read(init, options.second.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read structural snapshot.", options.second);
            const snapshot = core.snapshot.decode(allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid structural snapshot.", options.second);
            defer snapshot.deinit();
            const input = zig_adapter.inspect(allocator, init.io, options.path.?, snapshot.value.project, snapshot.value.document, config.max_input_bytes) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot inspect core source.", options.path);
            return emit(init, input, options.out);
        },
        .compile => {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(allocator, &.{ "node", config.typespec_adapter, options.path.? });
            if (options.project) |project| try argv.appendSlice(allocator, &.{ "--project", project });
            if (options.filter.revision) |revision| try argv.appendSlice(allocator, &.{ "--revision", revision });
            const result = std.process.run(allocator, init.io, .{ .argv = argv.items, .expand_arg0 = .expand, .stdout_limit = .limited(config.max_input_bytes), .stderr_limit = .limited(64 * 1024) }) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot run TypeSpec compiler adapter.", options.path);
            if (result.term != .exited or result.term.exited != 0) return diagnostic(init, 4, "AdapterFailed", if (result.stderr.len > 0) result.stderr else "TypeSpec adapter failed.", options.path);
            const specification = core.specification.decode(allocator, result.stdout) catch |err| return diagnostic(init, 5, @errorName(err), "TypeSpec adapter emitted an invalid specification.", options.path);
            defer specification.deinit();
            return emit(init, specification.value, options.out);
        },
        .evaluate => {
            const spec_bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read specification.", options.path);
            const input_bytes = read(init, options.second.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read evaluation evidence.", options.second);
            const spec = core.specification.decode(allocator, spec_bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid specification.", options.path);
            defer spec.deinit();
            const input = core.specification.decodeInput(allocator, input_bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid evaluation evidence.", options.second);
            defer input.deinit();
            var result = core.specification.evaluate(allocator, spec.value, input.value) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot evaluate specification.", options.path);
            defer result.deinit();
            return emit(init, result.report, options.out);
        },
        .auth => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read authentication model.", options.path);
            const model = core.challenge.decode(core.authentication.Model, allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid authentication model.", options.path);
            defer model.deinit();
            const report = core.authentication.run(allocator, init.io, model.value, null) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot run authentication model.", options.path);
            return emit(init, report, options.out);
        },
        .@"auth-replay" => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read authentication replay.", options.path);
            const request = core.challenge.decode(core.authentication.Replay, allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid authentication replay.", options.path);
            defer request.deinit();
            if (request.value.authentication_replay_version != 1) return diagnostic(init, 5, "UnsupportedAuthenticationReplay", "Unsupported authentication replay version.", options.path);
            const report = core.authentication.run(allocator, init.io, request.value.model, request.value.trace) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot replay authentication history.", options.path);
            return emit(init, report, options.out);
        },
        .cross => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read cross-lens input.", options.path);
            const input = core.challenge.decode(core.crosslens.Input, allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid cross-lens input.", options.path);
            defer input.deinit();
            var previous: ?std.json.Parsed(core.crosslens.Report) = null;
            defer if (previous) |report| report.deinit();
            if (options.previous) |path| {
                const previous_bytes = read(init, path, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read previous cross-lens report.", path);
                previous = core.challenge.decode(core.crosslens.Report, allocator, previous_bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid previous cross-lens report.", path);
            }
            const report = core.crosslens.analyze(allocator, init.io, input.value, if (previous) |value| value.value else null) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot analyze cross-lens input.", options.path);
            return emit(init, report, options.out);
        },
        .@"cross-diff" => {
            const before_bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read previous cross-lens report.", options.path);
            const after_bytes = read(init, options.second.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read current cross-lens report.", options.second);
            const before = core.challenge.decode(core.crosslens.Report, allocator, before_bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid previous cross-lens report.", options.path);
            defer before.deinit();
            const after = core.challenge.decode(core.crosslens.Report, allocator, after_bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid current cross-lens report.", options.second);
            defer after.deinit();
            const report = core.crosslens.diff(allocator, before.value, after.value) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot compare cross-lens history.", options.path);
            return emit(init, report, options.out);
        },
        .solve => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read symbolic query.", options.path);
            const query = core.challenge.decode(core.symbolic.Query, allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid symbolic query.", options.path);
            defer query.deinit();
            var encoding = core.symbolic.encode(allocator, query.value) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot encode symbolic query.", options.path);
            var backend: ?std.json.Parsed(core.symbolic.BackendResult) = null;
            defer if (backend) |result| result.deinit();
            if (encoding.packet) |packet| {
                const packet_bytes = try std.json.Stringify.valueAlloc(allocator, packet, .{});
                if (packet_bytes.len > 60000) encoding = .{ .packet = null, .reason = "UnsupportedEncodingSize" } else {
                    const result = std.process.run(allocator, init.io, .{ .argv = &.{ "node", config.solver_adapter, packet_bytes }, .expand_arg0 = .expand, .stdout_limit = .limited(config.max_input_bytes), .stderr_limit = .limited(64 * 1024) }) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot run Z3 adapter.", options.path);
                    if (result.term != .exited or result.term.exited != 0) return diagnostic(init, 4, "SolverAdapterFailed", if (result.stderr.len > 0) result.stderr else "Z3 adapter failed.", options.path);
                    backend = core.challenge.decode(core.symbolic.BackendResult, allocator, result.stdout) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid solver response.", options.path);
                }
            }
            const report = core.symbolic.finish(allocator, init.io, query.value, encoding, if (backend) |result| result.value else null) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot interpret symbolic result.", options.path);
            return emit(init, report, options.out);
        },
        .challenges => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read specification.", options.path);
            const model = core.specification.decode(allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid specification.", options.path);
            defer model.deinit();
            return emit(init, try core.challenge.generate(allocator, model.value), options.out);
        },
        .judge => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read specification.", options.path);
            const model = core.specification.decode(allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid specification.", options.path);
            defer model.deinit();
            const request_bytes = read(init, options.second.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read oracle request.", options.second);
            const request = core.challenge.decode(core.challenge.Request, allocator, request_bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid oracle request.", options.second);
            defer request.deinit();
            const judgment = core.challenge.judge(allocator, model.value, request.value) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot judge response.", options.second);
            return emit(init, judgment, options.out);
        },
        .explore => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read exploration model.", options.path);
            const model = core.challenge.decode(core.exploration.Model, allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid exploration model.", options.path);
            defer model.deinit();
            const report = core.exploration.run(allocator, init.io, model.value, null) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot explore model.", options.path);
            return emit(init, report, options.out);
        },
        .replay => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read replay request.", options.path);
            const request = core.challenge.decode(core.exploration.Replay, allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid replay request.", options.path);
            defer request.deinit();
            if (request.value.replay_version != 1) return diagnostic(init, 5, "InvalidReplayVersion", "Unsupported replay version.", options.path);
            const report = core.exploration.run(allocator, init.io, request.value.model, request.value.trace) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot replay trace.", options.path);
            return emit(init, report, options.out);
        },
        .analyze => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read snapshot.", options.path);
            const snapshot = core.snapshot.decode(allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid snapshot.", options.path);
            defer snapshot.deinit();
            var previous: ?std.json.Parsed(core.analysis.Report) = null;
            defer if (previous) |old| old.deinit();
            if (options.previous) |path| {
                const old_bytes = read(init, path, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read previous analysis.", path);
                previous = core.analysis.decode(allocator, old_bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid previous analysis.", path);
            }
            var result = core.analysis.analyze(allocator, snapshot.value, if (previous) |old| old.value else null) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot analyze snapshot or reconcile review history.", options.path);
            defer result.deinit();
            return emit(init, result.report, options.out);
        },
        .review => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read analysis.", options.path);
            var report = core.analysis.decode(allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid analysis.", options.path);
            defer report.deinit();
            core.analysis.review(allocator, &report.value, options.finding.?, options.status.?, options.note.?) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot review finding.", options.path);
            return emit(init, report.value, options.out);
        },
        .diff => {
            const left_bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read before snapshot.", options.path);
            const right_bytes = read(init, options.second.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read after snapshot.", options.second);
            const left = core.snapshot.decode(allocator, left_bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid before snapshot.", options.path);
            defer left.deinit();
            const right = core.snapshot.decode(allocator, right_bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid after snapshot.", options.second);
            defer right.deinit();
            var result = core.diff.compare(allocator, left.value, right.value) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot compare snapshots from different projects.", null);
            defer result.deinit();
            return emit(init, result.report, options.out);
        },
        .import, .query, .update => {
            const bytes = read(init, options.path.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read input; check path, permissions, and max_input_bytes.", options.path);
            var store = core.Store.decode(allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid IR/snapshot; check version, fields, identities, and references.", options.path);
            defer store.deinit();
            if (options.command == .import) return emit(init, store.document(), null);
            if (options.command == .update) {
                const replacement_bytes = read(init, options.second.?, config) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read replacement document.", options.second);
                var replacement = core.Store.decode(allocator, replacement_bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid replacement document.", options.second);
                defer replacement.deinit();
                var updated = store.replaceFiles(allocator, replacement.document(), &.{options.file.?}) catch |err| return diagnostic(init, 5, @errorName(err), "Cannot replace selected file.", options.file);
                defer updated.deinit();
                return emit(init, updated.document(), options.out);
            }
            if (options.relations) {
                const rows = try store.queryRelations(allocator, options.filter);
                return emit(init, .{ .schema_version = @as(u32, 1), .revision = store.document().revision, .relations = rows }, null);
            }
            const rows = try store.queryFiltered(allocator, options.filter);
            return emit(init, .{ .schema_version = @as(u32, 1), .revision = store.document().revision, .observations = rows }, null);
        },
    }
    return 0;
}
pub fn main(init: std.process.Init) void {
    const status = run(init) catch |err| diagnostic(init, 1, @errorName(err), "Twinlens failed while processing the request.", null);
    if (status != 0) std.process.exit(status);
}
test "CLI rejects ambiguous queries and incomplete updates" {
    try std.testing.expectEqual(.help, (try parseArgs(&.{})).command);
    try std.testing.expectError(error.ExpectedInputPath, parseArgs(&.{"import"}));
    try std.testing.expectError(error.UnknownCommand, parseArgs(&.{"wat"}));
    try std.testing.expectError(error.UnexpectedArgument, parseArgs(&.{ "query", "a.json", "--metric", "x", "--metric", "y" }));
    try std.testing.expectError(error.ExpectedConfigAndCommand, parseArgs(&.{ "--config", "a.json" }));
    try std.testing.expectError(error.MetricFilterRequiresObservations, parseArgs(&.{ "query", "a", "--relations", "--metric", "x" }));
    try std.testing.expectError(error.OffsetRequiresSourcePath, parseArgs(&.{ "query", "a", "--start", "1" }));
    try std.testing.expectError(error.ExpectedReplacementFile, parseArgs(&.{ "update", "a", "b" }));
}
