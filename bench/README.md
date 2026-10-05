# Benchmarks

Compares `zigote stats --parse-only` with other FASTA parsers in C, Rust, Go and Python.

## What each command does

Each parser reads the whole file and reports the record count and total residues. Every parser except `seq_io-lines` builds each sequence as one contiguous run of bytes without line breaks, as zigote does. `run.sh` checks that all of them report identical counts before timing.

| Name | Language | What runs |
|---|---|---|
| zigote | Zig | `zig-out/bin/zigote stats --parse-only FILE` |
| kseq | C | `kseq/count.c`: `kseq_read` loop, reading through zlib `gzread` as seqtk and most kseq users do |
| kseq-read | C | the same program built with `-DPLAIN_READ`, reading with `read(2)` and skipping zlib's extra copy |
| seqtk | C (kseq) | `seqtk size FILE` |
| needletail | Rust | `rust-parsers`: `parse_fastx_file`, `record.seq()` |
| seq_io | Rust | `rust-parsers`: `fasta::Reader`, `record.full_seq()` |
| seq_io-lines | Rust | `rust-parsers`: sums `record.seq_lines()` lengths without joining them. A zero-copy reference point, not like-for-like |
| paraseq | Rust | `rust-parsers`: single-threaded `fasta::Reader` with record sets, `record.seq()` |
| noodles | Rust | `rust-parsers`: `noodles_fasta::io::Reader`, `read_definition` and `read_sequence` into reused buffers |
| rust-bio | Rust | `rust-parsers`: `bio::io::fasta::Reader::read` into a reused `Record` |
| seqkit | Go | `seqkit stats FILE`; computes a few more statistics |
| cat-floor | | `cat FILE`: not a parser, the cost of reading the file at all |
| pyfastx, needletail-py, biopython | Python | `pyfastx_count.py` (`pyfastx.Fastx`, no index), `needletail_py.py`, `biopython_count.py` (`SimpleFastaParser`) |
| python-startup | Python | `python -c pass` |
| samtools-faidx | C (htslib) | `samtools faidx FILE`: builds a `.fai` index rather than reading records in order, so it is timed separately. Its index agrees on the counts. |

Test files must not contain spaces or tabs inside sequences: zigote removes them (FA-R19), and the other parsers count them as residues.

## Running

Needs Zig 0.16, Rust 1.89 or newer (paraseq and rust-bio need it), a C compiler with zlib, hyperfine, seqkit, samtools, and a Python environment with `needletail`, `biopython`, `pyfastx` and `seqtk`.

```sh
PYTHON=/path/to/env/bin/python3 bench/run.sh [extra.fa ...]
```

Synthetic data goes to `bench/data/` (seeded, so it is the same on every run). Tables go to `bench/results/`, as `NAME-native`, `NAME-python` and `NAME-faidx`.

| Dataset | Size | Records | Shape |
|---|---|---|---|
| `long.fa` | 100 MB | 200 | 1 kb to 1 Mb, 60-column lines, some lowercase and N |
| `short.fa` | 175 MB | 1,000,000 | 150 bp each |
| `TAIR10_genome.fa` | 122 MB | 7 | Arabidopsis genome, 154 kb to 30 Mb per record |

### Getting TAIR10

