//! `zigote`: summarize a FASTA file. Used for smoke-testing the parser on real data.
//!
//! Usage: zigote [--parse-only] <file.fa>   read a file
//!        zigote [--parse-only] -           read standard input (e.g. `gunzip -c x.fa.gz | zigote -`)
//!
//! `--parse-only` reports only record and residue counts, so the parser can be
//! timed without the per-residue statistics.
const std = @import("std");
const Io = std.Io;

const zigote = @import("zigote");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const parse_only = args.len == 3 and std.mem.eql(u8, args[1], "--parse-only");
    if (args.len != 2 and !parse_only) {
        std.debug.print("usage: zigote [--parse-only] <file.fa | ->\n", .{});
        std.process.exit(2);
    }
    const path = args[args.len - 1];

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
        var records: u64 = 0;
        var residues: u64 = 0;
        while (true) {
            const rec = parser.next() catch |err| {
                std.debug.print("zigote: {s}: line {d}: {t}\n", .{ path, parser.line, err });
                std.process.exit(1);
            } orelse break;
            records += 1;
            residues += rec.seq.len;
        }
        try out.print("records:       {d}\nresidues:      {d}\n", .{ records, residues });
        try out.flush();
        return;
    }

    var lengths: std.ArrayList(u64) = .empty;
    defer lengths.deinit(gpa);
    var counts = [_]u64{0} ** 256;
    var empty_ids: u64 = 0;
    var first_ids: [3][]u8 = undefined;
    var first_len: usize = 0;
    defer for (first_ids[0..first_len]) |id| gpa.free(id);

    while (true) {
        const rec = parser.next() catch |err| {
            std.debug.print("zigote: {s}: line {d}: {t}\n", .{ path, parser.line, err });
            std.process.exit(1);
        } orelse break;
        try lengths.append(gpa, rec.seq.len);
        for (rec.seq) |c| counts[c] += 1;
        if (rec.id.len == 0) empty_ids += 1;
        if (first_len < first_ids.len) {
            first_ids[first_len] = try gpa.dupe(u8, rec.id);
            first_len += 1;
        }
    }

    const total = sum(lengths.items);
    try out.print("file:          {s}\n", .{path});
    try out.print("records:       {d}\n", .{lengths.items.len});
    try out.print("residues:      {d}\n", .{total});
    if (lengths.items.len > 0) {
        std.mem.sort(u64, lengths.items, {}, std.sort.desc(u64));
        try out.print("longest:       {d}\n", .{lengths.items[0]});
        try out.print("shortest:      {d}\n", .{lengths.items[lengths.items.len - 1]});
        try out.print("N50:           {d}\n", .{n50(lengths.items, total)});
    }
    const gc = counts['G'] + counts['C'] + counts['g'] + counts['c'];
    const at = counts['A'] + counts['T'] + counts['a'] + counts['t'];
    var lower: u64 = 0;
    for ('a'..'z' + 1) |c| lower += counts[c];
    const n = counts['N'] + counts['n'];
    if (gc + at > 0) try out.print("GC%:           {d:.2}\n", .{pct(gc, gc + at)});
    try out.print("N:             {d}\n", .{n});
    try out.print("lowercase:     {d} ({d:.2}%)\n", .{ lower, pct(lower, total) });
    try out.print("empty ids:     {d}\n", .{empty_ids});
    try out.print("first ids:    ", .{});
    for (first_ids[0..first_len]) |id| try out.print(" {s}", .{id});
    try out.print("\nlines read:    {d}\n", .{parser.line});
    try out.flush();
}

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

test "n50" {
    try std.testing.expectEqual(@as(u64, 4), n50(&.{ 5, 4, 3, 2, 1 }, 15));
    try std.testing.expectEqual(@as(u64, 10), n50(&.{10}, 10));
}
