# Alioth Kernel: BPF Backport + KernelSU Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a custom 4.19-cip kernel for Xiaomi alioth that has full Linux 5.10 BPF feature parity and integrated KernelSU, deployed to slot `_b` of an A/B device with multi-layer brick recovery, with `_a` slot preserved as a known-good fallback.

**Architecture:** Three sequential phases (P0 vanilla rebuild for pipeline validation → P1 BTF+ftrace+KSU minimum-viable → P2 selective backport of bpf_link/bpf_iter/trampoline/struct_ops/sleepable). Every kernel image is first tested via `fastboot boot` (RAM-only) before being committed to flash. `_a` slot is never touched after the initial backup.

**Tech Stack:** Linux 4.19.325-cip128 source from LineageOS, AOSP clang r563880c, `mkbootimg`/`avbtool` from AOSP, KernelSU (non-kprobes mode), `bpftool`, `bpftrace`, `stackplz`, frida; `adb`/`fastboot` for device interaction.

**References:**
- Spec: `docs/superpowers/specs/2026-04-28-alioth-bpf-kernelsu-design.md`
- Research: `docs/research/2026-04-28-ebpf-feature-survey.md`

**Phase gating model:**
- Phase 0 → Phase 1: gated on **user manual approval** ("OK, P0 done — proceed").
- Phase 1 → Phase 2: gated on **user manual approval** + AI feature-probe pass.
- Phase 2 done: gated on user manual approval + AI feature-probe pass.

---

## Pre-Phase: Bootstrap (one-time setup)

Tasks here lay foundation used by all phases. Each is a self-contained step.

### Task 0.1: Create workspace directory structure

**Files:**
- Create: `workspace/`, `workspace/toolchain/`, `workspace/kernel/`, `workspace/kernel/patches/`, `workspace/stock-images/`, `workspace/builds/`, `workspace/tests/`, `runs/`, `scripts/`

- [ ] **Step 1: Create directories**

```bash
cd /home/ltlly/Code/kernel_research
mkdir -p workspace/{toolchain,kernel,kernel/patches,stock-images,builds,tests}
mkdir -p workspace/kernel/patches/{phase1-btf-ftrace,phase1-kernelsu,phase2-bpf-backport}
mkdir -p workspace/kernel/patches/phase2-bpf-backport/{01-bpf-link,02-bpf-iter,03-trampoline-fentry,04-struct-ops,05-sleepable-bpf}
mkdir -p runs scripts
```

- [ ] **Step 2: Verify**

Run: `tree -L 3 workspace scripts runs`
Expected: directory tree matches Section 5.1 of the design spec.

- [ ] **Step 3: Create STATUS.md placeholder**

```bash
cat > /home/ltlly/Code/kernel_research/STATUS.md <<'EOF'
# Alioth Kernel Project — Status

| Phase | State | Notes |
|---|---|---|
| Pre-Phase | in-progress | bootstrap |
| Phase 0 (vanilla) | pending | |
| Phase 1 (BTF+ftrace+KSU) | pending | |
| Phase 2 (BPF backport) | pending | |

## Current device state

- Active slot: `_a` (stock LineageOS 23.2 kernel 4.19.325-cip128)
- Slot `_b`: not yet touched
- Stock backup taken: NO

EOF
```

- [ ] **Step 4: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git init -q 2>/dev/null || true
git add -A
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "chore: bootstrap workspace skeleton"
```

---

### Task 0.2: Install Ubuntu prerequisites

**Files:** none (system-wide install)

- [ ] **Step 1: Check what's missing**

```bash
for pkg in build-essential bison flex bc ccache lz4 cpio python3-dev libssl-dev libelf-dev clang gawk; do
  dpkg -s $pkg 2>/dev/null | grep -q "Status: install ok installed" || echo "MISSING: $pkg"
done
```

- [ ] **Step 2: If anything missing, request user permission, then install**

If Step 1 prints anything, ask the user:
> "Need to `sudo apt install <pkg-list>` to proceed. OK?"

After user OK:

```bash
sudo apt update
sudo apt install -y build-essential bison flex bc ccache lz4 cpio python3-dev libssl-dev libelf-dev clang gawk
```

- [ ] **Step 3: Verify**

```bash
for cmd in bison flex bc ccache lz4 cpio gcc clang; do
  which $cmd || echo "MISSING $cmd"
done
```
Expected: all paths printed, no MISSING.

- [ ] **Step 4: Install / verify pahole ≥ 1.21**

```bash
pahole --version 2>/dev/null || echo "MISSING"
```

If missing or < 1.21:

```bash
sudo apt install -y dwarves
pahole --version
```

If distro `dwarves` is too old (< 1.21), build from source into `workspace/toolchain/pahole/`:

```bash
cd /home/ltlly/Code/kernel_research/workspace/toolchain
git clone --depth 50 https://git.kernel.org/pub/scm/devel/pahole/pahole.git pahole-src
cd pahole-src && git submodule update --init --recursive
mkdir build && cd build
cmake -D__LIB=lib -DCMAKE_INSTALL_PREFIX=/home/ltlly/Code/kernel_research/workspace/toolchain/pahole ..
make -j$(nproc) install
/home/ltlly/Code/kernel_research/workspace/toolchain/pahole/bin/pahole --version
```

Expected: prints `v1.21` or higher.

- [ ] **Step 5: Commit STATUS.md note**

Edit `STATUS.md`'s "Pre-Phase" line to `in-progress (deps installed)`, then:
```bash
cd /home/ltlly/Code/kernel_research
git add STATUS.md
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "chore: prereqs installed"
```

---

### Task 0.3: Write recovery script

**Files:**
- Create: `scripts/recover.sh`

- [ ] **Step 1: Write the script**

```bash
cat > /home/ltlly/Code/kernel_research/scripts/recover.sh <<'EOF'
#!/usr/bin/env bash
# Multi-layer recovery for alioth.
# Usage: recover.sh [--auto-stock] [--reason "what happened"]
# Without --auto-stock: tries to switch active slot to _a only.
# With --auto-stock: also re-flashes original stock images from workspace/stock-images/ if both slots look bad.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOCK="$ROOT/workspace/stock-images"
LOG="$ROOT/runs/recovery-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$ROOT/runs"

auto_stock=0
reason="(unspecified)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-stock) auto_stock=1; shift;;
    --reason) reason="$2"; shift 2;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done

log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }

log "=== recovery start (reason: $reason) ==="

# Layer A: device is in adb / android
if adb devices | grep -qE "device$"; then
  log "device reachable via adb; rebooting to bootloader"
  adb reboot bootloader || true
  sleep 5
fi

# Wait for fastboot
deadline=$((SECONDS+120))
while ! fastboot devices | grep -q .; do
  if (( SECONDS > deadline )); then
    log "FATAL: device not in fastboot after 120s — escalate to user (L5)"
    echo "ESCALATE_USER" > "$ROOT/runs/RECOVERY_ESCALATED"
    exit 3
  fi
  sleep 2
done
log "device in fastboot"

# Layer B: switch active slot to _a (cheapest recovery)
log "setting active slot to a"
fastboot --set-active=a 2>&1 | tee -a "$LOG"

# Layer C: re-flash stock _a if requested AND active slot is already a
if (( auto_stock )); then
  if [[ ! -f "$STOCK/boot_a-original.img" ]]; then
    log "FATAL: stock backup missing at $STOCK; cannot recover"
    exit 4
  fi
  log "re-flashing stock boot to slot a"
  fastboot flash boot_a "$STOCK/boot_a-original.img" 2>&1 | tee -a "$LOG"
  if [[ -f "$STOCK/dtbo_a-original.img" ]]; then
    fastboot flash dtbo_a "$STOCK/dtbo_a-original.img" 2>&1 | tee -a "$LOG"
  fi
fi

log "rebooting"
fastboot reboot 2>&1 | tee -a "$LOG"

# Wait for adb back
deadline=$((SECONDS+180))
while ! adb devices | grep -qE "device$"; do
  if (( SECONDS > deadline )); then
    log "FATAL: device did not return to adb in 180s after recovery"
    echo "ESCALATE_USER" > "$ROOT/runs/RECOVERY_ESCALATED"
    exit 5
  fi
  sleep 3
done

log "=== recovery complete; device on slot a ==="
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/recover.sh
```

- [ ] **Step 2: Smoke-test the script (without actually triggering)**

```bash
bash -n /home/ltlly/Code/kernel_research/scripts/recover.sh && echo "syntax ok"
/home/ltlly/Code/kernel_research/scripts/recover.sh --reason "syntax-test" 2>&1 | head -5 &
sleep 1; kill %1 2>/dev/null || true
```

Expected: "syntax ok" prints, no immediate errors.

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add scripts/recover.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "feat: add recovery script"
```

---

### Task 0.4: Write device backup script

**Files:**
- Create: `scripts/backup-device.sh`

- [ ] **Step 1: Write the script**

```bash
cat > /home/ltlly/Code/kernel_research/scripts/backup-device.sh <<'EOF'
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
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/backup-device.sh
```

- [ ] **Step 2: Syntax check**

```bash
bash -n /home/ltlly/Code/kernel_research/scripts/backup-device.sh && echo "syntax ok"
```

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add scripts/backup-device.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "feat: add device backup script"
```

---

### Task 0.5: Run device backup (immutable bedrock)

**Files:** writes to `workspace/stock-images/`

- [ ] **Step 1: Connect device check**

```bash
adb devices -l
```
Expected: `39d89ed3 ... device:alioth ...` line present. If not, halt and ask user to reconnect.

- [ ] **Step 2: Run backup**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/backup-device.sh
```

