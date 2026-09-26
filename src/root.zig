//! ZIGote: a bioinformatics library for Zig.
const std = @import("std");

pub const fasta = @import("fasta.zig");

test {
    std.testing.refAllDecls(@This());
}
