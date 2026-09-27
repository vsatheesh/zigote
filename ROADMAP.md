# ZIGote roadmap

Order of work and progress. Each feature follows the workflow in
[specs/README.md](specs/README.md): spec, then failing tests, then code, then review.

## Done
- [x] FASTA parser (`zigote.fasta`, spec 001)
- [x] Single-pass sequence scan
- [x] Benchmarks against other parsers (`bench/`)

## 0. Warm-ups: packaging and docs
- [x] 0a. LICENSE and README in `build.zig.zon` `.paths`
- [x] 0b. Spec 001: bare `\r` line endings as a known limitation
- [x] 0c. Working agreement recorded (local `AGENTS.md`)
- [x] Merge `housekeeping` into `main`

## 1. CI
- [x] GitHub Actions workflow with Zig pinned to 0.16.0
- [x] `zig build test` in Debug and ReleaseFast
- [x] Linux and macOS

## 1b. Parser warm-ups (after CI)
- [ ] Simplify `OwnedRecord.deinit`
- [ ] Handle or document a zero-size reader buffer

## 1c. Release binaries
- [ ] Spec for the `zigote` command-line tool (commands, output format)
- [ ] Release workflow: build Linux (musl), macOS and Windows on version tags
- [ ] Attach binaries to GitHub Releases

## 2. `openFile` (FA-R16)
- [ ] Spec: who owns the file, buffer, reader and parser; whether the object may move; cleanup on failure
- [ ] Tests: same output as the reader-based parser, missing file, allocation failures, deinit after a parse error
- [ ] Implementation

## 3. Gzip (spec 003)
- [ ] Verify Zig 0.16.0 `flate.Decompress` behavior with tests: multi-member files, CRC checking, truncated input
- [ ] Spec: detection, multi-member (BGZF), checksums, truncation, trailing garbage
- [ ] Tests, including a record that crosses a member boundary
- [ ] Implementation as a reader-to-reader layer, reusable by FASTQ
- [ ] Benchmark `.fa.gz` against kseq and needletail

## 4. FASTQ (spec 002)
- [ ] Spec: four-line records only, `+` line rule, quality kept as raw bytes, explicit Phred+33/+64 decoding
- [ ] Tests
- [ ] Implementation

## 5. `zigote.seq` (spec 004)
- [ ] Alphabet validation
- [ ] Reverse complement

## Later
- [ ] k-mers
- [ ] Translation
