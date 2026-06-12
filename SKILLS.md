# Skills: Alioth Kernel Build System

## Overview

This repo builds a flashable Android kernel zip for **Xiaomi alioth** (Poco F3 / Redmi K40 / Mi 11X) using GitHub Actions. The kernel is Linux 4.19.x (LineageOS lineage-23.2 base) with zram/zswap enabled.

## Repository Structure

```
alioth-kernel-research/
├── .github/workflows/build.yml    # CI workflow — the single source of truth
├── scripts/
│   ├── build.sh                   # Kernel build orchestrator
│   ├── pack-boot.sh               # Packs Image into boot.img (unused by CI)
│   └── ...
├── workspace/
│   ├── kernel/
│   │   ├── DEFCONFIG.env          # Defconfig layers (base + overlays)
│   │   ├── SOURCE_COMMIT          # Pinned kernel source commit
│   │   └── patches/
│   │       ├── zram-zswap.config  # zram/zswap overlay (CI applies this)
│   │       └── phase1-btf-ftrace/ # Research overlays (not used by CI)
│   ├── stock-images/              # Stock boot.img params
│   └── toolchain/
│       └── clang-path.env         # Clang path (CI overwrites this)
└── docs/                          # Research documentation
```

## Critical: Kernel Source Selection

The kernel source is cloned from **LineageOS**, NOT from the ltlly/bpf-research fork.

```
# CORRECT — LineageOS lineage-23.2 (clean, compiles standalone)
https://github.com/LineageOS/android_kernel_xiaomi_sm8250.git  branch: lineage-23.2

# WRONG — ltlly/android_kernel_xiaomi_sm8250-bpf-research
# The alioth-bpf-research branch has incomplete BPF trampoline patches
# that cause "incomplete type struct ftrace_ops" compilation errors.
# The bpf-repatch patches (Phase 2) were designed for incremental apply,
# not standalone compilation.
```

**Why**: The `alioth-bpf-research` branch backports BPF trampoline JIT from Linux 6.0 but the ftrace-with-regs foundation (mainline 5.5) isn't fully committed. `kernel/bpf/trampoline.c` references `sizeof(struct ftrace_ops)` which is incomplete in 4.19.

## Defconfig Layering

The build uses layered configs merged via `scripts/kconfig/merge_config.sh`:

```
Base:   vendor/kona-perf_defconfig          (from kernel source tree)
Layer1: vendor/xiaomi/sm8250-common.config   (from kernel source tree)
Layer2: vendor/xiaomi/alioth.config          (from kernel source tree)
Layer3: workspace/kernel/patches/zram-zswap.config  (our additions)
```

Defined in `workspace/kernel/DEFCONFIG.env`. The build script (`scripts/build.sh`) applies layers in order.

## Toolchain

- **Compiler**: Clang 21.0.0 from NDK r29 (AOSP r563880c)
- **Full LLVM**: llvm-ar, llvm-nm, llvm-objcopy, llvm-objdump, llvm-strip, llvm-readelf
- **Cross-compile**: aarch64-linux-gnu-
- **Env vars**: LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld

The CI downloads NDK r29 from `dl.google.com` and patches `workspace/toolchain/clang-path.env` to point to the runner's NDK path.

## zram/zswap Configuration

### Kernel Config Overlay (`zram-zswap.config`)

```
CONFIG_SWAP=y              # Required for any swap
CONFIG_FRONTSWAP=y         # CRITICAL: zswap depends on this in 4.19 (removed in 5.x+)
CONFIG_ZRAM=y              # Compressed RAM block device (primary swap)
CONFIG_ZSMALLOC=y          # zram's internal memory allocator
CONFIG_ZSWAP=y             # Compressed cache in front of swap
CONFIG_ZPOOL=y             # Common compressed memory API
CONFIG_Z3FOLD=y            # zswap pool (50% better density than zbud)
CONFIG_CRYPTO_LZ4=y        # Best ARM64 compressor (NEON-optimized)
CONFIG_CRYPTO_ZSTD=y       # Best ratio compressor
```

### Kernel Cmdline (patched by AnyKernel3 at flash time)

```
zswap.enabled=1            # Activate zswap at boot
zswap.compressor=lz4       # Fastest ARM64 compressor
zswap.zpool=z3fold         # Better density than default zbud
zswap.max_pool_percent=25  # Cap at 25% of RAM
```

### What We DON'T Control

The ROM's `init.rc` sets zram disk size and activates swap. Typical defaults:
- `/sys/block/zram0/disksize` = 4GB (8GB RAM) or 3GB (6GB RAM)
- `/sys/block/zram0/comp_algorithm` = lz4
- `swapon /dev/zram0 -p 100`

