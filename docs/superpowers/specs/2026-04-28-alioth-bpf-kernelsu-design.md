# Alioth Kernel: Full BPF Backport + KernelSU Integration

**Date:** 2026-04-28
**Target device:** Xiaomi `alioth` (Redmi K40 / POCO F3 / Mi 11X), SoC sm8250 (Snapdragon 870)
**Current ROM:** LineageOS 23.2 nightly, Android 16, 4.19.325-cip128 kernel
**Owner of execution:** Claude (autonomous), with hardware-level escalation to user only when device is unreachable.

---

## 1. Goals

1. **Full eBPF feature parity with Linux 5.10** on this device's stock 4.19-cip kernel — to support security-research tooling: `frida`, `stackplz`, `bpftrace`, `libbpf-bootstrap`/CO-RE programs, `eunomia-bpf`. Scope justification and feature timeline detailed in [`docs/research/2026-04-28-ebpf-feature-survey.md`](../../research/2026-04-28-ebpf-feature-survey.md).
2. **KernelSU integrated** as the root-management mechanism (replace the implicit `adbd` root).
3. The device must remain a **daily-usable Android 16 phone** after each phase: cellular, WiFi, camera, audio, fingerprint, GPU, sensors all functional.
4. Build/flash/test loop must be driven by the AI **autonomously**, with human escalation **only** when the device is electrically unreachable (cannot be detected by `adb` or `fastboot` after a reboot).

## 2. Non-Goals

- Upgrading the kernel to 5.10.x mainline (rejected earlier — no sm8250 5.10 BSP exists, requires multi-month vendor-driver porting).
- Modifying any vendor (`techpack`) driver: camera CamX, MDSS display, KGSL GPU, LPASS audio, modem, fingerprint. These are explicitly **untouched** to keep blast radius small.
- Changing user-space ROM (LineageOS userdata, vendor partition, system partition) — only `boot.img` (kernel + ramdisk) is rebuilt and flashed.
- Performance tuning (PGO/BOLT/MLGO) — first build will use stock clang without these advanced optimizations; we accept ~5-15% perf regression on hot paths in exchange for reproducible builds.

## 3. Background — Current Capability Audit

Verified on device 2026-04-28:

| Capability | Status |
|---|---|
| `CONFIG_BPF_SYSCALL`, `BPF_JIT`, `BPF_JIT_ALWAYS_ON` | ✅ Enabled |
| `CONFIG_BPF_LSM` (5.7 feature) | ✅ Backported by CIP |
| ringbuf (5.8 feature) | ✅ Verified runtime via `/sys/fs/bpf/prog_bpfRingbufProg_skfilter_ringbuf_test` |
| `CONFIG_NET_CLS_BPF`, `XDP_SOCKETS`, `BPF_EVENTS` | ✅ Enabled |
| `CONFIG_KPROBES`, `UPROBES`, `UPROBE_EVENTS` | ✅ Enabled |
| `CONFIG_DEBUG_INFO_BTF` | ❌ **Not set** — blocks CO-RE, vmlinux BTF |
| `CONFIG_FUNCTION_TRACER`, `DYNAMIC_FTRACE` | ❌ **Not set** — blocks fentry/fexit, kprobe-on-ftrace |
| `CONFIG_KPROBE_EVENTS`, `FTRACE_SYSCALLS` | ❌ Not set |
| BPF trampoline (5.5 feature) | ❌ Not compiled in |
| `bpf_iter` (5.6), `bpf_link` (5.7), `struct_ops` (5.6), sleepable BPF (5.10) | ❌ Likely not backported (to be verified during P2) |
| `bpftool` userspace | ✅ Present at `/system/bin/bpftool` |
| `adbd` running as root | ✅ userdebug build |
| Bootloader unlocked | ✅ `verifiedbootstate=orange` |
| A/B partitioning, currently on `_a` slot | ✅ |

The active LSM stack already includes `bpf` per `CONFIG_LSM`.

