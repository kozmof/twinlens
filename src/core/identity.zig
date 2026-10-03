const std = @import("std");

/// IDs are distinct Zig types and plain strings at the transport boundary.
pub fn Id(comptime prefix: []const u8) type {
    return struct {
        bytes: []const u8,
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const bytes = try std.json.innerParse([]const u8, allocator, source, options);
            if (!valid(bytes, prefix)) return error.InvalidCharacter;
            return .{ .bytes = bytes };
        }
        pub fn jsonStringify(self: @This(), writer: anytype) !void {
            try writer.write(self.bytes);
        }
    };
}

pub const SubjectId = Id("sub_");
pub const SymbolId = Id("sym_");
pub const ObservationId = Id("obs_");
pub const RelationId = Id("rel_");

pub fn valid(bytes: []const u8, prefix: []const u8) bool {
    if (bytes.len != prefix.len + 64 or !std.mem.startsWith(u8, bytes, prefix)) return false;
    for (bytes[prefix.len..]) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// SHA-256 over UTF-8 fields, each prefixed with its big-endian u32 byte length.
pub fn make(allocator: std.mem.Allocator, comptime T: type, prefix: []const u8, fields: []const []const u8) !T {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (fields) |field| {
        const len = std.math.cast(u32, field.len) orelse return error.IdentityTooLong;
        var encoded: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded, len, .big);
        hash.update(&encoded);
        hash.update(field);
    }
    const hex = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return .{ .bytes = try std.mem.concat(allocator, u8, &.{ prefix, &hex }) };
}

test "typed stable identities distinguish fields and preserve UTF-8" {
    const allocator = std.testing.allocator;
    const a = try make(allocator, SubjectId, "sub_", &.{ "ab", "c" });
    defer allocator.free(a.bytes);
    const b = try make(allocator, SubjectId, "sub_", &.{ "a", "bc" });
    defer allocator.free(b.bytes);
    const again = try make(allocator, SubjectId, "sub_", &.{ "ab", "c" });
    defer allocator.free(again.bytes);
    try std.testing.expect(!std.mem.eql(u8, a.bytes, b.bytes));
    try std.testing.expectEqualStrings(a.bytes, again.bytes);
    try std.testing.expect(valid(a.bytes, "sub_"));
    try std.testing.expect(!valid(a.bytes, "sym_"));
}
