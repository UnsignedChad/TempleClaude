#!/usr/bin/env bash
# run.sh -- TempleClaude on VirtualBox.
#
# Subcommands:
#   ./run.sh setup      fetch TempleOS ISO, build payload, create disk + VM
#   ./run.sh payload    rebuild only the Claude payload ISO
#   ./run.sh bridge     start just the host bridge (foreground)
#   ./run.sh run        start bridge, launch the VM (GUI)
#   ./run.sh headless   start bridge, launch the VM headless
#   ./run.sh poweroff   force-stop the VM
#   ./run.sh destroy    unregister + delete the VM and disk
#
# Why VirtualBox: Terry developed TempleOS on VBox, so this is the
# best-tested path. QEMU works too but its SeaBIOS sometimes chokes
# on the El Torito record on Terry's RedSea ISOs.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
TEMPLE_ISO="$DIST/TempleOS.ISO"
PAYLOAD_ISO="$DIST/claude_payload.iso"
HDD="$DIST/templeos.vdi"
SOCK="/tmp/templeclaude.sock"
PIDFILE="$DIST/bridge.pid"

VM_NAME="${TEMPLECLAUDE_VM:-TempleClaude}"

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
  xorriso -as mkisofs -V CLAUDE -J -r -o "$PAYLOAD_ISO" "$stage" 2>&1 | tail -3
  rm -rf "$stage"
  echo "[payload] wrote $PAYLOAD_ISO"
}


# Inject Claude.HC and a custom Once.HC into /Home on the installed disk,
# so every boot auto-loads the module and prints a ready banner. Requires
# the VM to be powered off and nbd kernel module available.
inject_into_vdi() {
  if [[ ! -f "$HDD" ]]; then
    echo "[inject] no $HDD -- install first (./run.sh setup, boot, SysIns)" >&2
    return 1
  fi
  if VBoxManage list runningvms | grep -q "$VM_NAME"; then
    echo "[inject] VM is running -- power it off first (./run.sh poweroff)" >&2
    return 1
  fi
  local target_part="${TEMPLECLAUDE_INSTALL_PART:-2}"
  local mnt=/tmp/tc-d
  echo "[inject] mounting partition $target_part of $HDD"
  sudo modprobe nbd max_part=8
  sudo qemu-nbd --connect=/dev/nbd0 "$HDD"
  sleep 1
  sudo mkdir -p "$mnt"
  sudo mount -o uid=$(id -u),gid=$(id -g) "/dev/nbd0p${target_part}" "$mnt"
  mkdir -p "$mnt/Home"
  cp "$ROOT/Apps/Claude/Claude.HC"     "$mnt/Home/Claude.HC"
  cp "$ROOT/host/inject/Once.HC"       "$mnt/Home/Once.HC"
  # Remove the compressed default if present so our plain version wins.
  rm -f "$mnt/Home/Once.HC.Z"
  sync
  sudo umount "$mnt"
  sudo qemu-nbd --disconnect /dev/nbd0
  echo "[inject] /Home/Claude.HC and /Home/Once.HC are in place"
}

vm_exists() { VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; }

create_vm() {
  if vm_exists; then
    echo "[setup] VM '$VM_NAME' already exists -- skipping create"
    return
  fi
  if [[ ! -f "$HDD" ]]; then
    VBoxManage createmedium disk --filename "$HDD" --size 512 --format VDI
  fi
  # ostype "Other_64" -- TempleOS is 64-bit but not on the supported list.
  VBoxManage createvm --name "$VM_NAME" --ostype Other_64 --register --basefolder "$DIST"
  VBoxManage modifyvm "$VM_NAME" \
    --memory 512 --cpus 2 --vram 16 \
    --boot1 dvd --boot2 disk --boot3 none --boot4 none \
    --audio-driver none --usb-ohci off --usb-ehci off --usb-xhci off \
    --rtcuseutc on --acpi on
  # IDE controller -- TempleOS does not speak AHCI/SATA.
  VBoxManage storagectl "$VM_NAME" --name "IDE" --add ide --controller PIIX4
  VBoxManage storageattach "$VM_NAME" --storagectl "IDE" \
    --port 0 --device 0 --type hdd --medium "$HDD"
  # Install ISO sits in the second slot until install completes; ./run.sh
  # flip detaches it. After flip we never need a DVD again -- inject puts
  # everything we need into the VDI directly.
  VBoxManage storageattach "$VM_NAME" --storagectl "IDE" \
    --port 0 --device 1 --type dvddrive --medium "$TEMPLE_ISO"
  # COM1 -> host pipe (server mode: VBox owns the socket; bridge connects).
  VBoxManage modifyvm "$VM_NAME" --uart1 0x3F8 4
  VBoxManage modifyvm "$VM_NAME" --uartmode1 server "$SOCK"
  echo "[setup] VM created"
}

# Detach the install ISO once you've SysIns'd onto the HDD. After this,
# the VM boots from disk and the payload stays in the second DVD slot.
flip_to_hdd_boot() {
  if vm_exists; then
    VBoxManage storageattach "$VM_NAME" --storagectl "IDE" \
      --port 0 --device 1 --type dvddrive --medium emptydrive 2>/dev/null || true
    VBoxManage modifyvm "$VM_NAME" --boot1 disk --boot2 dvd --boot3 none --boot4 none
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
}

stop_bridge() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}
trap stop_bridge EXIT

cmd="${1:-run}"
case "$cmd" in
  setup)
    fetch_iso
    build_payload
    create_vm
    echo
    echo "[setup] done. Next: ./run.sh run"
    echo "[setup] In TempleOS: hit y to accept seed, run SysIns to install"
    echo "[setup] to C:, shut down, then ./run.sh flip and ./run.sh run."
    ;;
  inject)
    inject_into_vdi
    ;;
  payload)
    # Payload ISO is no longer attached to the VM (inject puts files
    # directly on the VDI), but the target is kept for back-compat.
    build_payload
    ;;
  flip)
    flip_to_hdd_boot
    echo "[flip] install ISO detached; VM now boots from disk."
    ;;
  bridge)
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
      echo "set ANTHROPIC_API_KEY" >&2; exit 1
    fi
    TEMPLECLAUDE_SOCK="$SOCK" exec "$ROOT/bridge/.venv/bin/python" "$ROOT/bridge/claude_bridge.py"
    ;;
  run)
    vm_exists || { echo "no VM -- run './run.sh setup' first" >&2; exit 1; }
    start_bridge
    VBoxManage startvm "$VM_NAME" --type gui
    # Bridge keeps running until the VM exits + trap fires.
    echo "[run] VM started. Ctrl-C here to stop the bridge."
    wait
    ;;
  headless)
    vm_exists || { echo "no VM -- run './run.sh setup' first" >&2; exit 1; }
    start_bridge
    VBoxManage startvm "$VM_NAME" --type headless
    echo "[headless] VM started. Console on VRDE if you enabled it."
    wait
    ;;
  poweroff)
    VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
    ;;
  destroy)
    VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
    sleep 1
    VBoxManage unregistervm "$VM_NAME" --delete 2>/dev/null || true
    rm -rf "$DIST/$VM_NAME"
    rm -f "$HDD"
    echo "[destroy] gone"
    ;;
  *)
    echo "usage: $0 {setup|inject|payload|flip|bridge|run|headless|poweroff|destroy}" >&2
    exit 1
    ;;
esac
