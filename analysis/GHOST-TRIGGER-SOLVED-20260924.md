# GhostLock 5.4 — ghost 触发机制已定位 + 覆盖几何已量化 (2026-09-24)

> 结论一句话: **ghost 真的存在, 而且本机可稳定造出; 但它不是"留在 rb 树里的 waiter",
> 而是"悬空的 `task->pi_blocked_on`"。** 移植卡死的原因不是机制, 是**覆盖层几何**(差 0x38 字节,
> 而 pselect6 永远够不着)——但换一个"单向用户拷贝"的 syscall 就能解决。
> 工具: `C:/qemu_test/ghost_probe.c` (模式 seq / cycle / fuzz)

## 1. ghost 的真实机制 (源码 + 反汇编 + 真机三重确认)

原版拓扑(比移植版多一层 PI 环):
```
waiter 线程: LOCK_PI(f_pi_chain)                      ⇒ 持 chain
owner  线程: LOCK_PI(f_pi_target)                     ⇒ 持 target
             LOCK_PI(f_pi_chain)                      ⇒ 阻塞(chain 在 waiter 手里)
waiter 线程: WAIT_REQUEUE_PI(f_wait → f_pi_target)     ⇒ 睡在 f_wait
主线程     : CMP_REQUEUE_PI(f_wait → f_pi_target)
```
⇒ 死锁环: waiter →(阻塞于) f_pi_target →(其 owner=owner)→ owner 阻塞于 f_pi_chain →(其 owner=waiter)。
`futex_requeue()` 的 requeue_pi 分支调用
`rt_mutex_start_proxy_lock(&pi_state->pi_mutex, q->rt_waiter, q->task)`, 于是:

```c
/* rtmutex.c 1795 */
int rt_mutex_start_proxy_lock(lock, waiter, task) {
	ret = __rt_mutex_start_proxy_lock(lock, waiter, task);   /* = task_blocks_on_rt_mutex(FULL_CHAINWALK) */
	if (unlikely(ret)) remove_waiter(lock, waiter);          /* ★ 回滚在这里 */
	return ret;
}
/* task_blocks_on_rt_mutex: 先入队, 再走完整链 */
	waiter->task = task; waiter->lock = lock; waiter->prio = task->prio;
	rt_mutex_enqueue(lock, waiter);
	task->pi_blocked_on = waiter;                            /* ★ 指向 waiter 的栈地址 */
	...
	res = rt_mutex_adjust_prio_chain(owner, FULL_CHAINWALK, lock, next_lock, waiter, task);
	return res;                                              /* -EDEADLK: 此处**没有**回滚 */
```
而回滚用的 `remove_waiter(lock, waiter)`:
```c
	rt_mutex_dequeue(lock, waiter);            /* 从 lock 的 rb 树摘掉 ✓ */
	current->pi_blocked_on = NULL;             /* ★ current = 执行 requeue 的主线程! */
```
⇒ **被清掉的是主线程的 pi_blocked_on(无害), waiter 线程自己的 `pi_blocked_on` 仍指向它的栈上
`rt_waiter`——而该 rt_waiter 已不在任何树里。** 这就是 ghost。

### 真机证据 (`ghost_probe cycle 100000 2000000 500`)
```
[ctrl] CMP_REQUEUE_PI ret=-1 errno=35      ← 35 = EDEADLK ✓ 死锁检测确实命中
[waiter] WAIT_REQUEUE_PI ret=-1 errno=110  ← 它一直只是普通 futex 等待, 超时收场
[ctrl] UNLOCK 后 *f_pi_target=0            ← 目标锁树里确实没有 waiter(与"回滚过"一致)
      owner stat18 始终 = 基线 39           ← 没有被 PI 提升(同上)
⇒ 与"pi_blocked_on 悬空"模型逐条吻合 ✓
```
★ 交接文档 §6 说的"ghost waiter 留在 rb tree"**用词是错的**: 树被回滚了, 悬空的是 pi_blocked_on。
这个差异很关键——正因为树里没有它, 才不会被 `remove_waiter` 顺手清掉, ghost 才能活到 punch。

## 2. punch 为什么一定会走到我们的数据