---

## 4. Phased Plan

The plan is three sequential phases, each independently testable and reversible.

### Phase 0 — Vanilla rebuild & flash sanity check

**Goal:** prove the build pipeline produces a kernel byte-equivalent (functionally) to the running one, and that the flash/boot/test loop works end-to-end. **Zero feature changes.**

**Steps:**
1. Provision toolchain (clang from AOSP `prebuilts/clang`, AOSP `build-tools` for `mkbootimg`/`avbtool`, NDK r29 if requested for userspace test builds).
2. Clone `https://github.com/LineageOS/android_kernel_xiaomi_sm8250` at the tag matching the running kernel (commit `a5b3099017ae` per `uname -r` suffix).
3. Build with the **exact** in-tree `vendor/alioth_defconfig` (no modifications).
4. Repack `boot.img` against the current device's ramdisk: pull current `boot_a` partition with `dd`, extract its ramdisk via `unpack_bootimg`, repack with the new `Image.gz` and identical kernel cmdline / DTB / pagesize / header version.
5. **Verify via `fastboot boot vanilla.img`** (memory-only, does not flash).
6. After boot, run a baseline check: `getprop sys.boot_completed`, `dmesg | grep -E "BUG|WARN|Oops"`, `uname -r`, ensure cellular/WiFi/audio still work for 5 minutes.
7. **Only if step 6 passes**, flash to inactive slot: `fastboot flash boot --slot=other vanilla.img`, do **not** switch active slot. Keep `_a` as the known-good fallback.
8. Use `fastboot --set-active=b` and reboot for a **soak test** (24-48 hours of normal use). If anything breaks, `fastboot --set-active=a` to revert.

**Success criteria:** Phase 0 done = the device boots and runs normally on a kernel we built ourselves, on slot `_b`. Slot `_a` remains stock/untouched as the bedrock fallback.

**Estimated effort:** 2-4 days (much of this is one-time toolchain setup).

### Phase 1 — BTF + ftrace + KernelSU

**Goal:** unlock CO-RE and basic fentry/kprobe BPF tracing, integrate KernelSU. After this, `frida` runs as before; `stackplz` (uprobe/kprobe modes), `bpftrace`, `libbpf-bootstrap` CO-RE programs all work. This is the **minimum viable target** for the user's day-to-day security research.

**Kconfig changes** (additive — append to a new `vendor/alioth_research_defconfig`):
```
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y     # if applicable to non-modular builds
CONFIG_FUNCTION_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_DYNAMIC_FTRACE_WITH_REGS=y
CONFIG_KPROBE_EVENTS=y
CONFIG_FTRACE_SYSCALLS=y
CONFIG_HAVE_KPROBES_ON_FTRACE=y     # if not already implied by arch
CONFIG_FUNCTION_GRAPH_TRACER=y
```

**KernelSU integration:**
- Use the **non-kprobes** mode (source-patched), based on `tiann/KernelSU` master at the latest tag compatible with 4.19.
- Apply the standard ~50-line hook patch into `fs/exec.c`, `fs/open.c`, `fs/read_write.c`, `fs/stat.c`.
- Add KernelSU as a git submodule under `drivers/staging/kernelsu`.
- Wire into Kbuild via `obj-$(CONFIG_KSU) += staging/kernelsu/`.

**Userspace verification:**
- `KernelSU Manager` APK installable, root grant works for `id -u 0`.
- `bpftool btf list` shows `vmlinux` BTF.
- `cat /sys/kernel/btf/vmlinux | wc -c` > 0.
- Run a stock `libbpf-bootstrap` example (`minimal.bpf.c`) — should load and trace.
- Run `bpftrace -e 'kprobe:do_sys_open { printf("%s\n", str(arg1)); }'` — should print opens.
- Run `stackplz` against any test target — should produce uprobe traces.

**Estimated effort:** 3-5 days.

### Phase 2 — Selective BPF feature backport

