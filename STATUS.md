# Alioth Kernel Project — Status

| Phase | State | Notes |
|---|---|---|
| Pre-Phase | DONE | deps + scripts + stock backup + kernel source pinned to a5b3099017ae |
| Phase 0 (vanilla) | in-progress | First build with system clang-21 hung at boot. Vermagic & config matched stock identically (only compiler version metadata differed). Switching to AOSP clang-r584948 (closer to stock r563880c). Download in progress. |
| Phase 1 (BTF+ftrace+KSU) | pending | |
| Phase 2 (BPF backport) | pending | |

## Current device state

- Active slot: `_a` (stock LineageOS 23.2 kernel 4.19.325-cip128)
- Slot `_b`: not yet touched
- Stock backup taken: YES (2026-04-28, sha256 in `workspace/stock-images/SHA256SUMS`)