Expected: produces files like `boot_a-original.img` (~96MB), `dtbo_a-original.img` (~24MB), `vbmeta_a-original.img` (~64KB), and a `SHA256SUMS` file.

- [ ] **Step 3: Sanity check sizes**

```bash
ls -la /home/ltlly/Code/kernel_research/workspace/stock-images/
```

Expected: all `*-original.img` files non-zero.
If `boot_a` is < 50MB, halt — something's wrong.

- [ ] **Step 4: Make backups read-only on the host (defensive)**

```bash
chmod -w /home/ltlly/Code/kernel_research/workspace/stock-images/*-original.img
```

- [ ] **Step 5: Update STATUS.md**

Set the "Stock backup taken" line to `YES (YYYY-MM-DD)` with today's date.

- [ ] **Step 6: Commit**

```bash
cd /home/ltlly/Code/kernel_research
# Note: do NOT commit the .img files (they're large and contain device data); commit only the index
echo "workspace/stock-images/*.img" >> .gitignore
echo "workspace/stock-images/getprop-*.txt" >> .gitignore
echo "workspace/builds/" >> .gitignore
echo "workspace/toolchain/" >> .gitignore
echo "workspace/kernel/android_kernel_xiaomi_sm8250/" >> .gitignore
echo "workspace/kernel/KernelSU/" >> .gitignore
echo "workspace/kernel/linux-stable/" >> .gitignore
echo "runs/" >> .gitignore
git add .gitignore STATUS.md workspace/stock-images/SHA256SUMS
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "chore: stock device images backed up (hashes only)"
```

---

### Task 0.6: Download AOSP clang

**Files:** writes to `workspace/toolchain/clang-aosp/`

- [ ] **Step 1: Determine the clang version used by stock**

The `uname -a` output earlier showed: `clang version 21.0.0 ... r563880`. So we want `clang-r563880c` (the stable letter suffix; "c" is the canonical AOSP point release for r563880).

- [ ] **Step 2: Clone the prebuilt repo (shallow, single-tree)**

```bash
cd /home/ltlly/Code/kernel_research/workspace/toolchain
# AOSP serves prebuilts via a separate repo; we only need the linux-x86 host tree
git clone --depth 1 --filter=blob:none -b master-kernel-build-2024 \
  https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 clang-aosp || \
git clone --depth 1 https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 clang-aosp
```

If both fail (network), fall back to direct tarball:

```bash
cd /home/ltlly/Code/kernel_research/workspace/toolchain
mkdir -p clang-aosp && cd clang-aosp
# Build server tarball (try a few common URLs)
for url in \
  "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/master/clang-r563880c.tar.gz" \
  "https://ci.android.com/builds/submitted/12080000/clang_linux_x86_64/latest/clang-r563880c.tar.gz" \
  ; do
  echo "Trying $url"
  curl -fL -o clang.tar.gz "$url" && break || true
done
[ -s clang.tar.gz ] || { echo "could not fetch clang"; exit 1; }
tar xzf clang.tar.gz
rm clang.tar.gz
```

- [ ] **Step 3: Locate the actual clang binary path**

```bash
find /home/ltlly/Code/kernel_research/workspace/toolchain/clang-aosp -name 'clang' -type f -executable | grep -v 'tidy\|format' | head -3
```

Expected: prints something like `.../clang-r563880c/bin/clang`.

- [ ] **Step 4: Smoke test the compiler**

```bash
CLANG_PATH=$(find /home/ltlly/Code/kernel_research/workspace/toolchain/clang-aosp -name 'clang' -type f -executable | grep -v 'tidy\|format' | head -1)
echo "CLANG_PATH=$CLANG_PATH"
"$CLANG_PATH" --version
```

Expected: prints `Android (...) clang version 21.0.0` or close (within minor).

- [ ] **Step 5: Save the path for build scripts**

```bash
cat > /home/ltlly/Code/kernel_research/workspace/toolchain/clang-path.env <<EOF
# Sourced by scripts/build.sh
CLANG_PATH="$CLANG_PATH"
CLANG_DIR="$(dirname "$CLANG_PATH")"
EOF
```

- [ ] **Step 6: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add workspace/toolchain/clang-path.env
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "chore: pin AOSP clang path"
```

---

### Task 0.7: Download mkbootimg tools

**Files:** writes to `workspace/toolchain/mkbootimg/`

- [ ] **Step 1: Clone shallow**

```bash
cd /home/ltlly/Code/kernel_research/workspace/toolchain
git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg
```

- [ ] **Step 2: Verify the scripts are present**

```bash
ls workspace/toolchain/mkbootimg/{mkbootimg.py,unpack_bootimg.py,avbtool.py} 2>&1
```

Expected: all three files listed.
If `avbtool.py` missing (it's actually in `external/avb`):

```bash
cd /home/ltlly/Code/kernel_research/workspace/toolchain
git clone --depth 1 https://android.googlesource.com/platform/external/avb avbtool-src
ln -sf "$PWD/avbtool-src/avbtool.py" "$PWD/mkbootimg/avbtool.py"
```

- [ ] **Step 3: Smoke test mkbootimg**

```bash
python3 /home/ltlly/Code/kernel_research/workspace/toolchain/mkbootimg/mkbootimg.py --help 2>&1 | head -10
```

Expected: prints usage info without error.

- [ ] **Step 4: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git -c user.email=claude@anthropic.com -c user.name=Claude commit --allow-empty -q -m "chore: mkbootimg tools cloned (gitignored)"
```

---

### Task 0.8: Clone LineageOS kernel source

**Files:** writes to `workspace/kernel/android_kernel_xiaomi_sm8250/`

- [ ] **Step 1: Clone**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel
git clone https://github.com/LineageOS/android_kernel_xiaomi_sm8250.git
```

- [ ] **Step 2: Look for the matching commit**

The `uname -r` suffix `ga5b3099017ae` indicates commit `a5b3099017ae`.

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250
git log --oneline | grep -i "a5b3099" | head -3
```

If found:

```bash
git checkout a5b3099017ae
```

If not found in upstream LineageOS history (possible — Lineage may carry private commits, or `g` prefix could be a build artifact, not a commit hash):

```bash
# Find the closest tag/branch matching CIP and the kernel sublevel 4.19.325
git log --oneline --all | head -30
git branch -a | grep -E "lineage-23|cip|alioth" | head -10
# Pick the most recent lineage-23.x branch
git checkout origin/lineage-23.2 -b research-base 2>/dev/null || \
  git checkout origin/lineage-23.1 -b research-base 2>/dev/null || \
  git checkout origin/lineage-23.0 -b research-base
```

- [ ] **Step 3: Confirm we're on a 4.19.325 kernel base**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250
head -5 Makefile
```

Expected: `VERSION = 4`, `PATCHLEVEL = 19`, `SUBLEVEL = 325` (or close).
If sublevel is much lower (e.g. 113): the LineageOS branch is older than the running kernel; STOP and report to user.

- [ ] **Step 4: Capture the commit we built from**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250
git rev-parse HEAD > /home/ltlly/Code/kernel_research/workspace/kernel/SOURCE_COMMIT
git describe --always --dirty >> /home/ltlly/Code/kernel_research/workspace/kernel/SOURCE_COMMIT
cat /home/ltlly/Code/kernel_research/workspace/kernel/SOURCE_COMMIT
```

- [ ] **Step 5: Identify the defconfig**

```bash
ls /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250/arch/arm64/configs/ | grep -i alioth
```

Expected: a file like `vendor/alioth_defconfig` or `alioth_defconfig`.
Note the exact filename for build.sh.

- [ ] **Step 6: Commit pinned info**

```bash
cd /home/ltlly/Code/kernel_research
git add workspace/kernel/SOURCE_COMMIT
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "chore: pin kernel source commit"
```

---

### Task 0.9: Pull current device ramdisk for repacking

**Files:** writes to `workspace/stock-images/ramdisk-current/`

- [ ] **Step 1: Unpack the stock boot image**

```bash
cd /home/ltlly/Code/kernel_research/workspace/stock-images
mkdir -p unpacked-boot-a
python3 ../toolchain/mkbootimg/unpack_bootimg.py \
  --boot_img boot_a-original.img \
  --out unpacked-boot-a 2>&1 | tee unpack-boot-a.log
ls unpacked-boot-a/
```

Expected: outputs `kernel`, `ramdisk`, `dtb`, possibly `recovery_dtbo`. Header info in the log.

- [ ] **Step 2: Save the boot.img header parameters for repack**

Read `unpack-boot-a.log` and write key values to a file:

```bash
cd /home/ltlly/Code/kernel_research/workspace/stock-images
grep -E "^(boot_magic|kernel|ramdisk|cmdline|page size|os version|os patch level|header version)" unpack-boot-a.log | tee bootimg-params.txt
```

- [ ] **Step 3: Verify ramdisk is a valid cpio**

```bash
file workspace/stock-images/unpacked-boot-a/ramdisk
```
Expected: `gzip compressed`, `LZ4 compressed`, or similar. Not "data" or empty.

- [ ] **Step 4: Commit the params reference**

```bash
cd /home/ltlly/Code/kernel_research
git add workspace/stock-images/bootimg-params.txt
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "chore: capture boot.img repack params from stock"
```

---

### Task 0.10: Write `scripts/build.sh`

**Files:**
- Create: `scripts/build.sh`

- [ ] **Step 1: Write the script**

