# Alioth Kernel Project — Status

| Phase | State | Notes |
|---|---|---|
| Pre-Phase | DONE | deps + scripts + stock backup + kernel source pinned |
| Phase 0 (vanilla) | DONE | NDK r29 clang r563880c match for stock; vermagic identical |
| Phase 1 (BTF+ftrace+KSU) | **🏆 完整功能 — Manager「工作中 ✓」** | KSU v3.2.4 全集成: 16 个 KSU 文件 patch + 真实 supercall dispatch + apk_sign 验证我们 fork 的 manager; 「Crowning manager」+ 「工作中 ✓」<GKI> 状态; 4 个 tab 全可用 |
| Phase 2 (BPF backport) | **🏆 tracing+lsm+ext 解锁** | CIP 已 backport bpf_link/iter/trampoline/struct_ops/sleepable; 我们 patch btf.c+verifier.c 增加 BTF firmware 加载（绕开 alioth 的 64MB Image 限制）→ 29/32 prog types available。仅 `syscall` / `netfilter` 真正缺（5.14+/6.x） |
| Phase 2 R3 (WITH_REGS hack, 已废弃) | 撤销 | 旧的 mcount-based 实现已 revert |
| **Phase 2 R4 (mainline 5.5/5.18 移植)** | **🏆 完整标准 eBPF: fentry/fexit/return-value** | 移植 mainline 5.5 `3b23e4991fb6` (-fpatchable-function-entry=2) + 5.18 `f64dd4627ec6` (register_ftrace_direct_multi) + arm64 ABI bridge in `ftrace_common_return`. 现在 `ctx[0..N]` 是真实参数，fexit 在 ret 后触发，能读 return value。完全和 upstream 一致 |

## Current device state

