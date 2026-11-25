#!/usr/bin/env bash
# A moshcli soak against a real mosh-server under a bad network (docs/PLAN.md, "Verification",
# Network): 20% loss, 200 ms delay with 50 ms jitter and reordering on the loopback device, in
# each direction.
#
#   scripts/netem.sh [minutes] [extra moshcli soak options]
#   scripts/netem.sh 10
#   scripts/netem.sh 3 --rebind-every 20
#   scripts/netem.sh --killloop [kill loop options]   the kill loop instead of the soak
#   scripts/netem.sh --killloop 260 --long            (scripts/killloop.sh; 26 min with loss 20% alone, longer with delay)
#
# Env: NETEM_SPEC replaces the netem parameters (default below); KILLLOOP_KEEP (with --killloop)
# a directory under /work that gets the logs of a failed run.
#
# --killloop runs scripts/killloop.sh as root (its tcpdump capture needs it; it writes nothing to
# .build because MOSHCLI is set here) with --no-guards: the guard tests are swift test, which
# would write .build as root and hangs under loss on lo, and they do not touch the network; the
# plain kill loop runs them. Its two waits are set for a lossy link (the reasons are below).
#
# One scripts/dev.sh --root call: the qdisc lives in that container's network namespace and
# is gone with it (natively it is removed at exit). The soak is scripts/soak.sh: the shell runs
# in tmux and the client's final screen must equal tmux capture-pane -p. Exits non-zero if the
# qdisc cannot be added or the network was not degraded, the soak failed (a marker took more
# than 30 s), the server died, a sequence number was not above the one before it, or the
# screens differ.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${NETEM_INSIDE:-0}" != 1 ]; then
  exec "$ROOT/scripts/dev.sh" --root env NETEM_INSIDE=1 NETEM_SPEC="${NETEM_SPEC:-}" \
    KILLLOOP_KEEP="${KILLLOOP_KEEP:-}" scripts/netem.sh "$@"
fi

# From here on: root in the dev container, in /work (or natively, as root).
KILLLOOP=0
if [ "${1:-}" = --killloop ]; then
  KILLLOOP=1
  shift
else
  MINUTES="${1:-10}"
  [ $# -gt 0 ] && shift
fi
SPEC="${NETEM_SPEC:-loss 20% delay 200ms 50ms reorder 25% 50%}"
# Everything that touches .build runs as the checkout's owner (ubuntu in the dev container).
OWNER="$(stat -c %U .)"
as_user() { if [ "$OWNER" = root ]; then "$@"; else runuser -u "$OWNER" -- "$@"; fi; }

# Build first: with loss on lo, swift build hangs in a build tool that talks over loopback.
as_user swift build -j 4 --product moshcli 2>&1 | tail -n 2
MOSHCLI="$(as_user swift build -j 4 --show-bin-path)/moshcli"
[ -x "$MOSHCLI" ] || { echo "netem: $MOSHCLI was not built" >&2; exit 1; }

# shellcheck disable=SC2086
if ! tc qdisc add dev lo root netem $SPEC; then
  echo "netem: FAIL: cannot add the netem qdisc (no sch_netem kernel module or no NET_ADMIN here)" >&2
  exit 1
fi
trap 'tc qdisc del dev lo root 2>/dev/null || true' EXIT
echo "netem: $(tc qdisc show dev lo | head -n 1)"

# The qdisc applies to each direction, so a ping sees the loss and the delay twice: with the
# default about 36% loss and 300 ms (a reordered packet is not delayed).
PING="$(ping -c 50 -i 0.1 -W 2 127.0.0.1 | tail -n 2)"
echo "netem: ping: $(echo "$PING" | tr '\n' ' ')"
LOSS="$(echo "$PING" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')"
RTT="$(echo "$PING" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')"
if [ -z "${NETEM_SPEC:-}" ]; then
  awk -v loss="$LOSS" -v rtt="$RTT" 'BEGIN { exit !(loss >= 10 && loss <= 70 && rtt >= 150) }' \
    || { echo "netem: the qdisc did not take effect (loss $LOSS%, average round trip $RTT ms)" >&2; exit 1; }
fi

if [ "$KILLLOOP" = 1 ]; then
  # The kill loop's two waits on a lossy link, from mosh-server's sender (.refs/mosh/src):
  # after sending a state, the server assumes the client has it for timeout() + ACK_DELAY
  # (network/transportsender-impl.h:284, update_assumed_receiver_state) and sends again from
  # the last acknowledged state only after that (:108-110; or :114-116, at the same time).
  # timeout() is the RTO, at most MAX_RTO = 1000 ms (network.cc:628, network.h:134), and
  # ACK_DELAY is 100 ms (transportsender.h:55); so the tries of one screen leave the server at
  # most 1100 ms apart, and arrive at most 1350 ms apart with the default spec (a reordered
  # datagram skips the 200 ms + 50 ms delay). The client's sender is a port of the same code
  # (Sources/MoshTransport/TransportCore.swift:475-523).
  # Screens: after wait-ack the loop now waits 7000 ms, more than five such gaps (6750 ms),
  # before its usual 500 ms without a new state; the client's screen can then be taken before
  # the server's last screen arrived only if that screen and its next four tries are all lost:
  # 0.2^5 = 3.2e-4 per comparison at 20% loss, about 4% over the ~130 comparisons of a
  # 260-iteration run. A screen that is wrong, not late, stays wrong however long the wait.
  # (A longer quiet time instead would never come: the server sends an empty ack with a new
  # state number every ACK_INTERVAL = 3000 ms, transportsender-impl.h:212 and :223,
  # transportsender.h:54. 500 ms alone is less than one gap here.)
  # Liveness: a typed line needs a try through in each direction. 15000 ms is 11 gaps of
  # 1350 ms; with the loop's own --loss 20 on top (36% lost per direction) fewer than two of
  # 11 tries get through with probability 2.7e-4, about 3% over the ~100 waits of those
  # iterations. The plain loop's 5000 ms is about three gaps.
  KILLLOOP_KEEP="${KILLLOOP_KEEP:-}"
  FAILED=0
  env MOSHCLI="$MOSHCLI" KILLLOOP_CATCHUP_MS="${KILLLOOP_CATCHUP_MS:-7000}" \
    KILLLOOP_LIVENESS_MS="${KILLLOOP_LIVENESS_MS:-15000}" KILLLOOP_KEEP="$KILLLOOP_KEEP" \
    scripts/killloop.sh "$@" --no-guards || FAILED=1
  if [ -n "$KILLLOOP_KEEP" ] && [ -d "$KILLLOOP_KEEP" ]; then chown -R "$OWNER" "$KILLLOOP_KEEP" || true; fi
  [ "$FAILED" = 0 ] && echo "netem: killloop: PASS" || echo "netem: killloop: FAIL"
  exit "$FAILED"
fi

# The soak itself, with the screen comparison against tmux capture-pane. Under loss the server
# resends a state until it is acknowledged (at most MAX_RTO = 1 s apart, network.h), so the screen is taken
# after 3 s without a new state instead of 500 ms.
FAILED=0
as_user env MOSHCLI="$MOSHCLI" SOAK_SETTLE_MS="${SOAK_SETTLE_MS:-3000}" scripts/soak.sh "$MINUTES" "$@" || FAILED=1
[ "$FAILED" = 0 ] && echo "netem: PASS" || echo "netem: FAIL"
exit "$FAILED"
