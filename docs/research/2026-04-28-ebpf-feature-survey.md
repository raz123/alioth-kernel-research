# Android eBPF Feature Survey — What to Backport for alioth's 4.19-cip Kernel

**Date:** 2026-04-28
**Purpose:** Determine the minimum and ideal sets of BPF subsystem patches to backport from upstream Linux into the 4.19-cip kernel running on alioth, in order to support the user's security-research toolchain (`frida`, `stackplz`, `bpftrace`, `libbpf-bootstrap`/CO-RE programs).

This is research input to `2026-04-28-alioth-bpf-kernelsu-design.md`. It is **descriptive**, not prescriptive — it lays out facts and tradeoffs; the design doc decides.

---

## 1. Reference points: Android GKI and upstream Linux BPF lineage

### 1.1 Android GKI version landscape (2026)

Android does not have its own BPF subsystem; it ships GKI (Generic Kernel Image) which is upstream Linux + Android-specific patches. Active GKI branches as of 2026-04:

| Branch | Linux base | Android release | Status |
|---|---|---|---|
| `android16-6.12` | 6.12 | Android 16 (primary) | Current |
| `android15-6.6` | 6.6 | Android 15 | Maintained |
| `android14-6.1` | 6.1 | Android 14 | Maintained |
| `android14-5.15` | 5.15 | Android 14 | Maintained |
| `android13-5.15` | 5.15 | Android 13 | Maintained |
| `android13-5.10` | 5.10 | Android 13 | Maintained |
| `android12-5.10` | 5.10 | Android 12 | Maintained |
| `android12-5.4` | 5.4 | Android 12 | Maintained |
| `android11-5.4` | 5.4 | Android 11 | LTS |

Note: Sources confirm Google announced from Android 15 onward, only one new GKI per kernel version. So no `android16-6.6` will appear; 6.12 is *the* Android 16 kernel.

**alioth's 4.19-cip is not in this list** — it is community-maintained (LineageOS + CIP SLTS), not GKI. That's why our project is backporting features rather than syncing branches.

### 1.2 BPF subsystem feature timeline (Linux 4.19 → 6.12)

Compressed to features that matter for tracing/security research:

| Linux ver | Year | Headline BPF features |
|---|---|---|
| 4.19 | 2018 | Base BPF, JIT, kprobe/uprobe attach via perf, BTF rudiments, `bpf_redirect_map` |
| 5.0-5.4 | 2019 | BTF dedup, BPF_LSM groundwork, type-aware verifier, `bpf_get_stack` |
| **5.5** | 2019-12 | **BPF trampoline, fentry/fexit** — direct function-replace, ~10× faster than kprobe |
| **5.6** | 2020-03 | **`bpf_iter`** (seq-file walking), `struct_ops`, `bpf_get_current_task` |
| **5.7** | 2020-05 | **`bpf_link`**, **LSM BPF** (mandatory access control via BPF), CAP_BPF separation |
| 5.8 | 2020-08 | **`ringbuf`** (BPF ring buffer, replaces perf_event for output) |
| 5.9 | 2020-10 | `bpf_d_path`, BPF iterator for files/maps, batched map ops |
| **5.10** | 2020-12 | **Sleepable BPF programs**, BTF for kernel modules, `bpf_per_cpu_ptr`. **LTS — most BPF tooling targets ≥ 5.10.** |
| 5.11 | 2021-02 | `BPF_PROG_TYPE_SK_LOOKUP`, atomic ops in maps, untrusted args, BPF func-id-to-string |
| 5.12 | 2021-04 | `bpf_link` cookies, syscall trampoline plumbing, `bpf_for_each_map_elem` |
| 5.13 | 2021-06 | Inline BPF dispatcher, expanded cgroup attach types |
| 5.14 | 2021-08 | `BPF_PROG_TYPE_SYSCALL`, bloom-filter map, mmap-able task struct |
| **5.15** | 2021-10 | **`bpf_timer_*`** (in-kernel periodic callbacks), task_local_storage, cpumask helpers. **LTS.** |
| 5.16 | 2022-01 | `bpf_loop`, BTF type tags, JIT direct call optimization |
| 5.17 | 2022-03 | `bpf_strncmp`, BPF_PROG_TYPE_TRACING + iterators integrated |
| 5.18 | 2022-05 | More verifier loop support, kfunc framework introduced |
| 5.19 | 2022-07 | **`dynptr`** (dynamic pointers — a major data-shape change) |
| 6.0 | 2022-10 | BPF dispatcher to perf_event, `bpf_loop` optimization |
| 6.1 | 2022-12 | BPF kfuncs go GA, network bpf_skb_* helpers expanded. **LTS.** |
| 6.2 | 2023-02 | BPF kptr exchange, refined `dynptr` |
| 6.3 | 2023-04 | **`tcx`** (next-gen tc), netfilter BPF |
| 6.4 | 2023-06 | `BPF_PROG_TYPE_NETFILTER` lands |
| 6.5 | 2023-08 | BPF trampoline rework, `bpf_link` to perf events |
| **6.6** | 2023-10 | **BPF token** (delegated capabilities), program signing groundwork. **LTS, android15-6.6.** |
| 6.7 | 2024-01 | struct_ops user expansion, fuse-bpf |
| 6.8 | 2024-03 | **BPF arena** (large shared memory), JIT improvements |
| 6.9 | 2024-05 | BPF token finalized, range tracker overhaul |
| 6.10 | 2024-07 | Misc verifier polish |
| 6.11 | 2024-09 | BPF token for cgroup, bpf_timer cleanup |
| **6.12** | 2024-11 | Refinements; Android 16 baseline. **LTS.** |

