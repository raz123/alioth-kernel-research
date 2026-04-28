# Alioth Kernel Research — 文档索引

这个项目把最新 KernelSU + 完整 BPF 工具链塞进 Linux 4.19-cip 的 alioth (Redmi K40 / POCO F3 / Mi 11X)。

## 文档结构

### 设计与计划
- [`superpowers/specs/2026-04-28-alioth-bpf-kernelsu-design.md`](superpowers/specs/2026-04-28-alioth-bpf-kernelsu-design.md) — 设计规范（项目目标、阶段划分、风险、DoD）
- [`superpowers/plans/2026-04-28-alioth-bpf-kernelsu.md`](superpowers/plans/2026-04-28-alioth-bpf-kernelsu.md) — 实施计划（每步 bite-sized 任务）
- [`research/2026-04-28-ebpf-feature-survey.md`](research/2026-04-28-ebpf-feature-survey.md) — eBPF 特性调研（5.5 → 6.12 时间线）

### 工程日志（Phase 0 + Phase 1 + Phase 2 完成）
- [`journey/2026-04-28-phase0-phase1-phase2-journey.md`](journey/2026-04-28-phase0-phase1-phase2-journey.md) — **完整工程日志：5 次砖 + 11 个 KSU 兼容补丁 + Phase 2 BTF firmware loader 4 次踩坑**
- [`FINAL-ACHIEVEMENTS.md`](FINAL-ACHIEVEMENTS.md) — **三阶段成果总结（推荐入口）**

### Runbook
- [`runbook/2026-04-28-ksu-patches.md`](runbook/2026-04-28-ksu-patches.md) — **每个 KSU 文件改动的详细解释**
- [`runbook/2026-04-28-btf-firmware-loader.md`](runbook/2026-04-28-btf-firmware-loader.md) — **Phase 2 Round 1: tracing/lsm/ext verifier-level 解锁**
- [`runbook/2026-04-28-arm64-bpf-trampoline.md`](runbook/2026-04-28-arm64-bpf-trampoline.md) — **Phase 2 Round 2: arm64 trampoline JIT + ftrace_function 适配器（fentry 真正 fire）**
- [`runbook/2026-04-29-arm64-ftrace-with-regs.md`](runbook/2026-04-29-arm64-ftrace-with-regs.md) — **Phase 2 Round 3: HAVE_DYNAMIC_FTRACE_WITH_REGS backport（fentry 程序读到真实 x1..x7 函数参数）**
- [`runbook/2026-04-28-recovery-runbook.md`](runbook/2026-04-28-recovery-runbook.md) — **设备砖了怎么救**

### Phase 2 patch + 工件
- `workspace/kernel/patches/phase2-bpf-backport/00-survey/STRATEGY.md` — Phase 2 调研结论：CIP 已 backport 五大系列
- `workspace/kernel/patches/phase2-bpf-backport/00-survey/btf-fw/vmlinux.btf` — 4.19-strict BTF 文件（部署到 `/data/local/tmp/`）
- `workspace/kernel/patches/phase2-bpf-backport/01-arm64-trampoline/STRATEGY.md` — Round 2 设计 + 4 次踩坑日志 + outcome

### 项目级状态
- [`/STATUS.md`](../STATUS.md) — 当前 phase 进度、device 状态、下一步

## 快速导航

| 需求 | 看这个 |
|---|---|
| 想看整个项目做了什么 | [FINAL-ACHIEVEMENTS](FINAL-ACHIEVEMENTS.md) |
| 我刷砖了 | [recovery-runbook](runbook/2026-04-28-recovery-runbook.md) |
| 想在另一台 4.19 设备复现 KSU 兼容补丁 | [ksu-patches](runbook/2026-04-28-ksu-patches.md) |
| 想搞清楚 BTF firmware loader 怎么做的 | [btf-firmware-loader](runbook/2026-04-28-btf-firmware-loader.md) |
| 想搞清楚为什么 BPF fentry 程序读到真实函数参数 | [arm64-ftrace-with-regs](runbook/2026-04-29-arm64-ftrace-with-regs.md) |
| 想理解为什么走到现在的方案（5 + 4 次踩坑） | [phase0-phase1-phase2-journey](journey/2026-04-28-phase0-phase1-phase2-journey.md) |
| 想知道 Phase 2 实际做了哪些 vs 计划 | [STRATEGY.md](../workspace/kernel/patches/phase2-bpf-backport/00-survey/STRATEGY.md) |
| 当前 active boot_a 跑啥版本 | [STATUS.md](../STATUS.md) |
