//! FASTA parser. See specs/001-fasta.md; test names carry requirement IDs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

pub const Options = struct {
    /// Maximum header plus sequence bytes per record. `null` means unbounded.
    max_record_size: ?usize = null,
};

pub const Error = error{
    MissingHeader,
    RecordTooLarge,
    OutOfMemory,
    ReadFailed,
};

/// Slices are borrowed from the parser and valid until the next `next()`.
pub const Record = struct {
    id: []const u8,
    desc: []const u8,
    seq: []const u8,

    /// Copies the record into one allocation owned by the caller.
    pub fn dupe(self: Record, allocator: Allocator) Allocator.Error!OwnedRecord {
        const mem = try allocator.alloc(u8, self.id.len + self.desc.len + self.seq.len);
        @memcpy(mem[0..self.id.len], self.id);
        @memcpy(mem[self.id.len..][0..self.desc.len], self.desc);
        @memcpy(mem[self.id.len + self.desc.len ..], self.seq);
        return .{
            .id = mem[0..self.id.len],
            .desc = mem[self.id.len..][0..self.desc.len],
            .seq = mem[self.id.len + self.desc.len ..],
        };
    }
};

pub const OwnedRecord = struct {
    id: []const u8,
    desc: []const u8,
    seq: []const u8,

    pub fn deinit(self: OwnedRecord, allocator: Allocator) void {
        // id, desc and seq are consecutive slices of a single allocation.
        const total = self.id.len + self.desc.len + self.seq.len;
        if (total == 0) return;
        const start: [*]const u8 = if (self.id.len > 0) self.id.ptr else if (self.desc.len > 0) self.desc.ptr else self.seq.ptr;
        allocator.free(start[0..total]);
    }
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isSequenceBreak(c: u8) bool {
    return c == '\n' or isBlank(c);
}

/// Returns the index of the first newline, space or tab at or after `start`.
/// Each block is first checked for any byte <= ' ' with one comparison, which
/// skips almost all residue data. Other bytes below 0x20 are ordinary data
/// (FA-R7), so a block that passes that check is then matched exactly.
fn findSequenceBreak(bytes: []const u8, start: usize) ?usize {
    var i = start;
    if (std.simd.suggestVectorLength(u8)) |n| {
        const V = @Vector(n, u8);
        const space: V = @splat(' ');
        const tab: V = @splat('\t');
        const newline: V = @splat('\n');
        while (i + n <= bytes.len) : (i += n) {
            const block: V = bytes[i..][0..n].*;
            if (!@reduce(.Or, block <= space)) continue;
            const hits = (block == newline) | (block == space) | (block == tab);
            if (std.simd.firstTrue(hits)) |j| return i + j;
        }
    }
    while (i < bytes.len) : (i += 1) {
        if (isSequenceBreak(bytes[i])) return i;
    }
    return null;
}

pub const Parser = struct {
    allocator: Allocator,
    reader: *Reader,
    options: Options,
    /// Header text (after `>`) followed by sequence bytes; reused per record.
    buf: std.ArrayList(u8) = .empty,
    /// 1-based line number of the most recently read line.
    line: usize = 0,
    /// Set by the first error; later calls return it (FA-R18).
    err: ?Error = null,

    pub fn init(allocator: Allocator, reader: *Reader, options: Options) Parser {
        return .{ .allocator = allocator, .reader = reader, .options = options };
    }

    pub fn deinit(self: *Parser) void {
        self.buf.deinit(self.allocator);
    }

    /// Returns the next record, or null at end of input. The returned slices
    /// are invalidated by the next call. After an error, every later call
    /// returns that error.
    pub fn next(self: *Parser) Error!?Record {
        if (self.err) |e| return e;
        return self.nextRecord() catch |e| {
            self.err = e;
            return e;
        };
    }

    fn nextRecord(self: *Parser) Error!?Record {
        self.buf.clearRetainingCapacity();

        // Find the header, skipping blank lines.
        while (true) {
            const c = try self.peekByte() orelse return null;
            if (c == '>') break;
            if (try self.skipLine()) return error.MissingHeader;
        }
        self.reader.toss(1);
        try self.readLine(.header);
        const header_len = self.buf.items.len;

        // Sequence lines run until the next header or end of input.
        while (try self.peekByte()) |c| {
            if (c == '>') break;
            try self.readLine(.sequence);
        }

        const header = self.buf.items[0..header_len];
        var i: usize = 0;
        while (i < header.len and isBlank(header[i])) i += 1;
        const id_start = i;
        while (i < header.len and !isBlank(header[i])) i += 1;
        const id_end = i;
        while (i < header.len and isBlank(header[i])) i += 1;
        return .{
            .id = header[id_start..id_end],
            .desc = header[i..],
            .seq = self.buf.items[header_len..],
        };
    }

    fn peekByte(self: *Parser) Error!?u8 {
        return self.reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => error.ReadFailed,
        };
    }

    /// Returns the rest of the current line in the reader's buffer, up to but
    /// not including `\n`, and whether the `\n` was found. Null at end of input.
    fn lineChunk(self: *Parser) Error!?struct { []const u8, bool } {
        const r = self.reader;
        if (r.bufferedLen() == 0) {
            r.fill(1) catch |err| switch (err) {
                error.EndOfStream => return null,
                error.ReadFailed => return error.ReadFailed,
            };
        }
        const chunk = r.buffered();
        if (std.mem.findScalar(u8, chunk, '\n')) |nl| return .{ chunk[0..nl], true };
        return .{ chunk, false };
    }

    /// Consumes one line without buffering it. Returns true if the line has
    /// content other than spaces, tabs and the line terminator.
    fn skipLine(self: *Parser) Error!bool {
        self.line += 1;
        var content = false;
        while (try self.lineChunk()) |chunk| {
            const bytes, const ended = chunk;
            if (!content) {
                for (bytes) |c| {
                    if (!isBlank(c) and c != '\r') content = true;
                }
            }
            self.reader.toss(bytes.len + @intFromBool(ended));
            if (ended) break;
        }
        return content;
    }

    /// Appends one line to `buf` without its terminator (`\n` or `\r\n`).
    /// Sequence lines have spaces and tabs removed (FA-R19).
    fn readLine(self: *Parser, kind: enum { header, sequence }) Error!void {
        self.line += 1;
        const start = self.buf.items.len;
        switch (kind) {
            .header => while (try self.lineChunk()) |chunk| {
                const bytes, const ended = chunk;
                try self.append(bytes);
                self.reader.toss(bytes.len + @intFromBool(ended));
                if (ended) break;
            },
            .sequence => try self.readSequenceLine(),
        }
        if (self.buf.items.len > start and self.buf.items[self.buf.items.len - 1] == '\r') {
            self.buf.items.len -= 1;
        }
        if (self.options.max_record_size) |max| {
            if (self.buf.items.len > max) return error.RecordTooLarge;
        }
    }

    /// Appends one sequence line, dropping spaces and tabs. A single pass over
    /// the buffered bytes finds both the line end and the bytes to drop.
    fn readSequenceLine(self: *Parser) Error!void {
        const r = self.reader;
        while (true) {
            if (r.bufferedLen() == 0) {
                r.fill(1) catch |err| switch (err) {
                    error.EndOfStream => return,
                    error.ReadFailed => return error.ReadFailed,
                };
            }
            const bytes = r.buffered();
            var pos: usize = 0;
            while (findSequenceBreak(bytes, pos)) |i| {
                try self.append(bytes[pos..i]);
                if (bytes[i] == '\n') {
                    r.toss(i + 1);
                    return;
                }
                pos = i + 1;
            }
            try self.append(bytes[pos..]);
            r.toss(bytes.len);
        }
    }

    fn append(self: *Parser, bytes: []const u8) Error!void {
        // One byte of slack: a trailing `\r` is stripped in `readLine`, which
        // then makes the exact check.
        if (self.options.max_record_size) |max| {
            if (bytes.len > max +| 1 or self.buf.items.len + bytes.len > max +| 1) return error.RecordTooLarge;
        }
        try self.buf.appendSlice(self.allocator, bytes);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectRecord(rec: ?Record, id: []const u8, desc: []const u8, seq: []const u8) !void {
    const r = rec orelse return error.TestExpectedRecord;
    try testing.expectEqualStrings(id, r.id);
    try testing.expectEqualStrings(desc, r.desc);
    try testing.expectEqualStrings(seq, r.seq);
}

/// Parse `input` and expect exactly one record. Also parses it through
/// 1- and 3-byte reader buffers so lines and `\r\n` split across reads.
fn expectOne(input: []const u8, options: Options, id: []const u8, desc: []const u8, seq: []const u8) !void {
    var fixed: Reader = .fixed(input);
    try expectOneFrom(&fixed, options, id, desc, seq);
    inline for (.{ 1, 3 }) |size| {
        var src: Reader = .fixed(input);
        var small: [size]u8 = undefined;
        var limited = src.limited(.unlimited, &small);
        try expectOneFrom(&limited.interface, options, id, desc, seq);
    }
}

fn expectOneFrom(reader: *Reader, options: Options, id: []const u8, desc: []const u8, seq: []const u8) !void {
    var p = Parser.init(testing.allocator, reader, options);
    defer p.deinit();
    try expectRecord(try p.next(), id, desc, seq);
    try testing.expectEqual(@as(?Record, null), try p.next());
}

test "FA-R1: header splits into id and desc at first space or tab" {
    try expectOne(">seq1 first record\nACGT\n", .{}, "seq1", "first record", "ACGT");
    try expectOne(">seq1\tfirst record\nACGT\n", .{}, "seq1", "first record", "ACGT");
    try expectOne(">seq1\nACGT\n", .{}, "seq1", "", "ACGT");
}

test "FA-R2: multi-line sequence is joined" {
    try expectOne(">s\nACGT\nTTGA\nCC\n", .{}, "s", "", "ACGTTTGAC");
}

test "FA-R3: CRLF terminators, no CR in output" {
    try expectOne(">s d\r\nACGT\r\nTT\r\n", .{}, "s", "d", "ACGTTT");
}

test "FA-R4: missing trailing newline" {
    try expectOne(">s\nACGT", .{}, "s", "", "ACGT");
    try expectOne(">s d", .{}, "s", "d", "");
}

test "FA-R5: header without sequence lines" {
    var reader: Reader = .fixed(">a\n>b\nAC\n");
    var p = Parser.init(testing.allocator, &reader, .{});
    defer p.deinit();
    try expectRecord(try p.next(), "a", "", "");
    try expectRecord(try p.next(), "b", "", "AC");
    try testing.expectEqual(@as(?Record, null), try p.next());
}

test "FA-R6: blank lines are skipped" {
    var reader: Reader = .fixed(">a\n\nAC\n\nGT\n\n\n>b\nTT\n");
    var p = Parser.init(testing.allocator, &reader, .{});
    defer p.deinit();
    try expectRecord(try p.next(), "a", "", "ACGT");
    try expectRecord(try p.next(), "b", "", "TT");
    try testing.expectEqual(@as(?Record, null), try p.next());
}

test "FA-R7: sequence bytes pass through unchanged" {
    const seq = "acgtNRYKMSWBDHVn-*ACGU";
    try expectOne(">s\n" ++ seq ++ "\n", .{}, "s", "", seq);
}

test "FA-R6: whitespace-only lines are skipped" {
    try expectOne(" \t\n>s\nAC\n  \n\t\nGT\n", .{}, "s", "", "ACGT");
}

test "FA-R7: other bytes below 0x20 pass through in sequence" {
    // Only space, tab and the line terminator are special. Other control
    // bytes, and a `\r` that is not at the end of a line, are kept, including
    // when they share a 16-byte block with a real break.
    const odd = "A\x00C\x01G\x0bT\x0cA\x1fC\rG";
    try expectOne(">s\n" ++ odd ++ "\n", .{}, "s", "", odd);
    try expectOne(">s\n" ++ odd ++ " T\tA\n", .{}, "s", "", odd ++ "TA");
    const long = ("ACGT\x0cACGT\x0bACG" ** 8) ++ " \x1f";
    try expectOne(">s\n" ++ long ++ "\n", .{}, "s", "", ("ACGT\x0cACGT\x0bACG" ** 8) ++ "\x1f");
}

test "FA-R8: content before first header is an error" {
    var reader: Reader = .fixed("ACGT\n>s\nAC\n");
    var p = Parser.init(testing.allocator, &reader, .{});
    defer p.deinit();
    try testing.expectError(error.MissingHeader, p.next());
}

test "FA-R9: empty input yields no records" {
    var reader: Reader = .fixed("");
    var p = Parser.init(testing.allocator, &reader, .{});
    defer p.deinit();
    try testing.expectEqual(@as(?Record, null), try p.next());
}

test "FA-R10: errors carry a 1-based line number" {
    var reader: Reader = .fixed("\n\nACGT\n>s\n");
    var p = Parser.init(testing.allocator, &reader, .{});
    defer p.deinit();
    try testing.expectError(error.MissingHeader, p.next());
    try testing.expectEqual(@as(usize, 3), p.line);
}

test "FA-R11: no allocation on a second record that fits the buffer" {
    var fa = testing.FailingAllocator.init(testing.allocator, .{});
    var reader: Reader = .fixed(">a\nACGTACGT\n>b\nTTTT\n");
    var p = Parser.init(fa.allocator(), &reader, .{});
    defer p.deinit();
    _ = try p.next();
    const allocs = fa.allocations;
    const resizes = fa.resize_index;
    const bytes = fa.allocated_bytes;
    _ = try p.next();
    try testing.expectEqual(allocs, fa.allocations);
    try testing.expectEqual(resizes, fa.resize_index);
    try testing.expectEqual(bytes, fa.allocated_bytes);
}

test "FA-R11: a larger later record does allocate" {
    var fa = testing.FailingAllocator.init(testing.allocator, .{});
    const big = "A" ** 5000;
    var reader: Reader = .fixed(">a\nAC\n>b\n" ++ big ++ "\n");
    var p = Parser.init(fa.allocator(), &reader, .{});
    defer p.deinit();
    _ = try p.next();
    const after_first = fa.allocated_bytes;
    _ = try p.next();
    try testing.expect(fa.allocated_bytes > after_first);
}

test "FA-R12: record slices do not point into the reader's buffer" {
    const input = ">a desc\nAAAA\n";
    var reader: Reader = .fixed(input);
    var p = Parser.init(testing.allocator, &reader, .{});
    defer p.deinit();
    const r = (try p.next()).?;
    const lo = @intFromPtr(input.ptr);
    const hi = lo + input.len;
    for ([_][]const u8{ r.id, r.desc, r.seq }) |slice| {
        const addr = @intFromPtr(slice.ptr);
        try testing.expect(addr < lo or addr >= hi);
    }
}

test "FA-R13: dupe outlives the next call and is freed by the caller" {
    var reader: Reader = .fixed(">a desc\nAAAA\n>b\nCCCC\n");
    var p = Parser.init(testing.allocator, &reader, .{});
    defer p.deinit();
    const owned = try (try p.next()).?.dupe(testing.allocator);
    defer owned.deinit(testing.allocator);
    _ = try p.next();
    try testing.expectEqualStrings("a", owned.id);
    try testing.expectEqualStrings("desc", owned.desc);
    try testing.expectEqualStrings("AAAA", owned.seq);
}

test "FA-R14: max_record_size boundary" {
    // Header ">a" contributes "a" (1 byte); sequence is 4 bytes; total 5.
    const input = ">a\nACGT\n";
    try expectOne(input, .{ .max_record_size = 5 }, "a", "", "ACGT");

    var reader: Reader = .fixed(input);
    var p = Parser.init(testing.allocator, &reader, .{ .max_record_size = 4 });
    defer p.deinit();
    try testing.expectError(error.RecordTooLarge, p.next());
}

test "FA-R14: CRLF does not count toward the limit" {
    try expectOne(">a\r\nACGT\r\n", .{ .max_record_size = 5 }, "a", "", "ACGT");
}

test "FA-R14: lines before the first header do not count" {
    var reader: Reader = .fixed("ACGTACGTACGT\n>a\nAC\n");
    var p = Parser.init(testing.allocator, &reader, .{ .max_record_size = 4 });
    defer p.deinit();
    try testing.expectError(error.MissingHeader, p.next());
}

test "FA-R14: removed spaces do not count toward the limit" {
    try expectOne(">a\nA C G T\n", .{ .max_record_size = 5 }, "a", "", "ACGT");
}

test "FA-R14: unbounded by default" {
    const big = "A" ** 100_000;
    try expectOne(">a\n" ++ big ++ "\n", .{}, "a", "", big);
}

test "FA-R15: bare and whitespace-only headers give empty id and desc" {
    try expectOne(">\nACGT\n", .{}, "", "", "ACGT");
    try expectOne(">   \nACGT\n", .{}, "", "", "ACGT");
    try expectOne(">\t \nACGT\n", .{}, "", "", "ACGT");
}

test "FA-R15: leading whitespace after > is skipped" {
    try expectOne("> foo bar\nAC\n", .{}, "foo", "bar", "AC");
    try expectOne(">\t foo\nAC\n", .{}, "foo", "", "AC");
}

test "FA-R15: only space and tab count as whitespace" {
    // Form feed is part of the id, not a delimiter.
    try expectOne(">a\x0cb c\nAC\n", .{}, "a\x0cb", "c", "AC");
}

test "FA-R17: whitespace run between id and desc is skipped" {
    try expectOne(">foo   bar\nAC\n", .{}, "foo", "bar", "AC");
    try expectOne(">foo \t bar baz\nAC\n", .{}, "foo", "bar baz", "AC");
}

test "FA-R17: trailing whitespace in desc is preserved" {
    try expectOne(">foo bar  \nAC\n", .{}, "foo", "bar  ", "AC");
    try expectOne(">foo bar  \r\nAC\r\n", .{}, "foo", "bar  ", "AC");
}

test "FA-R17: only whitespace after id gives empty desc" {
    try expectOne(">foo  \nAC\n", .{}, "foo", "", "AC");
}

test "FA-R18: errors are terminal" {
    var reader: Reader = .fixed(">a\nAAAAAAAA\n>b\nCC\n");
    var p = Parser.init(testing.allocator, &reader, .{ .max_record_size = 4 });
    defer p.deinit();
    try testing.expectError(error.RecordTooLarge, p.next());
    const line = p.line;
    try testing.expectError(error.RecordTooLarge, p.next());
    try testing.expectError(error.RecordTooLarge, p.next());
    try testing.expectEqual(line, p.line);
}

test "FA-R19: spaces and tabs are removed from sequence lines" {
    try expectOne(">s\nAC GT\n\tTT  \nG \r\n", .{}, "s", "", "ACGTTTG");
}

test "FA-R19: interleaved spaces and tabs on a long line" {
    const unit = "ACGT \tAC\tGT  A\t\tC ";
    const want = "ACGTACGTAC";
    try expectOne(">s\n" ++ unit ** 50 ++ "\n", .{}, "s", "", want ** 50);
}

// FA-R16 (openFile(allocator, io, path, options)) is implemented and tested
// after the core parser.

test "property: line width never changes parsed seq" {
    const seq = "ACGTNacgtn" ** 13;
    var width: usize = 1;
    while (width <= seq.len + 1) : (width += 7) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        try buf.appendSlice(testing.allocator, ">s\n");
        var i: usize = 0;
        while (i < seq.len) : (i += width) {
            try buf.appendSlice(testing.allocator, seq[i..@min(i + width, seq.len)]);
            try buf.append(testing.allocator, '\n');
        }
        try expectOne(buf.items, .{}, "s", "", seq);
    }
}