Key observations:
- The "modern BPF" inflection is **5.5 → 5.10**: trampoline + iter + link + LSM + ringbuf + sleepable. After 5.10 the gains are diminishing-returns for tracing tools.
- 5.15 adds `bpf_timer` — useful but rarely required.
- 5.19 adds `dynptr` — fundamental enough that backporting beyond 5.15 gets significantly harder.
- **Most third-party BPF tooling explicitly targets 5.10 as the minimum baseline** (this is what stackplz, libbpf-bootstrap examples, and bpftrace reference distros use).

---

## 2. What each tool actually needs

### 2.1 frida
- Mostly userspace; uses ptrace + uprobe via `/sys/kernel/tracing/uprobe_events`
- **No BPF dependency.** Works on any kernel that has `CONFIG_UPROBES`.
- Already works on alioth today.

### 2.2 stackplz (per upstream README and source)
- Linux **5.10+** for full functionality (per project README)
- Required configs: `CONFIG_DEBUG_INFO_BTF`, `CONFIG_HAVE_HW_BREAKPOINT`, `CONFIG_BPF_SYSCALL`, `CONFIG_BPF_JIT`, `CONFIG_KPROBES`, `CONFIG_UPROBES`, `CONFIG_BPF_EVENTS`
- BPF features used: uprobe/uretprobe, kprobe (syscall tracing), ringbuf, BTF/CO-RE
- Optional: hw breakpoint mode works on 4.1x with `CONFIG_HAVE_HW_BREAKPOINT`
- **Will work fully after Phase 1** (BTF + ftrace already gives uprobe/kprobe/ringbuf/CO-RE)

### 2.3 bpftrace
- Modern bpftrace (≥ 0.18) wants:
  - BTF (5.4+ for vmlinux BTF) — **needed in P1**
  - `bpf_iter` (5.6) — for `iter:task` etc. probes
  - fentry/fexit (5.5) — for `fentry:func{ ... }` probes (much faster than kprobe)
  - ringbuf (5.8) — for `printf` output buffering
  - LSM BPF (5.7) — for `lsm:*` probes
- Older bpftrace (≤ 0.17) only needs BTF + kprobe + perf_event_array; works on P1.
- **Full bpftrace experience needs Phase 2** (specifically series 1, 2, 3 — bpf_link, bpf_iter, trampoline).

### 2.4 libbpf-bootstrap / CO-RE programs
- BTF (`/sys/kernel/btf/vmlinux`) is the hard requirement
- libbpf relocations work on any kernel ≥ 5.4 with BTF, **but** any program using a feature added after 5.10 will fail to load on a 5.10-equivalent kernel
- Most public tutorials and examples (Brendan Gregg, Cilium examples, eunomia-bpf samples) target 5.10
- **Phase 1 covers ~80% of public examples; Phase 2 covers the rest.**

