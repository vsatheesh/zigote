"""Count records and residues with pyfastx, iterating without building an index."""
import sys

import pyfastx

records = 0
residues = 0
for _name, seq in pyfastx.Fastx(sys.argv[1]):
    records += 1
    residues += len(seq)
print(records, residues)
