const std = @import("std");
const core = @import("twinlens");
const help =
    \\Twinlens — specification analysis and behavioral telemetry
    \\Usage: twinlens [--config FILE] COMMAND
    \\  import FILE                         Validate IR and emit normalized JSON
    \\  query FILE [--subject ID] [--metric NAME]
    \\                                      Emit matching observations as JSON
    \\  scan PATH                           Reserved for Phase 1 (exit 3)
    \\  --help                              Show this help
    \\  --version                           Show version
    \\Config: {"max_input_bytes":16777216}; paths are relative to the working directory.
    \\Exit: 0 success, 1 internal, 2 usage/config, 3 unsupported, 4 I/O, 5 invalid IR.
    \\
;
const Config = struct { max_input_bytes: u32 = 16 * 1024 * 1024 };
const Options = struct {
    command: enum { help, version, import, query, scan },
    path: ?[]const u8 = null,
    config: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    metric: ?[]const u8 = null,
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
    while (i < args.len) : (i += 2) {
        if (command != .query or i + 1 >= args.len) return error.UnexpectedArgument;
        if (std.mem.eql(u8, args[i], "--subject") and options.subject == null) {
            if (!core.identity.valid(args[i + 1], "sub_")) return error.InvalidSubjectId;
            options.subject = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--metric") and options.metric == null) {
            if (!core.ir.nonempty(args[i + 1])) return error.InvalidMetric;
            options.metric = args[i + 1];
        } else return error.UnexpectedArgument;
    }
    return options;
}

fn diagnostic(init: std.process.Init, status: u8, code: []const u8, message: []const u8, path: ?[]const u8) u8 {
    const bytes = std.json.Stringify.valueAlloc(init.arena.allocator(), .{
        .code = code,
        .message = message,
        .path = path,
    }, .{}) catch return 1;
    std.Io.File.stderr().writeStreamingAll(init.io, bytes) catch return 1;
    std.Io.File.stderr().writeStreamingAll(init.io, "\n") catch return 1;
    return status;
}
fn output(init: std.process.Init, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(init.arena.allocator(), value, .{ .whitespace = .indent_2 });
    try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
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
        if (shape.value == .object) {
            if (shape.value.object.get("max_input_bytes")) |limit| {
                if (limit != .integer and limit != .float) return diagnostic(init, 2, "InvalidInputLimit", "max_input_bytes must be a JSON number.", path);
            }
        }
        const parsed = std.json.parseFromSlice(Config, allocator, bytes, .{}) catch |err| return diagnostic(init, 2, @errorName(err), "Invalid config; expected max_input_bytes as a positive integer.", path);
        defer parsed.deinit();
        config = parsed.value;
        if (config.max_input_bytes == 0 or config.max_input_bytes > 256 * 1024 * 1024) return diagnostic(init, 2, "InvalidInputLimit", "max_input_bytes must be between 1 and 268435456.", path);
    }
    switch (options.command) {
        .help => try std.Io.File.stdout().writeStreamingAll(init.io, help),
        .version => try std.Io.File.stdout().writeStreamingAll(init.io, "twinlens 0.1.0 (IR v1)\n"),
        .scan => return diagnostic(init, 3, "UnsupportedCommand", "Source scanning is planned for Phase 1; use import for an IR document.", options.path),
        .import, .query => {
            const path = options.path.?;
            const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(config.max_input_bytes)) catch |err| return diagnostic(init, 4, @errorName(err), "Cannot read input; check the path, permissions, and max_input_bytes.", path);
            var store = core.Store.decode(allocator, bytes) catch |err| return diagnostic(init, 5, @errorName(err), "Invalid IR; check schema version, fields, identities, and references against docs/ir-v1.md.", path);
            defer store.deinit();
            if (options.command == .import) {
                try output(init, store.document());
            } else {
                const observations = try store.query(allocator, options.subject, options.metric);
                defer allocator.free(observations);
                try output(init, .{ .schema_version = @as(u32, 1), .revision = store.document().revision, .observations = observations });
            }
        },
    }
    return 0;
}

pub fn main(init: std.process.Init) void {
    const status = run(init) catch |err| diagnostic(init, 1, @errorName(err), "Twinlens failed while processing the request.", null);
    if (status != 0) std.process.exit(status);
}

test "CLI rejects missing values, duplicate options, and unknown commands" {
    try std.testing.expectEqual(.help, (try parseArgs(&.{})).command);
    try std.testing.expectEqual(.import, (try parseArgs(&.{ "import", "a.json" })).command);
    try std.testing.expectError(error.ExpectedInputPath, parseArgs(&.{"import"}));
    try std.testing.expectError(error.UnknownCommand, parseArgs(&.{"wat"}));
    try std.testing.expectError(error.UnexpectedArgument, parseArgs(&.{ "query", "a.json", "--metric", "x", "--metric", "y" }));
    try std.testing.expectError(error.UnexpectedArgument, parseArgs(&.{ "query", "a.json", "--metric" }));
    try std.testing.expectError(error.ExpectedConfigAndCommand, parseArgs(&.{ "--config", "a.json" }));
}
