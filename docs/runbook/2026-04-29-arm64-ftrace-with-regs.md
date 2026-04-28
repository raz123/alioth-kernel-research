# arm64 4.19 HAVE_DYNAMIC_FTRACE_WITH_REGS Backport

**Date:** 2026-04-29
**Outcome:** BPF fentry programs on alioth 4.19-cip arm64 now read **real
function argument registers** (x1..x7) via `regs->regs[1..7]` from a
`pt_regs *` snapshot taken inside `ftrace_regs_caller`. Previously the
`ksu_register_ftrace_adapter` callback received `regs == NULL` and had to
feed the BPF program a zero-filled args buffer.

## Problem

Phase 2 Round 2 (commits `9a7c71dabb06` + `8ccba43d1805`) made fentry
attach work via a `register_ftrace_function`-based adapter. The adapter
ran fine but its callback signature was effectively `func(ip, parent_ip,
ftrace_ops*, NULL)` — the `pt_regs *regs` argument was always NULL
because 4.19 arm64 didn't select `HAVE_DYNAMIC_FTRACE_WITH_REGS`. BPF
programs reading `ctx[0..7]` got zeros.

The blocker is purely an arch-level missing piece: ftrace's WITH_REGS
infrastructure (`FTRACE_OPS_FL_SAVE_REGS`, `ftrace_modify_call`,
`FTRACE_REGS_ADDR`) is fully present in 4.19-cip's `kernel/trace/ftrace.c`
but conditioned on `CONFIG_DYNAMIC_FTRACE_WITH_REGS`, which `def_bool y;
depends on HAVE_DYNAMIC_FTRACE_WITH_REGS` — and arm64 4.19 doesn't select
that.

## The fix — single commit `2f9a02d7877f` in `android_kernel_xiaomi_sm8250-bpf-research`

Five files changed, ~165 LOC additions:

### `arch/arm64/Kconfig` — opt in

```diff
 select HAVE_DYNAMIC_FTRACE
+select HAVE_DYNAMIC_FTRACE_WITH_REGS
 select HAVE_EFFICIENT_UNALIGNED_ACCESS
```

This automatically turns on `CONFIG_DYNAMIC_FTRACE_WITH_REGS=y` (def_bool y).

### `arch/arm64/include/asm/ftrace.h` — declare 4-arg ABI

```c
#define ARCH_SUPPORTS_FTRACE_OPS 1
```

With this, ftrace stops auto-routing all calls through `ftrace_ops_list_func`
(it sets `FTRACE_FORCE_LIST_FUNC=0`) and expects the arch's `ftrace_caller`
to pass `(ip, parent_ip, op, regs)` to the patched-in callback.

### `arch/arm64/kernel/entry-ftrace.S` — two trampolines

#### Updated `ftrace_caller` (no-regs path)

```asm
ENTRY(ftrace_caller)
    mcount_enter
    mcount_get_pc0  x0
    mcount_get_lr   x1
    ldr_l           x2, function_trace_op   // <- new: load global
    mov             x3, xzr                 // <- new: NULL regs
ftrace_call:
    nop                                     // patched to bl <tracer>
    ...
    mcount_exit
ENDPROC(ftrace_caller)
```

#### New `ftrace_regs_caller` (regs path)

