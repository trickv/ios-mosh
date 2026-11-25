# Hostile reviews of MoshTransport (item 3 of docs/CLOUD.md)

Three independent reviews of `Sources/MoshTransport` against the mosh 1.4.0
source, made in cloud round 4 (2026-11-13):

- `review-i.md`: sender timing, retransmission, sent-states list (I-1 .. I-5)
- `review-ii.md`: receiver, fragments, acks, throwaway, guards N1-N4 (II-1 .. II-5)
- `review-iii.md`: export, import, quiesce seams vs PLAN.md section 3 (III-1 .. III-6)

The `Review*Tests.swift` files are the reviewers' scratch tests that reproduce
findings against the code as it was at commit 94e5aae. They are not part of the
package; the fixes add their own tests under `Tests/`. `refutation.md` holds the
second agent's verdict on each finding.
