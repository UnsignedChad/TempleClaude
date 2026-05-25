#!/usr/bin/env bash
# run.sh -- launch TempleOS + Claude bridge.
#
# Subcommands:
#   ./run.sh setup      one-time: fetch TempleOS ISO, build payload ISO, install
#   ./run.sh payload    rebuild only the Claude payload ISO
#   ./run.sh bridge     start just the host bridge (foreground)
#   ./run.sh run        boot installed HDD + payload ISO + bridge (default)
#   ./run.sh live       boot the live ISO (no install) + payload + bridge

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
TEMPLE_ISO="$DIST/TempleOS.ISO"
PAYLOAD_ISO="$DIST/claude_payload.iso"
HDD="$DIST/templeos.qcow2"
SOCK="/tmp/templeclaude.sock"
PIDFILE="$DIST/bridge.pid"

# Source of truth for the official TempleOS distro. SHA-1 is from
# Terry's last published nightly. If this mirror dies, swap the URL.
TEMPLE_ISO_URL="${TEMPLE_ISO_URL:-https://www.templeos.org/Downloads/TempleOS.ISO}"
TEMPLE_ISO_SHA1="${TEMPLE_ISO_SHA1:-411287597741d045a1860d25a15aaad2a7fc2151}"

mkdir -p "$DIST"

fetch_iso() {
  if [[ -f "$TEMPLE_ISO" ]]; then
    echo "[setup] TempleOS.ISO already present"
    return
  fi
  echo "[setup] fetching TempleOS.ISO from $TEMPLE_ISO_URL"
  curl -L --fail -o "$TEMPLE_ISO.tmp" "$TEMPLE_ISO_URL"
  local got; got=$(sha1sum "$TEMPLE_ISO.tmp" | awk '{print $1}')
  if [[ "$got" != "$TEMPLE_ISO_SHA1" ]]; then
    echo "[setup] SHA-1 mismatch: got $got expected $TEMPLE_ISO_SHA1" >&2
    echo "[setup] override with TEMPLE_ISO_SHA1=$got if you trust the source" >&2
    rm -f "$TEMPLE_ISO.tmp"
    return 1
  fi
  mv "$TEMPLE_ISO.tmp" "$TEMPLE_ISO"
  echo "[setup] sha1 ok: $got"
}

build_payload() {
  local stage; stage="$(mktemp -d)"
  mkdir -p "$stage/Apps/Claude"
  cp "$ROOT/Apps/Claude/Claude.HC" "$stage/Apps/Claude/"
  cp "$ROOT/Apps/Claude/Load.HC"   "$stage/Apps/Claude/"
  # ISO9660 with Joliet so TempleOS sees normal filenames on the T: drive.
  xorriso -as mkisofs -V CLAUDE -J -r -o "$PAYLOAD_ISO" "$stage" 2>&1 | tail -3
  rm -rf "$stage"
  echo "[payload] wrote $PAYLOAD_ISO"
}

ensure_hdd() {
  if [[ ! -f "$HDD" ]]; then
    echo "[setup] creating blank 512MB qcow2 at $HDD"
    qemu-img create -f qcow2 "$HDD" 512M
  fi
}

start_bridge() {
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "ANTHROPIC_API_KEY not set -- bridge will fail. Export it first." >&2
    return 1
  fi
  if [[ ! -d "$ROOT/bridge/.venv" ]]; then
    python3 -m venv "$ROOT/bridge/.venv"
    "$ROOT/bridge/.venv/bin/pip" install -q -r "$ROOT/bridge/requirements.txt"
  fi
  TEMPLECLAUDE_SOCK="$SOCK" "$ROOT/bridge/.venv/bin/python" "$ROOT/bridge/claude_bridge.py" &
  echo $! > "$PIDFILE"
  # Give the server a moment to bind before QEMU tries to connect.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -S "$SOCK" ]] && return 0
    sleep 0.2
  done
  echo "bridge failed to bind $SOCK" >&2
  return 1
}

stop_bridge() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}
trap stop_bridge EXIT

qemu_common=(
  qemu-system-x86_64
  -m 512
  -cpu qemu64
  -smp 2
  # COM1 -> bridge unix socket. server=off means QEMU connects as client;
  # the bridge bound the socket first, so this works without races.
  -chardev "socket,id=ser0,path=$SOCK,server=off"
  -serial chardev:ser0
  -display gtk
  -name "TempleClaude"
)

cmd="${1:-run}"
case "$cmd" in
  setup)
    fetch_iso
    build_payload
    ensure_hdd
    echo
    echo "[setup] now run:  ./run.sh install"
    echo "[setup] then in TempleOS, hit y to accept the seed, then run SysIns;"
    echo "[setup] follow prompts to install to C: (the qcow2). Shutdown when done."
    ;;
  install)
    fetch_iso
    ensure_hdd
    qemu-system-x86_64 \
      -m 512 -cpu qemu64 -smp 2 \
      -drive "file=$TEMPLE_ISO,media=cdrom" \
      -drive "file=$HDD,format=qcow2,index=0,media=disk" \
      -boot d -display gtk -name "TempleClaude install"
    ;;
  payload)
    build_payload
    ;;
  bridge)
    rm -f "$SOCK"
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
      echo "set ANTHROPIC_API_KEY" >&2; exit 1
    fi
    TEMPLECLAUDE_SOCK="$SOCK" exec "$ROOT/bridge/.venv/bin/python" "$ROOT/bridge/claude_bridge.py"
    ;;
  live)
    fetch_iso
    build_payload
    rm -f "$SOCK"
    start_bridge
    "${qemu_common[@]}" \
      -drive "file=$TEMPLE_ISO,media=cdrom,index=0" \
      -drive "file=$PAYLOAD_ISO,media=cdrom,index=2" \
      -boot d
    ;;
  run)
    if [[ ! -f "$HDD" ]]; then
      echo "no $HDD -- run './run.sh setup' then './run.sh install' first" >&2
      exit 1
    fi
    build_payload
    rm -f "$SOCK"
    start_bridge
    "${qemu_common[@]}" \
      -drive "file=$HDD,format=qcow2,index=0,media=disk" \
      -drive "file=$PAYLOAD_ISO,media=cdrom,index=2" \
      -boot c
    ;;
  *)
    echo "usage: $0 {setup|install|payload|bridge|live|run}" >&2
    exit 1
    ;;
esac
