const std = @import("std");
pub const ir = @import("ir.zig");
pub const identity = @import("identity.zig");
pub const Store = @import("store.zig").Store;

test {
    std.testing.refAllDecls(@This());
}
