# 000 Principles

Status: Draft. Applies to every module.

## Decisions

- **P1 Streaming first.** Parsers read from a `std.Io.Reader` and never require the whole file in memory.
- **P2 Borrowed records.** A yielded record's slices point into a parser-owned buffer and are valid only until the next call to `next()`. Callers who need to keep data call `record.dupe(allocator)` with their own allocator.
- **P3 Allocation-conscious.** The hot path performs no allocation after init. The allocator is passed explicitly; no global state. Record size is unbounded by default; parsers accept an optional `max_record_size` for untrusted input.
- **P4 Explicit errors.** Malformed input returns a typed error with line/offset info, never panics or is silently skipped. Empty-but-well-formed constructs, such as a bare `>`, are accepted.
- **P5 Real-world input.** CRLF, missing final newline, empty records, lowercase/soft-masked bases and IUPAC codes are handled or explicitly rejected per spec.
- **P6 Pinned toolchain.** `minimum_zig_version` in `build.zig.zon` is 0.16.0; CI tests against it.
- **P7 Import name** is always lowercase `zigote`.

## Non-goals (for now)

Alignment, SAM/BAM/CRAM, variant formats, multithreaded parsing.
