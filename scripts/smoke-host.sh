#!/usr/bin/env bash
# Throwaway target for the phone self-test: a container from the dev image with its
# own sshd, a UDP echo and room for mosh-server. Nothing else on this machine is
# touched and no key is added to anyone's authorized_keys.
#   scripts/smoke-host.sh up      # start; writes out/smoke/host.env (mode 600)
#   scripts/smoke-host.sh down    # remove
#   scripts/smoke-host.sh status
# Ports are published on the Tailscale address only, so only tailnet devices reach
# them. The container removes itself after SMOKE_TTL seconds (default 3600).
# Settings (optional) in scripts/smoke.env, which is not committed: SMOKE_SSH_PORT,
# SMOKE_ECHO_PORT, SMOKE_UDP_LO, SMOKE_UDP_HI, SMOKE_TTL. Variables already set in the
# environment win over the file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=ios-mosh-smoke
IMAGE=ios-mosh-dev
OUT="$ROOT/out/smoke"
if [ -f "$ROOT/scripts/smoke.env" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      SMOKE_SSH_PORT|SMOKE_ECHO_PORT|SMOKE_UDP_LO|SMOKE_UDP_HI|SMOKE_TTL)
        [ -n "${!key:-}" ] || export "$key=$value" ;;
    esac
  done < "$ROOT/scripts/smoke.env"
fi
SSH_PORT="${SMOKE_SSH_PORT:-2222}"
ECHO_PORT="${SMOKE_ECHO_PORT:-61000}"
UDP_LO="${SMOKE_UDP_LO:-61001}"
UDP_HI="${SMOKE_UDP_HI:-61011}"
TTL="${SMOKE_TTL:-3600}"

case "${1:-}" in
  up)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    BIND="$(tailscale ip -4 | head -1)"
    HOSTNAME_TS="$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
    mkdir -p "$OUT"
    umask 077
    PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
    docker run -d --rm --name "$NAME" --init \
      -p "$BIND:$SSH_PORT:22/tcp" \
      -p "$BIND:$ECHO_PORT:$ECHO_PORT/udp" \
      -p "$BIND:$UDP_LO-$UDP_HI:$UDP_LO-$UDP_HI/udp" \
      -e SMOKE_PASSWORD="$PASSWORD" -e ECHO_PORT="$ECHO_PORT" -e TTL="$TTL" \
      "$IMAGE" bash -c '
        set -e
        useradd -m -s /bin/bash smoke
        echo "smoke:$SMOKE_PASSWORD" | chpasswd
        unset SMOKE_PASSWORD
        mkdir -p /run/sshd /etc/ssh/smoke
        ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/smoke/host_ed25519
        cat > /etc/ssh/smoke/sshd_config <<EOF
Port 22
HostKey /etc/ssh/smoke/host_ed25519
PasswordAuthentication yes
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers smoke
UsePAM no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
EOF
        python3 -c "
import os, socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((\"0.0.0.0\", int(os.environ[\"ECHO_PORT\"])))
while True:
    data, addr = s.recvfrom(2048)
    s.sendto(data, addr)
" &
        exec timeout "$TTL" /usr/sbin/sshd -D -e -f /etc/ssh/smoke/sshd_config
      ' >/dev/null
    for _ in $(seq 1 30); do
      docker exec "$NAME" test -f /etc/ssh/smoke/host_ed25519.pub 2>/dev/null && break
      sleep 0.5
    done
    HOSTKEY="$(docker exec "$NAME" ssh-keygen -lf /etc/ssh/smoke/host_ed25519.pub | awk '{print $2}')"
    cat > "$OUT/host.env" <<EOF
SMOKE_HOST=$HOSTNAME_TS
SMOKE_ADDR=$BIND
SMOKE_PORT=$SSH_PORT
SMOKE_USER=smoke
SMOKE_PASSWORD=$PASSWORD
SMOKE_HOSTKEY=$HOSTKEY
SMOKE_UDP_PORT=$ECHO_PORT
SMOKE_UDP_RANGE=$UDP_LO:$UDP_HI
EOF
    chmod 600 "$OUT/host.env"
    echo "smoke host up: $HOSTNAME_TS ($BIND) ssh $SSH_PORT, udp echo $ECHO_PORT, mosh udp $UDP_LO-$UDP_HI, host key $HOSTKEY"
    ;;
  down)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -f "$OUT/host.env"
    echo "smoke host removed"
    ;;
  status)
    docker ps --filter "name=^$NAME$" --format '{{.Names}} {{.Status}} {{.Ports}}'
    ;;
  *)
    echo "usage: $0 up|down|status" >&2
    exit 2
    ;;
esac
