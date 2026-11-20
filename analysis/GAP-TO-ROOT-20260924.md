# 距离"临时 root"的差距分析（2026-09-24）

> ★★**时效声明（2026-10-12 加）：这份文件是 9-24 那天的差距分析，现在已经过期。**
> 目标当天就达成了，而且交付形态已收敛成三条命令：`I_KNOW=1 bash kmod/go.sh` → 现取 uid → `bash kmod/ui_grant.sh <搜索词> <uid> <包名> [--revoke]`。
> **现状请看 `analysis/CONTINUE_HERE.md` 顶部那一节；对外口径看 `kmod/DELIVERY.md`；每一条读数的出处在 `kmod/ROUTE-B-OFFSET-INVERSION.md`（§6.236~§6.241 是 2026-10-12 的九发窗口）。**
> 本文只保留作历史：它写的"还缺什么"不要当结论用。

> 设备：iQOO Z6 / SM7325 · kernel 5.4.281-qgki · Android 14 · BL locked · SELinux enforcing · 起点 uid=2000(shell)
> 依据：本会话(CVE-2025-38352 全过程, `analysis/CVE38352-PORT-PLAN.md` §1-§36) + 项目记忆(GhostLock/HID/已关闭路线)

---

## 0. 目标的技术定义

"临时 root" = 让一个进程持有 `uid=0`（不需要持久化）。技术等价于：
**拿到一个受控的内核写原语**，改写某个进程的 `struct cred`（uid/gid/capabilities）⇒ execve root shell。
⇒ 所以"差距"就是：**从现在的状态到"受控内核写原语"还差几步、每步是什么。**

---

## 1. 全局地图：所有已知路线与各自卡点

