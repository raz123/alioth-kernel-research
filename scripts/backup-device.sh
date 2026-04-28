#!/usr/bin/env bash
# Captures stock partition backups of alioth into workspace/stock-images/.
# Idempotent: skips files that already exist (these are immutable bedrock backups).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/workspace/stock-images"
mkdir -p "$DEST"

# Confirm device reachable
adb devices | grep -qE "device$" || { echo "device not in adb mode"; exit 1; }
adb root >/dev/null 2>&1 || true
sleep 1

# Identify partitions of interest
PARTS=(boot_a boot_b dtbo_a dtbo_b vbmeta_a vbmeta_b)

for p in "${PARTS[@]}"; do
  out="$DEST/${p}-original.img"
  if [[ -s "$out" ]]; then
    echo "[skip] $out already exists ($(du -h "$out" | cut -f1))"
    continue
  fi
  echo "[dump] $p -> $out"
  block=$(adb shell readlink -f "/dev/block/by-name/$p" 2>/dev/null | tr -d '\r')
  if [[ -z "$block" ]]; then
    echo "  WARN: /dev/block/by-name/$p not found (this device may not have it; e.g. dtbo on some)"
    continue
  fi
  adb shell "dd if=$block 2>/dev/null" > "$out"
  sz=$(stat -c%s "$out")
  if (( sz < 1024 )); then
    echo "  ERROR: $out only $sz bytes — backup failed"
    rm -f "$out"
    exit 2
  fi
  echo "  OK $sz bytes"
done

# Also dump prop snapshot for forensics
adb shell getprop > "$DEST/getprop-stock-$(date +%Y%m%d).txt"

# Hash for integrity verification
( cd "$DEST" && sha256sum *-original.img | tee SHA256SUMS )

echo "=== backup complete ==="
ls -la "$DEST"