`__sched_setscheduler`(sched_core.c:5109) → `rt_mutex_adjust_pi(task)`:
```c
	waiter = task->pi_blocked_on;                     /* = 我们线程栈上的悬空 rt_waiter */
	if (!waiter || rt_mutex_waiter_equal(waiter, task_to_waiter(task))) return;
	next_lock = waiter->lock;                          /* 这一步就 deref 我们的数据 */
	rt_mutex_adjust_prio_chain(task, RT_MUTEX_MIN_CHAINWALK, NULL, next_lock, NULL, task);
```
⇒ 只要那 0x50 字节是我们的, 链走就按交接 §1 的路线做 rb 手术 ⇒ `ashmem_misc.fops = fake_fops`。
注意 `rt_mutex_waiter_equal()` 只比 prio: punch 时 task->prio 已变成 139, 而 waiter->prio 是我们给的值,
**只要不等于 139 就继续** ✓(移植版给 119 也对, 但不是必须)。

## 3. ★ 覆盖层几何(本次核心量化)

单位: **相对 syscall 入口 SP 的"深度"**(地址 = S0 − 深度)。
waiter 线程栈上悬空 rt_waiter 的位置:
```
rt_waiter = S0 − (0xC0 [__arm64_sys_futex] + 0xD0 [do_futex] + 0x1A0 [futex_wait_requeue_pi]) + 0x98
          = S0 − 0x298            ⇒ 占深度 [0x248, 0x298]
字段深度: tree.pc 0x298 · tree.right 0x290 · tree.left 0x288 ·
          pi.pc 0x280 · pi.right 0x278 · pi.left 0x270 ·
          task 0x268 · lock 0x260 · prio 0x258 · deadline 0x250
```
**需要覆盖全部 0x50 字节**(链走会读 lock/prio/task, 手术用 pi_tree_entry)。

已量测的各"用户数据→内核栈"通道:

| syscall | 缓冲 | 缓冲起始深度 | 可控长度 | 覆盖 [0x248,0x298]? |
|---|---|---|---|---|
| pselect6 (现方案) | fd_sets(in/out/ex) | 0x210(最深端) | 3×40=0x78 | ✗ **差 0x38**, 且 n 再大就转 kmalloc ⇒ 无栈拷贝 |
| `select` | 同 | 0x1F0 | 0x78 | ✗ 更浅 |
| `readv/writev` | `vfs/do_readv` 的 iovstack | 0xE8 | 0x80 | ✗ 太浅 |
| `vmsplice` | 内联进 `__arm64_sys_vmsplice` 的 iovstack | 0xC8 | 0x80 | ✗ 太浅 |
| `poll/ppoll` | `do_sys_poll` 的 pollfds | 0x3D0(跨 [0xA0,0x3D0]) | 0x330 | **✓ 覆盖!但…** |
| `*sendmsg` | `__sys_sendmsg`(帧 0x1B0) 的 sockaddr_storage | 待测(估计 ~0x190) | 0x80 | 待测(可能太浅) |

★ **poll 虽然覆盖, 但 `do_pollfd()` 无条件写 `revents`(每 8 字节 entry 写 2 字节)** ⇒ 任何 8 字节
指针对齐后高位 2 字节被写坏 ⇒ **含指针的字段不可用**, 弃。
⇒ 需要的是**单向(只读入、不回写)且起始深度 ≥0x298、长度 ≥0x80** 的拷贝。

### 仍未量测的候选(按期望排序, 都是单向拷贝)
1. **`__sys_sendmsg` 的 `struct sockaddr_storage address`(128B)** — 深度需精确定位 offset(帧 0x1B0),
   若落在 [0x298, 0x2C8] 即命中; 注意 sendmsg 后续不回写它。
2. **`perf_event_open` 的 `struct perf_event_attr attr`(128B)** — 本机 perf 可达(paranoid=-1);
   注意内核会规范化部分字段(size/config), 需核对。
3. **`io_uring_setup` 的 `struct io_uring_params p`(120B)** — 本机 io_uring 可达;
   但内核会回写 p 的多个字段 ✗ 风险高。
4. **`clone3` 的 `struct kernel_clone_args`(88B)** — 单向 ✓, 但帧浅(疑 ~0x100)。
5. 反向思路: 让**悬空 rt_waiter 落在更浅处**——链上 `__arm64_sys_futex`(0xC0)+`do_futex`(0xD0) 固定,
   只有内层函数 `帧−waiter偏移` 可变: 现为 0x108。若存在 `= 0x68` 的内层(例如 compat 路径
   `__arm64_compat_sys_futex`+`compat_do_futex` 合计 ≈0xF0), 则 waiter 深度 = 0x1F8, 正好落进
   pselect6 窗口 [0x198,0x210] ✓ ⇒ 值得量测(需 32-bit helper 进程)。