## AnyKernel3 Packaging

The CI clones [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) and customizes `anykernel.sh`:

- `BLOCK=auto` — auto-detect boot partition
- `IS_SLOT_DEVICE=1` — Virtual A/B (alioth uses slot _a only)
- `split_boot` → `patch_cmdline` → `flash_boot` flow
- Kernel image: `Image.gz` from build output

### Zip Creation

```bash
zip -r1X "${ZIP_NAME}" * -x '.git' 'README.md' '*placeholder'
```

- `-r1`: fast compression (better TWRP compatibility than `-r9`)
- `-X`: no extra file attributes (avoids platform-specific issues)
- Filename: `alioth-kernel-YYYYMMDD-HHMMSS.zip`

## Common Pitfalls

### 1. KernelSU Kconfig Reference (SOLVED)

The `alioth-bpf-research` branch has `source "drivers/kernelsu/Kconfig"` in `drivers/Kconfig` but the directory doesn't exist. This causes:
```
drivers/Kconfig:237: can't open file "drivers/kernelsu/Kconfig"
```
**Solution**: We switched to LineageOS source which doesn't have this reference. If using the bpf-research branch, add:
```bash
sed -i '/source "drivers\/kernelsu\/Kconfig"/d' drivers/Kconfig
```

### 2. BPF Trampoline Compile Error (SOLVED)

```
kernel/bpf/trampoline.c:84: error: invalid application of 'sizeof' to an incomplete type 'struct ftrace_ops'
```
**Solution**: Don't use the bpf-research branch for standalone builds. Use LineageOS source.

### 3. Zip Format Rejected by TWRP

Common causes:
- `zip -r9` (max compression) can cause issues on some TWRP builds → use `zip -r1X`
- Browser download can corrupt zip → use `adb push` instead
- Check TWRP version (some Xiaomi TWRP have ZIP parser bugs)

### 4. GitHub Actions Node.js Deprecation

Add to workflow job:
```yaml
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
```

### 5. Disk Space on Runners

GitHub Actions ubuntu-22.04 has ~14GB free. NDK is ~3GB, kernel source ~3GB. Free space first:
```yaml
- name: Free disk space
  run: |
    sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc
    sudo apt-get clean
```

## Build Workflow (Step by Step)

1. Free disk space on runner
2. Install deps (bison, flex, bc, clang, llvm, lld, etc.)
3. Download NDK r29 (~1.7GB)
4. Clone LineageOS kernel source (shallow, `--depth 1`)
5. Patch `clang-path.env` to runner's NDK path
6. `build.sh vanilla zram-zswap.config`:
   - `make vendor/kona-perf_defconfig`
   - Merge overlays via `merge_config.sh`
   - `make olddefconfig`
   - `make -j$(nproc) Image.gz dtbs`
7. Clone AnyKernel3, customize `anykernel.sh`
8. Copy `Image.gz` into AnyKernel3 dir
9. `zip -r1X` with datetime-stamped filename
10. Upload artifact

## How to Add New Config Overlays

1. Create `workspace/kernel/patches/my-feature.config`:
   ```
   CONFIG_SOME_OPTION=y
   CONFIG_ANOTHER=m
   ```
2. Pass it to build.sh:
   ```bash
   ./scripts/build.sh vanilla workspace/kernel/patches/zram-zswap.config workspace/kernel/patches/my-feature.config
   ```
3. The merge_config.sh handles layering automatically.

## How to Modify the Kernel Cmdline

Edit the `anykernel.sh` in the workflow. Available AnyKernel3 commands:
- `patch_cmdline <name> <value>` — add/replace cmdline parameter
- `patch_fstab` — modify fstab entries
- `replace_string` — string replacement in files
- `insert_line` / `remove_line` — line-level edits

## Flash Instructions

1. Download artifact from GitHub Actions run
2. Transfer to phone: `adb push alioth-kernel-*.zip /sdcard/`
3. Boot into TWRP → Install → select the zip
4. Reboot

**Recovery**: `fastboot flash boot_a workspace/stock-images/boot_a-original.img`

## Companion Repos

| Repo | Purpose |
|---|---|
| `LineageOS/android_kernel_xiaomi_sm8250` | Kernel source (lineage-23.2 branch) |
| `osm0sis/AnyKernel3` | Flashable zip template |
| `ltlly/alioth-kernel-research` | Original research repo (reference only) |
| `ltlly/android_kernel_xiaomi_sm8250-bpf-research` | BPF research fork (reference only, not for building) |
