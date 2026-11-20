# GhostLock 5.4 移植 — 交接文档复核 (2026-09-24)

复核对象: `SESSION_HANDOFF.md`(根目录) + `analysis/GHOSTLOCK-5.4-PORT.md`
方法: 反汇编 `vmlinux.elf`(llvm-objdump, 全 VMA) + 本地 5.4 源码 `k54src/`
(注: `k54src/kernel/futex.c` 含 `set_restart_fn()`, 说明基线是带部分 backport 的 5.4.281, 与真机一致)

## 0. 结论速览

交接文档的**链路描述与代码状态基本可信**, 但 §2/§3 里解释"ghost 为何没写中"的
**"restart 深度路径"在本机 5.4 上不存在**, 且**两个端点地址我已逐条量测**:
fd_set 窗口与唯一可能的 `rt_mutex_waiter` 相距 **0x88**, 无论怎么调参都够不着。
⇒ "cfi step4: pre_rb=0" 不是机制问题, 是**几何不成立**(加上一个未验证的前提: ghost 是否真的存活)。
另外发现 `ret=78-90`(pselect 未超时)有明确成因, 属实现 bug, 需修。

## 1. 已量测的栈帧 (全部反汇编确认)

| 函数 | 帧大小 | 备注 |
|---|---|---|
| `__arm64_sys_futex` | 0xC0 | @0x103eb870 |
| `do_futex` | 0xD0 | @0x103e6874 |
| `futex_wait_requeue_pi` | **0x1A0**, `rt_waiter` @ **sp+0x98** | @0x103eb2d8 |
| `futex_wait_restart` | 0x40, **`bl futex_wait`** | @0x103ee5f4 |
| `__arm64_sys_restart_syscall` | 0x20 | @0x102f7df0 |
| `__arm64_sys_futex_time32` | 0xC0(与 native 相同) | @0x103ebac8 |
| `__arm64_sys_pselect6` | 0x10 | @0x1059a52c |
| `__do_sys_pselect6` | 0x90 | @0x1059afc8 |
| `core_sys_select` | 0x1C0, `stack_fds`(=fd 区起点) @ **sp+0x50** | @0x10599988 |
| `__arm64_sys_select` | 0x80 (直接调用 core_sys_select) | @0x1059a3d8 |

**端点 A — 唯一能造出的 rt_mutex_waiter**
```
waiter = S0 - (0xC0 + 0xD0 + 0x1A0) + 0x98 = S0 - 0x298
```
**端点 B — pselect6 的 fd_set 可写窗口** (n=320 ⇒ FDS_BYTES=40=5 longs, in/out/ex 连续)
```
window = [S0 - (0x10+0x90+0x1C0) + 0x50 , +3*40) = [S0-0x210, S0-0x198)
```
`__arm64_sys_select` 更浅(窗 [S0-0x1F0,...)) ⇒ 两者都够不着 S0-0x298。

⇒ **差 0x88(select 差 0xA8)**。fops.c 里 "waiter = fd 区起点 + 0x18" 的映射要求
fd 区起点 = S0-0x2B0, 与实测的 S0-0x210 相差 **0xA0**。
(附:交接文档 §3 自己也有两个不一致的 fd 起点: 0x210 与 0x1B0, 差 0x60 —— 后者应为笔误/6.x 数值。)

## 2. "restart 深度路径"在 5.4 不成立 (决定性)

本地 `k54src/kernel/futex.c` 全文只有 **一处** 武装 restart:
`futex_wait()` ~2867 行 `ret = set_restart_fn(restart, futex_wait_restart);`
而 `futex_wait_restart()` 只调 **`futex_wait()`**(反汇编 0x103ee668 亦证), 后者**根本不分配 rt_mutex_waiter**。

`futex_wait_requeue_pi()` **完全没有 restart 武装**(全文无 `futex_wait_restart` 的任何引用, 反汇编核对),
被信号打断时走 `handle_early_requeue_pi_wakeup()` 返回 **`-ERESTARTNOINTR`(= -513)**:
```
0x103eb67c: mov w9, #-0x201   // -513 = -ERESTARTNOINTR
0x103eb828: mov w8, #-0xb     // -11  = -EAGAIN/-EWOULDBLOCK
```
`-ERESTARTNOINTR` 的语义是**原样重放同一个 syscall**(arm64 仅 `pc -= 4`, x8 不变), 
⇒ 第二次调用与第一次**同深度**(仍在 S0-0x298), 既不会经 `restart_syscall`, 也不会变浅。

⇒ 交接 §6-①/§3 想借 "restart 路径" 把 waiter 抬到 fd 窗口里的方案**不可能实现**;
`signaler_thread` 的 SIGUSR1 实际只造成"同深度重放", 对几何零贡献。

## 3. 第二个未验证前提: ghost 必须"存活"

