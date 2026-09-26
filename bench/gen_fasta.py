"""Write seeded synthetic FASTA files for benchmarking.

usage: gen_fasta.py long <out.fa>    200 records, 1 kb to 1 Mb, about 100 MB
       gen_fasta.py short <out.fa>   1,000,000 records of 150 bp, about 170 MB
"""
import random
import sys

WIDTH = 60


def write_record(f, name, seq):
    f.write(f">{name} synthetic\n")
    for i in range(0, len(seq), WIDTH):
        f.write(seq[i : i + WIDTH])
        f.write("\n")


def main():
    kind, out = sys.argv[1], sys.argv[2]
    rng = random.Random(1)
    with open(out, "w") as f:
        if kind == "long":
            for i in range(200):
                n = rng.randint(1_000, 1_000_000)
                write_record(f, f"r{i}", "".join(rng.choices("ACGTacgtN", k=n)))
        elif kind == "short":
            pool = "".join(rng.choices("ACGT", k=1_000_000))
            for i in range(1_000_000):
                start = rng.randrange(len(pool) - 150)
                write_record(f, f"read{i}", pool[start : start + 150])
        else:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