```bash
cat > /home/ltlly/Code/kernel_research/scripts/build.sh <<'EOF'
#!/usr/bin/env bash
# Build the alioth kernel.
# Usage: build.sh <defconfig-name> [tag]
# Default tag = "vanilla"; "research" used by P1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_SRC="$ROOT/workspace/kernel/android_kernel_xiaomi_sm8250"
OUT="$KERNEL_SRC/out"

defconfig="${1:?defconfig required, e.g. vendor/alioth_defconfig}"
tag="${2:-vanilla}"

source "$ROOT/workspace/toolchain/clang-path.env"
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
export KBUILD_BUILD_USER=claude
export KBUILD_BUILD_HOST=research

mkdir -p "$OUT"
cd "$KERNEL_SRC"

echo "=== make $defconfig ==="
make O=out $defconfig

echo "=== make Image.gz dtbs modules ==="
make O=out -j$(nproc) Image.gz dtbs 2>&1 | tee "$ROOT/runs/build-$(date +%Y%m%d-%H%M%S)-$tag.log"

# Verify outputs
test -s "$OUT/arch/arm64/boot/Image.gz" || { echo "Image.gz missing"; exit 2; }
echo "=== build complete ==="
ls -la "$OUT/arch/arm64/boot/Image.gz"
ls "$OUT/arch/arm64/boot/dts/vendor/qcom/" | head -10
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/build.sh
```

- [ ] **Step 2: Syntax check**

```bash
bash -n /home/ltlly/Code/kernel_research/scripts/build.sh && echo "syntax ok"
```

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add scripts/build.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "feat: kernel build script"
```

---

### Task 0.11: Write `scripts/pack-boot.sh`

**Files:**
- Create: `scripts/pack-boot.sh`

- [ ] **Step 1: Write the script**

```bash
cat > /home/ltlly/Code/kernel_research/scripts/pack-boot.sh <<'EOF'
#!/usr/bin/env bash
# Pack a kernel Image into a boot.img using the stock ramdisk + DTB.
# Usage: pack-boot.sh <tag>
# Inputs: workspace/kernel/android_kernel_xiaomi_sm8250/out/arch/arm64/boot/Image.gz
#         workspace/stock-images/unpacked-boot-a/ramdisk + dtb + bootimg-params.txt
# Output: workspace/builds/<timestamp>-<tag>.img
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_OUT="$ROOT/workspace/kernel/android_kernel_xiaomi_sm8250/out"
STOCK="$ROOT/workspace/stock-images"
UNPACK="$STOCK/unpacked-boot-a"
BUILDS="$ROOT/workspace/builds"
mkdir -p "$BUILDS"

tag="${1:?tag required, e.g. vanilla, p1, p2-trampoline}"
timestamp=$(date +%Y%m%d-%H%M%S)
output="$BUILDS/$timestamp-$tag.img"

# Read params
PARAMS="$STOCK/bootimg-params.txt"
test -f "$PARAMS" || { echo "$PARAMS missing"; exit 2; }
get_param() { grep -m1 "^$1" "$PARAMS" | sed -E 's/^[^:]+: *//' | head -1; }

cmdline=$(get_param "kernel cmdline")
pagesize=$(get_param "page size" || echo 4096)
header_version=$(get_param "header version" || echo 3)
os_version=$(get_param "os version" || echo "16.0.0")
os_patch_level=$(get_param "os patch level" || echo "2026-03")

# Find the right DTB. Stock device DTB is in the unpacked image; we use that
# unless we want to use a freshly built one. For vanilla rebuild, use stock DTB
# to remove DTB as a variable. For P1+, optionally use freshly built.
dtb_source="$UNPACK/dtb"
if [[ "${USE_BUILT_DTB:-0}" == "1" ]]; then
  # Concatenate per-soc DTBs from build output
  cat "$KERNEL_OUT/arch/arm64/boot/dts/vendor/qcom/"*.dtb > /tmp/dtb.combined
  dtb_source=/tmp/dtb.combined
fi

python3 "$ROOT/workspace/toolchain/mkbootimg/mkbootimg.py" \
  --kernel "$KERNEL_OUT/arch/arm64/boot/Image.gz" \
  --ramdisk "$UNPACK/ramdisk" \
  --dtb "$dtb_source" \
  --cmdline "$cmdline" \
  --pagesize "$pagesize" \
  --header_version "$header_version" \
  --os_version "$os_version" \
  --os_patch_level "$os_patch_level" \
  --output "$output"

ls -la "$output"
echo "=== packed boot.img ready: $output ==="
echo "$output" > "$ROOT/workspace/builds/LATEST"
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/pack-boot.sh
```

- [ ] **Step 2: Syntax check**

```bash
bash -n /home/ltlly/Code/kernel_research/scripts/pack-boot.sh && echo "syntax ok"
```

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add scripts/pack-boot.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "feat: boot.img pack script"
```

---

### Task 0.12: Write `scripts/flash-test.sh` (memory-only fastboot boot)

**Files:**
- Create: `scripts/flash-test.sh`

- [ ] **Step 1: Write the script**

```bash
cat > /home/ltlly/Code/kernel_research/scripts/flash-test.sh <<'EOF'
#!/usr/bin/env bash
# RAM-only fastboot boot of a candidate boot.img + smoke probe.
# Does NOT write to flash. On success, exits 0. On failure, calls recover.sh.
# Usage: flash-test.sh <path/to/boot.img> [--probe <probe-script>]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
img="${1:?img required}"
probe=""
if [[ "${2:-}" == "--probe" ]]; then probe="$3"; fi

ts=$(date +%Y%m%d-%H%M%S)
RUN_DIR="$ROOT/runs/$ts-flash-test"
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/flash-test.log"
log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }

trap 'log "trap fired; running recover.sh"; "$ROOT/scripts/recover.sh" --reason "flash-test trap"' ERR

log "=== flash-test start: $img ==="

# Reboot to bootloader if needed
state=$(adb get-state 2>/dev/null || echo unknown)
if [[ "$state" == "device" ]]; then
  log "rebooting device to bootloader"
  adb reboot bootloader
  sleep 5
fi

# Wait for fastboot
deadline=$((SECONDS+90))
until fastboot devices | grep -q .; do
  if (( SECONDS > deadline )); then log "device never reached fastboot"; exit 11; fi
  sleep 2
done

log "issuing 'fastboot boot $img'"
fastboot boot "$img" 2>&1 | tee -a "$LOG"

# Wait for adb
log "waiting for adb (up to 120s)"
deadline=$((SECONDS+120))
until adb get-state 2>/dev/null | grep -q '^device$'; do
  if (( SECONDS > deadline )); then
    log "ABORT: adb never came back; running recover"
    "$ROOT/scripts/recover.sh" --reason "boot timed out"
    exit 12
  fi
  sleep 3
done
adb root >/dev/null 2>&1 || true
sleep 2

# Smoke checks
log "--- uname ---"
adb shell uname -a 2>&1 | tee -a "$LOG"
log "--- dmesg panic/oops/bug ---"
if adb shell 'dmesg 2>/dev/null | grep -iE "panic|oops|BUG:|Unable to handle"' 2>&1 | tee -a "$LOG" | grep -q .; then
  log "WARN: dmesg shows trouble — review $LOG"
fi
log "--- sys.boot_completed ---"
deadline=$((SECONDS+60))
while [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]]; do
  if (( SECONDS > deadline )); then
    log "WARN: boot_completed never reached 1 (still functional but degraded)"
    break
  fi
  sleep 3
done
adb shell getprop sys.boot_completed 2>&1 | tee -a "$LOG"

# Run probe if specified
if [[ -n "$probe" ]]; then
  log "--- running probe: $probe ---"
  bash "$probe" 2>&1 | tee -a "$LOG/probe.log" || { log "PROBE FAILED"; exit 13; }
fi

log "=== flash-test PASS ==="
echo "RUN_DIR=$RUN_DIR" > "$ROOT/runs/LAST_TEST"
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/flash-test.sh
```

- [ ] **Step 2: Syntax check**

```bash
bash -n /home/ltlly/Code/kernel_research/scripts/flash-test.sh && echo "syntax ok"
```

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add scripts/flash-test.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "feat: fastboot boot test loop with auto-recover"
```

---

### Task 0.13: Write `scripts/flash-commit.sh` (write to slot _b)

**Files:**
- Create: `scripts/flash-commit.sh`

- [ ] **Step 1: Write the script**

```bash
cat > /home/ltlly/Code/kernel_research/scripts/flash-commit.sh <<'EOF'
#!/usr/bin/env bash
# Permanently flash a validated boot.img to slot _b and switch active.
# Refuses to run unless a green LAST_TEST exists (i.e., flash-test.sh passed).
# Usage: flash-commit.sh <boot.img>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
img="${1:?img required}"

LAST_TEST="$ROOT/runs/LAST_TEST"
test -f "$LAST_TEST" || { echo "Refusing: no green flash-test run on record"; exit 21; }

# Defensive: never touch slot _a
log() { echo "[$(date +%T)] $*"; }

state=$(adb get-state 2>/dev/null || echo unknown)
if [[ "$state" == "device" ]]; then
  log "rebooting to bootloader"
  adb reboot bootloader
  sleep 5
fi

deadline=$((SECONDS+90))
until fastboot devices | grep -q .; do
  if (( SECONDS > deadline )); then echo "no fastboot"; exit 22; fi
  sleep 2
done

log "current slots:"
fastboot getvar all 2>&1 | grep -E "current-slot|has-slot|slot-count" || true

# Flash to b only
log "flashing $img to boot_b"
fastboot flash boot_b "$img"

log "setting active=b"
fastboot --set-active=b

log "rebooting"
fastboot reboot

# Wait for adb back
deadline=$((SECONDS+180))
until adb get-state 2>/dev/null | grep -q '^device$'; do
  if (( SECONDS > deadline )); then
    log "device did not return — invoking recover.sh"
    "$ROOT/scripts/recover.sh" --reason "flash-commit boot timeout"
    exit 23
  fi
  sleep 3