TAIR10 is not in the repo (it is over GitHub's 100 MB file limit). Download the *Arabidopsis thaliana* TAIR10 whole-genome DNA FASTA from Ensembl Plants (`Arabidopsis_thaliana.TAIR10.dna.toplevel.fa.gz`), decompress it, and save it as `TAIR10_genome.fa` in the repo root. Check it before benchmarking: it should have 7 records (`1` to `5`, `Mt`, `Pt`) and 119,667,750 bp, the longest record being 30,427,671 bp. Pass it to the run script as an extra file:

```sh
PYTHON=/path/to/env/bin/python3 bench/run.sh TAIR10_genome.fa
```

## Results (2026-09-25)

Apple M3 Max, 96 GB, macOS 26.2. hyperfine 1.20.0 with `-N --warmup 3 --runs 30` for every command.

Versions:
- zigote with the single-pass sequence scan, after `f86282e` (Zig 0.16.0, ReleaseFast)
- kseq.h from klib master, built with Apple clang `-O3`
- seqtk 1.5-r133, seqkit 2.9.0, samtools 1.20
- Rust 1.98.1, release profile with LTO: needletail 0.7.3, seq_io 0.3.4, paraseq 0.6.0 (no compression features), noodles-fasta 0.58.0, bio 4.0.1
- Python 3.13.15: needletail 0.7.3, Biopython 1.88, pyfastx 2.3.1

### Native parsers

Mean wall time ± σ, sorted by the TAIR10 column:

| Parser | long.fa | short.fa | TAIR10 |
|---|---|---|---|
| cat-floor (no parsing) | 10.0 ± 0.9 ms | 14.8 ± 0.7 ms | 10.5 ± 0.7 ms |
| **zigote** | **28.2 ± 1.3 ms** | **68.2 ± 1.1 ms** | **35.9 ± 1.0 ms** |
| seq_io-lines (no joining) | 21.5 ± 0.7 ms | 46.8 ± 2.4 ms | 39.4 ± 1.5 ms |
| kseq-read | 32.8 ± 1.0 ms | 84.5 ± 4.4 ms | 42.6 ± 1.6 ms |
| kseq | 34.4 ± 1.5 ms | 86.1 ± 3.5 ms | 44.3 ± 1.2 ms |
| paraseq | 39.6 ± 0.9 ms | 78.7 ± 2.3 ms | 50.7 ± 1.9 ms |
| seqtk | 34.8 ± 1.4 ms | 85.2 ± 1.5 ms | 50.7 ± 14.1 ms (outliers) |
| seqkit | 43.2 ± 1.6 ms | 93.5 ± 1.4 ms | 56.5 ± 3.0 ms |
| seq_io | 31.2 ± 0.7 ms | 125.9 ± 3.2 ms | 59.8 ± 1.2 ms |
| needletail | 34.9 ± 0.5 ms | 70.5 ± 1.2 ms | 60.2 ± 2.7 ms |
| rust-bio | 67.6 ± 2.0 ms | 177.6 ± 2.5 ms | 81.4 ± 1.3 ms |
| noodles | 156.0 ± 2.8 ms | 106.0 ± 3.3 ms | 193.3 ± 2.7 ms |

- **zigote is the fastest parser that builds contiguous sequences on all three files.**
  - long.fa: 1.11× ahead of the next, seq_io.
  - short.fa: 1.03× ahead of needletail. The gap is 2.3 ms, about two standard deviations, so treat that one as close to a tie.
  - TAIR10: 1.19× ahead of kseq-read.
- **seq_io-lines is faster on the synthetic files because it never copies the sequence into one buffer.** That shows what the copy costs, but it doesn't give callers a single contiguous sequence.
- **zigote runs at 2.8 to 4.6× the time of just reading the file** (cat-floor).
- **seqtk on TAIR10 had outliers** (σ 27.7%, one run at 121.4 ms). Its median of 47.1 ms is close to kseq's 43.9 ms, as expected, since seqtk uses kseq.
- **None of these used more than one thread.** paraseq's high wall time comes from operating-system time (21.5 to 27.6 ms), not from CPU time spread across threads.

### Python parsers

| Parser | long.fa | short.fa | TAIR10 |
|---|---|---|---|
| python-startup | 8.7 ms | 10.8 ms | 9.8 ms |
| pyfastx | 47.6 ± 1.3 ms | 205.1 ± 9.4 ms | 65.0 ± 2.2 ms |
| needletail-py | 81.2 ± 2.0 ms | 311.3 ± 8.8 ms | 115.4 ± 3.8 ms |
| biopython | 323.7 ± 26.5 ms | 739.2 ± 10.3 ms | 381.3 ± 7.5 ms |

### samtools faidx (index build, different work)

208.4 ms (long.fa), 648.1 ms (short.fa), 248.7 ms (TAIR10).

### Peak memory (max RSS, largest of 3 runs)

| Parser | long.fa | short.fa | TAIR10 |
|---|---|---|---|
| cat (reference) | 1.4 MB | 1.4 MB | 1.4 MB |
| **zigote** | **2.6 MB** | **1.6 MB** | **32.6 MB** |
| kseq | 2.4 MB | 1.4 MB | 32.5 MB |
| kseq-read | 2.3 MB | 1.3 MB | 32.4 MB |
| noodles | 2.6 MB | 1.5 MB | 32.7 MB |
| rust-bio | 2.6 MB | 1.6 MB | 32.6 MB |
| seqtk | 2.7 MB | 1.6 MB | 38.7 MB |
| seq_io-lines | 2.9 MB | 1.6 MB | 56.9 MB |
| needletail | 4.0 MB | 1.7 MB | 86.3 MB |
| seq_io | 5.0 MB | 1.7 MB | 170.7 MB |
| paraseq | 99.8 MB | 1.8 MB | 148.7 MB |
| seqkit | 32.3 MB | 31.1 MB | 161.4 MB |
| python-startup (reference) | 9.5 MB | 9.3 MB | 9.3 MB |
| pyfastx | 19.2 MB | 10.7 MB | 104.6 MB |
| needletail-py | 28.8 MB | 9.9 MB | 166.2 MB |
| biopython | 59.5 MB | 46.7 MB | 159.5 MB |

Memory follows the longest record, not the file size: every file is 100 to 175 MB.
- **short.fa (150 bp records):** almost every native parser needs under 2 MB. seqkit needs about 31 MB on every file, which looks like a fixed cost of its runtime and buffers rather than of the data.
- **long.fa (longest record about 1 Mb):** most parsers stay under 5 MB. paraseq needs 99.8 MB, and Biopython 59.5 MB.
- **TAIR10 (longest record 30.4 Mb):** about 32 MB is the minimum for keeping a whole record as one contiguous sequence. zigote, kseq, noodles and rust-bio sit at that minimum. Others need 2.5 to 5 times more. For needletail the cause is known, two copies of each record (see below); the others were not investigated.

## History: the single-pass sequence scan

At `f86282e`, zigote was slower than needletail on the synthetic files and level on TAIR10:

| Dataset | zigote at `f86282e` | needletail | zigote after the fix |
|---|---|---|---|
| long.fa | 44.7 ms (36.3 program CPU) | 34.7 ms | 28.5 ms (19.4) |
| short.fa | 99.1 ms (85.1) | 74.9 ms | 66.6 ms (52.7) |
| TAIR10 | 56.7 ms (44.2) | 57.8 ms | 37.4 ms (24.4) |

The extra program CPU time was steady per line (5.2 to 6.1 ns per line across the three files, against a 1.6× spread per byte). A profile with macOS `sample` (1 ms intervals, ReleaseFast, 20 copies of each synthetic file from stdin) showed where it went:

| Source at `f86282e` | short.fa (1,635 samples) | long.fa (568 samples) |
|---|---|---|
| Space and tab searches (two `findScalarPos` calls per line) | 35% | 42% |
| Copying sequence bytes (`memmove`) | 21% | 29% |
| Newline search (`lineChunk`) | 13% | 16% |
| Reading the file (`readv`) | 7% | 9% |
| Header and record handling (`next`) | about 23% | about 3% |

The fix, `findSequenceBreak` in `src/fasta.zig`, replaces all three searches on sequence lines with one pass. Each 16-byte block is first checked for any byte ≤ 0x20 with one comparison, which skips almost all residue data. A block that passes is then matched exactly against newline, space and tab. Other bytes below 0x20 (NUL, vertical tab, form feed, a `\r` in mid-line) are ordinary data under FA-R7, so they must not be treated as breaks. A test (`FA-R7: other bytes below 0x20 pass through in sequence`) guards this, and it fails against the naive "≤ 0x20 is whitespace" version.

Program CPU time fell by 38 to 47%, a little more than the 35 to 42% the whitespace searches accounted for, because the separate newline search is gone too.

## Why needletail uses more memory

needletail 0.7.3 holds two copies of each large record:

- its read buffer holds the raw record with newlines, growing by doubling up to 8 MiB and then in 8 MiB steps (`src/parser/utils.rs:24`)
- `seq()` allocates a second, newline-free copy (`src/parser/fasta.rs:66–95`)

zigote strips newlines while reading, so it keeps one copy and reuses its buffer across records. The fresh large allocation per record may also explain needletail's higher operating-system time on TAIR10 (21.5 vs 11.3 ms); that part is a hypothesis.

## Caveats

- Single machine, warm page cache.
- needletail and seqkit keep spaces in sequences and zigote removes them (FA-R19). zigote still checks for them on every line, and is faster anyway.
- The Python bindings copy every sequence into a Python string; per-record cost dominates on short.fa.
- Each parser is used through its fastest normal API for this task, as far as its documentation shows. A parser's authors may know a faster way.