## 4. cm54 需要改的三处

1. **把 requeue 的返回值当"ghost 已生成"的判据**: 现在 `futex_op(&f_wait, FUTEX_CMP_REQUEUE_PI, ...)`
   的返回值被丢弃。应断言 `ret == -1 && errno == EDEADLK(35)`(拓扑对了才会是 35)。
   移植版 main.c 的拓扑(waiter 持 chain + owner 阻塞 chain)**已经是正确的环** ✓ 不需要改。
2. **换覆盖层**: 把 `do_pselect_fake_lock_route()` 里的 pselect+fd_set 换成上面选定的 syscall,
   并按 §3 的深度公式算好"我们的字节 ↔ waiter 字段"的偏移(不再是 +0x18)。
3. **时序**: 覆盖必须在 futex 返回**之后**(同一线程栈), punch 必须在任何会清 pi_blocked_on 的操作**之前**。
   另外注意: 悬空 rt_waiter 的线程若退出, 其内核栈被释放 ⇒ 之后 punch 会打到已释放内存 ⇒ 别让 ghost 线程退出。

## 5. 诚实边界

- ghost 的**存在性**已由机制+真机证据确立; 但"ghost 在 punch 时仍悬空"这一步还没做**直接**观测
  (缺一个不破坏 ghost 的 oracle)。下一步可以: 生成 ghost 后就 punch, 并观察 `rt_mutex_adjust_prio_chain`
  是否动了 owner 的优先级(需要先把覆盖层装上才有意义)。
- 覆盖层选定之前, 不能断言整条链走通; §3 的候选 1/2 需要再量 4~6 个函数的帧与偏移。

---

# 补记 (2026-09-24 下午, 第二轮自主探索)

## 6. punch 真机行为 + 一个危险的偶然发现

新工具 `C:/qemu_test/ghost_scan.c`(`scan <overlay> [step] [kmax] [to_ms] [punch]`):
复用 ghost 拓扑, 每轮: 造 ghost → ghost 线程调一次"用户→内核栈拷贝"的 syscall(缓冲区偏移 k 处置毒值
`0x4141414141414141`) → 控制器 `sched_setattr(ghost_tid, nice)` punch → 若内核 deref 到毒值 ⇒ oops。
日志写 `/data/local/tmp/gs.log`, **必须 O_SYNC + fsync**(硬复位 PS_HOLD 会丢页缓存 —— 我因此丢过两份日志)。

实测:
- `scan 0 ... punch=0`(不 punch): 3 轮全部正常, `requeue=-35(EDEADLK)`、`futex_ret=-110(ETIMEDOUT)` ✓
- `scan 0 ... punch=1`: 有一轮 3/3 存活(`punch_ret=0`); 但另两轮**第 1 次 punch 就把内核打崩**
  (`uptime` 复位 + `ro.boot.battery=HARD_RESET/PS_HOLD` ⇒ 真 panic), 日志停在 `[k=0x000] … → PUNCH` 之后。
- ⇒ **punch(链走)确实会动到我们的悬空 waiter, 但现状不稳定/会 panic**。这与"悬空 waiter 不在任何树里"吻合:
  链走会对 `task->pi_waiters` 做 dequeue/enqueue, 并可能命中 `WARN_ON`/一致性检查 ⇒ 有时崩、有时不崩。
  对 exploit 的含义: **覆盖层一旦到位, 链走就会按我们的数据走**; 但在覆盖层到位之前**不要反复 punch**。

## 7. 覆盖层候选: 继续量测(仍未命中)

要求: **单向(用户→内核栈、不回写)**, 缓冲起始深度 δ ∈ [0x298, 0x298+len−0x50]。