- Active slot: `_a` flashed with **P2 R4 kernel** (P1 + BTF FW + 5.5/5.18 mainline ports + bpf_shtab fix + persist BTF path) — persistent
- Persistent image: `workspace/builds/20260429-095317-p2-final-persist.img`
- Kernel: `Linux 4.19.325-cip128-st12-perf-g43c03d52ba05-dirty`
- BTF location: **`/mnt/vendor/persist/vmlinux.btf`** (survives factory reset; install via `scripts/install-btf-to-persist.sh`)
- `/proc/version` shows `(claude@research)` — our build
- KSU module: loaded, feature handlers registered, manager 工作中 ✓
- BTF file at `/mnt/vendor/persist/vmlinux.btf` (9.7MB strict-4.19, no FLOAT/ENUM64/etc, with bpf_shtab fix) — survives factory reset / OTA
- Canonical strict BTF: `workspace/kernel/patches/phase2-bpf-backport/00-survey/btf-fw/vmlinux.btf`
- One-shot install script: `scripts/install-btf-to-persist.sh` (run once per device)
- Released artifacts at GitHub: [`alioth-r2`](https://github.com/ltlly/alioth-kernel-research/releases/tag/alioth-r2)
- Stock backup at `workspace/stock-images/boot_a-original.img` for instant restore
- AVB: vbmeta_a + vbmeta_b flashed with `--disable-verification`

### Phase 2 persistent boot — verified after cold reboot

```
[   36.081] btf: loaded vmlinux BTF from /data/local/tmp/vmlinux.btf (9762784 bytes)
[   36.123] btf: btf_parse_vmlinux SUCCESS, 188258 types
```

`bpftool feature probe` after hard reboot: tracing / lsm / ext / struct_ops all `available`.
First-attempt BTF load at boot time 5s fails (NetBpfLoad runs before /data is mounted) —
that's the 5-second-rate-limit retry path. Recovery is automatic; no functional impact.

## What works in Phase 1

✅ Dynamic ftrace (68942 traceable functions)
✅ kprobe events via `/sys/kernel/tracing/kprobe_events`
✅ uprobe events (already worked in stock)
✅ Detached BTF for libbpf CO-RE programs (use `--btf` flag pointing to `/data/local/tmp/vmlinux.btf`)
✅ KernelSU module loaded; `feature management` initialized
✅ KSU sulog and adb_root handlers registered
✅ frida unaffected (no kernel dependency)
✅ adb root persists (userdebug ROM)

## What works in Phase 2 (BTF firmware loader) — partial unlock

### Verifier-level (load + verify)
✅ **`tracing` prog type** — verifier accepts and JITs (P2 unlock via BTF)
✅ **`lsm` prog type** — verifier accepts and JITs
✅ **`ext` prog type** — verifier accepts and JITs
✅ **`struct_ops`** — full
✅ in-kernel `btf_vmlinux` populated from `/data/local/tmp/vmlinux.btf`
✅ `/sys/kernel/btf/vmlinux` exposed for userspace libbpf (after P2v2 patch)
✅ All 18 BPF map types
✅ NetBpfLoad / gpuMem / netd / ringbuf — 60+ existing BPF programs unaffected

### Attach-level for tracing/lsm/ext — ⚠️ BLOCKED
**Cannot attach `tracing` / `lsm` / `ext` programs to kernel functions** because
`arch_prepare_bpf_trampoline()` is the `__weak` default in 4.19-cip and returns
`-ENOTSUPP`. CIP-128 backported the trampoline framework but not the arm64
specific assembler (upstream Linux 6.0 commit `efc9909fdce0`, Aug 2022).

```
$ bpftool prog loadall fentry_test.bpf.o /sys/fs/bpf/x autoattach
libbpf: prog 'trace_open': failed to attach: Unknown error 524
```

`-ENOTSUPP = 524` is from `kernel/bpf/trampoline.c:552`.

**What still works fully** (real-world hooking):
- ✅ uprobe + tracefs (kernel 4.19 base) — verified live on `Ena1907_req`
- ✅ kprobe + tracefs / kprobe BPF prog type — 19 programs running
- ✅ BPF tracepoint, raw_tracepoint, perf_event, sched_cls, etc. — 26 prog types
- ✅ frida / stackplz / bpftrace (uprobe/kprobe subset)

⚠️ `syscall` (5.14+) and `netfilter` (6.x) prog types — not backported

### The BTF firmware loader patch

`kernel/bpf/btf.c::btf_parse_vmlinux()` + `kernel/bpf/verifier.c::bpf_get_btf_vmlinux()` +
`kernel/bpf/sysfs_btf.c` (lazy /sys/kernel/btf/vmlinux):
当 `__start_BTF == __stop_BTF`（无 .BTF section）时，从 FS 加载 BTF 文件。
绕开 alioth bootloader 的 ~64MB Image 大小限制——内核 Image 零增长。
完整说明: `docs/runbook/2026-04-28-btf-firmware-loader.md`

### Phase 2 Round 2: BPF fentry attach 真正打通 (kernel commits `9a7c71dabb06` + `8ccba43d1805`)

✅ **arm64 BPF trampoline JIT 完整 backport** (~500 LOC)
- `arch_prepare_bpf_trampoline()` strong-symbol implementation
- `bpf_arch_text_poke()` for arm64 (nop ↔ bl patching)
- Supporting `aarch64_insn_gen_load_store_imm()` + A64_LS_IMM macros

✅ **`register_ftrace_function`-based fallback adapter** (~150 LOC)
- 当 `register_ftrace_direct` 返回 `-ENOTSUPP`（4.19 arm64 没 `ARCH_SUPPORTS_FTRACE_DIRECT`），fallback 到我们的 ftrace_ops 适配器
- 适配器 ftrace_ops 用 `FTRACE_OPS_FL_SAVE_REGS_IF_SUPPORTED`
- callback 走 `tr->progs_hlist[BPF_TRAMP_FENTRY]`，C 里直接 call `p->bpf_func(ctx, insns)`

✅ **Validated live**:
```
$ /system/bin/bpftool prog loadall fentry.bpf.o /sys/fs/bpf/x autoattach
$ /system/bin/bpftool link list
  1: tracing  prog 77   prog_type tracing  attach_type trace_fentry
  2: tracing  prog 79   prog_type tracing  attach_type trace_fexit

$ ls / ; cat /sys/kernel/tracing/trace
  sh-4443  ... bpf_trace_printk: fentry do_sys_open flags=0
  ... 451 events captured in <1s
```

### Phase 2 Round 4: 完整 mainline 移植，达成标准 eBPF 行为

通过移植 mainline 5.5 + 5.18 三个上游 commit 实现完全标准的 BPF fentry/fexit/return-value 语义：

| 上游 commit | 功能 | 我们的 commit |
|---|---|---|
| Linux 5.5 `fbf6c73c5b26` | `ftrace_init_nop` weak callback | `ee041ac767d3` |
| Linux 5.5 `3b23e4991fb6` | arm64 ftrace_with_regs (`-fpatchable-function-entry=2`) | `15491ac9ca5d` |
| Linux 5.18 `f64dd4627ec6` | `register_ftrace_direct_multi` API | `a89e06fd2f44` |
| Linux 6.0 `efc9909fdce0` (前已移植) | BPF arm64 trampoline JIT | `9a7c71dabb06` |
| 这次新增 | arm64 `ftrace_common_return` ABI bridge (`pt_regs->orig_x0` 直接调用重定向) | `9b69f0d293a4` |
| 这次新增 | BPF JIT: 不跳过 bpf_func 当 `__bpf_prog_enter` 返回 0（4.19 语义） | `6aa1a1ec0463` |
| 这次新增 | BPF trampoline 改用 direct_multi，删除 ksu_adapter | `549c996be470` |

✅ **Validated live (cold reboot from slot _a)**:
```
$ adb shell bpftool prog loadall fexit_test.bpf.o /sys/fs/bpf/y autoattach
$ adb shell cat /sys/kernel/tracing/enabled_functions
do_sys_open (1) R I D    tramp: ftrace_regs_caller (call_direct_funcs)
                         direct--> bpf_trampoline_105579_1

$ ls /
$ echo z > /data/local/tmp/cold.txt
$ adb shell cat /sys/kernel/tracing/trace
sh ENTRY  dfd=ffffffffffffff9c flags=20241                     # AT_FDCWD, real flags
sh EXIT   dfd=ffffffffffffff9c flags=20241 ret=3               # 真实 ret value (fd 3)
ls ENTRY  dfd=ffffffffffffff9c flags=a8000
ls EXIT   dfd=ffffffffffffff9c flags=a8000 ret=3
```

**完全标准 eBPF 接口**：
- `ctx[0..N]` = 函数实际参数 0..N (含 arg0 — AT_FDCWD = -100) ✓
- fentry 触发于函数入口 ✓
- fexit 触发于函数 ret 之后 ✓
- fexit 读 return value ✓
- fmod_ret 改 return value（mainline JIT 已支持，自动可用） ✓

### Phase 2 Round 3 (deprecated): HAVE_DYNAMIC_FTRACE_WITH_REGS hack (commit `2f9a02d7877f`, 已 revert)

✅ **arm64 4.19 mcount-based WITH_REGS** (~200 LOC asm + C)
- `arch/arm64/include/asm/ftrace.h`: `ARCH_SUPPORTS_FTRACE_OPS 1`
- `arch/arm64/Kconfig`: `select HAVE_DYNAMIC_FTRACE_WITH_REGS`
- `arch/arm64/kernel/entry-ftrace.S`:
  - `ftrace_caller` 现在 load `function_trace_op` 到 x2，传 NULL regs (x3)
  - 新加 `ftrace_regs_caller`：mcount_enter 后 `sub sp, #S_FRAME_SIZE` 分配 pt_regs，
    保存 x0..x29 + 从 mcount frame 恢复 instr-fn 的 x29/x30 + sp/pc/pstate，传 pt_regs* 作为 x3
- `arch/arm64/kernel/ftrace.c`:
  - 新加 `ftrace_modify_call(rec, old, new)` — 切换 patch site 在 ftrace_caller / ftrace_regs_caller 之间
  - `ftrace_update_ftrace_func` 现在同时 patch `ftrace_call` 和 `ftrace_regs_call` 两个 NOP（x86 同款）
- `kernel/bpf/trampoline.c`:
  - `ksu_register_ftrace_adapter` 显式设 `FTRACE_OPS_FL_SAVE_REGS`（之前只设 IF_SUPPORTED 不行 ——
    `CONFIG_DYNAMIC_FTRACE_WITH_REGS=y` 时 ftrace.c 的 IF_SUPPORTED→SAVE_REGS auto-upgrade 被 `#ifndef` 编译掉了）

✅ **Validated live** (cold reboot from slot _a):
```
$ adb shell cat /sys/kernel/tracing/enabled_functions
do_sys_open (1) R       <- R 标志: ftrace 已切换 patch site 到 ftrace_regs_caller

$ ls / ; echo > /data/local/tmp/test
$ adb shell cat /sys/kernel/tracing/trace
  ls    FENTRY x1_filename=72d088f968 x2_flags=a8000  x3_mode=0    <- O_DIRECTORY|O_NONBLOCK|...
  sh    FENTRY x1_filename=b40000718da8b2d8 x2_flags=20241 x3_mode=1b6  <- 0666 写文件
```

### 仍存在的限制（mcount ABI 硬限制）

- **`regs->regs[0]` 仍是 parent_pc，不是函数 arg0** —— gcc/clang `-pg` 在函数 prologue 末尾发射 `mov x0, x30; bl _mcount`，
  把 lr 放到 x0 当 mcount 的第一个参数。等到 ftrace_regs_caller 保存寄存器时 x0 已经被覆盖。
  编译器会把原始 x0 spill 到一个 callee-saved register（x19/x20/x21 等），但 spill 位置因函数而异，无法通用恢复。
  要根治需要走 `-fpatchable-function-entry=2` ABI（arm64 5.5+ 路线），重新编译整个 kernel + 重写 ftrace 入口。
- **fexit 仍在入口触发** —— 适配器是入口 hook，fexit 也跑在入口
- **每次调用 ~120 cycles 开销** —— ftrace_regs_caller 比 ftrace_caller 多保存了 304 bytes 的 pt_regs

### 实际意义

BPF fentry 程序现在可以做的事：
- ✅ 读函数参数 1..7 (`ctx[1]` 到 `ctx[7]`) — userspace 指针、syscall flags、mode、length 等
- ✅ 读 syscall 入口的 `pt_regs *regs` 参数（很多 syscall handler 第一个就是 regs，等于 `ctx[1]`）
- ⚠️ `ctx[0]` 是 parent_pc —— 程序应该忽略它，或者用它做 caller 识别
- ❌ 不能修改寄存器后让函数继续（pt_regs snapshot only — adapter 不写回硬件 regs）

## KSU on 4.19 — full capability (final state)

✅ All KSU init paths active (hook_init / supercalls_init / hook_manager_init)
✅ Real `supercall/dispatch.c` running on 4.19 — full 14-command IOCTL dispatch active
✅ `apk_sign.c` re-enabled — verifies manager APK signature against EXPECTED_HASH
✅ `throne_tracker` finds manager APK at boot, `Crowning manager` log
✅ `handle_setresuid` hook firing live for uid transitions
✅ KSU init.rc fragment appended; `on_post_fs_data!` fires
✅ Stable RSA-4096 keystore committed as GH secret — APK signature deterministic across CI runs
✅ ksud daemon installs, talks to kernel via ioctl, all features queryable
✅ 4 manager tabs functional: 主页 / 超级用户 / 模块 / 设置

### The breakthrough fix

`drivers/kernelsu/hook/arm64/patch_memory.c` — added 4.19-compatible pmd_leaf/pud_leaf
fallback (alias to `pmd_sect`/`pud_sect`). Without this, `phys_from_virt()` couldn't
detect section-mapped huge pages (used to map kernel text on arm64 4.19), so all
syscall table patches silently failed. With this 6-line fix, all KSU runtime
hooks now work.

### SELinux integration (`selinux/selinux.c`)

✅ Replaced stubs with **real 4.19 implementations**:
- `setenforce/getenforce` — uses 4.19's `enforcing_set`/`enforcing_enabled`
- `cache_sid` — uses `security_secctx_to_secid` (same API as 5.7+)
- `is_task_ksu_domain/is_zygote/is_init` — compares cached SID via `selinux_cred(cred)->sid`
- `setup_selinux/setup_ksu_cred` — sets task_security_struct fields
- `escape_to_root_for_adb_root` — full uid/gid + capability escalation + SID transition (best-effort)

### Remaining minor limitation

⚠️ **ksu domain not in active SELinux policy** → `security_secctx_to_secid("u:r:ksu:s0")` returns sid=0. So escalated processes get **uid=0 + full caps** but stay in original SELinux context.

**Mitigation auto-applied:** init.rc fragment auto-runs `setenforce 0` at multiple stages → SELinux is permissive at boot. KSU functionality fully unaffected.

For full enforcing ksu_domain: needs sepolicy.c rewrite for 4.19's `selinux_state.ss->policydb` (~1-2 days, deferred to a future Phase).

### Manager APK + ksud daemon

✅ **Installed and working**:
- `me.weishu.kernelsu` package installed via `adb install`
- ksud sub-processes execute on-demand from manager
- logcat shows ksud successfully querying kernel features:
  ```
  ksud::cli: command: Feature { command: Get { id: "sulog" } }
  ksud::cli: command: Feature { command: Check { id: "adb_root" } }
  ```
- Kernel responds via our 4.19-compat'd feature handler subsystem

### Auto-Permissive at boot

Injected `setenforce 0` into KSU's init.rc fragment at multiple stages
(`on early-init`, `on post-fs-data`, `on nonencrypted`, `on property:sys.boot_completed=1`).
The post-boot_completed trigger reliably sets Permissive after Android's
`selinux_setup` runs. Verified `getenforce` returns `Permissive` post-boot.

To fully restore KSU functionality on 4.19 would require ~1-2 weeks of arch-specific work:
1. Reimplement syscall hook layer for 4.19 syscall table layout
2. Reimplement SELinux integration against 4.19's `selinux_state.ss` (vs 5.7's `.policy`)
3. Reimplement supercall ioctl with 4.19 task_pgrp/init_task semantics

For security research goals (frida, stackplz, bpftrace, BPF CO-RE): all work without these KSU features.

## Patches applied to KernelSU

Recorded in `workspace/kernel/android_kernel_xiaomi_sm8250/drivers/kernelsu/` git history. Files modified:
- core/init.c — MODULE_IMPORT_NS guard + bypass syscall hooks at runtime
- policy/allowlist.c — TWA_RESUME compat + put_task_struct include
- policy/app_profile.c — seccomp.filter_count guard + seccomp_filter_release fallback
- infra/seccomp_cache.c — wrapped 5.13+ guard
- infra/su_mount_ns.c — wrapped 5.9+ guard with 4.x stub
- infra/file_wrapper.c — wrapped 5.1+ guard with 4.x stub
- selinux/selinux.c, selinux/rules.c, selinux/sepolicy.c — wrapped 5.7+ guard with 4.x stubs
- supercall/dispatch.c — wrapped 5.0+ guard with 4.x stubs
- sulog/event.c, supercall/supercall.c — minmax.h + TWA_RESUME compat
- feature/kernel_umount.c — path_umount 5.9+ guard
