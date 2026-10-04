//! `zigote`: command-line tool. Behavior is defined in specs/005-cli.md.
//!
//! Usage: zigote stats [--parse-only] [FILE]   summarize a FASTA file (FILE omitted or `-`: stdin)
//!        zigote --help | -h
//!        zigote --version | -v
const std = @import("std");
const Io = std.Io;

const zigote = @import("zigote");
const build_options = @import("build_options");

const usage =
    \\usage: zigote stats [--parse-only] [FILE]
    \\       zigote --help | -h
    \\       zigote --version | -v
    \\
    \\Commands:
    \\  stats           summarize a FASTA file; FILE omitted or - reads standard input
    \\
    \\Options for stats:
    \\  --parse-only    report only record and residue counts
    \\
    \\Gzip is not built in yet: gunzip -c genome.fa.gz | zigote stats
    \\
;

const Command = union(enum) {
    help,
    version,
    stats: struct { path: []const u8 = "-", parse_only: bool = false },
};

const UsageError = struct { message: []const u8, arg: []const u8 = "" };

/// Parses the arguments after the program name (CL-R1, CL-R2).
fn parseArgs(args: []const []const u8) union(enum) { ok: Command, err: UsageError } {
    if (args.len == 0) return .{ .err = .{ .message = "missing command" } };
    const first = args[0];
    if (isAny(first, &.{ "--help", "-h" })) return if (args.len == 1) .{ .ok = .help } else .{ .err = .{ .message = "unexpected argument", .arg = args[1] } };
    if (isAny(first, &.{ "--version", "-v" })) return if (args.len == 1) .{ .ok = .version } else .{ .err = .{ .message = "unexpected argument", .arg = args[1] } };
    if (!std.mem.eql(u8, first, "stats")) {
        return .{ .err = .{ .message = if (first.len > 0 and first[0] == '-') "unknown option" else "unknown command", .arg = first } };
    }

    var stats: @FieldType(Command, "stats") = .{};
    var have_path = false;
    for (args[1..]) |arg| {
        if (isAny(arg, &.{ "--help", "-h" })) return .{ .ok = .help };
        if (std.mem.eql(u8, arg, "--parse-only")) {
            stats.parse_only = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .err = .{ .message = "unknown option", .arg = arg } };
        } else if (have_path) {
            return .{ .err = .{ .message = "only one input is accepted; extra argument", .arg = arg } };
        } else {
            stats.path = arg;
            have_path = true;
        }
    }
    return .{ .ok = .{ .stats = stats } };
}

fn isAny(arg: []const u8, names: []const []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const command = switch (parseArgs(args[1..])) {
        .ok => |command| command,
        .err => |e| {
            if (e.arg.len > 0) {
                std.debug.print("zigote: {s}: {s}\n{s}", .{ e.message, e.arg, usage });
            } else {
                std.debug.print("zigote: {s}\n{s}", .{ e.message, usage });
            }
            std.process.exit(2);
        },
    };
    switch (command) {
        .help => try out.writeAll(usage),
        .version => try out.print("zigote {s}\n", .{build_options.version}),
        .stats => |opts| try runStats(io, gpa, out, opts.path, opts.parse_only),
    }
    try out.flush();
}

fn runStats(io: Io, gpa: std.mem.Allocator, out: *Io.Writer, path: []const u8, parse_only: bool) !void {
    const from_stdin = std.mem.eql(u8, path, "-");
    const file = if (from_stdin) Io.File.stdin() else Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        std.debug.print("zigote: cannot open {s}: {t}\n", .{ path, err });
        std.process.exit(1);
    };
    defer if (!from_stdin) file.close(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader = if (from_stdin) file.readerStreaming(io, &read_buffer) else file.reader(io, &read_buffer);

    var parser = zigote.fasta.Parser.init(gpa, &file_reader.interface, .{});
    defer parser.deinit();

    if (parse_only) {
        // Kept separate from `Stats` so benchmarks time the parser, not the statistics.
        var records: u64 = 0;
        var residues: u64 = 0;
        while (try nextOrExit(&parser, path)) |rec| {
            records += 1;
            residues += rec.seq.len;
        }
        try out.print("records:       {d}\nresidues:      {d}\n", .{ records, residues });
        return;
    }

    var stats: Stats = .{};
    defer stats.deinit(gpa);
    while (try nextOrExit(&parser, path)) |rec| try stats.add(gpa, rec);
    try stats.write(out, path);
}

/// Returns the next record. On a parse or read error, reports it and exits 1 (CL-R7).
fn nextOrExit(parser: *zigote.fasta.Parser, path: []const u8) !?zigote.fasta.Record {
    return parser.next() catch |err| {
        std.debug.print("zigote: {s}: line {d}: {t}\n", .{ path, parser.line, err });
        std.process.exit(1);
    };
}