```asm
ENTRY(ftrace_regs_caller)
    mcount_enter                       // pushes [x29, x30] of instrumented fn
    sub sp, sp, #S_FRAME_SIZE          // alloc 320-byte pt_regs frame
    stp x0,  x1, [sp, #S_X0]
    stp x2,  x3, [sp, #S_X2]
    ...
    stp x26, x27, [sp, #S_X26]
    ldr x9,  [x29, #0]                 // saved x29 of instrumented fn
    ldr x10, [x29, #8]                 // saved x30 of instrumented fn
    stp x28, x9,  [sp, #S_X28]
    str x10,      [sp, #S_LR]
    add x11, x29, #16
    str x11,      [sp, #S_SP]          // caller sp
    sub x11, x10, #4
    str x11,      [sp, #S_PC]          // patch site
    mrs x9, nzcv
    str x9,       [sp, #S_PSTATE]
    str xzr,      [sp, #S_ORIG_X0]
    sub x0, x10, #4                    // ip = patch site
    ldr x11, [x29, #0]
    ldr x1,  [x11, #8]                 // parent_ip
    ldr_l x2, function_trace_op
    mov x3, sp                         // pt_regs *
ftrace_regs_call:
    nop                                 // patched to bl <tracer>
    add sp, sp, #S_FRAME_SIZE
    mcount_exit
ENDPROC(ftrace_regs_caller)
```

### `arch/arm64/kernel/ftrace.c` — two patcher API additions

```c
int ftrace_update_ftrace_func(ftrace_func_t func)
{
    /* patch the bl in ftrace_call ... */
#ifdef CONFIG_DYNAMIC_FTRACE_WITH_REGS
    /* ALSO patch the bl in ftrace_regs_call so both trampolines hit
     * the same dispatcher. (Modeled on x86's same-named function.) */
#endif
}

int ftrace_modify_call(struct dyn_ftrace *rec,
                       unsigned long old_addr, unsigned long new_addr)
{
    /* patch bl at rec->ip from `bl old_addr` to `bl new_addr`. ftrace
     * core calls this when toggling FTRACE_FL_REGS — i.e. switching
     * a record between ftrace_caller and ftrace_regs_caller. */
}
```

Module records out of ±128MB return -EINVAL — ftrace falls back to the
regular caller for those.

### `kernel/bpf/trampoline.c` — adapter consumer update

```c
ad->ops.flags = FTRACE_OPS_FL_SAVE_REGS               // <- new: required
              | FTRACE_OPS_FL_SAVE_REGS_IF_SUPPORTED  // <- kept for back-compat
              | FTRACE_OPS_FL_DYNAMIC;
```

Why both: when `CONFIG_DYNAMIC_FTRACE_WITH_REGS=y`, ftrace.c's
`#ifndef CONFIG_DYNAMIC_FTRACE_WITH_REGS` block (lines 347-359, the
auto-upgrade `IF_SUPPORTED → SAVE_REGS`) is compiled out, so consumers
must declare `SAVE_REGS` explicitly. `IF_SUPPORTED` stays so the same
source builds on a kernel without the WITH_REGS backport.

## Three-iteration discovery — what got debugged

The summary above looks tidy; reality was three rounds. Each `flash-test
+ adb` cycle is below.

### Round 1 — kernel built but adapter still got NULL regs

Kconfig + asm.h + entry-ftrace.S + ftrace_modify_call all in. Build OK,
boot OK. fentry program loaded, `bpftool link list` showed it attached.
But `cat /sys/kernel/tracing/enabled_functions` reported `do_sys_open (1)`
with **no `R`** flag — meaning ftrace did not flip the patch site to
`ftrace_regs_caller`. Trace events still showed `flags=0` (zero buffer).

**Cause:** `ksu_register_ftrace_adapter` set only `FL_SAVE_REGS_IF_SUPPORTED`,
relying on ftrace.c to auto-upgrade to `FL_SAVE_REGS`. But the upgrade
lives inside `#ifndef CONFIG_DYNAMIC_FTRACE_WITH_REGS`, so when
`CONFIG_DYNAMIC_FTRACE_WITH_REGS=y` it's gone. Without `FL_SAVE_REGS` set,
`__ftrace_hash_rec_update` doesn't set `FTRACE_FL_REGS` on the record,
and the patch site stays on `ftrace_caller`.

**Fix:** add `FTRACE_OPS_FL_SAVE_REGS` to `ad->ops.flags`.

### Round 2 — `R` flag set, but no events fire

