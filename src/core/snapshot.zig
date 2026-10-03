const std = @import("std");
const ir = @import("ir.zig");
const wire = @import("wire.zig");
pub const FileDigest = struct { path: []const u8, sha256: []const u8 };
pub const Configuration = struct { adapter: []const u8, compiler: []const u8, options_sha256: []const u8, configs: []const FileDigest };
pub const Diagnostic = struct {
    category: enum { @"error", warning, suggestion, message },
    code: u32,
    message: []const u8,
    path: ?[]const u8,
    start: ?u32,
    end: ?u32,
};
pub const Snapshot = struct {
    snapshot_version: u32,
    project: []const u8,
    configuration: Configuration,
    files: []const FileDigest,
    diagnostics: []const Diagnostic,
    coverage: struct { unresolved_calls: u32, unresolved_accesses: u32 },
    document: ir.Document,
};
pub fn validHash(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}
fn inventory(allocator: std.mem.Allocator, files: []const FileDigest) !std.StringHashMapUnmanaged(void) {
    var map: std.StringHashMapUnmanaged(void) = .empty;
    errdefer map.deinit(allocator);
    for (files) |file| {
        if (!ir.validPath(file.path) or !validHash(file.sha256)) return error.InvalidFileDigest;
        const item = try map.getOrPut(allocator, file.path);
        if (item.found_existing) return error.DuplicateFile;
    }
    return map;
}
pub fn validate(allocator: std.mem.Allocator, value: Snapshot) !void {
    if (value.snapshot_version != 1) return error.UnsupportedSnapshotVersion;
    if (!ir.nonempty(value.project) or !ir.nonempty(value.configuration.adapter) or !ir.nonempty(value.configuration.compiler) or !validHash(value.configuration.options_sha256)) return error.InvalidSnapshotConfiguration;
    var configs = try inventory(allocator, value.configuration.configs);
    defer configs.deinit(allocator);
    var files = try inventory(allocator, value.files);
    defer files.deinit(allocator);
    try ir.validate(allocator, value.document);
    for (value.document.subjects) |subject| {
        if (!std.mem.eql(u8, value.project, subject.key.project) or !files.contains(subject.key.path)) return error.SnapshotSourceMismatch;
    }
    inline for (.{ value.document.observations, value.document.relations }) |rows| for (rows) |row| {
        if (!files.contains(row.source.path)) return error.SnapshotSourceMismatch;
    };
    for (value.diagnostics) |diagnostic| {
        if (diagnostic.message.len == 0) return error.InvalidDiagnostic;
        if (diagnostic.path) |path| if (!ir.validPath(path)) return error.InvalidDiagnostic;
        if ((diagnostic.start == null) != (diagnostic.end == null)) return error.InvalidDiagnostic;
        if (diagnostic.start) |start| if (diagnostic.path == null or diagnostic.end.? < start) return error.InvalidDiagnostic;
    }
}
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Snapshot) {
    const shape = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer shape.deinit();
    try wire.validateShape(Snapshot, shape.value);
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(allocator, parsed.value);
    return parsed;
}
