"""Count records and residues with Biopython's SimpleFastaParser."""
import sys

from Bio.SeqIO.FastaIO import SimpleFastaParser

records = 0
residues = 0
with open(sys.argv[1]) as handle:
    for _title, seq in SimpleFastaParser(handle):
        records += 1
        residues += len(seq)
print(records, residues)