| 路线 | 原语类型 | 当前卡点 | 到"受控写"的距离 |
|---|---|---|---|
| **A. GhostLock 5.4**（主线，`SESSION_HANDOFF.md`） | 悬空 `task->pi_blocked_on` → 链走改 rb | **栈覆盖通道不可达**（§35.2 终判） | 一步（但需要新思路） |
| **B. CVE-2025-38352**（本会话主战场） | posix-cpu-timers UAF → sigqueue 复用 | **ptrace-线程收割语义**（§36 已定位到函数级） | 两步（之后是工程） |
| C. HID 越界写（副线，已受控） | 盲/相邻/**只写零** | 原语太弱，无法改 cred | 无法独立完成（只能当辅助） |
| D. 尚开放的 CVE：2025-37804(io_uring iowq) · 2025-27038(Adreno/kgsl) · 2025-37790(mctp) | — | 未投入分析 | 未知 |

---

## 2. 路线 A：GhostLock 5.4 —— 距离最短，但卡点被证明"结构性不可达"

**已做到**（全部真机验证）：
- `perf` KASLR 破解 ✓ · KernelSnitch mm 泄漏 ✓ · SLUB 喷射 ✓ · **pselect ghost**（悬空 `task->pi_blocked_on`）✓（真机 errno 35）
- 且已证明 **punch 必中**：`rt_mutex_adjust_pi()` 会 deref 我们的数据 ⇒ 链走按预期进行

**卡点（终判，`GHOST-TRIGGER-SOLVED` §14）**：
- 链走需要覆盖**栈上深度 [0x288, 0x298] 的 3 个 qword**（tree_entry 等）
- 而所有直连内核栈写入通道的**上限是 ~0x210**：uinput 0x168 · kgsl 0x178 · tty 0x208 · pselect6 0x210 ·
  ppoll 0x3D0（覆盖到了，但 `revents` 会写坏指针）· readv 0xE8 · vmsplice 0xC8 · sendmsg ≤0x1B0 · recvmsg 0x170 · recvmmsg 0x1D0
- 32-bit compat 路线也已证伪（帧深度相同） ⇒ **无交集 ⇒ stack-overlay 写法在本机不可达**

**补差距的选项**（未系统排查）：
- (a) 找一个**非栈**的、可达 [0x288,0x298] 等效位置的写通道（跨 cache / 其它含函数指针的对象）
- (b) 换一个"产生悬空 `pi_blocked_on`"的路径，让悬空对象落在**可达**的位置（而非栈上）
- (c) 把"punch 必中"用作**信息泄露**通道而非直接写 —— 未探索
- (d) 系统排查剩余内核对象里的**函数指针/指针字段**（可能比栈更容易打）

**距离**：**一步**（写原语），但这一步在已知的栈通道上被证明不可达 ⇒ 需要 (a)-(d) 中至少一条新思路。

---

## 3. 路线 B：CVE-2025-38352 —— 本会话主战场，卡点已精确到函数级

**链条**：竞态窗口 → **收割** → UAF free → sigqueue 复用 → 任意写 → cred patch → root

**已做到**（全部真机验证，本会话产出）：
1. 两套竞态 harness（`cve38352d.c` 旧拓扑 / `cve38352e.c` 新拓扑），**零崩溃**，20+ 参数命令行可调
2. **竞态窗口可稳定产出 3.5ms**（投递成本铁律：`信号数 × entries × 32ns ≪ tick(4ms)`；实测 4,000 entry + 8 stall）
3. **三个内核事实已在真机验证**（`probe_tmr.c`）：进程级定时器在 owner 为"未收割僵尸"时仍能被收集 ✓ ·
   收割后投递仍成立 ✓ · `PIDTYPE_TGID` 解析仍成功 ✓
4. **UAF 直接观测通道**（父进程 1s 周期重分配定时器 + 100ms 静默窗）—— 任何改动跑一轮即知有没有 UAF
5. 干净、可证伪的判据体系（`noreap`/`noarm` 对照 + `sival_int` 魔数判别）
6. **8 个被实测证伪的内核模型**（防止后续会话重蹈）

**卡点（§36，已精确到源码函数级）**：
- 需要"收割一个 **ptrace 的组 leader**（组内还有存活线程）"，但实测：
  `waitpid(leader_tid, __WALL|WNOHANG)` **立即 ECHILD** ⇒ 既收不到 `PTRACE_EVENT_EXIT`，也无法收尸
  ⇒ **收割从未真正发生** ⇒ `leader->sighand` 恒有效 ⇒ `posix_cpu_timer_del` 走正常路径 ⇒ **漏洞分支不可达**
- （这也是此前所有"收割时序"问题的总根因；连"收割 100%"的旧结论都是 `reaped++` 无条件自增的假象）

**补差距的选项（按序）**：
1. 读 `__ptrace_link` / `wait_task_zombie` / `do_notify_parent` 源码，解决"**ptrace-线程收割语义**"
   —— 一个边界清晰的源码研究问题
2. **直接读 chronomaly 原版 `exploit.c` 的 do_wait/ptrace 部分**（它同样需要收割一个非 autoreap 的 victim）
   —— 应读原版而不是自己推导（本会话已多次因自行推导而绕路）
3. 替代 victim 结构：整进程死亡（但 `group_dead` ⇒ `exit_itimers` 会删掉进程级定时器 ✗）需绕过；
   或 `PTRACE_SEIZE` 打在 victim 的**每个线程**上（逐 thread 收割）

**距离**：**两步**（收割语义 → UAF free），之后的 cross-cache 与写原语是"工程"（有原版参照）而非"研究"。

---

## 4. 路线 C：HID 越界写 —— 原语太弱，只能当辅助

- 可复现原语 = **盲 + 相邻 + 只能写零** ⇒ 无法把 cred 改成 0（需要写任意值）
- 唯一可打的对象：AF_UNIX 的 `unix_address` / SELinux `sk_security_struct`（都不含 uid）
- **价值**：可作"占位/风水"的辅助手段，**不能单独提权** ⇒ 不计入主线差距

---

## 5. 配置层面的差距（影响所有利用的"最后一公里"）

| 配置 | 本机 | 对"最后一公里"的影响 |
|---|---|---|
| `SLAB_MERGE_DEFAULT` | =n ✓ | 有利（对象不会被其它 cache 复用，cross-cache 更可控） |
| `PREEMPT` / `SMP` / 核数 | =y / =y / 6 ✓ | 有利（多核对齐成为可能） |
| `POSIX_CPU_TIMERS_TASK_WORK` | 符号不存在 ✓（5.4 必为 IRQ 路径） | 有利（B 线结构上可触发） |
| `HZ` | 250（tick 4ms） | 窗口粒度受限（已用投递成本不等式补偿） |
| **`DEBUG_LIST`** | **=y** ⛔ | **任何 list 操作型 UAF 的利用（如 `list_del_init` 写原语）会先触发校验** ⇒ chronomaly 的写原语需重新设计 |
| **`BUG_ON_DATA_CORRUPTION`** | **=y** ⛔ | 同上 |
| SELinux | enforcing | 提权后还需 policy 收尾，但不影响"拿到 uid=0" |

⇒ **B 线即使拿到 UAF，写原语阶段也要绕过 DEBUG_LIST**（参考：LG webOS 变体用"单次任意写"
`prev->next = next` 替代原版的多次递减 —— 在 DEBUG_LIST 下该路径的校验仍需满足，需实测）。

---

## 6. 汇总：差距的本质与最短路径

**两条主线都卡在"受控内核写"之前的一步**：
- A（GhostLock）：卡在**覆盖通道**（栈深度不够）—— 需要新思路（(a)-(d) 均未系统排查）
- B（CVE-38352）：卡在**UAF 触发**（收割语义）—— 触发之后还有 cross-cache 与写原语两步（有原版参照）

**最短路径判断**：
- B 线的"收割语义"是一个**边界清晰、可独立完成的源码研究问题**（读 `wait_task_zombie` + 原版 exploit.c），
  解决后链条其余部分都是工程；
- A 线的卡点需要**找一个不存在的通道**（或新思路），不确定性更高。
⇒ **短期优先级：B 线的收割语义 > A 线的覆盖通道。**

**预估工作量**（按专门会话计）：
| 步骤 | 会话数 |
|---|---|
| B: 收割语义（读源码 + 实测） | 1-2 |
| B: UAF 验证（观测通道已就位） | 0.5 |
| B: sigqueue cross-cache（有原版参照） | 2-3 |
| B: 写原语（含 DEBUG_LIST 绕过实测） | 2-3 |
| cred patch → root shell | 1 |
| **合计到"临时 root"** | **≈ 6-9 个专门会话** |

**风险**：DEBUG_LIST=y 可能把"写原语"阶段的方案全部否掉 ⇒ 若实测不可绕，B 线在"任意写"处截断，
届时只剩 A 线的覆盖通道或开放 CVE（D）。

---

## 7. 结论

- **距离临时 root ≈ 6-9 个专门会话**，最短路径是 B 线（CVE-38352），
  且**下一个会话的具体任务已经写清**（§36.2：解决 ptrace-线程收割语义，或直接读原版 exploit.c 的 reap 实现）。
- 本会话的净产出：两套可用的 harness、一条量化设计不等式、3 个真机验证的内核事实、
  **UAF 直接观测通道**（后续任何改动跑一轮即知结果）、以及 **8 个被证伪的模型**（防止重蹈）。
- A 线（GhostLock）的卡点已被证明"在已知栈通道上不可达"，其 (a)-(d) 四个补差距选项**均未系统排查**——
  若 B 线受阻，这是备选方向。
