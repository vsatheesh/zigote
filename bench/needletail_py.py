"""Count records and residues with needletail's Python bindings."""
import sys

import needletail

records = 0
residues = 0
for record in needletail.parse_fastx_file(sys.argv[1]):
    records += 1
    residues += len(record.seq)
print(records, residues)