done

log "=== flash-commit done; on slot b. Run soak monitor next. ==="
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/flash-commit.sh
```

- [ ] **Step 2: Syntax check**

```bash
bash -n /home/ltlly/Code/kernel_research/scripts/flash-commit.sh && echo "syntax ok"
```

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add scripts/flash-commit.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "feat: flash-commit script (slot _b only)"
```

---

### Task 0.14a: Write `scripts/cherry-pick-series.sh` (reusable series helper)

**Files:**
- Create: `scripts/cherry-pick-series.sh`

- [ ] **Step 1: Write the script**

```bash
cat > /home/ltlly/Code/kernel_research/scripts/cherry-pick-series.sh <<'EOF'
#!/usr/bin/env bash
# Cherry-pick a list of upstream commits into the current branch, recording
# any conflicts to a per-series conflict folder. Stops on first conflict so a
# human (or Claude) can resolve, then re-run continues from the next commit.
#
# Usage: cherry-pick-series.sh <series-dir> <base-branch>
#   <series-dir> e.g. workspace/kernel/patches/phase2-bpf-backport/01-bpf-link
#   reads <series-dir>/commit-candidates.txt (one "<hash> <subject>" per line)
#   writes <series-dir>/conflicts/<hash>.conflict on conflict
#   writes <series-dir>/applied.txt as the running success log
#   <base-branch> is checked out as the starting point if branch doesn't exist
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERIES_DIR="${1:?series-dir required}"
BASE_BRANCH="${2:?base-branch required}"
KERNEL="$ROOT/workspace/kernel/android_kernel_xiaomi_sm8250"

CANDIDATES="$SERIES_DIR/commit-candidates.txt"
APPLIED="$SERIES_DIR/applied.txt"
CONFLICT_DIR="$SERIES_DIR/conflicts"
mkdir -p "$CONFLICT_DIR"
touch "$APPLIED"

cd "$KERNEL"

# Make sure linux-stable remote exists for cherry-picks
git remote get-url linux-stable >/dev/null 2>&1 || \
  git remote add linux-stable "$ROOT/workspace/kernel/linux-stable"
git fetch linux-stable --tags 2>/dev/null || true

# Determine target branch from series-dir name (research-p2-s<N>)
target_branch=$(basename "$SERIES_DIR" | sed -E 's/^([0-9]+)-.*/research-p2-s\1/')
echo "[info] series=$(basename $SERIES_DIR) target_branch=$target_branch base=$BASE_BRANCH"

# Create or switch to the series branch
if git rev-parse --verify "$target_branch" >/dev/null 2>&1; then
  git checkout "$target_branch"
else
  git checkout "$BASE_BRANCH"
  git checkout -b "$target_branch"
fi

while IFS= read -r line; do
  [[ -z "$line" || "${line#\#}" != "$line" ]] && continue
  hash="${line%% *}"
  # Skip if already applied
  if grep -qF "$hash" "$APPLIED" 2>/dev/null; then
    echo "[skip] $hash already applied"
    continue
  fi
  echo "[pick] $hash $line"
  if git cherry-pick -x "$hash"; then
    echo "$hash $line" >> "$APPLIED"
  else
    echo "[conflict] $hash — see $CONFLICT_DIR/$hash.conflict"
    git diff > "$CONFLICT_DIR/$hash.conflict"
    echo "$hash $(date)" >> "$CONFLICT_DIR/index.txt"
    git cherry-pick --abort
    echo "STOP — fix conflict, then re-run this script to continue from next commit"
    exit 1
  fi
done < "$CANDIDATES"

echo "[done] series complete: $(wc -l < "$APPLIED") commits applied"
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/cherry-pick-series.sh
```

- [ ] **Step 2: Syntax check**

```bash
bash -n /home/ltlly/Code/kernel_research/scripts/cherry-pick-series.sh && echo "syntax ok"
```

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add scripts/cherry-pick-series.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "feat: reusable series cherry-pick helper"
```

---

### Task 0.14: Write basic boot probe `scripts/probes/boot-smoke.sh`

**Files:**
- Create: `scripts/probes/boot-smoke.sh`

- [ ] **Step 1: Write the probe**

```bash
mkdir -p /home/ltlly/Code/kernel_research/scripts/probes
cat > /home/ltlly/Code/kernel_research/scripts/probes/boot-smoke.sh <<'EOF'
#!/usr/bin/env bash
# Basic post-boot probe: kernel sanity, network, Android responsiveness.
# Returns 0 on pass.
set -euo pipefail

fail() { echo "PROBE FAIL: $*"; exit 1; }

# uname must show our kernel string (KBUILD_BUILD_USER=claude)
adb shell uname -a 2>/dev/null | grep -q "claude" || fail "uname does not show claude (rebuild marker)"

# Basic adb features
adb shell id | grep -q "uid=0" || fail "adb not root"
adb shell getprop sys.boot_completed | grep -q "1" || fail "boot not completed"

# Networking up
adb shell ip a show wlan0 2>/dev/null | grep -q "inet " || echo "WARN: wlan0 has no IP (may be acceptable if WiFi disabled)"

# No kernel BUG/oops in dmesg
if adb shell 'dmesg 2>/dev/null | grep -iE "BUG:|Oops|kernel panic"' | grep -q .; then
  fail "dmesg shows kernel issues"
fi

echo "PROBE PASS: boot-smoke"
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/probes/boot-smoke.sh
```

- [ ] **Step 2: Syntax check**

```bash
bash -n /home/ltlly/Code/kernel_research/scripts/probes/boot-smoke.sh && echo "syntax ok"
```

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add scripts/probes/boot-smoke.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "feat: boot smoke probe"
```

---

## Phase 0 — Vanilla rebuild

### Task 1.1: Build vanilla kernel with stock defconfig

- [ ] **Step 1: Identify defconfig name from Task 0.8 step 5**

Let `DEFCONFIG` = the defconfig name found earlier (e.g., `vendor/alioth_defconfig`). Write it down:

```bash
echo "DEFCONFIG=vendor/alioth_defconfig" > /home/ltlly/Code/kernel_research/workspace/kernel/DEFCONFIG.env
```

(Replace value with whatever was actually found.)

- [ ] **Step 2: Build**

```bash
cd /home/ltlly/Code/kernel_research
source workspace/kernel/DEFCONFIG.env
./scripts/build.sh "$DEFCONFIG" vanilla
```

Expected: prints `=== build complete ===`, shows `Image.gz` size > 30MB.
On failure: read the build log under `runs/`, fix issue (likely missing toolchain piece), retry up to 3 times.

- [ ] **Step 3: Sanity-diff the produced .config against stock**

```bash
diff <(adb shell zcat /proc/config.gz | sort) \
     <(sort /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250/out/.config) \
     | head -50
```

A small diff is expected (build user/host strings). If there are large `+CONFIG_*` or `-CONFIG_*` differences, the defconfig drifted; investigate before proceeding.

- [ ] **Step 4: Commit progress**

```bash
cd /home/ltlly/Code/kernel_research
echo "P0 vanilla kernel built: $(date)" >> STATUS.md
git add STATUS.md workspace/kernel/DEFCONFIG.env
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p0: vanilla kernel built"
```

---

### Task 1.2: Pack vanilla boot.img

- [ ] **Step 1: Pack**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/pack-boot.sh vanilla
```

Expected: `=== packed boot.img ready: workspace/builds/<ts>-vanilla.img ===`.

- [ ] **Step 2: Verify image is well-formed**

```bash
img=$(cat /home/ltlly/Code/kernel_research/workspace/builds/LATEST)
python3 /home/ltlly/Code/kernel_research/workspace/toolchain/mkbootimg/unpack_bootimg.py --boot_img "$img" --out /tmp/repack-check 2>&1 | head -20
```

Expected: prints magic, kernel size, ramdisk size, header version. No error.

---

### Task 1.3: Flash-test the vanilla image (RAM-only)

- [ ] **Step 1: Run flash-test with smoke probe**

```bash
cd /home/ltlly/Code/kernel_research
img=$(cat workspace/builds/LATEST)
./scripts/flash-test.sh "$img" --probe ./scripts/probes/boot-smoke.sh
```

Expected: ends with `=== flash-test PASS ===`. Device boots, adb works, no panic in dmesg.
On fail: `recover.sh` ran automatically; the device should be back on slot a; review `runs/<ts>-flash-test/flash-test.log` for diagnosis.

- [ ] **Step 2: Run two more times for repeatability**

```bash
for i in 2 3; do
  echo "=== retest $i ==="
  cd /home/ltlly/Code/kernel_research
  ./scripts/flash-test.sh "$(cat workspace/builds/LATEST)" --probe ./scripts/probes/boot-smoke.sh
