# GHOSTLOCK / CVE-2026-43499 存在性静态核查 (2026-09-26)

目标设备：vivo iQOO Z6, SM7325, Android 14, kernel `5.4.281-qgki` clang 11.0.2 built #1 SMP 2025-05-07。
本次为纯静态分析（read-only adb + 反汇编），未改变设备状态，未写其它文件。

## 结论 (Verdict)
**VULNERABLE（高危确认，置信度 ~95%）** — 本机编译进 `vmlinux` 的 `remove_waiter()` 是 **修复前** 形态；fix `3bfdc63936dd` **不存在**。

## (a) pi_blocked_on 偏移
- `pi_lock` 偏移 = **0x91c**：`task_blocks_on_rt_mutex` 用参数 `task`(x2) 做 `add x24, x2, #0x91c` 后 `_raw_spin_lock`（地址 `0xffffffc0103789bc`）。
- `pi_blocked_on` 偏移 = **0x940**：`task_blocks_on_rt_mutex` 死锁链遍历处 `ldr x8, [x23, #0x940]`（x23=owner task，`0xffffffc010378ad4`）。两处交叉印证。
- arm64 上 `current` 经 `mrs xN, SP_EL0` 直接取得（非 per-cpu 惯用法）。注意 `futex_lock_pi` 顶部 `[current,#0xa78]` 是 `current->pi_state`（owner==pid 快速获锁路径），**不是** pi_blocked_on。

## (b) remove_waiter 关键指令 (0xffffffc010378d58 – 0xffffffc010378fbc)
`remove_waiter` 未被内联，有独立符号。前 15 个参数：x19=lock, x23=waiter。
```
10378d90: mrs   x20, SP_EL0          ; x20 = current
10378d94: add   x21, x20, #0x91c     ; x21 = &current->pi_lock   (应为 waiter->task->pi_lock)
10378d9c: bl    _raw_spin_lock
10378da0: ldr   x8, [x23]            ; rt_mutex_dequeue(lock,waiter) — 无 waiter->task 载入
10378dd4: mov   x0, x21
10378dd8: str   xzr, [x20, #0x940]   ; current->pi_blocked_on = NULL   <== BUG
10378ddc: bl    _raw_spin_unlock
...
10378f70: mov   x0, x21              ; owner
10378f78: mov   x2, x19              ; lock
10378f80: mov   x4, xzr              ; NULL
10378f84: mov   x5, x20              ; 传入 current  <== 修复后应传 waiter_task
10378f88: bl    rt_mutex_adjust_prio_chain
```

## (c) 最强证据
函数体内 **从未** 出现 `ldr x?, [x23, #0x30]`（`waiter->task`，waiter 字段 task 偏移 0x30，由 `task_blocks` 的 `stp x20,x19,[x22,#0x30]` 印证）。pi_lock 与 `pi_blocked_on=NULL` 的基址均为 `mrs SP_EL0` 得到的 `current`；且 `rt_mutex_adjust_prio_chain` 末参传 `current`(x20)。这与上游 buggy 形态逐字对应，而修复形态必须先把 `waiter->task` 载入再做上述两步——该 load 缺失即为判据。
（`current==waiter->task` 是常见情形，但在 proxy-lock / `futex_requeue` 的 PI 路径中二者可不一致，此时 `current->pi_blocked_on` 被错误清空、真实 waiter task 的 `pi_blocked_on` 悬挂 → 触发 rtmutex stack-UAF，CVE-2026-43499。）

## (d) 相关 CONFIG（均取自 /proc/config.gz，可读）
- **CONFIG_FUTEX_PI=y** → proxy-lock 路径编入，漏洞真实可达。
- **CONFIG_CFI_CLANG=y** + `CONFIG_CFI_CLANG_SHADOW=y`（非 permissive）→ kCFI 生效，间接调用受类型校验。
- **CONFIG_SHADOW_CALL_STACK=y / _VMAP=y** → 返回地址受 SCS 保护（prologue 可见 `str x30,[x18],#0x8`，x18=shadow SP）。
- **CONFIG_STACKPROTECTOR_STRONG=y**、**CONFIG_ARM64_SW_TTBR0_PAN=y**、**CONFIG_ARM64_PTR_AUTH=y**（PAC）。
- **CONFIG_KASAN 未开**（`# CONFIG_KASAN is not set`）、`# CONFIG_DEBUG_RT_MUTEXES is not set`、`# CONFIG_PROVE_LOCKING is not set` → 无调试检测，运行时不易暴露。
- 无 `CONFIG_LIVEPATCH`、无 `CONFIG_RANDOMIZE_KSTACK_OFFSET`（5.4 无此特性）→ 无热补丁可携带该 fix。
这些缓解提高利用难度，但不改变“脆弱代码存在”这一事实。

## (e) 证明 proxy-lock 路径已编入的符号（存在即有效）
- `__rt_mutex_start_proxy_lock` (0xffffffc0103786e0)
- `rt_mutex_start_proxy_lock` (0xffffffc010378cc0)
- `rt_mutex_wait_proxy_lock` (0xffffffc010378ff8)
- `remove_waiter` (0xffffffc010378d58) — 被 `rt_mutex_wait_proxy_lock`/`__rt_mutex_slowlock` 调用（如 `bl 0xffffffc010378d58`）
- `futex_wait_requeue_pi` (0xffffffc0103eb2d8)、`futex_requeue` (0xffffffc0103e7ba8)、`futex_lock_pi` (0xffffffc0103ea51c)、`task_blocks_on_rt_mutex` (0xffffffc010378990)、`rt_mutex_adjust_prio_chain` (0xffffffc010377bb4)。

## 备注 / 诚实声明
判据基于反汇编形态直接比对，符号未被剥离、`remove_waiter` 独立存在，故非“理论推断”。唯一残余不确定性：0xffffffc010378d8c 的 `cbz x22`/owner 相关分支属正常 top_waiter 逻辑，不影响结论。综合评估 **VULNERABLE**（fix 缺失），置信度约 95%。