punch 的触发点(本地源码, 已核对):
```c
void rt_mutex_adjust_pi(struct task_struct *task)   /* 注释: Called from sched_setscheduler */
{
	waiter = task->pi_blocked_on;
	if (!waiter || rt_mutex_waiter_equal(waiter, task_to_waiter(task))) return;  /* ★ 静默退出 */
	next_lock = waiter->lock;
	rt_mutex_adjust_prio_chain(task, RT_MUTEX_MIN_CHAINWALK, NULL, next_lock, NULL, task);
}
```
而 5.4 正常退出路径都会清掉它:
```c
rt_mutex_cleanup_proxy_lock():  if (rt_mutex_owner(lock) != current) remove_waiter(lock, waiter);
remove_waiter():  rt_mutex_dequeue(lock, waiter);  current->pi_blocked_on = NULL;
```
⇒ 若 ghost 在 punch 前已被 `remove_waiter` 摘掉, **`sched_setattr` 会静默 no-op**(consumer 仍报 ret=0/success=1,
日志上完全看不出来 —— 这正是本轮最可能的"假信号")。
⇒ 必须先**独立证明 ghost 存活**, 再谈几何。

### ★ 可执行的 ghost 存活判据 (无需崩溃, 建议优先做)
PI 链会让**持有者**被抬到等待者的优先级。只要:
1. waiter 线程先 `setpriority` 到一个**独特**值(如 nice=-5 ⇒ prio 115);
2. 走完 requeue(+超时/punch)后, 读 **owner 线程**(持 f_pi_target 的那个 tid)的 `/proc/<tid>/stat` 第 18 字段(prio);
- ghost 存活 ⇒ owner 的 prio 停在 115(启发式提升未撤销);
- ghost 被清掉 ⇒ owner 回到 120。
两态可区分、不依赖 fd_set 几何, 也不会重启设备。

## 4. `ret=78-90`(pselect 提前返回) 的成因 (实现 bug)

`open_selected_fds()` 把每个置位 fd `dup2` 到**空管道的读端**以"永不就绪", 但循环是
`for (fd = 0; fd < 320; fd++)`, 而 `pipefd[1]`(写端)本身就是个低位 fd;
只要我们的 fd 位图里**碰巧置位了那个 fd**(fake_lock/119 之类很容易命中低 64 位),
`dup2` 就把自己管道的写端**顶掉/关闭** ⇒ 读端变 EOF ⇒ in 组全部立即"可读" ⇒ pselect 提前返回
(ret = 就绪 fd 数 ≈ 78~90, 与观测吻合)。
修法: `fcntl(pipefd[1], F_DUPFD, 320+16)` 把写端挪到高位再做 dup2 循环;
并加一条自检(返回 0/errno=0=超时 才算时序成立)。

## 5. 建议的下一步 (按性价比)

1. **(先做, 30 分钟)** 用 §3 的 prio 判据确认 ghost 是否存活。若不存在 ⇒ 整个"信号+requeue"时序要改成
   **真竞态**: requeue 必须落在"waiter 被唤醒后重新抢 `hb->lock`"的窗口里(此时
   `handle_early_requeue_pi_wakeup()` 见 `q.pi_state != NULL` ⇒ `goto out_put_keys` 返回 -EAGAIN,
   而 waiter 已被 `rt_mutex_start_proxy_lock` 挂进目标树 ⇒ 真 ghost)。
2. **(然后)** 重做几何: 需要"在 S0-0x2C0..S0-0x298 处拷贝 ≥0x50 攻击者字节"的 syscall。
   已知全部不够浅/不够深: `pselect6`/`select` 太浅(差 0x88/0xA8); native `futex` 链固定(0xC0+0xD0),
   只能靠"内层函数的 帧−waiter偏移 = 0x68", `futex_wait_requeue_pi` 是 0x108 ⇒ 差 0xA0。
   **可量化候选**: `__arm64_compat_sys_futex` + `compat_do_futex`(需 32-bit helper 进程, 若本机
   CONFIG_COMPAT/32-bit 支持可用) ⇒ 若两帧合计 ≈0xF0 即正好补齐 0xA0; 用同样方法先静态量帧, 再上机。
3. **(顺手)** 修 §4 的 dup2 自伤, 让 pselect 回到确定性"整段阻塞 ⇒ 满窗口"。
4. **(之后)** 几何对齐后再谈 `fake_fops` 修复槽位/CFI 阶段 —— 那部分代码(--> §GHOSTLOCK-5.4-PORT §1/§2)
   本轮未复核, 暂不否定。

## 6. 复核结论(诚实边界)

- 已证实(反汇编+源码): §1 的帧表、§2 的 restart 结论、§3 的 punch 前置条件、§4 的提前返回成因。
- 未复核: `fake_fops` 表/ashmem 叠置/CFI 读写/pipe physrw/root.c 偏移 (都还没跑到)。
- 未证实: ghost 本身是否存活 —— **这是当前第一未知量**, 建议先花最小代价把它变成已知。