| 候选 | 帧/位置 | δ | 判定 |
|---|---|---|---|
| `readv/writev`(iovstack 128B) | do_readv 帧 0x110, 缓冲 @+0x38; 入口 0x10 | 0xE8 | ✗ 太浅 |
| `vmsplice`(iovstack 128B) | 内联进 __arm64_sys_vmsplice(帧 0x100, @+0x38) | 0xC8 | ✗ 太浅 |
| `pselect6`(fd_sets) | core_sys_select 帧 0x1C0, stack_fds @+0x50 | 可控 [0x198,0x210] | ✗ 差 0x38, 且 n 再大转 kmalloc |
| `ppoll`(pollfds ≤816B) | do_sys_poll 帧 0x3D0, 缓冲 @+0x50+0x10 | 深端 ≈0x3D0(+ppoll 帧) | ✓ 覆盖但 `do_pollfd` 无条件写 `revents`(每 8B 写 2B) ⇒ 指针字段必坏 ✗ |
| `sendmsg`(sockaddr_storage 128B) | __sys_sendmsg 帧 0x1B0, 入口无帧 | ≤0x1B0 | ✗ 太浅 |
| `recvmsg` / `recvmmsg`(128B) | __sys_recvmsg 帧 0x170; recvmmsg 帧 0x60 再嵌套 | ≈0x1D0 | ✗ 太浅 |
| `perf_event_open`(attr 128B) | handler 帧未量到(入口是 thunk) | 待量 | 候选: 帧够大就可能命中 |
| `io_sqe_buffer_register` / `io_uring_register` | 未量 | 待量 | 候选(链深) |
| `process_madvise`(iovstack) | 未量 | 待量 | 候选 |

**结论: 一族"直连 syscall"的浅链统统够不着 0x298; 只有帧极大的处理器(poll 0x3D0 / 可能的 perf、io_uring)
才够深, 而 poll 被 revents 回写废掉。⇒ 下一优先: 量 `perf_event_open` handler 与 `io_uring_register`
链的 δ; 若都不行, 则走"反向"方案(compat futex 让 waiter 落到 0x1F8, 落进 pselect6 现有窗口 [0x198,0x210])。**

## 8. 设备状态与运维教训(本轮新增)
- 硬复位(PS_HOLD)会丢 `/data` 页缓存 ⇒ 设备侧日志**必须 O_SYNC + fsync**, 否则崩溃后拿不到证据。
- 崩溃归因仍用 `uptime` 复位 + `ro.boot.bootreason=HARD_RESET/PS_HOLD` ✓
- 反复 punch 会把设备打崩(见 §6) ⇒ 每轮实验前先确认 uptime, 失败重启后**重新打量基线**。

---

# 补记 2 (2026-09-24 晚, 第三轮自主探索) — 覆盖层"死亡区"结论

## 9. 链走到底读了哪些字节(源码级, 决定覆盖层的最小需求)

`rt_mutex_adjust_prio_chain`(k54src/kernel/locking/rtmutex.c 612–790, `requeue` 分支)在 punch 时执行:
```c
	prerequeue_top_waiter = rt_mutex_top_waiter(lock);      /* = lock->waiters.rb_leftmost → 我们的 forge 页 */
	rt_mutex_dequeue(lock, waiter);                         /* ★ rb_erase_cached(&waiter->tree_entry, &lock->waiters) */
	waiter->prio = task->prio;  waiter->deadline = ...;     /* 内核覆盖这两个字段(无需我们管) */
	rt_mutex_enqueue(lock, waiter);                         /* ★ 重新插入(按 prio) */
	if (!rt_mutex_owner(lock)) { ... }                      /* lock->owner 来自 forge 页 ⇒ 必须为真 */
	task = get_task_struct(rt_mutex_owner(lock));           /* ★ task = forge 页给的 owner ⇒ 用 INIT_TASK(合法 task_struct) */
	raw_spin_lock(&task->pi_lock);
	if (waiter == rt_mutex_top_waiter(lock)) {
		rt_mutex_dequeue_pi(task, prerequeue_top_waiter);   /* ★ rb_erase_cached(&pre->pi_tree_entry, &task->pi_waiters) */
		rt_mutex_enqueue_pi(task, waiter);                  /* ★ 插入 task->pi_waiters */
		rt_mutex_adjust_prio(task);                         /* → rt_mutex_setprio(task=INIT_TASK,...) 会早退(prio 相同) */
	}
	next_lock = task_blocked_on_lock(task);                 /* INIT_TASK 未阻塞 ⇒ NULL ⇒ 链走在此结束 ✓ */
```
⇒ **必须由我们控制的字节 = waiter 的 [tree_entry(0x00) + pi_tree_entry(0x18) + task(0x30) + lock(0x38)]**
即 **深度 [0x258, 0x298] 的 0x40 字节**(prio 0x258 也要不等于 punch 后的 task->prio, 否则链走提前退出)。
两次 rb 手术各提供一次任意写:
- `rt_mutex_dequeue(lock, waiter)` → parent=tree.pc / child=tree.rb_left|right ⇒ `__rb_change_child` + `rb_set_parent_color(child, parent, black)`(写 `*(child) = parent|1`)
- `rt_mutex_dequeue_pi(task, waiter)` → 同构, 用 pi_tree 三字段(→ `ashmem_misc.fops = fake_fops` 走这条)