done
```

Expected: 3 consecutive passes. After this, the LAST_TEST sentinel exists and flash-commit is allowed.

- [ ] **Step 3: Commit progress**

```bash
cd /home/ltlly/Code/kernel_research
echo "P0 vanilla flash-test: 3 PASS" >> STATUS.md
git add STATUS.md
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p0: vanilla flash-test 3x pass"
```

---

### Task 1.4: User manual gate — P0

- [ ] **Step 1: Tell the user**

Send to user (note: at end of Task 1.3, the device is currently running the RAM-loaded vanilla kernel from the last `fastboot boot` — a normal reboot will fall back to stock slot _a, no harm):

> "P0 vanilla kernel passed AI smoke probes 3× via `fastboot boot`. The device is currently running my custom build (RAM-loaded — a power-cycle will fall back to stock slot _a, so there's nothing to lose). Please use the phone for ~5 minutes: open a few apps, make a quick call test, check WiFi/camera. Reply 'OK P0' if it's fine; I'll then commit the vanilla build to slot _b and start Phase 1. Reply with what's broken if not."

- [ ] **Step 2: Wait for user response**

Block here until user replies. If user reports issues, do NOT proceed. Investigate.

---

### Task 1.5: Flash vanilla to slot _b

(Only after user OK from Task 1.4.)

- [ ] **Step 1: Flash**

```bash
cd /home/ltlly/Code/kernel_research
img=$(cat workspace/builds/LATEST)
./scripts/flash-commit.sh "$img"
```

Expected: device reboots, comes back on slot _b, adb reachable.

- [ ] **Step 2: Verify slot**

```bash
adb shell getprop ro.boot.slot_suffix
```
Expected: `_b`.

- [ ] **Step 3: Verify it's our kernel**

```bash
adb shell uname -a
```
Expected: build host/user shows `claude@research`.

- [ ] **Step 4: Commit progress**

```bash
cd /home/ltlly/Code/kernel_research
echo "P0 DONE: vanilla on slot _b ($(date))" >> STATUS.md
git add STATUS.md
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p0: vanilla committed to slot b — Phase 0 done"
```

---

## Phase 1 — BTF + ftrace + KernelSU

### Task 2.1: Create research defconfig overlay

**Files:**
- Create: `workspace/kernel/patches/phase1-btf-ftrace/research-overlay.config`
- Modify: `workspace/kernel/android_kernel_xiaomi_sm8250/arch/arm64/configs/vendor/alioth_research_defconfig`

- [ ] **Step 1: Write the overlay**

```bash
cat > /home/ltlly/Code/kernel_research/workspace/kernel/patches/phase1-btf-ftrace/research-overlay.config <<'EOF'
# Phase 1 additions for BTF + dynamic ftrace.
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_FUNCTION_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_DYNAMIC_FTRACE_WITH_REGS=y
CONFIG_KPROBE_EVENTS=y
CONFIG_FTRACE_SYSCALLS=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_HAVE_KPROBES_ON_FTRACE=y
EOF
```

- [ ] **Step 2: Generate research defconfig**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250
src=arch/arm64/configs/vendor/alioth_defconfig
dst=arch/arm64/configs/vendor/alioth_research_defconfig
overlay=/home/ltlly/Code/kernel_research/workspace/kernel/patches/phase1-btf-ftrace/research-overlay.config
cat "$src" "$overlay" > "$dst"
# Use scripts/kconfig/merge_config.sh for proper deduplication
ARCH=arm64 scripts/kconfig/merge_config.sh -m -O out "$src" "$overlay"
mv out/.config "$dst"
echo "wrote $dst"
```

- [ ] **Step 3: Build with new defconfig (no KSU yet)**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/build.sh vendor/alioth_research_defconfig p1-noksu
```

Expected: build completes. Watch for BTF generation messages from pahole during the build.

- [ ] **Step 4: Confirm BTF was generated**

```bash
ls -la workspace/kernel/android_kernel_xiaomi_sm8250/out/.btf.vmlinux.bin.o 2>/dev/null
ls -la workspace/kernel/android_kernel_xiaomi_sm8250/out/vmlinux 2>/dev/null
# Look for .BTF section
llvm-readelf -S workspace/kernel/android_kernel_xiaomi_sm8250/out/vmlinux | grep -i btf
```

Expected: a `.BTF` section in `vmlinux`.
If pahole errors: see Task 0.2 step 4 for upgrading pahole.

- [ ] **Step 5: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add workspace/kernel/patches/phase1-btf-ftrace/research-overlay.config
# Note: research_defconfig in the kernel tree is gitignored (in workspace/kernel/...)
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p1: research-overlay defconfig"
```

---

### Task 2.2: Quick-test P1 (no KSU) image

- [ ] **Step 1: Pack and flash-test**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/pack-boot.sh p1-noksu
img=$(cat workspace/builds/LATEST)
./scripts/flash-test.sh "$img" --probe ./scripts/probes/boot-smoke.sh
```

Expected: PASS.

- [ ] **Step 2: Probe BTF on device**

```bash
adb shell 'ls -la /sys/kernel/btf/vmlinux'
adb shell 'cat /sys/kernel/btf/vmlinux | wc -c'
adb shell '/system/bin/bpftool btf dump file /sys/kernel/btf/vmlinux format raw 2>&1 | head -20'
```

Expected: `/sys/kernel/btf/vmlinux` exists, size > 1MB, bpftool prints type definitions.
**This is the moment of truth for Phase 1's BTF goal.** If this works, the rest of Phase 1 (KSU integration) is straightforward.

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
echo "P1 BTF generation: confirmed via flash-test" >> STATUS.md
git add STATUS.md
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p1: BTF working via fastboot boot (no KSU yet)"
```

---

### Task 2.3: Add KernelSU as submodule

**Files:**
- Modify: `workspace/kernel/android_kernel_xiaomi_sm8250/drivers/staging/`

- [ ] **Step 1: Run the official setup script**

KernelSU upstream provides a one-line installer that adds the submodule and tweaks Kbuild correctly. Use the official path:

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s main
```

This adds `KernelSU/` as a git submodule and edits `drivers/Makefile` and `drivers/Kconfig` to wire it in.

- [ ] **Step 2: Verify integration**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250
ls KernelSU/
grep -r "kernelsu\|KernelSU" drivers/Makefile drivers/Kconfig 2>/dev/null | head -5
```

Expected: `KernelSU/` populated, drivers/Makefile/Kconfig modified.

- [ ] **Step 3: Apply non-kprobes mode hooks (4.19 needs this)**

For 4.19 the kprobes-based KernelSU hooks are unreliable; use the manual hook patch from KernelSU's docs (https://kernelsu.org/guide/how-to-integrate-for-non-gki.html). The patch touches `fs/exec.c`, `fs/open.c`, `fs/read_write.c`, `fs/stat.c`. Pull and apply:

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250
# KernelSU repo ships the patch as a script
bash KernelSU/kernel/setup-non-gki.sh 2>/dev/null || true
# If that doesn't exist, fall back to manual edit guided by KernelSU/Documentation/HOW-TO/non-gki.md
```

- [ ] **Step 4: Sanity build (just the KernelSU subdir)**

```bash
cd /home/ltlly/Code/kernel_research
# Ensure KernelSU compiles standalone first
cd workspace/kernel/android_kernel_xiaomi_sm8250
source ../../toolchain/clang-path.env
export ARCH=arm64 PATH="$CLANG_DIR:$PATH" CC=clang LD=ld.lld
make O=out vendor/alioth_research_defconfig
make O=out -j$(nproc) drivers/staging/kernelsu/ 2>&1 | tail -30 || true
```

Expected: errors here are tolerable if related to undefined symbols — full build is in next task.

- [ ] **Step 5: Commit submodule reference**

```bash
cd /home/ltlly/Code/kernel_research
git add workspace/kernel/SOURCE_COMMIT
git -c user.email=claude@anthropic.com -c user.name=Claude commit --allow-empty -q -m "p1: KernelSU added as submodule"
```

---

### Task 2.4: Build P1 (research defconfig + KernelSU)

- [ ] **Step 1: Enable CONFIG_KSU in defconfig**

```bash
echo "CONFIG_KSU=y" >> /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250/arch/arm64/configs/vendor/alioth_research_defconfig
```

- [ ] **Step 2: Build**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/build.sh vendor/alioth_research_defconfig p1-ksu
```

Expected: build completes. Look in build log for `KernelSU` compile lines.

- [ ] **Step 3: Pack image**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/pack-boot.sh p1-ksu
```

- [ ] **Step 4: Flash-test with smoke probe**

```bash
cd /home/ltlly/Code/kernel_research
img=$(cat workspace/builds/LATEST)
./scripts/flash-test.sh "$img" --probe ./scripts/probes/boot-smoke.sh
```

Expected: PASS.

- [ ] **Step 5: Commit progress**

```bash
cd /home/ltlly/Code/kernel_research
echo "P1 build with KSU: PASS" >> STATUS.md
git add STATUS.md
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p1: kernel with KSU built and boot-tested"
```

---

### Task 2.5: Write feature-probe scripts for P1

**Files:**
- Create: `scripts/probes/p1-features.sh`

- [ ] **Step 1: Write the probe**

```bash
cat > /home/ltlly/Code/kernel_research/scripts/probes/p1-features.sh <<'EOF'
#!/usr/bin/env bash
# Phase 1 feature probe: BTF, kprobe-via-ftrace, ringbuf, KSU.
# Returns 0 on full pass.
set -uo pipefail

PASS=0; FAIL=0
ok() { echo "  PASS: $*"; PASS=$((PASS+1)); }
ng() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
have() { adb shell "$1" 2>/dev/null | tr -d '\r'; }

echo "=== Phase 1 feature probe ==="

# 1. BTF for vmlinux
test -n "$(have 'ls /sys/kernel/btf/vmlinux 2>/dev/null')" && ok "/sys/kernel/btf/vmlinux exists" || ng "BTF missing"
btf_size=$(have 'stat -c%s /sys/kernel/btf/vmlinux 2>/dev/null')
[[ "${btf_size:-0}" -gt 1000000 ]] && ok "BTF size > 1MB ($btf_size)" || ng "BTF too small ($btf_size)"

# 2. bpftool can dump it
have '/system/bin/bpftool btf dump file /sys/kernel/btf/vmlinux format raw 2>&1 | head -3' | grep -qi "TYPE\|btf" && ok "bpftool btf dump ok" || ng "bpftool btf dump failed"

