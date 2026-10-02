# 001 FASTA parser

Status: Accepted. Module: `zigote.fasta`.

## Purpose

Iterate over records in a FASTA stream with minimal allocation. This module does structural parsing only: split id, description and sequence. It does not validate residues.

## API sketch

```zig
var parser = zigote.fasta.Parser.init(allocator, reader, .{ .max_record_size = null });
defer parser.deinit();
while (try parser.next()) |rec| {
    // rec.id: []const u8   text after '>' up to first whitespace
    // rec.desc: []const u8 remainder of header line (may be empty)
    // rec.seq: []const u8  residues with line breaks removed
    // Valid only until the next call to parser.next().

    const owned = try rec.dupe(gpa); // keep past next()
    defer owned.deinit(gpa);
}

// Convenience: composes the core API, no separate parse path.
var fp = try zigote.fasta.openFile(allocator, io, path, .{});
defer fp.deinit();
```

`reader` is a `*std.Io.Reader`. It is the only core input type, so a decompressing reader (spec 003) plugs in unchanged.

## Requirements

| ID | Requirement |
|----|-------------|
| FA-R1 | A record starts with a line beginning `>`; header text is split into `id` and `desc` at the first space or tab. |
| FA-R2 | Multi-line sequences are joined into one contiguous `seq` with no line terminators. |
| FA-R3 | Both `\n` and `\r\n` terminators are accepted; `\r` never appears in output. |
| FA-R4 | A missing trailing newline at EOF is accepted. |
| FA-R5 | A header with no sequence lines yields a record with empty `seq`. |
| FA-R6 | Lines that are empty or contain only spaces and tabs are skipped, before the first header and within records. |
| FA-R7 | Sequence bytes other than space and tab are passed through unchanged: case (soft-masking), IUPAC codes, gaps and stop codons are preserved. No validation in v0.1. |
| FA-R8 | A line before the first `>` containing anything other than spaces and tabs returns `error.MissingHeader`. |
| FA-R9 | Empty input yields zero records and no error. |
| FA-R10 | Errors carry the 1-based line number via `parser.line`. |
| FA-R11 | After init, `next()` allocates only when the internal buffer must grow: a record that fits the existing capacity causes no allocation, and a larger one does. |
| FA-R12 | Record slices point into a buffer owned by the parser, not the caller's or the underlying reader's buffer. The buffer is cleared and refilled on each `next()`. Slices are valid until the next `next()` call, and no longer. |
| FA-R13 | `Record.dupe(allocator)` returns an `OwnedRecord` allocated with the caller's allocator. The caller frees it with `OwnedRecord.deinit(allocator)`. The parser never allocates on behalf of `dupe`. |
| FA-R14 | `Options.max_record_size: ?usize = null`. `null` means unbounded. The record size is the header text after `>` (as written, without the terminator) plus the stored `seq` bytes. When set, a larger record returns `error.RecordTooLarge`; a record of exactly `max_record_size` bytes is accepted. Lines before the first header do not count. |
| FA-R15 | "Whitespace" means space and tab only. Leading whitespace after `>` is skipped. A bare `>` or a header that is only whitespace after `>` yields empty `id` and empty `desc`, not an error. `> foo bar` yields id `foo`, desc `bar`. |
| FA-R16 | `openFile(allocator, io, path, options)` takes a `std.Io` instance, as file opening does in Zig 0.16. It only opens the file, wraps it in a buffered reader and constructs the core `Parser`. Implemented after the core parser. Behavior must be identical to the reader-based core. |
| FA-R17 | The whole run of whitespace between `id` and `desc` is skipped, so `>foo   bar` yields desc `bar`. Trailing whitespace on the header line is preserved verbatim in `desc` (`>foo bar  ` yields `bar  `), except for the line terminator (FA-R3). If only whitespace follows the id, `desc` is empty. |
| FA-R18 | Errors are terminal. After `next()` returns an error, every later call returns the same error without reading further. |
| FA-R19 | Spaces and tabs inside sequence lines are removed from `seq`, including trailing ones (`AC GT  ` contributes `ACGT`). |
| FA-R20 | A streaming reader passed to `Parser.init` must have a buffer of at least 1 byte. zigote doesn't check this itself, and `std.Io.Reader` asserts it in safe builds when it fills. A fixed reader over an empty slice is valid (FA-R9). This is a programmer error rather than an input error. |