### 2.5 KernelSU
- Officially supports GKI 2.0 (5.10+), older kernels (4.14+) supported with manual build
- For 4.19: standard non-kprobes (source-patched) integration is ~50 lines into `fs/exec.c`, `fs/open.c`, `fs/read_write.c`, `fs/stat.c`
- No BPF dependency
- Manager APK works regardless of kernel BPF state

---

## 3. What's already in alioth's 4.19-cip (verified on device)

Already backported (CIP + LineageOS + Google maintenance combined):
- Base BPF subsystem ✓
- BPF JIT (always-on) ✓
- **BPF_LSM** (5.7 feature) ✓ — `CONFIG_BPF_LSM=y`, listed in active LSM stack
- **ringbuf** (5.8 feature) ✓ — verified runtime via test program in `/sys/fs/bpf/`
- XDP, NET_CLS_BPF, BPF_EVENTS ✓
- kprobe, uprobe, uprobe_events ✓
- KASAN-capable build infrastructure ✓
- `bpftool` userspace at `/system/bin/bpftool` ✓

**The CIP team has been quietly doing more BPF backporting work than expected.** This significantly reduces the work in our Phase 2.

Not present (the gaps):
- `CONFIG_DEBUG_INFO_BTF` — config-level, just needs flipping on
- `CONFIG_FUNCTION_TRACER` / `DYNAMIC_FTRACE` — config-level, but consumes ~2-5 MB extra text + small runtime cost
- `CONFIG_KPROBE_EVENTS`, `FTRACE_SYSCALLS` — config-level
- BPF trampoline (5.5) — **code-level patch series needed**
- bpf_iter (5.6) — **code-level patch series needed**
- bpf_link (5.7) — **code-level patch series needed** (note: BPF_LSM uses links, so a partial implementation may already exist — to be confirmed by reading `kernel/bpf/syscall.c` in the source tree)
- struct_ops (5.6) — **code-level patch series needed**
- Sleepable BPF (5.10) — **code-level patch series needed**

---

## 4. Gap analysis vs. user goals

### 4.1 Phase 1 alone is sufficient for:
- ✅ Running stackplz against any user-space target (uprobe + ringbuf + BTF available)
- ✅ Running frida (no kernel feature dependency)
- ✅ Running ~80% of `libbpf-bootstrap` examples
- ✅ Running bpftrace ≤ 0.17 scripts
- ✅ Most CO-RE BPF programs that target Linux 5.4-5.7
- ✅ KernelSU (no BPF dependency)

### 4.2 Phase 2 additionally enables:
- 🟦 fentry/fexit-based bpftrace probes (~10× faster than kprobe-based equivalent)
- 🟦 `iter:` probes in bpftrace (walk tasks/files/maps)
- 🟦 Sleepable BPF programs (LSM hooks that can take page faults, e.g., for path-based access control)
- 🟦 struct_ops (used by tcp_congestion modules — niche for tracing)
- 🟦 bpf_link cookies (per-attach private data — improves multiplex)

### 4.3 Phase 2 does NOT add:
- ❌ bpf_timer (5.15) — unless we extend scope
- ❌ dynptr (5.19) — out of practical reach for 4.19 (verifier divergence)
- ❌ kfunc framework (5.18 GA, 6.1 stable) — out of practical reach for 4.19
- ❌ BPF arena / token (6.6+) — out of practical reach

---

## 5. Recommended backport scope

### 5.1 Phase 1 (Recommended — no code changes, only config + KSU)
Flip these Kconfig options + integrate KernelSU. Effort: 3-5 days.

```
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_FUNCTION_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_DYNAMIC_FTRACE_WITH_REGS=y
CONFIG_KPROBE_EVENTS=y
CONFIG_FTRACE_SYSCALLS=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_HAVE_KPROBES_ON_FTRACE=y    # if not already implied by arch
```

Plus KernelSU non-kprobes integration.

### 5.2 Phase 2 (Recommended — selective backport from 5.5-5.10)
Five patch series, in dependency order:

| # | Series | Source ver | Patches (est) | Risk |
|---|---|---|---|---|
| 1 | `bpf_link` infra (verify what's already there) | 5.7 | ~10 | Low |
| 2 | `bpf_iter` | 5.6 | ~15 | Low |
| 3 | BPF trampoline + fentry/fexit | 5.5 | ~30 | **High (arm64 JIT)** |
| 4 | `struct_ops` | 5.6 | ~10 | Low-Med |
| 5 | Sleepable BPF | 5.10 | ~5 | Low |

Effort: 2-3 weeks (high variance from series 3).

### 5.3 Out of scope, but listed for later (Phase 3 if user requests)
Optional series, none of which the current toolchain needs:

| Feature | Source ver | Effort if pursued | Marginal value |
|---|---|---|---|
| `bpf_timer` | 5.15 | 1 week | Low — only useful for periodic in-kernel work |
| `bpf_loop` helper | 5.16 | 3 days | Low |
| `bpf_d_path` extensions | 5.10 | 2 days | Already partial in 4.19-cip |
| `BPF_PROG_TYPE_SYSCALL` | 5.14 | 1 week | Niche |
| dynptr | 5.19 | **Not feasible** for 4.19 backport | High but unreachable |
| kfunc framework | 5.18 GA | **Not feasible** | Diverges verifier |
| BPF arena / token | 6.6+ | **Not feasible** | Out of scope |

The 5.19+ features cannot be cleanly backported to 4.19 because the verifier underwent fundamental restructuring around register types and memory tracking. Attempts to backport these would essentially mean rewriting 4.19's verifier. **This is the practical ceiling for this project: 5.10 BPF + perhaps 5.15 timer if there's special demand.**

---

## 6. Sources of patches

In order of preference:

1. **Upstream Linux git** (`git.kernel.org`) — `linux-5.5.y`, `linux-5.6.y`, ..., `linux-5.10.y`. Cherry-pick by feature tag.
2. **Google's `android-mainline` and `android-4.19-stable`** branches — many BPF series have already been validated for 4.19 by Google for GKI testing. If accessible from `android.googlesource.com/kernel/common`, this is the highest-quality source (already tested on real Android).
3. **CIP (Civil Infrastructure Platform) `linux-4.19.y-cip` tree** — already partially BPF-backported; review their work for bpf_iter / trampoline patches that may already be partially present.
4. **Manual cherry-pick from `linux-stable` "fixes" series** with `Cc: stable@vger.kernel.org # 4.19+` markers — these are pre-vetted backports.

The AI's strategy: try sources in order; for each missing series, prefer pre-validated patches (sources 2, 3, 4) over manual cherry-pick (1).

---

## 7. Final scope decision (feeds back to design doc)

**Recommendation:** Stick with the design doc's Phase 1 + Phase 2 scope (target = Linux 5.10 BPF feature parity). Do not expand to 5.11+ unless user later requests specific features that need them.

Reasoning:
- 5.10 is the explicit baseline for stackplz, modern bpftrace, and most libbpf-bootstrap examples
- Going beyond 5.10 hits exponentially increasing backport difficulty (verifier evolution)
- 5.10-equivalent gives the user the full security-research toolchain they listed
- A well-defined, achievable scope beats an ambitious scope that stalls

If the user later needs `bpf_timer` or `bpf_loop` specifically, those are isolated 1-week additions and can be tacked on without restructuring.

---

## Sources

- [android16-6.12 release builds — AOSP](https://source.android.com/docs/core/architecture/kernel/gki-android16-6_12-release-builds)
- [Android common kernels — AOSP](https://source.android.com/docs/core/architecture/kernel/android-common)
- [Generic Kernel Image (GKI) project — AOSP](https://source.android.com/docs/core/architecture/kernel/generic-kernel-image)
- [Extend the kernel with eBPF — AOSP](https://source.android.com/docs/core/architecture/kernel/bpf)
- [stackplz upstream — GitHub](https://github.com/SeeFlowerX/stackplz)
- [KernelSU upstream — GitHub](https://github.com/tiann/KernelSU)
- [BPF Kernel Functions (kfuncs) — kernel.org](https://docs.kernel.org/next/bpf/kfuncs.html)
- [BPF Timers in Linux 5.15 — Phoronix](https://www.phoronix.com/news/BPF-Timers-For-Linux-5.15)
- [eBPF Advanced: Overview of New Kernel Features — eunomia](https://eunomia.dev/blogs/bpf-news/)
- [bpftrace docs](https://bpftrace.org/docs/0.21)
- Mishaal Rahman's roundup on Android 16 supported kernel versions: [Threads post](https://www.threads.com/@mishaal_rahman/post/DFvPes5xN8J?hl=en)
