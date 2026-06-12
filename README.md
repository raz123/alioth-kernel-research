# alioth-kernel CI

Automated kernel builds for **Xiaomi alioth** (Poco F3 / Redmi K40 / Mi 11X) with **zram + zswap** enabled. Flash via TWRP or any custom recovery.

Based on [LineageOS lineage-23.2](https://github.com/LineageOS/android_kernel_xiaomi_sm8250) (Linux 4.19.302, SM8250/Snapdragon 870).

## Latest Build

[![Build alioth kernel](https://github.com/raz123/alioth-kernel-research/actions/workflows/build.yml/badge.svg)](https://github.com/raz123/alioth-kernel-research/actions/workflows/build.yml)

Download the latest `alioth-kernel-*.zip` from [Actions](https://github.com/raz123/alioth-kernel-research/actions).

## What's Included

| Feature | Details |
|---|---|
| **Kernel** | Linux 4.19.302 (LineageOS lineage-23.2) |
| **Toolchain** | Clang 21.0.0 (NDK r29, AOSP r563880c) |
| **zram** | Built-in (`CONFIG_ZRAM=y`), lz4 compression, ROM-controlled disk size |
| **zswap** | Enabled at boot via cmdline: `zswap.enabled=1 zswap.compressor=lz4 zswap.zpool=z3fold` |
| **Defconfig** | `kona-perf_defconfig` + `sm8250-common.config` + `alioth.config` + zram/zswap overlay |
| **Packaging** | AnyKernel3 flashable zip (A/B slot aware) |

## Flash

```bash
# Download
gh run download <run-id> --name "alioth-kernel-*.zip"

# Transfer to phone
adb push alioth-kernel-YYYYMMDD-HHMMSS.zip /sdcard/

# Flash via TWRP
# TWRP → Install → select the zip → reboot
```

**Recovery** (if anything goes wrong):
```bash
fastboot flash boot_a <path-to-stock-boot.img>
```

## How It Works

GitHub Actions (ubuntu-22.04) runs this pipeline on every push to `master` or manual trigger:

1. Free disk space on runner
2. Install build dependencies
3. Download NDK r29 toolchain
4. Clone LineageOS kernel source (shallow)
5. Build kernel with `build.sh vanilla zram-zswap.config`
6. Package as AnyKernel3 zip with datetime stamp
7. Upload artifact

Build time: ~17-21 minutes.

## Configuration

### Adding Kernel Config Options

Create a `.config` overlay file and pass it to the build:

```bash
# In .github/workflows/build.yml, add an extra overlay:
./scripts/build.sh vanilla \
  workspace/kernel/patches/zram-zswap.config \
  workspace/kernel/patches/my-new-feature.config
```

### Adding Kernel Cmdline Parameters

Edit the `anykernel.sh` template in `.github/workflows/build.yml`:

```bash
patch_cmdline my.param value
```

### Changing the Kernel Source

Edit the `Clone kernel source` step in `.github/workflows/build.yml`. The source must have:
- `arch/arm64/configs/vendor/kona-perf_defconfig`
- `arch/arm64/configs/vendor/xiaomi/sm8250-common.config`
- `arch/arm64/configs/vendor/xiaomi/alioth.config`

## Repository Layout

```
.github/workflows/build.yml      # CI pipeline
scripts/build.sh                  # Kernel build orchestrator
scripts/pack-boot.sh              # boot.img packer (local use only)
workspace/kernel/DEFCONFIG.env    # Defconfig layer definitions
workspace/kernel/patches/         # Config overlays
workspace/stock-images/           # Stock boot params for reference
SKILLS.md                         # AI onboarding doc (for other agents)
```

## Credits

- [ltlly/alioth-kernel-research](https://github.com/ltlly/alioth-kernel-research) — original KernelSU + eBPF research (reference)
- [LineageOS/android_kernel_xiaomi_sm8250](https://github.com/LineageOS/android_kernel_xiaomi_sm8250) — kernel source
- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) — flashable zip framework

## For AI Agents

See [`SKILLS.md`](SKILLS.md) for a comprehensive guide covering build system internals, common pitfalls, and how to extend the pipeline.
