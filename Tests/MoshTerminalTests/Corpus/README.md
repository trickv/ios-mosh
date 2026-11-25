Golden corpus for the terminal model. Written by Tools/mosh-oracle (see its FORMAT.md
for the exact format of every file and its README.md for the list of cases).
Loaded by tests relative to #filePath.

Each directory is one case:

- `meta.json`: format version, first window size
- `session.jsonl`: what the program wrote to the pty, one `read()` per line, and resizes
- `instructions.jsonl`: the instructions a mosh server sent for it (`old_num`, `new_num`, diff)
- `expected.jsonl`: the client's complete state after each instruction, from mosh's own emulator
- `server.jsonl`: the server's complete state after each session line

`rec-*` cases are recordings of real programs, `syn-*` cases are hand-written
(`Tools/mosh-oracle/synthetic.py`). Do not edit the files by hand:

    scripts/corpus-check.sh           # the oracle reproduces expected.jsonl and server.jsonl
    scripts/corpus-check.sh --gen     # and gen reproduces every generated file
    scripts/corpus-check.sh --regen   # write them again after a change to the oracle
    scripts/record-golden.sh NAME     # record a rec-* case again
