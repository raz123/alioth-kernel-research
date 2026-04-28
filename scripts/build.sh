#!/usr/bin/env bash
# Build the alioth kernel.
# Usage: build.sh <tag> [extra_overlay.config ...]
#   <tag> e.g. "vanilla", "p1-noksu", "p1-ksu", "p2-s1"
#   extra overlays are *.config files merged AFTER alioth.config
#
# Defconfig layering: kona-perf base → sm8250-common → alioth → extras.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_SRC="$ROOT/workspace/kernel/android_kernel_xiaomi_sm8250"
OUT="$KERNEL_SRC/out"

tag="${1:?tag required, e.g. vanilla}"; shift || true
extra_overlays=("$@")

source "$ROOT/workspace/toolchain/clang-path.env"
source "$ROOT/workspace/kernel/DEFCONFIG.env"

export PATH="$CLANG_DIR:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip
export READELF=llvm-readelf
export HOSTCC=clang
export HOSTCXX=clang++
export HOSTAR=llvm-ar
export HOSTLD=ld.lld
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER=claude
export KBUILD_BUILD_HOST=research
# Use the same clang that built the running stock kernel (NDK r29 = r563880c).
# That clang version produces a working kernel without warning suppression.
# Keep this empty unless build errors require specific overrides.
unset KCFLAGS

mkdir -p "$OUT"
cd "$KERNEL_SRC"

ts=$(date +%Y%m%d-%H%M%S)
LOG="$ROOT/runs/build-$ts-$tag.log"
mkdir -p "$ROOT/runs"

echo "=== build.sh tag=$tag ==="
echo "log: $LOG"
echo "base: $DEFCONFIG_BASE"
echo "overlays: ${DEFCONFIG_OVERLAYS[*]} ${extra_overlays[*]:-}"

# Step 1: produce base .config
echo "=== make $DEFCONFIG_BASE ==="
make O=out "$DEFCONFIG_BASE" 2>&1 | tee -a "$LOG"

# Step 2: merge overlays
configs_dir="arch/arm64/configs"
overlay_paths=()
for o in "${DEFCONFIG_OVERLAYS[@]}" "${extra_overlays[@]:-}"; do
  if [[ -z "$o" ]]; then continue; fi
  if [[ -f "$o" ]]; then
    overlay_paths+=("$o")
  elif [[ -f "$configs_dir/$o" ]]; then
    overlay_paths+=("$configs_dir/$o")
  else
    echo "WARN: overlay '$o' not found" | tee -a "$LOG"
  fi
done
if [[ ${#overlay_paths[@]} -gt 0 ]]; then
  echo "=== merging overlays: ${overlay_paths[*]} ===" | tee -a "$LOG"
  ARCH=arm64 scripts/kconfig/merge_config.sh -m -O out "out/.config" "${overlay_paths[@]}" 2>&1 | tee -a "$LOG"
fi

# Step 3: olddefconfig (resolve any new options from kconfig defaults)
make O=out olddefconfig 2>&1 | tee -a "$LOG"

# Note: BTFIDS step in scripts/link-vmlinux.sh is patched to skip if
# resolve_btfids tool is missing (4.19 doesn't have tools/bpf/resolve_btfids/).
# See workspace/kernel/patches/phase1-btf-ftrace/skip-btfids-if-missing.patch

# Step 4: build
echo "=== make Image.gz dtbs (parallel $(nproc)) ===" | tee -a "$LOG"
make O=out -j$(nproc) Image.gz dtbs 2>&1 | tee -a "$LOG"

# Verify outputs
test -s "$OUT/arch/arm64/boot/Image.gz" || { echo "Image.gz missing"; exit 2; }
echo "=== build complete (tag=$tag) ===" | tee -a "$LOG"
ls -la "$OUT/arch/arm64/boot/Image.gz"