**Goal:** complete BPF feature parity with 5.10 by backporting the missing series.

**Patch series to backport (in dependency order):**

1. **`bpf_link` infrastructure** (Linux 5.7) — `kernel/bpf/syscall.c` link APIs, generic `bpf_link_*` helpers. ~10 patches.
2. **`bpf_iter`** (Linux 5.6) — `kernel/bpf/bpf_iter.c` and seq-file based iterators. ~15 patches.
3. **BPF trampoline + fentry/fexit** (Linux 5.5) — `arch/arm64/net/bpf_jit_comp.c` and `kernel/bpf/trampoline.c`. ~30 patches. **Highest risk** because of arch-specific JIT.
4. **`struct_ops`** (Linux 5.6) — extends BPF with kernel struct overrides. ~10 patches.
5. **Sleepable BPF programs** (Linux 5.10) — allows BPF programs to take faults / call sleeping helpers. ~5 patches.
6. **CO-RE refinements** — newer relocation kinds, type comparisons. ~5 patches.

**Source of patches:**
- Primary: `git log` from `linux-5.10.y` and `linux-5.5..5.10` upstream.
- Secondary: Google's `android-mainline` BPF backport tree (if accessible via android.googlesource.com), which has 4.19-tested versions of many of these.
- Tertiary: searches for `Cc: stable@vger.kernel.org # 4.19+` markers to find pre-vetted backports.

**Methodology:** Each series applied to its own git branch, built, fastboot-booted, validated against a feature-specific smoke test before merging into the main research branch. Failure of any series falls back to the previous green branch — Phase 2 is incremental and any subset is shippable.

**Estimated effort:** 2-3 weeks (high variance — trampoline/JIT work is the long pole).

---

## 5. Architecture

### 5.1 Workspace layout
```
/home/ltlly/Code/kernel_research/
├── docs/                              # specs, plans, runbooks
│   └── superpowers/specs/
├── workspace/
│   ├── toolchain/                     # project-pinned toolchain (version-locked to this kernel)
│   │   ├── clang-aosp/               # AOSP prebuilt clang (pinned to r563880c)
│   │   ├── pahole/                    # if distro pkg too old
│   │   ├── build-tools/               # mkbootimg, avbtool, unpack_bootimg
│   │   └── linaro-gcc/                # backup gcc cross compiler
│   │   # NOTE: NDK lives at ~/Android/Sdk/ndk/r29/ (shared across projects, not here)
│   ├── kernel/
│   │   ├── android_kernel_xiaomi_sm8250/      # main fork (LineageOS upstream)
│   │   ├── KernelSU/                  # submodule
│   │   └── patches/
│   │       ├── phase1-btf-ftrace/
│   │       ├── phase1-kernelsu/
│   │       └── phase2-bpf-backport/
│   │           ├── 01-bpf-link/
│   │           ├── 02-bpf-iter/
│   │           ├── 03-trampoline-fentry/
│   │           ├── 04-struct-ops/
│   │           └── 05-sleepable-bpf/
│   ├── stock-images/                  # backups taken on day 1 (immutable)
│   │   ├── boot_a-original.img        # the bedrock fallback
│   │   ├── boot_b-original.img
│   │   ├── dtbo_a-original.img
│   │   ├── dtbo_b-original.img
│   │   ├── vbmeta_a-original.img
│   │   └── vbmeta_b-original.img
│   ├── builds/                        # output: dated boot.img per build
│   │   └── YYYY-MM-DD-HH-<phase>-<tag>.img
│   └── tests/
│       ├── bpf-feature-probe/         # Go/C programs that probe BPF caps
│       ├── stackplz-smoke/
│       └── bpftrace-smoke/
├── scripts/
│   ├── build.sh                       # idempotent kernel build entry
│   ├── pack-boot.sh                   # repack boot.img against device ramdisk
│   ├── flash-test.sh                  # fastboot-boot + adb wait + dmesg + autorollback
│   ├── flash-commit.sh                # only flashes after flash-test passes 3 times
│   └── recover.sh                     # automatic rollback to slot _a
└── runs/                              # per-attempt logs
    └── YYYY-MM-DD-HHMM/
        ├── build.log
        ├── dmesg-boot.log
        ├── last_kmsg.log
        └── status.json
```

