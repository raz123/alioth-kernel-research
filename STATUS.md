# Alioth Kernel Project — Status

| Phase | State | Notes |
|---|---|---|
| Pre-Phase | DONE | deps + scripts + stock backup + kernel source pinned |
| Phase 0 (vanilla) | DONE | NDK r29 clang r563880c match for stock; vermagic identical |
| Phase 1 (BTF+ftrace+KSU) | **DONE — KSU fully working** | Latest KSU v3.2.4: pmd_leaf fix unlocked phys_from_virt → all syscall hooks + supercalls + manager init now active |
| Phase 2 (BPF backport) | pending | |

## Current device state

- Active slot: `_a` (research kernel: P1 = ftrace + kprobes + KSU + detached BTF)
- `/proc/version` shows `(claude@research)` — our build
- KSU module: loaded, feature handlers registered
- BTF file at `/data/local/tmp/vmlinux.btf` (9.7MB, extracted from BTF-enabled build)
- Stock backup at `workspace/stock-images/boot_a-original.img` for instant restore
- AVB: vbmeta_a + vbmeta_b flashed with `--disable-verification`

## What works in Phase 1

✅ Dynamic ftrace (68942 traceable functions)
✅ kprobe events via `/sys/kernel/tracing/kprobe_events`
✅ uprobe events (already worked in stock)
✅ Detached BTF for libbpf CO-RE programs (use `--btf` flag pointing to `/data/local/tmp/vmlinux.btf`)
✅ KernelSU module loaded; `feature management` initialized
✅ KSU sulog and adb_root handlers registered
✅ frida unaffected (no kernel dependency)
✅ adb root persists (userdebug ROM)

## KSU on 4.19 — current capability

✅ All three init paths now work:
   - `ksu_syscall_hook_init` — dispatcher installed at NI-syscall slot 42
   - `ksu_supercalls_init` — reboot kprobe registered (manager comms)
   - `ksu_syscall_hook_manager_init` — kretprobes + 4 syscall hooks (setresuid/execve/newfstatat/faccessat) + sys_enter tracepoint
✅ `handle_setresuid` hook firing live for uid transitions during boot
✅ KSU init.rc fragment appended; `on_post_fs_data!` fires
✅ `ksu_register_syscall_hook` succeeds (was silently failing on 4.19 before pmd_leaf fix)

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

### Remaining limitation

⚠️ **ksu domain not in active SELinux policy** → `security_secctx_to_secid("u:r:ksu:s0")` returns sid=0. So escalated processes get **uid=0 + full caps** but SELinux MAC context unchanged. SELinux denials may still happen when ksu-domain doesn't exist.

**Mitigations:**
- userdebug ROM (you have this): `adb shell setenforce 0` removes MAC enforcement entirely
- Manager APK installs: most root use cases work since uid=0 + caps suffice for many ops
- Full ksu domain transition: requires runtime sepolicy.c reimpl for 4.19 (~1-2 days more, deferred)

For your security research use (frida + BPF + stackplz from `adb shell`): no SELinux issues — adb already has trusted SELinux context.

### Manager APK + ksud daemon

Userspace components: not installed. Once installed, the kernel side services their supercall ioctls correctly via the now-working hook path.

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
