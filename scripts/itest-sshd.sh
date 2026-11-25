#!/usr/bin/env bash
# Runs INSIDE the dev container, as root (scripts/itest.sh bootstrap starts it through
# scripts/dev.sh --root). Prepares a test user and four sshd instances on 127.0.0.1, then runs
# the given command AS THE ubuntu USER (the checkout's owner) with MOSH_SSHD_ITEST=1 and MOSH_SSHD_ITEST_DIR set, and
# stops the servers when it ends. Natively (no Docker) the command runs as the checkout's owner.
#
#   scripts/itest-sshd.sh swift test -j 4 --filter MoshBootstrapTests
#
# Instances (each with its own config, host key, pid file and log under $DIR/<name>/):
#   normal      22201  ed25519 host key, password and publickey login
#   rsaonly     22202  RSA host key only          -> "no shared host-key algorithm"
#   kbdonly     22203  keyboard-interactive only  -> "unsupported login method"
#   nopassword  22204  publickey only, a second ed25519 host key
# $DIR/env.json tells the tests the user, the password, the ports and the host key files.
set -euo pipefail

if [ "$(id -u)" != 0 ]; then
  echo "itest-sshd.sh must run as root inside the dev container" >&2
  exit 2
fi
if [ $# -eq 0 ]; then
  echo "usage: itest-sshd.sh <command> [args...]" >&2
  exit 2
fi

# Longer than 8 characters on purpose: procps then prints "moshite+" in ps -o user=, which the
# identity check has to cope with.
TEST_USER=moshitestuser
DIR="$(mktemp -d /tmp/mosh-sshd-itest.XXXXXX)"
chmod 755 "$DIR"
PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"

cleanup() {
  status=$?
  for pidfile in "$DIR"/*/sshd.pid; do
    [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null || true
  done
  pkill -u "$TEST_USER" 2>/dev/null || true
  if [ "$status" != 0 ] && [ "${ITEST_SHOW_SSHD_LOG:-0}" = 1 ]; then
    for log in "$DIR"/*/sshd.log; do echo "==== $log"; tail -n 60 "$log"; done >&2
  fi
  rm -rf "$DIR"
  exit "$status"
}
trap cleanup EXIT

if ! id "$TEST_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$TEST_USER"
fi
echo "$TEST_USER:$PASSWORD" | chpasswd
TEST_HOME="$(getent passwd "$TEST_USER" | cut -d: -f6)"
mkdir -p /run/sshd

# name port hostkeytype extra-config...
start_sshd() {
  local name="$1" port="$2" keytype="$3"
  shift 3
  local d="$DIR/$name"
  mkdir -p "$d"
  ssh-keygen -q -t "$keytype" -N '' -C "itest-$name" -f "$d/ssh_host_${keytype}_key"
  {
    echo "Port $port"
    echo "ListenAddress 127.0.0.1"
    echo "HostKey $d/ssh_host_${keytype}_key"
    echo "PidFile $d/sshd.pid"
    echo "AuthorizedKeysFile .ssh/authorized_keys"
    echo "AllowUsers $TEST_USER"
    echo "StrictModes yes"
    echo "PrintMotd no"
    echo "PrintLastLog no"
    echo "LogLevel VERBOSE"
    echo "MaxAuthTries 6"
    echo "LoginGraceTime 60"
    echo "MaxStartups 100:30:200"
    echo "PerSourcePenalties no"
    printf '%s\n' "$@"
  } >"$d/sshd_config"
  # PerSourcePenalties exists only in OpenSSH 9.8 and later; drop the line if sshd rejects it.
  if ! /usr/sbin/sshd -t -f "$d/sshd_config" 2>/dev/null; then
    sed -i '/^PerSourcePenalties/d' "$d/sshd_config"
  fi
  /usr/sbin/sshd -t -f "$d/sshd_config"
  /usr/sbin/sshd -f "$d/sshd_config" -E "$d/sshd.log"
  chmod 644 "$d"/*.pub
  for _ in $(seq 1 50); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "sshd '$name' did not start on port $port" >&2
  cat "$d/sshd.log" >&2
  return 1
}

start_sshd normal 22201 ed25519 \
  "UsePAM no" "PasswordAuthentication yes" "PubkeyAuthentication yes" "KbdInteractiveAuthentication no"
start_sshd rsaonly 22202 rsa \
  "UsePAM no" "PasswordAuthentication yes" "PubkeyAuthentication yes" "KbdInteractiveAuthentication no"
start_sshd kbdonly 22203 ed25519 \
  "UsePAM yes" "PasswordAuthentication no" "PubkeyAuthentication no" "KbdInteractiveAuthentication yes"
start_sshd nopassword 22204 ed25519 \
  "UsePAM no" "PasswordAuthentication no" "PubkeyAuthentication yes" "KbdInteractiveAuthentication no"

# A "mosh-server" that never answers, for the timeout test.
mkdir -p "$DIR/hang"
printf '#!/bin/sh\nexec sleep 600\n' >"$DIR/hang/mosh-server"
chmod 755 "$DIR/hang" "$DIR/hang/mosh-server"

cat >"$DIR/env.json" <<EOF
{
  "user": "$TEST_USER",
  "password": "$PASSWORD",
  "home": "$TEST_HOME",
  "hangingServer": "$DIR/hang/mosh-server",
  "servers": {
    "normal":     {"port": 22201, "hostKeyFile": "$DIR/normal/ssh_host_ed25519_key.pub"},
    "rsaonly":    {"port": 22202, "hostKeyFile": "$DIR/rsaonly/ssh_host_rsa_key.pub"},
    "kbdonly":    {"port": 22203, "hostKeyFile": "$DIR/kbdonly/ssh_host_ed25519_key.pub"},
    "nopassword": {"port": 22204, "hostKeyFile": "$DIR/nopassword/ssh_host_ed25519_key.pub"}
  }
}
EOF
chmod 644 "$DIR/env.json"

# Everything that touches .build runs as the owner of the checkout: ubuntu (uid 1000) in the
# dev container, so the build volume does not end up root-owned; on a native machine
# (scripts/dev.sh without Docker) whoever owns the checkout, root in a cloud session, whose
# .build and SwiftPM lock files another user could not write.
OWNER="$(stat -c %U "$(dirname "$0")/..")"
if [ "$OWNER" = root ]; then
  env MOSH_SSHD_ITEST=1 MOSH_SSHD_ITEST_DIR="$DIR" "$@"
else
  runuser -u "$OWNER" -- env MOSH_SSHD_ITEST=1 MOSH_SSHD_ITEST_DIR="$DIR" "$@"
fi
