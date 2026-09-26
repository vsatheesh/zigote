# ZIGote

A bioinformatics library for Zig.

ZIGote is intended to provide practical tools for working with biological sequence data, beginning with FASTA and FASTQ parsers and growing alongside research needs.

The project is named after the zygote—the first cell from which an organism grows—with **ZIG** highlighted to reflect the implementation language. The package and import name is always lowercase: `zigote`.

## Status

ZIGote is in its initial development stage. Its API is not yet stable.

## Try it

Requires Zig 0.16.0.

```sh
zig build test                          # run the test suite
zig build -Doptimize=ReleaseFast        # build the smoke-test tool
./zig-out/bin/zigote genome.fa          # summarize a FASTA file
gunzip -c genome.fa.gz | ./zig-out/bin/zigote -   # gzip is not built in yet
```

Behavior is defined in [`specs/`](specs/).

## Planned modules

- `zigote.fasta`
- `zigote.fastq`
- `zigote.seq`

## License

[MIT](LICENSE) © 2026 VSatheesh
