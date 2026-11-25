#!/usr/bin/env bash
# Integration tests that need more than a plain `swift test`: servers, root, netem.
# Each subcommand is one scripts/dev.sh call (one container), because servers started in one
# call are gone in the next.
#
#   scripts/itest.sh handshake     moshcli handshake against a real mosh-server
#   scripts/itest.sh hello         type echo hello-$((6*7)), expect hello-42
#   scripts/itest.sh script        the other script commands and exit codes 0, 1 and 4
#   scripts/itest.sh rebind        a new socket in mid-session; same mosh-server process
#   scripts/itest.sh resume-mem    export, discard the connection, import: all variants
#   scripts/itest.sh predict       local echo: moshcli --predict over a slow link (--delay-ms)
#   scripts/itest.sh soak          30 s soaks on a clean loopback, shell in tmux; the final
#                                  client screen must equal tmux capture-pane -p
#   scripts/itest.sh bootstrap [swift test options]
#                                  MoshBootstrap against real OpenSSH servers (needs root)
#   scripts/itest.sh bootstrap-session
#                                  moshcli bootstrap: SSH login, mosh-server, a session on it
#                                  (needs root, the same sshd instances)
#   scripts/itest.sh killloop [iterations] [--long] [--no-crashpoints] [--no-damage] [--no-guards]
#                                  scripts/killloop.sh, resume stage 1: a client with a session
#                                  record is killed again and again (default 20 times, then at
#                                  every storage step, then with damaged records) and must
#                                  resume or fall back without reusing a number.
#                                  `killloop 260 --long` is the plan's run: 200 resumes and more (about 5 minutes)
#   scripts/itest.sh netem-soak [minutes]
#                                  scripts/netem.sh (default 2 min): the soak under 20% loss
#                                  (needs root and the sch_netem kernel module)
#   scripts/itest.sh all           all of the above; netem-soak only where netem works: where
#                                  it does not, it says so (SKIP, needs yellow) and passes
#
# On a machine with its own toolchain and mosh-server (the Mac): ITEST_NO_CONTAINER=1.
# bootstrap always needs root (scripts/dev.sh --root: the container, or natively root/sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cmd="${1:-}"
[ $# -gt 0 ] && shift

# Runs scripts/itest-mosh.sh in the dev container, or here with ITEST_NO_CONTAINER=1.
mosh_itest() {
  if [ "${ITEST_NO_CONTAINER:-0}" = 1 ]; then
    "$ROOT/scripts/itest-mosh.sh" "$@"
  else
    "$ROOT/scripts/dev.sh" scripts/itest-mosh.sh "$@"
  fi
}

# scripts/itest-sshd.sh, as root in the container, creates a test user and four sshd
# instances on 127.0.0.1 and then runs the tests as the ubuntu user with MOSH_SSHD_ITEST=1.
bootstrap_itest() {
  "$ROOT/scripts/dev.sh" --root scripts/itest-sshd.sh \
    swift test -j 4 --filter MoshBootstrapTests "$@"
}

bootstrap_session_itest() {
  "$ROOT/scripts/dev.sh" --root scripts/itest-sshd.sh scripts/itest-mosh.sh bootstrap-session
}

# Whether a netem qdisc can be added on lo (root, NET_ADMIN, sch_netem), in the same kind of
# dev.sh --root call that scripts/netem.sh makes.
netem_available() {
  "$ROOT/scripts/dev.sh" --root bash -c \
    'tc qdisc add dev lo root netem delay 1ms 2>/dev/null && tc qdisc del dev lo root' >/dev/null 2>&1
}

netem_soak_itest() {
  echo "== netem-soak"
  if ! netem_available; then
    echo "SKIP netem-soak: tc netem does not work here (no sch_netem module, or not root): needs yellow"
    return 0
  fi
  "$ROOT/scripts/netem.sh" "${1:-${ITEST_NETEM_MINUTES:-2}}"
  echo "PASS netem-soak"
}

# scripts/killloop.sh in the dev container, or here with ITEST_NO_CONTAINER=1. As root it also
# captures the run with tcpdump; without root that check is left out and the logs are checked.
killloop_itest() {
  if [ "${ITEST_NO_CONTAINER:-0}" = 1 ]; then
    "$ROOT/scripts/killloop.sh" "$@"
  else
    "$ROOT/scripts/dev.sh" scripts/killloop.sh "$@"
  fi
}

case "$cmd" in
  handshake|hello|script|rebind|resume-mem|soak|predict)
    mosh_itest "$cmd" "$@"
    ;;
  bootstrap)
    bootstrap_itest "$@"
    ;;
  bootstrap-session)
    bootstrap_session_itest
    ;;
  killloop)
    killloop_itest "$@"
    ;;
  netem-soak)
    netem_available || { echo "itest: tc netem does not work here (no sch_netem module, or not root)" >&2; exit 1; }
    netem_soak_itest "$@"
    ;;
  all)
    mosh_itest handshake hello script rebind resume-mem soak predict
    bootstrap_itest
    bootstrap_session_itest
    killloop_itest "${ITEST_KILLLOOP_ITERATIONS:-20}"
    netem_soak_itest
    ;;
  *)
    echo "usage: scripts/itest.sh handshake|hello|script|rebind|resume-mem|soak|predict|bootstrap|bootstrap-session|killloop|netem-soak|all" >&2
    exit 2
    ;;
esac