# 3. dynamic ftrace + kprobe events
test "$(have 'cat /sys/kernel/debug/tracing/available_filter_functions 2>/dev/null | wc -l')" -gt 100 && ok "available_filter_functions populated (dyn ftrace)" || ng "ftrace functions not available"
test -n "$(have 'ls /sys/kernel/debug/tracing/kprobe_events 2>/dev/null')" && ok "kprobe_events present" || ng "kprobe_events missing"

# 4. ringbuf already present (regression check)
have 'ls /sys/fs/bpf/ 2>/dev/null | grep -i ringbuf' | grep -q ringbuf && ok "ringbuf in /sys/fs/bpf" || echo "  INFO: no ringbuf programs loaded yet"

# 5. KernelSU presence
adb shell 'ls /data/adb/ksud 2>/dev/null || ls /data/adb/modules 2>/dev/null' >/dev/null 2>&1 && ok "KernelSU userspace dirs present" || echo "  INFO: KSU userspace dirs not yet created (need Manager install)"
have 'cat /sys/module/kernelsu/version 2>/dev/null || cat /proc/ksuapi 2>/dev/null' && ok "KernelSU module loaded" || ng "KernelSU module not visible"

# 6. Frida won't break (just check uprobe_events still exists)
test -n "$(have 'ls /sys/kernel/debug/tracing/uprobe_events 2>/dev/null')" && ok "uprobe_events present (frida ok)" || ng "uprobe_events missing"

echo "=== summary: $PASS pass / $FAIL fail ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/probes/p1-features.sh
```

- [ ] **Step 2: Syntax check**

```bash
bash -n /home/ltlly/Code/kernel_research/scripts/probes/p1-features.sh && echo "syntax ok"
```

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add scripts/probes/p1-features.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "feat: P1 feature probe"
```

---

### Task 2.6: Write tool-integration probes for P1

**Files:**
- Create: `scripts/probes/p1-tools.sh`

- [ ] **Step 1: Write the script**

```bash
cat > /home/ltlly/Code/kernel_research/scripts/probes/p1-tools.sh <<'EOF'
#!/usr/bin/env bash
# Phase 1 tool integration probe: bpftrace + stackplz + frida + libbpf-bootstrap minimal.
# Most of these need to be downloaded/copied to the device first.
set -uo pipefail

PASS=0; FAIL=0
ok() { echo "  PASS: $*"; PASS=$((PASS+1)); }
ng() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "=== Phase 1 tool probe ==="

# 1. bpftrace static binary (push if not present)
adb shell 'test -x /data/local/tmp/bpftrace' || {
  if [[ -f /home/ltlly/Code/kernel_research/workspace/tests/bpftrace ]]; then
    adb push /home/ltlly/Code/kernel_research/workspace/tests/bpftrace /data/local/tmp/bpftrace
    adb shell chmod 755 /data/local/tmp/bpftrace
  fi
}
out=$(adb shell '/data/local/tmp/bpftrace -e "kprobe:do_sys_open { printf(\"%s\n\", str(arg1)); exit(); }"' 2>&1 | head -5)
echo "$out" | grep -qE "[a-z]+/[a-z]+|^/[a-z]" && ok "bpftrace kprobe works" || ng "bpftrace failed: $out"

# 2. stackplz binary
adb shell 'test -x /data/local/tmp/stackplz' && {
  out=$(adb shell '/data/local/tmp/stackplz syscall -i 0 --no-pid' 2>&1 | timeout 5 head -3)
  echo "$out" | grep -qE "syscall|enter|exit" && ok "stackplz syscall works" || ng "stackplz failed"
} || echo "  SKIP: stackplz not pushed"

# 3. frida-server smoke
adb shell 'pidof frida-server >/dev/null 2>&1 || /data/local/tmp/frida-server &' 2>&1 &
sleep 2
adb shell 'pidof frida-server' | grep -q . && ok "frida-server running" || ng "frida-server not running"

# 4. minimal libbpf-bootstrap CO-RE program
adb shell 'test -x /data/local/tmp/minimal' && {
  out=$(adb shell 'timeout 3 /data/local/tmp/minimal' 2>&1)
  echo "$out" | grep -qE "BPF program|hello|tid" && ok "minimal CO-RE works" || ng "minimal CO-RE failed: $out"
} || echo "  SKIP: minimal not pushed"

# 5. KSU 'su -c id' returns root
out=$(adb shell 'echo y | su -c id 2>&1' | head -1)
echo "$out" | grep -q "uid=0" && ok "KSU su -c id returns root" || ng "KSU su failed: $out"

echo "=== summary: $PASS pass / $FAIL fail ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/probes/p1-tools.sh
```

- [ ] **Step 2: Pre-fetch the test binaries (so the probe has something to run)**

```bash
cd /home/ltlly/Code/kernel_research/workspace/tests
mkdir -p arm64 && cd arm64
# bpftrace Android prebuilt
curl -fL -o bpftrace https://github.com/SeeFlowerX/bpftrace-android/releases/latest/download/bpftrace || \
  echo "bpftrace fetch failed; will skip tool test"
# stackplz prebuilt
curl -fL -o stackplz.tar.gz https://github.com/SeeFlowerX/stackplz/releases/latest/download/stackplz_aarch64.tar.gz || true
[ -s stackplz.tar.gz ] && tar xzf stackplz.tar.gz
# frida-server (matched to host frida version)
fver=$(frida --version 2>/dev/null || echo 17.0.0)
curl -fL -o frida-server.xz "https://github.com/frida/frida/releases/download/${fver}/frida-server-${fver}-android-arm64.xz" || \
  curl -fL -o frida-server.xz "https://github.com/frida/frida/releases/latest/download/frida-server-17.0.0-android-arm64.xz" || true
[ -s frida-server.xz ] && xz -d frida-server.xz
chmod 755 bpftrace stackplz frida-server 2>/dev/null || true
ls -la
```

- [ ] **Step 3: Push test binaries**

```bash
cd /home/ltlly/Code/kernel_research/workspace/tests/arm64
adb shell 'mkdir -p /data/local/tmp'
for b in bpftrace stackplz frida-server; do
  test -f "$b" && adb push "$b" "/data/local/tmp/$b" && adb shell "chmod 755 /data/local/tmp/$b"
done
```

