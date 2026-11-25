#!/usr/bin/env bash
# Checks a moshcli --seq-log file: every client-to-server sequence number is above the one
# before it, so none appears twice (N1 in docs/PLAN.md section 3). The file may span several
# process generations of one session (one key): each then starts above the last of the one
# before.
#
# If FILE.numbers is there (moshcli writes it beside FILE: every number taken from the
# durability gate, as "seq N", "state N" or "frag N"), it is checked too: each kind only goes up
# (N1, N2, N4), and every sequence number on the wire was taken from the gate.
#   scripts/check-seq-log.sh FILE
set -euo pipefail
file="${1:?usage: check-seq-log.sh FILE}"
[ -s "$file" ] || { echo "seq log $file is missing or empty" >&2; exit 1; }
awk '
  !/^[0-9]+$/ { printf "line %d is not a number: %s\n", NR, $0; bad = 1; exit }
  NR > 1 && $1 + 0 <= prev { printf "line %d: %s after %s\n", NR, $1, prev; bad = 1; exit }
  { prev = $1 + 0 }
  END {
    if (bad) exit 1
    printf "seq log: %d numbers, strictly increasing, last %s\n", NR, prev
  }
' "$file"
[ -e "$file.numbers" ] || exit 0
awk -v wire="$file" '
  BEGIN { while ((getline line < wire) > 0) onwire[line] = 1 }
  $1 != "seq" && $1 != "state" && $1 != "frag" || $2 !~ /^[0-9]+$/ || NF != 2 {
    printf "numbers log line %d is not seq|state|frag N: %s\n", NR, $0; bad = 1; exit
  }
  ($1 in last) && $2 + 0 <= last[$1] { printf "numbers log line %d: %s %s after %s\n", NR, $1, $2, last[$1]; bad = 1; exit }
  { last[$1] = $2 + 0; count[$1]++ }
  $1 == "seq" { taken[$2] = 1 }
  END {
    if (bad) exit 1
    for (number in onwire) if (!(number in taken)) { printf "sequence number %s is on the wire but was not taken from the gate\n", number; exit 1 }
    printf "numbers log: %d sequence numbers, %d state numbers, %d fragment ids taken, each kind strictly increasing\n", count["seq"], count["state"], count["frag"]
  }
' "$file.numbers"
