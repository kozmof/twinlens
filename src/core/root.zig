const std = @import("std");
pub const ir = @import("ir.zig");
pub const identity = @import("identity.zig");
pub const Store = @import("store.zig").Store;

pub const Filter = @import("store.zig").Filter;
pub const snapshot = @import("snapshot.zig");
pub const merge = @import("merge.zig");
pub const crosslens = @import("crosslens.zig");
pub const symbolic = @import("symbolic.zig");
pub const challenge = @import("challenge.zig");
pub const exploration = @import("exploration.zig");
pub const specification = @import("specification.zig");
pub const analysis = @import("analysis.zig");
pub const diff = @import("diff.zig");

test {
    _ = @import("phase_six_tests.zig");
    std.testing.refAllDecls(@This());
}

// Structural inspection checks source against the schema/index compiled into this binary.
pub const ir_source = @embedFile("ir.zig");
pub const index_source = @embedFile("index.zig");
pub const store_source = @embedFile("store.zig");