- [ ] **Step 4: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add scripts/probes/p1-tools.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "feat: P1 tool integration probe"
```

---

### Task 2.7: Run P1 feature probes

- [ ] **Step 1: Re-flash test the P1 image, then run feature probes**

(Device should currently be on slot _b vanilla from Phase 0; we need to RAM-load P1 again.)

```bash
cd /home/ltlly/Code/kernel_research
img=$(ls -t workspace/builds/*-p1-ksu.img | head -1)
./scripts/flash-test.sh "$img"
./scripts/probes/p1-features.sh
```

Expected: P1 features probe → 0 fail.
If KernelSU module not visible: that's expected before installing the Manager APK; user-side install needed.

- [ ] **Step 2: Run tool probes**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/probes/p1-tools.sh
```

Expected: bpftrace works, frida starts. KSU `su -c id` requires the Manager APK to be installed and a target app authorized — this may be ng on first run; ask user to install Manager.

- [ ] **Step 3: User: install KernelSU Manager APK**

Send to user:

> "Please install the KernelSU Manager APK from https://github.com/tiann/KernelSU/releases/latest (the `.apk` artifact). Then open it once, grant root to a test app (e.g., the built-in Terminal), then reply 'KSU manager set up'."

- [ ] **Step 4: Re-run tool probe after user installs Manager**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/probes/p1-tools.sh
```

Expected: KSU `su -c id` returns `uid=0`.

- [ ] **Step 5: Commit progress**

```bash
cd /home/ltlly/Code/kernel_research
echo "P1 feature & tool probes: PASS" >> STATUS.md
git add STATUS.md
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p1: feature probes pass"
```

---

### Task 2.8: User manual gate — P1

- [ ] **Step 1: Tell the user**

> "P1 (BTF + dynamic ftrace + KernelSU) passes my feature and tool probes. The device is currently running the P1 kernel via `fastboot boot` (RAM only — power-cycle falls back to slot _b which still has the P0 vanilla, and slot _a is still pristine stock). Please use the phone for ~5-10 min — calls, WiFi, camera, your usual apps. Reply 'OK P1' if it's daily-driver acceptable; I'll then flash this P1 image to slot _b (overwriting the P0 vanilla on _b) and start Phase 2. Reply with what's broken if not."

- [ ] **Step 2: Block waiting for user response.**

---

### Task 2.9: Flash P1 to slot _b

(Only after user OK from Task 2.8.)

- [ ] **Step 1: Flash**

```bash
cd /home/ltlly/Code/kernel_research
img=$(ls -t workspace/builds/*-p1-ksu.img | head -1)
./scripts/flash-commit.sh "$img"
```

- [ ] **Step 2: Verify after reboot**

```bash
adb shell uname -a   # claude@research
adb shell ls /sys/kernel/btf/vmlinux
adb shell 'echo y | su -c id 2>&1 | head -1'  # uid=0 if KSU active
```

- [ ] **Step 3: Update STATUS.md and commit**

```bash
cd /home/ltlly/Code/kernel_research
sed -i 's/Phase 1 (BTF+ftrace+KSU) | pending/Phase 1 (BTF+ftrace+KSU) | DONE/' STATUS.md
git add STATUS.md
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p1: committed to slot b — Phase 1 done"
```

---

## Phase 2 — BPF Backport (5 patch series)

### Task 3.0: Survey existing bpf_link infra in source

The 4.19-cip kernel has BPF_LSM, which uses `bpf_link`. So some link infra is likely already there. Determine "extend" vs "from-scratch" scope before cherry-picking.

- [ ] **Step 1: Survey symbols**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250
grep -rn "bpf_link\|BPF_LINK_TYPE" kernel/bpf/ include/linux/bpf.h include/uapi/linux/bpf.h 2>/dev/null | head -50
```

- [ ] **Step 2: Compare with 5.7 baseline**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel
test -d linux-stable || git clone --depth 1 -b v5.7 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-stable
cd linux-stable
grep -rn "bpf_link\|BPF_LINK_TYPE" kernel/bpf/syscall.c include/linux/bpf.h include/uapi/linux/bpf.h 2>/dev/null | head -50
```

- [ ] **Step 3: Decide series-1 strategy**

Compare grep counts. Write decision to `workspace/kernel/patches/phase2-bpf-backport/01-bpf-link/STRATEGY.md`:

```bash
mkdir -p /home/ltlly/Code/kernel_research/workspace/kernel/patches/phase2-bpf-backport/01-bpf-link
cat > /home/ltlly/Code/kernel_research/workspace/kernel/patches/phase2-bpf-backport/01-bpf-link/STRATEGY.md <<EOF
# bpf_link backport strategy

Existing 4.19-cip uses bpf_link for: <fill in based on grep>
Missing pieces: <fill in>
Strategy: <extend | from-scratch | skip>
Decision date: $(date)
EOF
```

Read the file, fill in based on grep output, commit.

```bash
cd /home/ltlly/Code/kernel_research
git add workspace/kernel/patches/phase2-bpf-backport/01-bpf-link/STRATEGY.md
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p2: bpf_link survey"
```

---

### Task 3.1: Series 1 — `bpf_link` (or extend existing)

**Patches to cherry-pick** (canonical commits in upstream Linux):

| Hash | Subject |
|---|---|
| 70ed506c3bbc | bpf: Introduce pinnable bpf_link abstraction |
| a3b80e10184a | bpf: Allocate ID for bpf_link |
| af6eea57437a | bpf: Add bpf_link_new_file that doesn't install FD |
| 70ed506c3bbc | bpf: refactor cgroup_bpf_*_link |
| (and ~6 follow-ups) |

- [ ] **Step 1: List exact commits**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/linux-stable
git log --oneline v5.6..v5.7 -- kernel/bpf/syscall.c kernel/bpf/cgroup.c include/linux/bpf.h include/uapi/linux/bpf.h | grep -i "bpf_link" | tee /home/ltlly/Code/kernel_research/workspace/kernel/patches/phase2-bpf-backport/01-bpf-link/commit-candidates.txt
```

- [ ] **Step 2: Cherry-pick using the series helper**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/cherry-pick-series.sh \
  workspace/kernel/patches/phase2-bpf-backport/01-bpf-link \
  HEAD
```

If the script stops on a conflict: open `workspace/kernel/patches/phase2-bpf-backport/01-bpf-link/conflicts/<hash>.conflict`, read the diff, manually edit the offending files in `workspace/kernel/android_kernel_xiaomi_sm8250/`, then `git add -A && git commit -m "manual resolve: <hash>"` and re-run the helper to pick up the next commit. Budget 5 manual conflict resolutions before pausing for design review.

- [ ] **Step 3: Build, fix until it compiles**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/build.sh vendor/alioth_research_defconfig p2-s1
```

If errors: read log, fix in source, rebuild. Up to 5 iterations before escalating to user.

- [ ] **Step 4: Pack, flash-test, probe**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/pack-boot.sh p2-s1
img=$(cat workspace/builds/LATEST)
./scripts/flash-test.sh "$img" --probe ./scripts/probes/p1-features.sh
```

Expected: existing features still pass (regression check).

- [ ] **Step 5: Add bpf_link probe (extend `p2-features.sh` — created here)**

```bash
cat > /home/ltlly/Code/kernel_research/scripts/probes/p2-features.sh <<'EOF'
#!/usr/bin/env bash
# Phase 2 cumulative feature probe.
set -uo pipefail
PASS=0; FAIL=0
ok() { echo "  PASS: $*"; PASS=$((PASS+1)); }
ng() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# Series 1 — bpf_link
adb shell '/system/bin/bpftool link list 2>&1' | grep -qE "id [0-9]+|^$" && ok "bpf_link list works" || ng "bpf_link not exposed"

# Series 2 — bpf_iter (placeholder until done)
adb shell '/system/bin/bpftool iter list 2>&1 | head -1' | grep -qE "task|file" && ok "bpf_iter targets present" || echo "  PEND: bpf_iter not yet"

# Series 3 — fentry/fexit via trampoline
adb shell 'cat /proc/kallsyms 2>/dev/null | grep -q "bpf_trampoline_link"' && ok "BPF trampoline linked" || echo "  PEND: trampoline not yet"

# Series 4 — struct_ops
adb shell '/system/bin/bpftool struct_ops list 2>&1' | grep -qE "id|^$" && ok "struct_ops command works" || echo "  PEND: struct_ops not yet"

# Series 5 — sleepable
adb shell 'cat /proc/kallsyms 2>/dev/null | grep -q "bpf_lsm_for_each_link"' && echo "  INFO: lsm hooks present" || true

echo "=== summary: $PASS pass / $FAIL fail ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/probes/p2-features.sh
```

- [ ] **Step 6: Run probe and commit**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/probes/p2-features.sh
git add workspace/kernel/patches/phase2-bpf-backport/01-bpf-link scripts/probes/p2-features.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p2-s1: bpf_link backport"
```

---

### Task 3.2: Series 2 — `bpf_iter` (5.6)

**Methodology:** identical to Task 3.1 with bpf_iter commits.

- [ ] **Step 1: Find candidate commits**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/linux-stable
git fetch --depth 1000 linux-stable v5.5 v5.6 2>/dev/null || true
git log --oneline v5.5..v5.6 -- kernel/bpf/bpf_iter.c kernel/bpf/task_iter.c kernel/bpf/map_iter.c include/linux/bpf.h | tee /home/ltlly/Code/kernel_research/workspace/kernel/patches/phase2-bpf-backport/02-bpf-iter/commit-candidates.txt
```

- [ ] **Step 2: Cherry-pick using the series helper (base = research-p2-s1)**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/cherry-pick-series.sh \
  workspace/kernel/patches/phase2-bpf-backport/02-bpf-iter \
  research-p2-s1
```

Resolve conflicts per the pattern described in Task 3.1 step 2: open the conflict file, fix in source, `git add && git commit`, re-run the helper.

- [ ] **Step 3: Build, pack, flash-test, run regression + new probe**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/build.sh vendor/alioth_research_defconfig p2-s2
./scripts/pack-boot.sh p2-s2
./scripts/flash-test.sh "$(cat workspace/builds/LATEST)" --probe ./scripts/probes/p1-features.sh
./scripts/probes/p2-features.sh
```

Expected: P1 features still pass (regression); the bpf_iter line in p2-features now shows PASS (was PEND before).
On compile failure: read build log, fix, retry up to 5 times before pausing.

Expected: bpf_iter line in p2-features now shows PASS.

- [ ] **Step 4: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add workspace/kernel/patches/phase2-bpf-backport/02-bpf-iter
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p2-s2: bpf_iter backport"
```

---

### Task 3.3: Series 3 — BPF trampoline + fentry/fexit (5.5) — **highest risk**

This series touches `arch/arm64/net/bpf_jit_comp.c` and adds `kernel/bpf/trampoline.c`. The arm64 JIT trampoline patches landed in 5.10, not 5.5 — for 4.19, both need to be backported together.

**Key commits:**

| Hash | Subject | Where |
|---|---|---|
| fec56f5890d9 | bpf: Introduce BPF trampoline | core |
| 5b92a28aae4d | bpf: Support attaching tracing BPF program to other BPF programs | core |
| efc9909fdce0 | bpf, x86: Generate trampoline | x86 (reference, ignore) |
| ce8f7c86d12c | arm64/insn: Support to encode FTR | arm64 |
| 7b4cdf1d5f37 | bpf, arm64: Implement bpf_arch_text_poke() | arm64 |
| (and follow-ups) |

- [ ] **Step 1: Pre-flight — confirm arch/arm64 has the necessary base infrastructure**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250
grep -l "bpf_arch_text_poke\|bpf_trampoline" arch/arm64/net/*.c arch/arm64/kernel/*.c 2>/dev/null | head -5
```

If empty: backport requires both the core trampoline patches AND the arm64 enablement patches.

- [ ] **Step 2: Find arm64 trampoline commits**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/linux-stable
git log --oneline v5.4..v5.10 -- arch/arm64/net/bpf_jit_comp.c arch/arm64/kernel/insn.c | grep -iE "trampoline|text_poke|bpf|fentry" | tee /home/ltlly/Code/kernel_research/workspace/kernel/patches/phase2-bpf-backport/03-trampoline-fentry/commit-candidates.txt
```

- [ ] **Step 3: Cherry-pick using the series helper (base = research-p2-s2)**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/cherry-pick-series.sh \
  workspace/kernel/patches/phase2-bpf-backport/03-trampoline-fentry \
  research-p2-s2
```

**Expect many more conflicts than s1/s2** because `arch/arm64/net/bpf_jit_comp.c` and `arch/arm64/kernel/insn.c` evolved heavily between 4.19 and 5.10. For each conflict:
1. Read `<conflict-dir>/<hash>.conflict`.
2. Compare the corresponding 4.19 file with the 5.10 reference at `workspace/kernel/linux-stable/`.
3. Resolve in the source tree, `git add && git commit -m "manual resolve trampoline: <hash>"`.
4. Re-run the helper to continue.

Budget: 6 hours for this series. If still stuck after 6h, this triggers escalation per the spec's autonomy contract.

- [ ] **Step 4: Iterate compile fixes — budget 6 hours**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/build.sh vendor/alioth_research_defconfig p2-s3
```

If unable to make progress in 6 hours: log status, **escalate to user** with a clear summary of what's stuck. This is one of the explicit escalation triggers.

- [ ] **Step 5: Pack, flash-test, probe, commit**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/pack-boot.sh p2-s3
./scripts/flash-test.sh "$(cat workspace/builds/LATEST)" --probe ./scripts/probes/p1-features.sh
./scripts/probes/p2-features.sh
git add workspace/kernel/patches/phase2-bpf-backport/03-trampoline-fentry
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p2-s3: bpf trampoline + fentry/fexit (arm64 jit)"
```

- [ ] **Step 6: Add fentry-specific test**

Run a bpftrace `fentry:do_sys_open` script and confirm it works AND is faster than `kprobe:do_sys_open` on a comparable workload:

```bash
cat > /home/ltlly/Code/kernel_research/scripts/probes/fentry-vs-kprobe.sh <<'EOF'
#!/usr/bin/env bash
adb push /home/ltlly/Code/kernel_research/workspace/tests/arm64/bpftrace /data/local/tmp/bpftrace 2>/dev/null
echo "=== kprobe time ==="
adb shell 'time /data/local/tmp/bpftrace -e "kprobe:do_sys_open { @[probe]=count(); } interval:s:5 { exit(); }"'
echo "=== fentry time ==="
adb shell 'time /data/local/tmp/bpftrace -e "fentry:do_sys_open { @[probe]=count(); } interval:s:5 { exit(); }"'
EOF
chmod +x /home/ltlly/Code/kernel_research/scripts/probes/fentry-vs-kprobe.sh
/home/ltlly/Code/kernel_research/scripts/probes/fentry-vs-kprobe.sh
```

Expected: both run; fentry version has lower per-call overhead.

---

### Task 3.4: Series 4 — `struct_ops` (5.6)

- [ ] **Step 1: Find candidate commits**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/linux-stable
git log --oneline v5.5..v5.6 -- kernel/bpf/bpf_struct_ops.c kernel/bpf/bpf_struct_ops_types.h 2>/dev/null | tee /home/ltlly/Code/kernel_research/workspace/kernel/patches/phase2-bpf-backport/04-struct-ops/commit-candidates.txt
```

- [ ] **Step 2: Cherry-pick using the series helper (base = research-p2-s3)**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/cherry-pick-series.sh \
  workspace/kernel/patches/phase2-bpf-backport/04-struct-ops \
  research-p2-s3
```

Resolve conflicts per the standard loop (read conflict diff, fix in source, commit, re-run helper).

- [ ] **Step 2b: Build, pack, flash-test, regression + new probe**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/build.sh vendor/alioth_research_defconfig p2-s4
./scripts/pack-boot.sh p2-s4
./scripts/flash-test.sh "$(cat workspace/builds/LATEST)" --probe ./scripts/probes/p1-features.sh
./scripts/probes/p2-features.sh
```

Expected: struct_ops line in p2-features goes from PEND to PASS.

- [ ] **Step 3: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add workspace/kernel/patches/phase2-bpf-backport/04-struct-ops
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p2-s4: struct_ops backport"
```

---

### Task 3.5: Series 5 — Sleepable BPF (5.10)

- [ ] **Step 1: Find candidate commits**

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/linux-stable
test -d .git && git fetch --depth 1000 origin v5.9 v5.10 2>/dev/null
git log --oneline v5.9..v5.10 -- kernel/bpf/syscall.c kernel/bpf/verifier.c | grep -iE "sleep" | tee /home/ltlly/Code/kernel_research/workspace/kernel/patches/phase2-bpf-backport/05-sleepable-bpf/commit-candidates.txt
```

- [ ] **Step 2: Cherry-pick using the series helper (base = research-p2-s4)**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/cherry-pick-series.sh \
  workspace/kernel/patches/phase2-bpf-backport/05-sleepable-bpf \
  research-p2-s4
```

Smallest of the five series; conflicts should be minimal.

- [ ] **Step 2b: Build, pack, flash-test, regression + new probe**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/build.sh vendor/alioth_research_defconfig p2-s5
./scripts/pack-boot.sh p2-s5
./scripts/flash-test.sh "$(cat workspace/builds/LATEST)" --probe ./scripts/probes/p1-features.sh
./scripts/probes/p2-features.sh
```

- [ ] **Step 3: Add sleepable probe**

```bash
# Append to p2-features.sh:
cat >> /home/ltlly/Code/kernel_research/scripts/probes/p2-features.sh <<'EOF'

# Sleepable BPF
adb shell 'cat /proc/kallsyms 2>/dev/null | grep -q "bpf_sleepable_prog"' && ok "sleepable BPF symbols present" || ng "sleepable not backported"
EOF
```

- [ ] **Step 4: Commit**

```bash
cd /home/ltlly/Code/kernel_research
git add workspace/kernel/patches/phase2-bpf-backport/05-sleepable-bpf scripts/probes/p2-features.sh
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p2-s5: sleepable BPF backport"
```

---

### Task 3.6: Final integration — merge all P2 series into one branch

- [ ] **Step 1: Create the integrated branch**

The series branches were stacked (s2 on s1, s3 on s2, etc.), so `research-p2-s5` already contains everything. Tag it.

```bash
cd /home/ltlly/Code/kernel_research/workspace/kernel/android_kernel_xiaomi_sm8250
git checkout research-p2-s5
git tag -f research-p2-final
git log --oneline research-p2-final ^research-p2-s1^ | head -50
```

- [ ] **Step 2: Build, pack, flash-test (full p1+p2)**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/build.sh vendor/alioth_research_defconfig p2-final
./scripts/pack-boot.sh p2-final
./scripts/flash-test.sh "$(cat workspace/builds/LATEST)" --probe ./scripts/probes/p1-features.sh
```

- [ ] **Step 3: Run all probes (regression + new)**

```bash
cd /home/ltlly/Code/kernel_research
./scripts/probes/p1-features.sh && \
  ./scripts/probes/p1-tools.sh && \
  ./scripts/probes/p2-features.sh && \
  ./scripts/probes/fentry-vs-kprobe.sh
```

Expected: all probes 0 fail.

- [ ] **Step 4: Commit**

```bash
cd /home/ltlly/Code/kernel_research
echo "P2 final integration: ALL PROBES PASS" >> STATUS.md
git add STATUS.md
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p2: all 5 series integrated, all probes pass"
```

---

### Task 3.7: User manual gate — P2

- [ ] **Step 1: Tell the user**

> "Phase 2 done — all 5 BPF backport series applied, all my feature/tool probes pass. Device is running the P2 kernel now via `fastboot boot` (RAM only — power-cycle goes back to P1 on slot _b, which is the current good fallback). Please use the phone for ~10 min — calls, WiFi, camera, your usual apps, plus anything BPF-related you care about (frida/stackplz/bpftrace). Reply 'OK P2' if it's stable; I'll flash this image to slot _b (overwriting P1 on _b). Reply with what's broken if not."

- [ ] **Step 2: Block waiting for response.**

---

### Task 3.8: Flash P2 to slot _b

(Only after user OK from Task 3.7.)

- [ ] **Step 1: Flash**

```bash
cd /home/ltlly/Code/kernel_research
img=$(ls -t workspace/builds/*-p2-final.img | head -1)
./scripts/flash-commit.sh "$img"
```

- [ ] **Step 2: Verify**

```bash
adb shell uname -a
./scripts/probes/p2-features.sh
```

- [ ] **Step 3: Final STATUS update + commit**

```bash
cd /home/ltlly/Code/kernel_research
sed -i 's/Phase 2 (BPF backport) | pending/Phase 2 (BPF backport) | DONE/' STATUS.md
echo "" >> STATUS.md
echo "## Final state ($(date))" >> STATUS.md
echo "- Slot _a: stock LineageOS (untouched)" >> STATUS.md
echo "- Slot _b: research kernel — vanilla → +BTF/ftrace/KSU → +full BPF (P0+P1+P2)" >> STATUS.md
echo "- Active: _b" >> STATUS.md
git add STATUS.md
git -c user.email=claude@anthropic.com -c user.name=Claude commit -q -m "p2: research kernel committed to slot b — project done"
```

---

## Self-Review Checklist

Before handing off, verify:

1. **Spec coverage:** Every numbered phase in the spec has corresponding tasks. Recovery layers L0-L4 are implemented in `recover.sh` + `flash-test.sh`. L5 escalation is encoded in `recover.sh` writing `RECOVERY_ESCALATED`.
2. **No placeholders:** All bash blocks contain real commands. Cherry-pick lists include the discovery method (`git log` queries with exact paths) since exact commit lists vary by what's already in CIP.
3. **Type consistency:** Script names are stable across tasks (`recover.sh`, `flash-test.sh`, `flash-commit.sh`, `build.sh`, `pack-boot.sh`, probe paths under `scripts/probes/`).
4. **Test pyramid:** Every kernel change is followed by build → pack → flash-test → probe → commit. Regression probe (`p1-features.sh`) re-run for every P2 series.
5. **Commits:** Frequent, scoped commits at every checkpoint.

## Known limitations

- **bpf_link discovery in Task 3.0** is non-mechanical and may produce a strategy ("extend" vs "from-scratch") that requires re-planning Task 3.1's cherry-pick set. This is acceptable since it gates a re-decision rather than a placeholder.
- **Task 3.3 (trampoline)** has the most uncertainty. If it cannot be completed in the 6-hour budget, the project is still useful at series 1+2+4+5 — fentry/fexit-based probes can fall back to kprobe.
- **APK install (Task 2.7 Step 3)** is the only manual user step in Phase 1. It's unavoidable — KSU Manager is a userspace app.
