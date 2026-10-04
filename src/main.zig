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
    \\  --help                              Show this help
    \\  --version                           Show version
    \\Config: max_input_bytes (16 MiB), typescript_adapter (packages/typescript/dist/cli.js).
    \\Paths are relative to cwd. Query/update source paths are project-relative.
    \\Exit: 0 success, 1 internal, 2 usage/config, 3 unsupported, 4 I/O/adapter, 5 invalid IR.
    \\
;
const Config = struct {
    max_input_bytes: u32 = 16 * 1024 * 1024,
    typescript_adapter: []const u8 = "packages/typescript/dist/cli.js",
};
const Options = struct {
    command: enum { help, version, import, query, scan, diff, update },
    path: ?[]const u8 = null,
    second: ?[]const u8 = null,
    config: ?[]const u8 = null,
    out: ?[]const u8 = null,
    project: ?[]const u8 = null,
    file: ?[]const u8 = null,
    language: ?enum { typescript, zig, both } = null,
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
    if (command == .diff or command == .update) {
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
        if ((command == .scan or command == .diff or command == .update) and std.mem.eql(u8, option, "--out") and options.out == null) {
            options.out = value;
            continue;
        }
        if (command == .scan and std.mem.eql(u8, option, "--language") and options.language == null) {
            options.language = std.meta.stringToEnum(@typeInfo(@FieldType(Options, "language")).optional.child, value) orelse return error.InvalidLanguage;
            continue;
        }
        if (command == .scan and std.mem.eql(u8, option, "--project") and options.project == null) {
            options.project = value;
            continue;
        }
        if (command == .update and std.mem.eql(u8, option, "--file") and options.file == null) {
            if (!core.ir.validPath(value)) return error.InvalidSourcePath;
            options.file = value;
            continue;
        }
        if ((command == .scan or command == .query) and std.mem.eql(u8, option, "--revision") and options.filter.revision == null) {
            options.filter.revision = value;
            continue;
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
        const parsed = std.json.parseFromSlice(Config, allocator, bytes, .{ .allocate = .alloc_always }) catch |err| return diagnostic(init, 2, @errorName(err), "Invalid config; expected max_input_bytes and/or typescript_adapter.", path);
        // Config strings live in the process arena through command execution.
        config = parsed.value;
        if (config.max_input_bytes == 0 or config.max_input_bytes > 256 * 1024 * 1024 or !core.ir.nonempty(config.typescript_adapter)) return diagnostic(init, 2, "InvalidConfig", "max_input_bytes must be 1..268435456 and typescript_adapter must be nonempty.", path);
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