### 5.2 Toolchain
All toolchain artifacts land under `workspace/toolchain/` (user-writable, no sudo, no system pollution).

- **Compiler:** clang from AOSP `prebuilts/clang/host/linux-x86/clang-r563880c` (matches the version reported by stock kernel's `Linux version` string). This guarantees binary compatibility for vendor modules loaded against the new kernel. Downloaded into `workspace/toolchain/clang-aosp/`.
- **`pahole`:** Required for BTF generation, ≥ 1.21 needed for proper DEDUP. Built from source into `workspace/toolchain/pahole/` if distro pkg is too old.
- **`mkbootimg`, `avbtool`, `unpack_bootimg`:** From AOSP `system/tools/mkbootimg`, cloned shallow into `workspace/toolchain/mkbootimg/` (no full AOSP `repo init` required).
- **NDK r29:** Fetched on first need into `~/Android/Sdk/ndk/r29/` (shared across all Android projects, not project-local). Used only if userspace test programs need cross-compiling against bionic libc (`bpftool feature-probe` and similar). Build scripts will export `ANDROID_NDK_HOME=~/Android/Sdk/ndk/r29`.
- **`fastboot`, `adb`:** Already installed system-wide at v36.0.0; reused.
- **`bison`, `flex`, `bc`, `ccache`, `lz4`, `cpio`, `python3-dev`:** System-level prerequisites; if missing, AI will request user permission for `apt install` (one-time setup), since these are too small to vendor.

### 5.3 Build pipeline
A single `build.sh` script with these phases:
1. Set environment (PATH, CC, AR, NM, OBJCOPY pointing at AOSP clang).
2. `make ARCH=arm64 O=out vendor/alioth_research_defconfig` (or vanilla for P0).
3. `make ARCH=arm64 O=out -j$(nproc)` building `Image.gz` and `dtbs`.
4. Pack DTB: assemble `dtb` from `out/arch/arm64/boot/dts/vendor/qcom/sm8250-*.dtb`.
5. Pack `boot.img`: combine `Image.gz` + ramdisk-from-device + dtb with stock cmdline and header v3.
6. Output to `builds/<timestamp>-<phase>-<tag>.img`.

### 5.4 Flash & test pipeline
**`flash-test.sh <img>` is the workhorse:**
1. Sanity: `fastboot devices` shows alioth in fastboot mode.
2. `fastboot boot <img>` (memory-only, no flash).
3. Wait up to 90s for `adb wait-for-device`.
4. Probe: `getprop sys.boot_completed` (retry up to 60s); `dmesg | grep -i "panic\|oops\|bug"`; basic feature probe (`/sys/kernel/btf/vmlinux` exists for P1+, `bpftool feature` succeeds, etc.).
5. Run phase-specific smoke test (per-phase script).
6. Persist outcome to `runs/<timestamp>/status.json`.
7. **No flash to permanent storage.** That's `flash-commit.sh`'s job.

**`flash-commit.sh <img>` is invoked only after 3 successful `flash-test.sh` runs across reboots:**
1. Confirm slot `_a` still contains stock backup (compare hash with `stock-images/boot_a-original.img`).
2. `fastboot flash boot_b <img>`.
3. `fastboot --set-active=b`.
4. `fastboot reboot`.
5. Soak monitor: poll device every 60s for 24h, abort to `recover.sh` on failure.

**`recover.sh`:**
1. If `adb` reachable: `adb reboot bootloader`.
2. If `fastboot` reachable: `fastboot --set-active=a; fastboot reboot`.
3. If neither for >2 min: log + escalate to user (this is the only case requiring user intervention — likely physical hold of vol-down to enter fastboot, or in worst case EDL).

### 5.5 Brick-recovery layers
| Layer | Trigger | Recovery | AI-driven? |
|---|---|---|---|
| L0: `fastboot boot` failure | Image fails sig check | None needed — never written | ✅ |
| L1: Boot loop on `_b` | Kernel panics in early boot | Slot fallback to `_a` | ✅ |
| L2: Boots but adbd doesn't come up | Userspace ABI mismatch | Slot fallback to `_a` | ✅ |
| L3: Slow brick (works at boot, dies hours later) | Subtle regression | Triggered by soak monitor → slot fallback | ✅ |
| L4: Bootloader/fastboot still works, both slots dead | Catastrophic flash to both | Re-flash stock from `stock-images/` | ✅ |
| L5: Phone won't power on / unreachable | Hardware-level failure | EDL via test-point short | ❌ User-physical |

L0-L4 are AI-recoverable. L5 (physical EDL) is the **only** escalation contract with the user.

---

## 6. AI Autonomy & Escalation Contract

The AI will:
- Drive the entire build → fastboot-test → soak → flash-commit pipeline.
- On any compile error: read the log, attempt fix, retry up to 5 times with backoff. If still failing, log to `runs/<ts>/blocked.md` and continue to next independent task.
- On boot failure: auto-rollback via `recover.sh`, capture artifacts (`last_kmsg`, `pstore`, `dmesg`), bisect within the last patch series.
- On soak failure: same as boot failure plus 24h log diff.
- Self-create new tasks for blockers as they arise.

**Escalation triggers — AI stops and pings user:**
1. `adb` and `fastboot` both unreachable for > 2 minutes after expected reboot window (L5 hardware-physical).
2. Two consecutive bisects converge on a patch the AI cannot fix within a 6-hour budget.
3. Patch series 03 (BPF trampoline / arm64 JIT) hits architecture-specific bugs that require oscilloscope-level inspection (extremely rare; flagged as a known risk).

**Progress reporting (when no escalation):**
- After each phase boundary (P0→P1, P1→P2): post a status summary listing what was built/tested/flashed and any deferred issues.
- During long backport runs: an end-of-day summary of which patch series were applied/blocked.
- All transient build/test logs land under `runs/`; permanent state of "what's on the device" is mirrored in a single `STATUS.md` at the workspace root.

---

## 7. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| BTF generation crashes pahole on this codebase | Medium | Phase 1 blocked | Have multiple pahole versions ready; fall back to `CONFIG_DEBUG_INFO_BTF=y` with `-j1` builds |
| Vendor blob ABI break after kernel rebuild | Low-Medium | Ramdisk loads fail | Keep stock kernel toolchain version exact; do P0 sanity check first |
| KernelSU patches conflict with CIP backports already present | Low | KSU integration delay | Use kprobes-mode KSU as fallback (zero source patches) |
| BPF trampoline arm64 JIT requires deep arch changes | Medium | P2 series 3 stretches | Series 3 is independently shippable; can defer if 1+2+4+5 cover use cases |
| Vendor verity / dm-verity rejects rebuilt boot.img | Low | Boot fails | Bootloader unlocked → `verifiedbootstate=orange` → verity warning, not enforcement |
| Both A/B slots overwritten before validation | Low | Need recovery flash | `flash-commit.sh` enforces "_a stays stock"; backups in `stock-images/` |
| Disk full during multi-build runs | Low | Pipeline halts | 1.7TB free at start; budget per-build at ~5GB (out tree + repacked images); auto-prune `builds/` older than 7 days |

---

## 8. Open Questions

1. **NDK / toolchain provisioning:** AI fetches everything fresh. **NDK r29 lives at `~/Android/Sdk/ndk/r29/`** (Android Studio standard, shareable across projects); `ANDROID_NDK_HOME` exported in build scripts. Other project-specific toolchain pieces (the kernel's pinned AOSP clang, pahole, mkbootimg) stay under `workspace/toolchain/` because they're version-locked to this kernel build.
2. **Reproducibility of stock build:** the running kernel was built with `+pgo +bolt +lto +mlgo` per its version string. Reproducing those requires Google's internal toolchain. **Decision:** P0 will not reproduce these optimizations; we accept ~5-15% perf regression for the research kernel. If the user later wants the perf back, that's a separable workstream.
3. **android-mainline BPF backport tree access:** Some patches may exist on `android.googlesource.com/kernel/common` branches that are 4.19-aligned. AI will probe availability; if unreachable, falls back to manually cherry-picking from upstream Linux.
4. **bpf_link partial presence:** Since `CONFIG_BPF_LSM=y` is set in stock and BPF_LSM uses `bpf_link`, some bpf_link infrastructure is likely already present. AI will read `kernel/bpf/syscall.c` in the source tree to determine whether series 1 in P2 is "extend existing" or "add from scratch", which significantly affects effort.

---

## 9. Definition of Done

Each phase has a two-part DoD: a **user-side manual check** (subjective, daily-use feel) and an **AI-driven feature check** (objective, scripted). A phase is *done* only when **both** parts pass.

### P0 — Vanilla rebuild & flash
- **User manual check (gate):** User flashes/boots the rebuilt vanilla kernel, uses the phone normally for some period, confirms it boots and apps don't crash. User signals "ok, P0 done" before AI proceeds to P1.
- **AI feature check:** N/A for P0 — there are no new features to verify; this phase is purely about pipeline validation.

### P1 — BTF + ftrace + KernelSU
- **User manual check (gate):** Boots, daily-use apps don't crash, no obvious regression vs stock or vs P0 vanilla.
- **AI feature check (all must pass):**
  - `/sys/kernel/btf/vmlinux` exists and `bpftool btf dump file /sys/kernel/btf/vmlinux format raw | head` succeeds.
  - `bpftrace -e 'kprobe:do_sys_open{ printf("%s\n", str(arg1)); }'` produces output.
  - KernelSU Manager APK grants root to a test target (`id -u 0` from a non-priv user via `su`).
  - `stackplz` runs against a chosen userspace target (e.g., `libc.so` `open`) and emits uprobe traces.
  - `frida-server` attaches to a test app and basic JS-side tracing works (regression check — frida shouldn't break).
  - A trivial CO-RE program (built from `libbpf-bootstrap/minimal.bpf.c`) loads and runs.

### P2 — Selective BPF backport (5.10 feature parity)
- **User manual check (gate):** Same — boots, apps don't crash, no regression vs P1.
- **AI feature check (all must pass):**
  - `feature-probe` test reports support for: `bpf_link` (5.7), `bpf_iter` (5.6), fentry/fexit via BPF trampoline (5.5), `struct_ops` (5.6), sleepable BPF (5.10).
  - bpftrace `iter:task` probe works (depends on bpf_iter).
  - bpftrace `fentry:do_sys_open` works and is faster than `kprobe:do_sys_open` on the same workload (sanity check that trampoline is actually used).
  - `stackplz` advanced modes (any that depend on Phase 2 features) work.
  - Original Phase 1 checks all still pass (regression).

The DoD is phrased so AI-driven loops can iterate on the AI check until green, then escalate to the user only for the daily-use validation gate. This matches the user's "全部由你做" + "完全无法链接设备时喊我" autonomy contract.

---

## 10. Out of scope (will not do)

- Anything that touches `techpack/` or vendor drivers.
- LineageOS user-space changes (no `system.img` / `vendor.img` rebuilds).
- Reproducing PGO/BOLT/MLGO optimizations.
- Public release / OTA packaging.
- Magisk integration (KernelSU is the chosen path).

---

*Plan terminus: once this spec is user-approved, control passes to `superpowers:writing-plans` to produce the detailed step-by-step implementation plan.*
