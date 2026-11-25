#!/usr/bin/env bash
# Prepare a plain Linux machine without Docker (a Claude cloud session) for the core
# work: Swift toolchain, mosh 1.4.0 (server binary and the built source tree at
# /opt/mosh-src that Tools/mosh-oracle links against), sshd, protobuf, reference
# clones. Idempotent; run it again after fixing a step. Needs root or passwordless
# sudo for the system parts; the rest still runs without.
#   scripts/cloud-setup.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo -n"
log() { echo "[cloud-setup] $*"; }
. /etc/os-release 2>/dev/null || true
ARCH="$(uname -m)"
export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update -qq || log "apt-get update failed (no root?)"
  $SUDO apt-get install -y -qq --no-install-recommends \
    binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libpython3-dev libsqlite3-0 \
    libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev ca-certificates curl \
    openssh-server iproute2 iputils-ping locales g++ make tcpdump tmux vim htop procps \
    autoconf automake protobuf-compiler libprotobuf-dev libncurses-dev libssl-dev perl \
    python3 less netcat-openbsd mosh || log "some apt packages failed"
  $SUDO apt-get install -y -qq --no-install-recommends libgcc-13-dev libstdc++-13-dev 2>/dev/null \
    || $SUDO apt-get install -y -qq --no-install-recommends libgcc-11-dev libstdc++-11-dev 2>/dev/null || true
  $SUDO locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
fi
$SUDO mkdir -p /run/sshd 2>/dev/null || true
# Scripts written for the dev container use /work.
[ -e /work ] || $SUDO ln -sfn "$ROOT" /work 2>/dev/null || true

if ! command -v swift >/dev/null 2>&1; then
  V="${SWIFT_VERSION:-6.2.4}"
  case "${VERSION_ID:-24.04}" in
    22.04) plat=ubuntu2204; dir=ubuntu22.04 ;;
    *) plat=ubuntu2404; dir=ubuntu24.04 ;;
  esac
  suffix=""; [ "$ARCH" = aarch64 ] && suffix="-aarch64"
  url="https://download.swift.org/swift-$V-release/${plat}${suffix}/swift-$V-RELEASE/swift-$V-RELEASE-${dir}${suffix}.tar.gz"
  log "installing Swift $V from $url"
  if curl -fsSL "$url" -o /tmp/swift.tar.gz; then
    $SUDO mkdir -p /opt/swift && $SUDO tar -xzf /tmp/swift.tar.gz -C /opt/swift --strip-components=1
    rm -f /tmp/swift.tar.gz
    for b in swift swiftc swift-build swift-test swift-package swift-run; do
      [ -e /opt/swift/usr/bin/$b ] && $SUDO ln -sf /opt/swift/usr/bin/$b /usr/local/bin/$b
    done
  else
    log "Swift download failed: check the version and URL at https://www.swift.org/install/linux/"
  fi
fi

if [ ! -f /opt/mosh-src/src/terminal/libmoshterminal.a ]; then
  log "building mosh 1.4.0 at /opt/mosh-src"
  $SUDO rm -rf /opt/mosh-src
  $SUDO git -c advice.detachedHead=false clone -q --depth 1 --branch mosh-1.4.0 https://github.com/mobile-shell/mosh.git /opt/mosh-src \
    && (cd /opt/mosh-src && $SUDO ./autogen.sh >/dev/null 2>&1 && $SUDO ./configure -q >/dev/null \
        && $SUDO make -j"$(nproc)" >/dev/null 2>&1) || log "mosh source build failed"
fi
# The server the tests talk to must be 1.4.0. Install the source build if apt's is older.
if ! mosh-server --version 2>/dev/null | grep -q "1\.4\.0"; then
  (cd /opt/mosh-src && $SUDO make install >/dev/null 2>&1) || log "mosh install failed"
fi

# Reference sources that the notes and CLAUDE.md point to.
mkdir -p "$ROOT/.refs"
clone() { [ -d "$ROOT/.refs/$1" ] || git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" "$2" "$ROOT/.refs/$1" || log "clone of $1 failed"; }
clone mosh https://github.com/mobile-shell/mosh.git mosh-1.4.0
clone SwiftTerm https://github.com/migueldeicaza/SwiftTerm.git v1.99.3
clone swift-nio-ssh https://github.com/apple/swift-nio-ssh.git 0.15.1

log "swift: $(swift --version 2>&1 | head -1)"
log "mosh-server: $(mosh-server --version 2>&1 | head -1)"
log "protoc: $(protoc --version 2>&1)  sshd: $(command -v sshd || echo missing)  tc: $(command -v tc || echo missing)"
log "mosh libs: $(ls /opt/mosh-src/src/*/*.a 2>/dev/null | wc -l) of 6   user: $(id -un) (uid $(id -u))   locale en_US.UTF-8: $(locale -a 2>/dev/null | grep -ci 'en_US.utf')"