After Round 1's fix, `enabled_functions` showed `do_sys_open (1) R    `.
ftrace had switched the patch site to `ftrace_regs_caller`. But `ls /`
produced **zero trace events**. dmesg clean — no panic, no oops.

**Cause:** `ftrace_update_ftrace_func()` only patches the NOP at
`ftrace_call`. With WITH_REGS there are TWO NOPs (`ftrace_call` inside
`ftrace_caller`, `ftrace_regs_call` inside `ftrace_regs_caller`). When
ftrace called `ftrace_update_ftrace_func` at register time, it patched
`ftrace_call` to `bl <handler>` but `ftrace_regs_call` stayed as `nop`.
So `bl ftrace_regs_caller; ...; ftrace_regs_call: nop` ran the prologue
and immediately fell through `mcount_exit` without ever calling our
handler.

**Fix:** mirror x86 — `ftrace_update_ftrace_func` patches BOTH NOPs.

### Round 3 — events fire, args are real

```
$ adb shell cat /sys/kernel/tracing/enabled_functions
do_sys_open (1) R

$ ls / ; echo x > /data/local/tmp/test
$ adb shell cat /sys/kernel/tracing/trace | grep FENTRY
sh   FENTRY x1_filename=b40000718da8b2d8 x2_flags=20241 x3_mode=1b6
ls   FENTRY x1_filename=72d088f968        x2_flags=a8000 x3_mode=0
ls   FENTRY x1_filename=72d088fa68        x2_flags=a8000 x3_mode=0
ls   FENTRY x1_filename=7fed233d00        x2_flags=a8000 x3_mode=0
```

Decoded:
- `x2_flags=0x20241` for sh's `> /data/local/tmp/test` =
  `O_RDONLY|O_NOCTTY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW`
- `x3_mode=0x1b6` = octal `0666` (the create mode for `>`)
- `x2_flags=0xa8000` for ls = `O_DIRECTORY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW`

These match what userspace actually requests for openat — args are real.

## Caveat — `regs->regs[0]` is parent_pc, not arg0

This is an mcount ABI hard limit. Looking at `do_sys_open`:

```
ffffff801030528c: aa1e03e0   mov x0, x30        ; clobber x0 with lr
ffffff8010305290: 97f66b60   bl  _mcount
```

By the time `_mcount` (or `ftrace_regs_caller`) is reached, x0 has been
overwritten with the parent return address. The compiler **does** spill
the original x0 to a callee-saved register before the clobber, but the
destination is function-specific (x19/x20/x21/...), so no generic
recovery path exists.

**What `regs->regs[0]` actually contains:** the address of the instruction
immediately after `bl <caller>` in the function's parent. This is useful
for caller identification but is NOT the function's first argument.

**What x1..x7 contain:** the function's argument registers 1..7. The
compiler spills them to callee-saved regs *before* `mov x0, x30; bl
_mcount` but does not modify x1..x7 in-place, so they are still the
original arg values at mcount entry.

To recover x0 properly we'd need `-fpatchable-function-entry=2` (used by
upstream arm64 5.5+). That places 2 NOPs **before** the function prologue,
so x0..x7 are all the original arg registers when the patched-in `bl
ftrace_caller` runs. Backporting that requires a kernel-wide compiler
flag change + recordmcount overhaul — out of scope for this branch.

## Reference

- Upstream pattern this borrows from: `arch/x86/kernel/ftrace.c::ftrace_update_ftrace_func`
  which patches both `ftrace_call` and `ftrace_regs_call` on x86.
- Linux 5.5 arm64 commit `3b23e4991fb6` ("arm64: implement ftrace with
  regs") — the *correct* WITH_REGS implementation, but uses
  `-fpatchable-function-entry=2`. We chose the mcount-based path because
  4.19-cip's existing ftrace is mcount-based and rebuilding userspace
  with new flags isn't practical here.
- 4.19-cip's `kernel/trace/ftrace.c` — already has full WITH_REGS support
  in the core, just needed the arch to opt in.