## 10. ★ 覆盖层"死亡区"(本轮最重要的结论)

对所有"用户→内核栈"拷贝通道做了量测, **目标: 缓冲区深端 ∈ [0x298, 0x298+len-0x40]**:

| 通道 | 深端 δ | 缓冲长 | 判定 |
|---|---|---|---|
| `readv/writev`(do_readv iovstack) | 0xE8 | 128 | ✗ 太浅 |
| `vmsplice`(内联进 sys 帧) | 0xC8 | 128 | ✗ 太浅 |
| `sendmsg`(__sys_sendmsg 的 sockaddr_storage 128B, 帧 0x1B0) | ≤0x1B0 | 128 | ✗ 太浅 |
| `recvmsg`(帧 0x170) / `recvmmsg`(+0x60 再嵌套) | ≈0x1D0 | 128 | ✗ 太浅 |
| **uinput ioctl** `UI_DEV_SETUP`(struct @x29-0x68, 帧 0x130) | ≈0x168 | 92 | ✗ 太浅 |
| **kgsl ioctl**(helper 栈缓冲 @sp+8, helper 帧 0xD0, 链 0xB0) | ≈0x178 | 可变(≤0x3a 走栈) | ✗ 太浅 |
| `select`(core_sys_select stack_fds, 链 0x80) | 0x1F0 | 可控 0x78 | ✗ 差 0x68 |
| `pselect6`(链 0xA0, 已反汇编确认 `bl core_sys_select` 直连) | 0x210 | 可控 0x78 | ✗ 差 0x48; 且 n 再大 ⇒ size>42 ⇒ 转 kmalloc ⇒ 无栈拷贝(结构性上限) |
| `ppoll`(do_sys_poll 帧 0x3D0, pollfds @sp+0x50+0x10) | 0x3D0 | 816 | **覆盖 ✓ 但不可用** |

**`ppoll` 为什么不可用(源码确证)**: `k54src/fs/select.c:870` — `do_pollfd()` **无条件** `pollfd->revents = mangle_poll(mask)`,
即每 8 字节 entry 的**偏移 6-7 两字节被内核改写**。waiter 的字段正好 8 字节对齐 ⇒ 每个指针字段的高 2 字节被写掉
(需要 0xffff, 实际得到 ≤0x3fff 的 POLL 掩码) ⇒ **任何内核指针都不可用** ⇒ 无法构造 tree/pi 的 pc/child。

⇒ **结论: 深度 [0x298, 0x2D0] 这一段是"直连系统调用"的死亡区** —— 所有浅链(0xC8~0x1D0)够不着,
够得着的只有超深帧(ppoll 0x3D0, 但被 revents 回写废掉)。

## 11. 剩余的两条出路(下一步)

**(A) compat(32-bit)入口改变 futex 侧深度** ★首选
原理: waiter 深度 = (futex 入口链) + 0x108。 nativeside 链 0xC0+0xD0 = 0x190 ⇒ 0x298;
若 32-bit 入口链为 **0x108~0x130**(比 native 短 0x60~0x88), 则 waiter 落到 **0x210~0x238**,
**正好落进 pselect6 现有可控窗口 [0x198,0x210] 的邻近区**(理想是 0x210 ⇒ 完全覆盖)。
- 设备**支持 32-bit**: `ro.product.cpu.abilist = arm64-v8a,armeabi-v7a,armeabi` ✓ `CONFIG_COMPAT=y` ✓ (STATIC armv7a 二进制即可, 不需要 32-bit libc)
- 已量: `__arm64_compat_sys_pselect6_time32` 0x10 + `compat_core_sys_select` **帧 0x1C0(与 native 同)** ⇒ compat 的 fd 区深端 ≈0x210(与 native 相同)
- 未量(卡点): **compat futex 的 handler 符号在 kallsyms 里不存在**(`__arm64_compat_sys_futex`/`compat_sys_futex` 都没有)。
  取法: `compat_sys_call_table` @0xffffffc012114438, 读 index **240**(arm32 __NR_futex) 的项;
  但 ELF 文件里该表项是 **R_AARCH64_RELATIVE 重定位**(文件里读出来是 0) ⇒ 需解析 `.rela.dyn` 的 addend 才能得到函数地址。
  ⇒ **下一步第一步: 写个小工具解析 .rela.dyn 取这个地址, 再量其帧。**
