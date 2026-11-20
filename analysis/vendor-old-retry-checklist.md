# 迁移到「旧 vendor 设备」的重试清单

- 适用: 目标设备 vendor(驱动侧) SPL **早于 2024-02**, 或不晚于 2024-08(落到 2024-08 Qualcomm bulletin 修复窗口内)。
- 背景: 本机 iQOO Z6(PD2220A / SM7325 / 5.4.281-qgki, SPL 2024-02)链路整条判死(见 `kernel-lpe-conclusions.md` §A–M)。多数判死是**该机环境性**:SMMU 代次(A6xx 无 A7xx 微码 bug)、稀疏/VBO 符号缺失、SELinux 掩码、perf 采样被禁。**换旧 vendor 设备前必须逐项重测, 不能照抄本机结论。**

---

## 0. 快筛(先摸清新机, ≤5 分钟)

- [ ] `uname -r` —— QGKI 与否、内核代次(5.4 / 4.19 / 4.14)。
  - 4.19 / 4.14 → §1.3 旧代 KGSL CVE(GhostLock)窗口可能重新打开。
- [ ] `getprop`(grep -iE "spatch|spL|security_patch") 或 `/system/build.prop` 的 `ro.build.version.security_patch`。
  - **SPL ≤ 2024-01** → 2024-08 bulletin 修复全未打 → §1.1/§1.2 直接存活。
  - **SPL ≤ 2023** → 2022-22057(§1.4)可能复活(本机已硬化)。
- [ ] KGSL 分发表是否能在 `kallsyms`/`/sys/kernel/tracing` 看到(见 §3)。
- [ ] 是否可先拿权限更易(`persist.sys.is_root`、`blackroot`、init root 是否已存在) —— 若已 root 就不必走内核。

---

## 1. 候选 CVE 复活重测(按倾向向下选第一个活着的)

### 1.1 首选: KGSL VBO / 稀疏区间树 UAF(vendor SPL ≤2024-01)
> 本机判死主因是**缺 `kgsl_sharedmem_vbo` / `kgsl_memdesc_add_range` / bind_ranges 符号**(载荷体缺失)。旧 vendor 设备只要符号在即复活。

- [ ] 符号存在性(任一):
  - [ ] `kgsl_ioctl_gpumem_bind_ranges`
  - [ ] `kgsl_sharedmem_vbo`
  - [ ] `kgsl_memdesc_add_range`
- [ ] 符号在 → 按序测: **CVE-2024-23380**(bind_ranges UAF) → **CVE-2024-23381**(VBO SMMU 未 unmap) → **CVE-2024-23384**(shrinker 回放) → **CVE-2024-33034**(过期 SMMU 映射)。
- [ ] 入口 ioctl `GPUMEM_BIND_RANGES` 在 `kgsl_ioctl_funcs` 分发表中存在(+compat)。

### 1.2 备选: GNSS/DSP/其它 vendor 模块 2024-02..08 窗口 CVE
- vendor SPL 落在 2024-02..2024-07 → 优先查 2024-08 Qualcomm bulletin **非 KGSL** 项(可经 /dev 或 vendor BSP ioctl 触发, 触发面常比 KGSL 宽)。

### 1.3 旧代: GhostLock / CVE-2026-43499(futex PI UAF)
- 本机判死源于 `waiter_node words_per_set` **几何限制**(内存控制器/SoC 相关)。
- 换机重测判定条件: `calls>0 && success>0`(不再 `step=33 not verified`) → **几何可行** → 这才值得继续。
- 若为更旧内核(非 QGKI): 竞态窗口/堆布局差异大, 需重新校准 trigger 时序。

### 1.4 硬化项复活检查: CVE-2022-22057 (kgsl_ioctl_timeline_destroy)
- 本机因 2022 后已有"饱和感知原子(kref_get_unless_zero)"修复而判死。
- 旧 vendor(SPL ≤2022 中)若 `kref_get_unless_zero` 未置入 → 该经典 OOB/use 复活, 且**不需要 KASLR 的载荷较成熟**。

---

## 2. 触发面 / 前置

- [ ] `/dev/kgsl-3d0` shell 可 open + `GPUMEM_ALLOC_ID` 正常(前测入口)。
- [ ] 若走 1.4(2022-22057): 确认不需精确内核地址(用 physmap/固定偏移), 否则跳 §3 先解 KASLR。
- [ ] 记录新机 `kgsl_ioctl_funcs` 分发表(反汇编重校准, **勿套本机 §H 常量**)。

---

## 3. KASLR / 指针泄漏前置(任一解封即好)

- [ ] `/proc/kallsyms` 是否给地址(非 denied)。
- [ ] `dmesg | head` 是否可读。
- [ ] `/proc/modules` 基址是否非 0。
- [ ] perf 采样:`perf_kaslr_mmap`(随附工具)+ `perf_event_paranoid` 是否出内核 IP(本机为 -1 但采样被禁)。
- [ ] `/sys/kernel/tracing/trace`、`/sys/kernel/debug/` 是否可见。
- [ ] 任一解封 → **KASLR 前置解除** → 才有资格评估高崩溃率 UAF 的 feng-shui; 全封 → 优先选 1.4 这类"免精确地址"原语。

---

## 4. 完成定义 / 回填

- [ ] 每项重测后在 `kernel-lpe-conclusions.md` §B–K 对应条目旁标注"新机 ✔/✘ + 日期"。
- [ ] 落地目标: shell → 临时 root; 只接受**:能写内核至少一处 → 验证写回自检** 视为可行, "只崩不提权"一律判死。
- [ ] 若新机可读内镜像, 重新走 §H 校准流程再反汇编, 不沿用本机 VA 常量。