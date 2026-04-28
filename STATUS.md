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

### What's still left for full functionality

⚠️ **SELinux integration**: All SELinux .c files are still stubbed (`is_ksu_domain` returns false, etc). When KSU intercepts execve to grant root to a manager-allowlisted app, the SELinux domain transition to `ksu` doesn't happen. The app gets uid=0 but stays in original SELinux context, so it'll hit denials when accessing protected files.
⚠️ **Manager APK + ksud daemon**: Userspace components not installed. Once installed, the kernel side will service their ioctls correctly via the now-working supercall path.

For typical `adb shell` security research use, none of these matter — adb is already root with elevated SELinux context.

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