**(B) 找"更深"的驱动 handler**: 要求 (入口链 + handler 帧 − 缓冲偏移) ≈ 0x298~0x2D0。
kgsl/uinput 都只有 0x168/0x178 ⇒ 需要 *更深的嵌套*(≥3 层驱动内部调用)且缓冲靠帧顶的驱动。

**(C) 兜底方案(不改几何)**: 让 punch 走"无害"路径 —— 即用 ppoll 只覆盖 **prio(0x258)+deadline(0x250)**(这两处 clobber 落在 padding 上),
配合**不动** 指针字段(tree/pi 保持内核留的值 = RB_CLEAR_NODE(pc=self) + 栈垃圾)。
链走会拿 pc=self 做 `__rb_change_child`(写 waiter 自身栈内)并把 child 当真实指针 deref ⇒ 不可控 ⇒ 现状(=有时 panic)。
⇒ 这条只能在**有 KASLR + forge 页**(即 exploit 内)才可能被驯服, 不适合当探针。

## 12. compat(32-bit)路线: 已实验证伪

新工具 `C:/qemu_test/elf_reloc_lookup.py`(解析 `.rela.dyn` 的 R_AARCH64_RELATIVE addend,
把"文件里读到 0"的函数指针表还原成真实 VA; 用法: `python elf_reloc_lookup.py vmlinux.elf <table_va> <idx...>`)。
验证: `compat_sys_call_table`(0xffffffc012114438) index **335** → addend 0xffffffc011588fc8
== `__arm64_compat_sys_pselect6_time32.cfi_jt` ✓(与符号表完全一致 ⇒ 工具正确)。

关键结果: **index 240(arm32 __NR_futex) → 0xffffffc0115893a0 == `__arm64_sys_futex_time32.cfi_jt`**
⇒ **32-bit 进程的 futex 走的是 `__arm64_sys_futex_time32`**, 其帧 = **0xC0(与 native 完全相同)**,
再加 `do_futex`(0xD0) ⇒ 入口链仍是 **0x190** ⇒ **waiter 深度仍是 0x298**。
而 `compat_core_sys_select` 帧也是 **0x1C0**(与 native 同) ⇒ fd 区深端仍 ≈0x210。
⇒ **compat 路线对几何零收益, 排除。**(不必再折腾 32-bit helper)

## 13. 当前状态与下一步的收敛结论

- ghost 机制 ✓ 已定位(悬空 pi_blocked_on, 真机可复现 `requeue=-35/EDEADLK`)
- punch 路径 ✓ 已源码级解码(需要 [0x258,0x298] 0x40 字节; 两处 rb 手术 = 两次任意写)
- 覆盖层 ✗ **所有直连 syscall / 驱动 ioctl 通道都在 [0x298,0x2D0] 死亡区之外**
- 下一步的两条真出路:
  **(B)** 找 *更深的驱动嵌套*: 需要 (入口链 + Σ驱动帧 − 缓冲偏移) ≈ 0x298~0x2D0。
        kgsl 的 helper(0xD0)/uinput handler(0x130) 都太浅(0x168/0x178); 要找 ≥3 层内部调用且缓冲贴帧顶的驱动。
        可枚举方向: 其他可开设备(uhid 的 *write* 路径、binder、ptmx、msm 系列)里 handler 帧 ≥0x180 且含 ≥0x40 栈拷贝的分支。
  **(D, 新)** 换一个 *不依赖栈覆盖* 的 ghost 利用方式: 例如只求"让链走跑一次可控的 rb 手术",
        但需要 pi_blocked_on 指向可控内存 —— 目前唯一产生该指针的路径(task_blocks_on_rt_mutex 的 requeue)
        给的必然是该线程栈上的 rt_waiter ⇒ 除非能找到别的产生悬空 pi_blocked_on 的路径
        (hmm: 需再审计 remove_waiter 的"清 current 而非 waiter"这一族调用点)。
