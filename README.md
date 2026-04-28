# alioth-kernel-research

**Goal:** Get **latest KernelSU (v3.2.4)** + **full BPF tooling support** running on **Linux 4.19-cip** for **Xiaomi alioth** (Redmi K40 / POCO F3 / Mi 11X), starting from LineageOS 23.2 nightly.

KernelSU upstream officially [dropped non-GKI support starting v1.0](https://kernelsu.org/zh_CN/guide/how-to-integrate-for-non-gki.html). This project re-enables it for 4.19 alioth via 11 source-level compat patches, including a critical [`pmd_leaf` fix](https://github.com/ltlly/KernelSU-alioth-4.19-research/blob/alioth-4.19-research/kernel/hook/arm64/patch_memory.c) that unlocks all syscall hooks on arm64 4.19.

## Companion repos

| Repo | Description |
|---|---|
| [`KernelSU-alioth-4.19-research`](https://github.com/ltlly/KernelSU-alioth-4.19-research) | Forked KernelSU v3.2.4 with 4.19 compat patches + manager UI fix |
| [`android_kernel_xiaomi_sm8250-bpf-research`](https://github.com/ltlly/android_kernel_xiaomi_sm8250-bpf-research) | LineageOS sm8250 kernel + KSU integration + ftrace/kprobe enablement |
| [`alioth-kernel-research`](https://github.com/ltlly/alioth-kernel-research) (this repo) | Engineering logs, build scripts, runbooks |

## Status

- ✅ **Phase 0** (vanilla kernel rebuild) — DONE
- ✅ **Phase 1** (BTF + ftrace + KSU manager working) — DONE
- ✅ **Phase 2 Round 1** (BTF firmware loader → tracing/lsm/ext verifier-level) — DONE
- ✅ **Phase 2 Round 2** (arm64 trampoline JIT + ftrace_function adapter → fentry actually fires) — DONE — 451 events/sec captured live
- ✅ **Phase 2 Round 3** (HAVE_DYNAMIC_FTRACE_WITH_REGS backport → fentry programs read real x1..x7 function args) — DONE — verified flags=0x20241/0xa8000, mode=0666 live

## Quick navigation

| Looking for | See |
|---|---|
| **Three-phase final summary** | [`docs/FINAL-ACHIEVEMENTS.md`](docs/FINAL-ACHIEVEMENTS.md) |
| The full story of how this was built (5 brick attempts, 11 KSU patches) | [`docs/journey/`](docs/journey/) |
| Each KSU patch explained line-by-line | [`docs/runbook/2026-04-28-ksu-patches.md`](docs/runbook/2026-04-28-ksu-patches.md) |
| **Phase 2 BTF firmware loader patch** | [`docs/runbook/2026-04-28-btf-firmware-loader.md`](docs/runbook/2026-04-28-btf-firmware-loader.md) |
| **Phase 2 R3: WITH_REGS backport — fentry args delivery** | [`docs/runbook/2026-04-29-arm64-ftrace-with-regs.md`](docs/runbook/2026-04-29-arm64-ftrace-with-regs.md) |
| Device bricked? Recovery steps | [`docs/runbook/2026-04-28-recovery-runbook.md`](docs/runbook/2026-04-28-recovery-runbook.md) |
| What CIP-128 already backported (informs Phase 2) | [`workspace/kernel/patches/phase2-bpf-backport/00-survey/STRATEGY.md`](workspace/kernel/patches/phase2-bpf-backport/00-survey/STRATEGY.md) |
| Original eBPF feature survey (5.5 → 6.12 timeline) | [`docs/research/2026-04-28-ebpf-feature-survey.md`](docs/research/2026-04-28-ebpf-feature-survey.md) |
| Current device + kernel state | [`STATUS.md`](STATUS.md) |
| Build scripts | [`scripts/`](scripts/) |

## Quick start (re-create on another alioth device)

Prerequisites:
- Xiaomi alioth (Redmi K40/POCO F3/Mi 11X) with **bootloader unlocked**
- LineageOS 23.2 nightly installed (any release with kernel `4.19.325-cip128-st12-perf-ga5b3099017ae`)
- Linux build host with ~30GB free, sudo, and reasonable bandwidth (need to download NDK r29 ~800MB)

```bash
# 1. Get this repo
git clone https://github.com/ltlly/alioth-kernel-research.git
cd alioth-kernel-research

# 2. Install prereqs (the project's docs detail what)
sudo apt install -y bison flex bc ccache lz4 cpio python3-dev libssl-dev libelf-dev clang gawk dwarves lld llvm

# 3. Run the bootstrap (downloads NDK r29 with stock-matched clang r563880c, AOSP mkbootimg, kernel + KSU)
# (TODO: turn the manual sequence in docs/journey/ into a one-shot script)

# 4. Build kernel and pack boot.img
./scripts/build.sh p1-final workspace/kernel/patches/phase1-btf-ftrace/p1-overlay.config
./scripts/pack-boot.sh p1-final

# 5. Backup device images (CRITICAL)
./scripts/backup-device.sh

# 6. Test in RAM first
./scripts/flash-test.sh workspace/builds/$(cat workspace/builds/LATEST | head -1) --probe ./scripts/probes/boot-smoke.sh

# 7. Persist to slot _a (Virtual A/B device — only _a is bootable)
./scripts/flash-commit.sh <image>

# 8. Install KSU manager APK from forked repo's release page
adb install KernelSU.apk

# Recovery (any time): fastboot flash boot_a workspace/stock-images/boot_a-original.img
```

## Why this exists

Researcher needed BPF + KernelSU on a 4.19 LineageOS device. Upstream KSU said no for non-GKI. This documents how to make it work anyway, with full transparency on every workaround.

## License

GPL-2.0 (matches kernel + KernelSU upstream).