/// Statistics over a whole file (CL-R3 to CL-R5).
const Stats = struct {
    lengths: std.ArrayList(u64) = .empty,
    counts: [256]u64 = @splat(0),
    empty_ids: u64 = 0,

    fn deinit(self: *Stats, gpa: std.mem.Allocator) void {
        self.lengths.deinit(gpa);
    }

    fn add(self: *Stats, gpa: std.mem.Allocator, rec: zigote.fasta.Record) !void {
        try self.lengths.append(gpa, rec.seq.len);
        for (rec.seq) |c| self.counts[c] += 1;
        if (rec.id.len == 0) self.empty_ids += 1;
    }

    /// Sorts the stored lengths, then writes the report.
    fn write(self: *Stats, out: *Io.Writer, path: []const u8) !void {
        const lengths = self.lengths.items;
        const total = sum(lengths);
        try out.print("file:          {s}\n", .{path});
        try out.print("records:       {d}\n", .{lengths.len});
        try out.print("residues:      {d}\n", .{total});
        if (lengths.len > 0) {
            std.mem.sort(u64, lengths, {}, std.sort.desc(u64));
            try out.print("longest:       {d}\n", .{lengths[0]});
            try out.print("shortest:      {d}\n", .{lengths[lengths.len - 1]});
            try out.print("N50:           {d}\n", .{n50(lengths, total)});
        }
        const c = &self.counts;
        const gc = c['G'] + c['C'] + c['g'] + c['c'];
        const at = c['A'] + c['T'] + c['a'] + c['t'];
        var lower: u64 = 0;
        for ('a'..'z' + 1) |i| lower += c[i];
        if (gc + at > 0) try out.print("GC%:           {d:.2}\n", .{pct(gc, gc + at)});
        try out.print("N:             {d}\n", .{c['N'] + c['n']});
        try out.print("lowercase:     {d} ({d:.2}%)\n", .{ lower, pct(lower, total) });
        try out.print("empty ids:     {d}\n", .{self.empty_ids});
    }
};

fn sum(xs: []const u64) u64 {
    var t: u64 = 0;
    for (xs) |x| t += x;
    return t;
}

/// `lengths` must be sorted in descending order.
fn n50(lengths: []const u64, total: u64) u64 {
    var acc: u64 = 0;
    for (lengths) |len| {
        acc += len;
        if (acc * 2 >= total) return len;
    }
    return 0;
}

fn pct(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectCommand(args: []const []const u8, want: Command) !void {
    switch (parseArgs(args)) {
        .ok => |got| try testing.expectEqualDeep(want, got),
        .err => |e| {
            std.debug.print("unexpected usage error: {s} {s}\n", .{ e.message, e.arg });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectUsageError(args: []const []const u8) !void {
    try testing.expect(parseArgs(args) == .err);
}

test "CL-R1: help and version" {
    try expectCommand(&.{"--help"}, .help);
    try expectCommand(&.{"-h"}, .help);
    try expectCommand(&.{ "stats", "--help" }, .help);
    try expectCommand(&.{"--version"}, .version);
    try expectCommand(&.{"-v"}, .version);
}

test "CL-R1: usage errors" {
    try expectUsageError(&.{});
    try expectUsageError(&.{"genome.fa"});
    try expectUsageError(&.{"--parse-only"});
    try expectUsageError(&.{"--bogus"});
    try expectUsageError(&.{ "--version", "x" });
    try expectUsageError(&.{ "stats", "--bogus" });
}

test "CL-R2: stats input is a path, - or omitted" {
    try expectCommand(&.{"stats"}, .{ .stats = .{ .path = "-" } });
    try expectCommand(&.{ "stats", "-" }, .{ .stats = .{ .path = "-" } });
    try expectCommand(&.{ "stats", "a.fa" }, .{ .stats = .{ .path = "a.fa" } });
    try expectCommand(&.{ "stats", "--parse-only", "a.fa" }, .{ .stats = .{ .path = "a.fa", .parse_only = true } });
    try expectCommand(&.{ "stats", "a.fa", "--parse-only" }, .{ .stats = .{ .path = "a.fa", .parse_only = true } });
}

test "CL-R2: only one input" {
    try expectUsageError(&.{ "stats", "a.fa", "b.fa" });
    try expectUsageError(&.{ "stats", "-", "a.fa" });
}

fn expectReport(input: []const u8, want: []const u8) !void {
    var reader: Io.Reader = .fixed(input);
    var parser = zigote.fasta.Parser.init(testing.allocator, &reader, .{});
    defer parser.deinit();
    var stats: Stats = .{};
    defer stats.deinit(testing.allocator);
    while (try parser.next()) |rec| try stats.add(testing.allocator, rec);
    var buf: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&buf);
    try stats.write(&out, "x.fa");
    try testing.expectEqualStrings(want, out.buffered());
}

test "CL-R3, CL-R4: stats report" {
    try expectReport(">a desc\nACGT\n>b\nNNac\n>\nGGGGCC\n",
        \\file:          x.fa
        \\records:       3
        \\residues:      14
        \\longest:       6
        \\shortest:      4
        \\N50:           4
        \\GC%:           75.00
        \\N:             2
        \\lowercase:     2 (14.29%)
        \\empty ids:     1
        \\
    );
}

test "CL-R5: empty input omits length lines and GC%" {
    try expectReport("",
        \\file:          x.fa
        \\records:       0
        \\residues:      0
        \\N:             0
        \\lowercase:     0 (0.00%)
        \\empty ids:     0
        \\
    );
}

test "CL-R5: GC% omitted without A, C, G or T" {
    try expectReport(">a\nNNNN\n",
        \\file:          x.fa
        \\records:       1
        \\residues:      4
        \\longest:       4
        \\shortest:      4
        \\N50:           4
        \\N:             4
        \\lowercase:     0 (0.00%)
        \\empty ids:     0
        \\
    );
}

test "CL-R4: N50" {
    try testing.expectEqual(@as(u64, 4), n50(&.{ 5, 4, 3, 2, 1 }, 15));
    try testing.expectEqual(@as(u64, 10), n50(&.{10}, 10));
    try testing.expectEqual(@as(u64, 0), n50(&.{ 0, 0 }, 0));
}