- 结论: 卡点已从"机制未知/几何未知"收敛为**一个明确的搜索问题**(找 ≥3 层嵌套的深栈拷贝)或**换利用方式**。

## 14. 第四轮: 需求再次化简 + tty 路线否定 ⇒ **覆盖层结论: 本机不可达(结构性)**

### 14.1 需求可以大幅化简(源码推导)
再看链走 requeue 分支的**顺序**:
```
[7] prerequeue_top = rt_mutex_top_waiter(lock);        ← lock 的树(我们 forge 或用真的)
    rt_mutex_dequeue(lock, waiter);                    ← ★ RB_EMPTY_NODE(tree_entry) 为真则直接 return!
    waiter->prio = task->prio; waiter->deadline = ...; ← 内核写, 无需我们管
    rt_mutex_enqueue(lock, waiter);                    ← rb_link_node **会写** tree_entry 的 pc/left/right(=NULL)
    ...
[11] if (waiter == rt_mutex_top_waiter(lock)) { dequeue_pi(task, pre_top); enqueue_pi(task, waiter); adjust_prio } 
     else if (prerequeue_top == waiter) { ... } else { /* 什么都不做 ⇒ 安全 */ }
```
- 若 **tree_entry 保持内核留的值**(pc=self, RB_EMPTY) ⇒ [7] 的 erase 直接 return ⇒ **没有任何手术**
- 若**只覆盖 tree_entry(0x288-0x298, 3 个 qword)** 且 `lock` 保持**真**的 f_pi_target mutex ⇒ [7] 的
  `rb_erase_cached(&waiter->tree_entry, &lock->waiters)` 走 **Case 1(单子)**: parent = 我们给的 tree.pc,
  child = 我们给的 tree.right ⇒ `__rb_change_child(node, child, parent)` **写 `parent->rb_right = child`(或 rb_left)**
  ⇒ **任意写!!**(不需要 forge 页, 不需要控制 lock) —— 前提是 [11] 落进 `else`(什么都不做)分支:
  只要**目标锁树的 top waiter 不是我们**(例: 另放一个 nice 更小的线程阻塞在 f_pi_target ⇒ 它的 prio 更优)即可 ✓
- ⇒ **理论上最小需求 = tree_entry 的 3 个 qword @ 深度 [0x288,0x298]**(或整块 0x40 更保险)

### 14.2 但依然够不着 —— "ioctl 天花板"实测
| 通道 | 链(入口+handler) | 缓冲深端 δ |
|---|---|---|
| uinput `UI_DEV_SETUP`(92B) | 0xA0 + handler 0x130(buffer@x29-0x68) | ≈0x168 |
| kgsl ioctl(可变长) | 0xA0+0x10+helper 0xD0(buffer@sp+8) | ≈0x178 |
| **tty `TCSETS`(termios 36B)** | 0xA0 + tty_ioctl 0xB0 + n_tty_helper **0x20** + tty_mode_ioctl 0xA0(buffer@sp+8) | **≈0x208** |
| pselect6(fd_sets) | 0xA0 + core_sys_select 0x1C0(stack_fds@+0x50) | 0x210(可控仅 0x78) |
| ppoll(pollfds 816B) | 0x60 + do_sys_poll 0x3D0(buffer@+0x60) | 0x3D0 ✓ 但 revents 回写废 |
| 悬空 waiter 需要覆盖的地方 | — | **[0x288,0x298](最小) / [0x258,0x298](保险)** |

⇒ **所有"入口链 + handler 帧"平坦地落在 0xC8~0x210, 唯一够深的是 ppoll(0x3D0)而它必写 revents。**
⇒ **覆盖层在本机结构性不可达** —— 不是"还没找到", 而是"这一类通道的上限(≈0x210)与目标下限(0x288)之间无交集"。

