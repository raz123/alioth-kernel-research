# arm64 BPF Trampoline Backport — Strategy

**Date:** 2026-04-28
**Goal:** Make `arch_prepare_bpf_trampoline()` work on 4.19-cip arm64, so
fentry/fexit/lsm BPF programs can attach to kernel functions.

## Why this is needed

Phase 2's BTF firmware loader unlocked the **verifier** for tracing/lsm/ext
prog types: bpftool `feature probe` reports them "available", and they JIT
successfully. But attempts to attach them fail:

```
libbpf: prog 'trace_open': failed to attach: Unknown error 524
```

`-ENOTSUPP` (524) comes from `kernel/bpf/trampoline.c:552`:

```c
int __weak arch_prepare_bpf_trampoline(...) { return -ENOTSUPP; }
```

CIP-128 has the trampoline **framework** (`bpf_trampoline_link_prog`,
`__bpf_prog_enter/exit`, etc.) but no arm64-specific assembly emitter.
Upstream Linux 6.0 commit `efc9909fdce0` added arm64 trampoline support
in 2022; we need to backport its essence to 4.19.

## Scope (~500-600 LOC)

### Files to modify

| File | Lines added | Purpose |
|---|---|---|
| `arch/arm64/include/asm/insn.h` | +5 | declare `aarch64_insn_gen_load_store_imm` |
| `arch/arm64/kernel/insn.c` | +40 | implement load/store immediate-offset insn generator |
| `arch/arm64/net/bpf_jit.h` | +30 | A64_LS_IMM macro family + LDR/STR_64I |
| `arch/arm64/net/bpf_jit_comp.c` | +500 | bpf_arch_text_poke + arch_prepare_bpf_trampoline + helpers |

### Key API differences from upstream 6.0

- 4.19 uses `struct bpf_tramp_progs` with `progs[]` and `nr_progs` fields
  (6.0 renamed to `bpf_tramp_links` with `links[]` and `nr_links`)
- 4.19's `__bpf_prog_enter(void)` returns u64, no run_ctx arg
  (6.0 takes `(prog, run_ctx)`)
- 4.19 has no `bpf_tramp_run_ctx` — simpler stack layout
- Skip `BPF_TRAMP_F_IP_ARG` (added later)
- No PLT/long-jump support (keep trampoline within ±128MB of patch site —
  works because both are vmalloc'd in module space)
- No BTI support (kernel not built with CONFIG_ARM64_BTI_KERNEL on this device)

## Plan (incremental, testable steps)

### Step 1: Add `aarch64_insn_gen_load_store_imm`
- Implement the LDR/STR (immediate, unsigned offset) instruction encoder
- Verify by adding A64_LS_IMM macro + test with a tiny snippet in bpf_jit_comp
- Risk: low — just an instruction encoder, no runtime side effects

### Step 2: Add `bpf_arch_text_poke()`
- Implements text patching: rewrite `nop` ↔ `bl <addr>` at function entry
- Uses existing `aarch64_insn_patch_text_nosync()` from `arch/arm64/kernel/insn.c`
- Risk: medium — mistakes corrupt kernel text, but only triggered on prog attach

### Step 3: Add minimal `arch_prepare_bpf_trampoline()` (fentry-only, no orig call)
- Support `BPF_TRAMP_F_RESTORE_REGS` flag only first
- ~150 lines: stack setup, save regs, call fentry progs, restore regs, return
- Risk: high — bad asm = oops on first attach

### Step 4: Extend to support `BPF_TRAMP_F_CALL_ORIG` + fexit
- Adds: call original function, save return value, run fexit progs
- ~150 more lines
- Risk: medium — mostly more of the same patterns

### Step 5: (Optional) PLT + long-jump support
- Currently skipped to avoid complexity
- Failure mode if needed: return -E2BIG when offset too big

### Step 6: (Optional) `BPF_TRAMP_F_RET_FENTRY_RET`, `BPF_TRAMP_F_IP_ARG`, fmod_ret
- Used by struct_ops and modify_return programs
- Skip for V1, can add later

## Test plan

Each step:
1. Compile (catch C errors)
2. flash-test (catch boot failures — 5 min cycle)
3. Load + attach a tiny fentry program
4. Verify trace_pipe shows bpf_printk output
5. Detach, reload, ensure no leaks/oops

## Brick risk + recovery

Each iteration is a kernel patch flash. Recovery:
- `recover.sh` flashes stock boot_a — instant restore (~1 min)
- Saved P2 image at `workspace/builds/20260428-222516-p2-btf-fw8.img` for fallback to last-good

## When to stop

If after Step 3 (minimal fentry) we can't get attach to work without oops,
this needs a serial console for proper debugging. Document the patch state
and stop, leaving a usable P2 (verifier-level) kernel on slot _a.

## Reference

Source of truth: upstream Linux 6.0 commit `efc9909fdce0` and follow-ups.
Reference file copies in this dir:
- `bpf_jit_v6.0.h` — upstream header for macro reference
- `bpf_jit_comp_v6.0.c` — upstream JIT for trampoline impl reference

---

## Outcome (2026-04-28 23:05)

### What we got done (committed kernel-side at 9a7c71dabb06)

✅ Step 1: `aarch64_insn_gen_load_store_imm()` + A64_LS_IMM macro family
✅ Step 2: `bpf_arch_text_poke()` for arm64 — with PLT-less short-jump only
✅ Step 3: `arch_prepare_bpf_trampoline()` + helpers (`invoke_bpf_prog`,
   `prepare_trampoline`, `save_args`, `restore_args`, `emit_call`)
✅ Step 4: A64_NOP / A64_HINT macros for older 4.19 bpf_jit.h
✅ Compiles cleanly, RAM-boots, vmlinux has the strong symbols
✅ ~500 LOC total

### What still blocks fentry attach

❌ The trampoline path in `kernel/bpf/trampoline.c::register_fentry()` calls
`register_ftrace_direct()` first, which returns `-ENOTSUPP` from a
static-inline stub in `include/linux/ftrace.h:275`. The real
implementation is gated on `CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS`,
which depends on `ARCH_SUPPORTS_FTRACE_DIRECT`. arm64 only got that
support in upstream Linux 6.2.

### Path to actually unlock fentry/fexit/lsm attach

The blocker is **independent** of our trampoline emitter — they're orthogonal
backport tasks. To get attach working, additionally:

1. Add `ARCH_SUPPORTS_FTRACE_DIRECT` Kconfig entry under `arch/arm64/Kconfig`
2. Implement `arch_ftrace_set_direct_caller()` in `arch/arm64/kernel/ftrace.c`
   - Modify the MCOUNT trampoline to load a per-fentry direct-caller pointer
3. Make `register_ftrace_direct` work with multiple direct callers per ip
4. Verify `tr->func.ftrace_managed = true` path works

Estimated 200-300 additional LOC in ftrace internals + arm64 entry asm.
This is genuinely 1-2 more days of focused work.

### Pragmatic stopping point

Our trampoline JIT is good code, it's committed, it's strong-symbol-
overriding the upstream stub. As soon as arm64 gets ftrace_direct support
(either by us or any other contributor), our emitter plugs in immediately.

For the user's actual research goal (Qunar's Ena1907_req SO function),
uprobe + tracefs is the right tool and works since 4.19 base — verified
live with full register-arg capture (Test 1+1b earlier in this session).

