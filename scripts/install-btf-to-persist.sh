#!/usr/bin/env bash
# Install vmlinux.btf into /mnt/vendor/persist on the device.
# This is the canonical location for BPF tracing/lsm/ext to find the
# kernel BTF — the persist partition survives factory reset, OTA, etc.
#
# Run this ONCE per device. After that, the BTF is permanent unless the
# user explicitly removes the file or wipes the persist partition (rare).
#
# Usage: install-btf-to-persist.sh [path/to/vmlinux.btf]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_BTF="$ROOT/workspace/kernel/patches/phase2-bpf-backport/00-survey/btf-fw/vmlinux.btf"
BTF="${1:-$DEFAULT_BTF}"

if [[ ! -f "$BTF" ]]; then
  echo "BTF not found at: $BTF"
  echo "Generate with: pahole -J --btf_features=encode_force,reproducible_build,var out/vmlinux"
  echo "Then objcopy the .BTF section out: llvm-objcopy --dump-section=.BTF=vmlinux.btf out/vmlinux"
  exit 1
fi

state=$(adb get-state 2>/dev/null || echo unknown)
if [[ "$state" != "device" ]]; then
  echo "Device not in adb mode (got: $state). Reboot to system first."
  exit 2
fi

# We need root to write to /mnt/vendor/persist
adb root >/dev/null
sleep 2
adb wait-for-device

echo "Pushing $(basename "$BTF") ($(stat -c %s "$BTF") bytes) to /mnt/vendor/persist/vmlinux.btf"
adb push "$BTF" /mnt/vendor/persist/vmlinux.btf
adb shell 'chmod 0644 /mnt/vendor/persist/vmlinux.btf; sync'
adb shell 'ls -la /mnt/vendor/persist/vmlinux.btf'

echo "Done. BTF is now at /mnt/vendor/persist/vmlinux.btf — survives factory reset."
echo "Verify by: rm /data/local/tmp/vmlinux.btf; reboot; bpftool prog loadall <fexit.bpf.o> /sys/fs/bpf/y autoattach"
