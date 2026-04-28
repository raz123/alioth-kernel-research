#!/usr/bin/env bash
# Pack a kernel Image.gz into a boot.img v3 (no DTB inside; DTB lives in dtbo).
# Usage: pack-boot.sh <tag>
# Inputs: workspace/kernel/android_kernel_xiaomi_sm8250/out/arch/arm64/boot/Image.gz
#         workspace/stock-images/unpacked-boot-a/ramdisk
# Output: workspace/builds/<timestamp>-<tag>.img + LATEST symlink
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_OUT="$ROOT/workspace/kernel/android_kernel_xiaomi_sm8250/out"
STOCK="$ROOT/workspace/stock-images"
UNPACK="$STOCK/unpacked-boot-a"
BUILDS="$ROOT/workspace/builds"
mkdir -p "$BUILDS"

tag="${1:?tag required, e.g. vanilla}"
timestamp=$(date +%Y%m%d-%H%M%S)
output="$BUILDS/$timestamp-$tag.img"

# Hardcoded for alioth/Android 16: header v3, no DTB in boot.img.
# Stock uses uncompressed Image (not Image.gz); matching that for compatibility.
python3 "$ROOT/workspace/toolchain/mkbootimg/mkbootimg.py" \
  --kernel "$KERNEL_OUT/arch/arm64/boot/Image" \
  --ramdisk "$UNPACK/ramdisk" \
  --header_version 3 \
  --os_version 16.0.0 \
  --os_patch_level 2026-03 \
  --output "$output"

# Add AVB hash footer matching stock's structure. Without this, alioth's
# bootloader cannot determine image size and hangs at fastboot boot.
# Algorithm NONE = no signing (works on unlocked bootloader); hash descriptor
# allows the bootloader to verify image integrity if it wants to.
python3 "$ROOT/workspace/toolchain/mkbootimg/avbtool.py" add_hash_footer \
  --image "$output" \
  --partition_size 201326592 \
  --partition_name boot \
  --salt 8d9e3353541ae39fa070bfb5c16c9b7c644c281aa8476c388f82e04cf360f77c \
  --algorithm NONE

ls -la "$output"
echo "=== packed boot.img ready: $output ==="
echo "$output" > "$BUILDS/LATEST"
