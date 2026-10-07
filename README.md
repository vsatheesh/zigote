# ZIGote

A bioinformatics library for Zig.

ZIGote is intended to provide practical tools for working with biological sequence data, beginning with FASTA and FASTQ parsers and growing alongside research needs.

The project is named after the zygote—the first cell from which an organism grows—with **ZIG** highlighted to reflect the implementation language. The package and import name is always lowercase: `zigote`.

## Status

Version 0.1.0: a streaming FASTA parser (`zigote.fasta`) and a `zigote` command-line tool. The API is not yet stable and may change between 0.x releases. See [benchmarks](bench/README.md) for speed and memory against other FASTA parsers.

## Command-line tool

Download the archive for your system from the [Releases](https://github.com/vsatheesh/zigote/releases) page. It contains a single binary with no dependencies; Zig is not needed.

| System              | Archive                                      |
|---------------------|----------------------------------------------|
| Linux x86-64        | `zigote-vVERSION-x86_64-linux-musl.tar.gz`   |
| Linux ARM64         | `zigote-vVERSION-aarch64-linux-musl.tar.gz`  |
| macOS Apple silicon | `zigote-vVERSION-aarch64-macos.tar.gz`       |
| macOS Intel         | `zigote-vVERSION-x86_64-macos.tar.gz`        |
| Windows x86-64      | `zigote-vVERSION-x86_64-windows.zip`         |

`SHA256SUMS` on the same page lists the checksums (`shasum -a 256 -c SHA256SUMS --ignore-missing`).

On macOS the binary is not signed, so Gatekeeper blocks it the first time. Remove the quarantine flag once:

```sh
xattr -d com.apple.quarantine ./zigote
```

Usage:

```sh
zigote stats genome.fa                    # statistics for a FASTA file
zigote stats --parse-only genome.fa       # record and residue counts only
gunzip -c genome.fa.gz | zigote stats     # gzip is not built in yet; read from stdin
zigote --help
zigote --version
```

Example output, for the Arabidopsis thaliana TAIR10 genome:

```text
file:          TAIR10_genome.fa
records:       7
residues:      119667750
longest:       30427671
shortest:      154478
N50:           23459830
GC%:           36.06
N:             185738
lowercase:     0 (0.00%)
empty ids:     0
```

Exit codes: 0 on success, 1 when the file cannot be opened or parsed (the message on stderr gives the line number), 2 for a usage error. The text output may change before 1.0. The full behavior is in [specs/005-cli.md](specs/005-cli.md).

## Zig library

Requires Zig 0.16.0. Add the dependency:

```sh
zig fetch --save git+https://github.com/vsatheesh/zigote#v0.1.0
```

In `build.zig`:

```zig
const zigote = b.dependency("zigote", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zigote", zigote.module("zigote"));
```

Then parse any `*std.Io.Reader`:

```zig
var file = try std.Io.Dir.cwd().openFile(io, "genome.fa", .{});
defer file.close(io);
var buf: [64 * 1024]u8 = undefined;
var file_reader = file.reader(io, &buf);

var parser = zigote.fasta.Parser.init(gpa, &file_reader.interface, .{});
defer parser.deinit();
while (try parser.next()) |rec| {
    // rec.id, rec.desc, rec.seq are valid until the next call to next().
    // Use rec.dupe(gpa) to keep a record.
}
```

The behavior is defined in [specs/001-fasta.md](specs/001-fasta.md).

## Limitations in 0.1

- No built-in gzip: decompress first, as above.
- No FASTQ.
- Files with old Mac line endings (a bare `\r` and no `\n`) are read as one header line.
- No `openFile` helper yet: open the file and pass its reader, as above.

## Building from source

Requires Zig 0.16.0.

```sh
zig build test                          # run the test suite
zig build -Doptimize=ReleaseFast        # build zig-out/bin/zigote
```

Release binaries are built with `ReleaseSafe`, which keeps safety checks on and is about 15% slower; build with `ReleaseFast` for maximum speed.

## Planned modules

- `zigote.fastq`
- `zigote.seq`

## License

[MIT](LICENSE) © 2026 VSatheesh