### 14.3 结论与建议
- GhostLock 的 **stack-overlay 技术在 5.4.281 本机上不成立**(ghost 机制 ✓ 成立, 但写不进去)。
- 资产: ①"ghost = 悬空 pi_blocked_on"这一机制已可复现(`ghost_probe`/`ghost_scan`);
  ②链走的精确数据需求已源码级解码(可复用于任何"PI 链走 + 可控 waiter"的场景);
  ③工具 `elf_reloc_lookup.py`(解析内核函数指针表)可复用。
- **建议转向**: (1) 其他 syscall 家族里有没有"能把 ≥0x18 字节写到深度 ≥0x288"的通道(需按上文方法系统性枚举,
  候选形态: 帧 ≥0x200 且缓冲贴帧顶的**单 syscall handler**); 或 (2) 换回 CVE-2025-38352 线
  (**已实测可触发的 UAF**, 其"到 task_struct->cred 的任意写"不依赖栈覆盖); 或 (3) 继续反向补丁审计找新 bug。

## 15. 最后两块石头也落地(覆盖层: 彻底关闭)

- **compat pselect6 也不行**: `__arm64_compat_sys_pselect6_time32` 帧 **0x10** + `__do_compat_sys_pselect6_time32`
  帧 **0x10**(只是个转指针的薄壳, 直接转调 native handler) ⇒ 其 fd_set 区深端 ≤ 0x220(比 native 的 0x210 只多 0x10)
  ⇒ 依然够不到 0x288 ✗。
- **其它"大帧"候选形态复查**: `do_timer_create` 的 `struct sigevent`(32B) 深端 ≈0xD0 ·
  `ptrace_regset` 的 `struct iovec`(16B) 目标是 *tracee 的 task/regs* 而非深栈 ·
  `sched_setaffinity` 的 cpumask 只有 8B · `clone3` args / `io_uring_setup` params 的链都太短 ⇒ 全部 ✗。
- ⇒ **结论: 唯一深端 ≥0x288 的通道是 ppoll(0x3D0), 而它必然写 revents ⇒ 指针字段不可用。覆盖层彻底关闭。**
- ⇒ **GhostLock(stack-overlay 版)在本机不可用** —— 本文件至此成为完整的"已知死路地图"。

---

# ★ 战略转向: 回到 CVE-2025-38352(已实测可触发的那条)
理由: 它的原语**完全不依赖内核栈覆盖** —— 见 `analysis/SESSION_HANDOFF.md` §26/§27 与
`analysis/HID-MT-AUDIT-20260921.md`: UAF 对象是 `struct k_itimer`(专用 cache `posix_timers_cache`, 264B/31obj/order-1),
IRQ 的 `firing` 列表循环对它做 `list_del_init(&timer->elist)` ⇒ **若该 slot 已被"内容可控的对象"回收,
就得到两次任意写**(elist.next->prev = elist.prev; elist.prev->next = elist.next) ⇒ 直接打 `task_struct->cred` 即可。
- 触发已证实: `C://qemu_test//cve38352b.c`, ~1/1400 per attempt, 6 实例并行 40-60s 必崩; A/B 归因成立 ✓
- **回收窗口的可行做法(本次新提出的关键简化)**: 不要跨线程抢 µs 窗口, 而在**同一线程内 self-reclaim** ——
  `timer_delete()` 把 k_itimer 还进 `posix_timers_cache` 的 freelist, 紧接着的 `timer_create()` 在 SLUB LIFO 下
  **必然拿回同一个 slot**; 于是"回收"这一步完全在我们自己代码里(µs 级可控), 只剩"IRQ 循环走到该 entry"的**
  相位**要对上(tick 相位 ⇒ 用 `CLOCK_PROCESS_CPUTIME_ID` 的 tick 跳变测相位, 见 §25 的结论)。
- 已存在的第一版利用框架: `C://qemu_test//cve38352x.c`(排空+占位+触发), 已知待修:
  "drain_and_reclaim(248,32) 之后 timer_create 因内存被 pipe buffer 占满而失败 ⇒ spray 降到 8-16 页, 或先建 timer 再 spray"
- 本机 slab 事实(可直接查证): `posix_timers_cache 264B/31obj/2pages` · `sigqueue 80B/51obj/1page` ·
  `task_struct: posix_cputimers=0x7e0, flags=0xb4` · `k_itimer: it_lock=0x38, elist=0x40, firing=0x60, sigq=0x68` ·
  `sigqueue: flags=0x18(PREALLOC=1), list=0x20, info=0x30`
