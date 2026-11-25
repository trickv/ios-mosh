#!/usr/bin/env bash
# Run a command in the dev container, with this checkout mounted at /work.
#   scripts/dev.sh swift test
#   scripts/dev.sh --root bash -c '...'     # as root (sshd, tc netem)
# Env: DEV_REBUILD=1 rebuilds the image. DEV_NAME=x names the container.
#      DEV_DOCKER_ARGS="..." adds docker run options (for example -p).
# .build lives in a Docker volume named after the checkout directory, because
# /home on yellow is small. Each git worktree therefore has its own build dir.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE=ios-mosh-dev

# No container: on a machine prepared by scripts/cloud-setup.sh (a cloud session), or
# with DEV_NATIVE=1, the command runs here. --root uses sudo when not already root.
# A docker client without a reachable daemon (cloud sessions have one) counts as no Docker.
if [ "${DEV_NATIVE:-0}" = 1 ] || { command -v swift >/dev/null 2>&1 \
     && ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; }; then
  cd "$ROOT"
  # The image sets these (docker/Dockerfile.dev); mosh-client refuses to start without a
  # UTF-8 locale, and cloud sessions start with none.
  export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
  if [ "${1:-}" = "--root" ]; then
    shift
    if [ "$(id -u)" = 0 ]; then exec "$@"; else exec sudo -n -E "$@"; fi
  fi
  exec "$@"
fi
if [ "${DEV_REBUILD:-0}" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -t "$IMAGE" -f "$ROOT/docker/Dockerfile.dev" "$ROOT/docker" >&2
fi
BUILDVOL="ios-mosh-build-$(basename "$ROOT")"
if ! docker volume inspect "$BUILDVOL" >/dev/null 2>&1; then
  docker volume create "$BUILDVOL" >/dev/null
  docker run --rm -v "$BUILDVOL":/b "$IMAGE" chown "$(id -u):$(id -g)" /b
fi
mkdir -p "$ROOT/.build"
USEROPT=(--user "$(id -u):$(id -g)")
if [ "${1:-}" = "--root" ]; then USEROPT=(); shift; fi
TTY=(); [ -t 0 ] && [ -t 1 ] && TTY=(-t)
NAME=(); [ -n "${DEV_NAME:-}" ] && NAME=(--name "$DEV_NAME")
# shellcheck disable=SC2086
exec docker run --rm -i "${TTY[@]}" "${NAME[@]}" "${USEROPT[@]}" \
  --init --cap-add NET_ADMIN --cap-add NET_RAW ${DEV_DOCKER_ARGS:-} \
  -e HOME=/home/ubuntu \
  -v "$ROOT":/work -v "$BUILDVOL":/work/.build -v ios-mosh-home:/home/ubuntu -w /work \
  "$IMAGE" "$@"