## Decisions

1. **Borrowed records** (FA-R12, FA-R13). Multi-line records need a contiguous buffer, so the parser owns a growable one. This is borrowed from the caller's perspective.
2. **Record size** (FA-R14). The default is unbounded because chromosome-scale records are legitimate. Docs must tell users parsing untrusted input to set `max_record_size`.
3. **No alphabet validation in v0.1** (FA-R7). Validation belongs in `zigote.seq` (spec 004) and operates on the slices this module returns.
4. **Reader type** (FA-R16). `*std.Io.Reader` is the real API; the path helper is sugar.
5. **Empty headers** (FA-R15, FA-R17). Permissive by default. A future opt-in `strict: bool` option is out of scope for v0.1.
6. **Errors are terminal** (FA-R18). Resynchronizing to the next header is possible later, but v0.1 keeps error behavior simple and predictable.
7. **Whitespace in sequence** (FA-R6, FA-R19). Hand-edited files often carry stray spaces; removing them keeps `seq` usable for downstream tools. Biopython's `SimpleFastaParser` is believed to remove spaces too (not yet verified).
8. **Document, don't check, a zero-size buffer** (FA-R20). `init` does not assert on the buffer length: a fixed reader over empty input also has a 0-byte buffer and is valid (FA-R9), and `init` cannot tell a fixed reader from a streaming one. It does not return an error either: for a streaming reader the buffer size is fixed in the caller's code, so a zero-size buffer is a bug, not bad input, and `std.Io.Reader` already asserts on it when it fills.

## Known differences from seqkit

Checked against seqkit v2.9.0. Counts match on files without these cases.

- seqkit keeps spaces and tabs in sequences (`GG CC` has length 5); zigote removes them (FA-R19).
- After a bare `>` line, seqkit reads the next line as part of the header (`>\nTT` gives a record named `\nTT` with an empty sequence); zigote gives an empty id and sequence `TT` (FA-R15).

## Test plan

Fixtures are inline byte strings in `src/fasta.zig`, read through `std.Io.Reader.fixed`, until a case needs a real file. Each Zig `test` block names its requirement ID.

- Bare `>`, `>   ` and `> foo bar` (FA-R15).
- `>foo   bar` (multi-space) and `>foo bar  ` (trailing spaces kept), plus `>foo  ` giving empty desc (FA-R17).
- Size limit: record at exactly the limit passes, one byte over fails (FA-R14).
- `dupe` result stays valid after a later `next()`; use `std.testing.allocator` to catch leaks (FA-R13).
- Buffer growth: a later, larger record allocates; a later, smaller one does not (FA-R11).
- Record slices do not point into the reader's buffer (FA-R12).
- `openFile` output equals reader-based output for the same fixtures (FA-R16).
- Streaming: every single-record fixture is also parsed through 1- and 3-byte reader buffers, which splits lines and `\r\n` across reads.
- Errors repeat on later calls (FA-R18); spaces inside and after sequence lines are removed (FA-R19).
- Property test: reformatting a record's line width never changes the parsed `seq`.
- Zero-size buffer (FA-R20): an assert failure would crash the test runner, so it isn't tested. The 1-byte buffer runs in `expectOne` cover the smallest valid buffer. FA-R9 covers the empty fixed reader.

## Known limitations

- What: files with Mac line endings, a bare `\r` with no `\n`.
- What happens: only `\n` ends a line (FA-R3), so the whole file is read as one header line. The result is one record whose id and description contain everything, with an empty sequence and no error.
- Status: not supported in v0.1. A later version could detect it and return an error.

