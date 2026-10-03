const std = @import("std");

/// std.json accepts numeric strings for numeric fields. The transport does not.
/// Check the wire shape before typed decoding, including required nullable fields.
pub fn validateShape(comptime T: type, value: std.json.Value) anyerror!void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (@hasDecl(T, "jsonParse")) {
                if (value != .string) return error.UnexpectedToken;
                return;
            }
            if (value != .object) return error.UnexpectedToken;
            if (value.object.count() > info.fields.len) return error.UnknownField;
            inline for (info.fields) |field| {
                const child = value.object.get(field.name) orelse return error.MissingField;
                try validateShape(field.type, child);
            }
            if (value.object.count() != info.fields.len) return error.UnknownField;
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("wire pointers must be slices");
            if (info.child == u8) {
                if (value != .string) return error.UnexpectedToken;
            } else {
                if (value != .array) return error.UnexpectedToken;
                for (value.array.items) |item| try validateShape(info.child, item);
            }
        },
        .optional => |info| if (value != .null) try validateShape(info.child, value),
        .int, .float => switch (value) {
            .integer, .float, .number_string => {},
            else => return error.UnexpectedToken,
        },
        .@"enum" => if (value != .string) return error.UnexpectedToken,
        else => @compileError("unsupported wire type " ++ @typeName(T)),
    }
}
