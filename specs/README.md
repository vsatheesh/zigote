# ZIGote specs

Spec-driven development: behavior is written down and agreed **before** code.

## Workflow

1. **Spec** (`specs/NNN-name.md`): what the module does, its API surface, and testable requirements. Status starts as `Draft`.
2. **Resolve open questions**: each one gets a decision recorded in the spec. The spec becomes `Accepted`.
3. **Tests first**: every requirement ID (e.g. `FA-R3`) maps to at least one Zig `test` block, named or commented with that ID.
4. **Implement** until the tests pass.
5. **Change behavior by changing the spec first.** Mark `Implemented` when done.

## Index

| Spec | Status |
|------|--------|
| [000-principles](000-principles.md) | Draft |
| [001-fasta](001-fasta.md) | Accepted |

Planned: 002-fastq, 003-gzip, 004-seq (owns alphabet validation, operating on slices from the parsers).
