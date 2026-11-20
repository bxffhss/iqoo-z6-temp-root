# binder 双 free：三轮上机空结果 + 源码判据把 §6 的前提否掉（2026-09-26 收尾）

> 承接 `BINDER-UAF-WHO-IS-FREED-20260926.md` §6/§7/§8 与 `PATH-TO-ROOT-20260926.md` §5。
> **结论先说**：§6 那条"todo + transaction_stack 双挂 ⇒ 同一个 `t` 被 free 两次
> ⇒ 抢回槽后得到 write-what-where"**在这台内核的代码形状下前提不成立**。
> 这不只是"没测到"，而是有正向的静态判据（§3），并且 §2 用一个守卫解释了
> 三轮实验里所有奇怪的返回值。§4 列出还**没有**被判死的部分。

## 1. 一手 ABI 事实（P53→P57，全部实测，不再靠推断）

| 项 | 实测值 | 来源 |
|---|---|---|
| `sizeof(struct binder_transaction_data)`（NDK 头 == 内核） | **64** | P54 `sizeof(td)=64` |
| write buffer 布局 | **`[u32 cmd][td @ +4]`，无 4 字节对齐 pad** | P54：`+4` ⇒ `consumed=68=size`；`+8` ⇒ `consumed=0` |
| `BR_DEAD_REPLY` 编码 | `0x7205`（`_IO('r',5)`），与反汇编 `mov w1,#0x7205` 对上 | P55 打印枚举值 |
| app 域能否发出真事务 | **能**。`open /dev/binder` + `mmap(PROT_READ, MAP_PRIVATE\|ANON)` + `BINDER_WRITE_READ` ⇒ 事务投递到 SM，读回 `0x720c`=BR_NOOP | P55 `[oracle] send ret=0 consumed=68` |
| binder `mmap` 参数 | 只接受 `PROT_READ` + `MAP_PRIVATE`；`PROT_READ\|PROT_WRITE, MAP_SHARED` ⇒ **EPERM** | P55 第一版踩到 |

**两条踩坑记录（都是探针自伤，写进方法论）**：
1. P55 第一版把 `uint8_t wb[64]` 开了 64 字节却 `memcpy(wb+4, td, 64)` ⇒ 溢出 4 字节踩到相邻的
   `struct binder_write_read` ⇒ 全部 `ret=-1 errno=22`。当时我几乎要把"EINVAL"记成驱动拒绝。
   ⇒ **写 buffer 的尺寸必须显式 ≥ 头 + payload**，这条已由注释钉在源码里。
2. P55/P54 的 `consumed=0 / ret=0` 被我先后误读成"线程被毒化""SELinux 拒绝"。真实原因见 §2。

## 2. `consumed=0 且 ret=0` 的真实来源（源码一手）

`analysis/binder_v5.4.281.c:4001`（`binder_thread_write` 主循环）：

```c
	while (ptr < end && thread->return_error.cmd == BR_OK) {
```

⇒ 只要该 binder 线程挂着 `return_error`（`thread->reply_error.cmd != BR_OK`），
之后**每一次** `BINDER_WRITE_READ` 都一个字节都不消费、返回 0。

而 `reply_error` 正是 §3 那条守卫拒绝第 2 条同步事务时设下的。于是：
第 1 条同步 OK → 第 2 条被拒并留下 `BR_FAILED_REPLY`（write 仍被"消费"完 ⇒ `consumed=68`）
→ 第 3 条起 `consumed=0`。**P54 的 layout 序列、P55 的 `2/48`、P56 的 `有效` 计数全部由这一个模型解释**，
不需要引入 SELinux、ABI 差异或驱动 bug。

> 自我纠正：P57 报的 `两条同步都成功=42713` **不是**"两条同步事务挂在同一条线程上"的证据。
> `consumed` 只证明 write loop 走完了，不证明 `binder_transaction()` 建了对象。
> 我按 §3 读到守卫之后才发现这一点；P57 的"成功"计数判据是弱的，它的 0 异常结果只能算
> "没有正信号"，不能算"链没形成所以没测"。

## 3. 静态判据：这条代码形状里 `t` 不会同时挂在 todo 与 stack 上

`binder_v5.4.281.c` 三处（均为上游 5.4.281 原文，本机 vendor 版在其上叠 `rsc_*`）：

1. **第 2 条同步出向事务被守卫拒绝**（`binder_transaction`，3321 行起）：
```c
	if (!(tr->flags & TF_ONE_WAY) && thread->transaction_stack) {
		tmp = thread->transaction_stack;
		if (tmp->to_thread != thread) {
			binder_user_error("... got new transaction with bad transaction stack ...");
			return_error = BR_FAILED_REPLY; goto err_bad_call_stack;
		}
		while (tmp) { ... if (from && from->proc == target_proc) { target_thread = from; break; }
		          tmp = tmp->from_parent; }
	}
```
⇒ `t->from_parent` 链（`3810: t->from_parent = thread->transaction_stack;`）**只有在"本线程正在处理一条进来的同步事务"**
（栈顶 `to_thread == thread`，即嵌套/回调）时才可能长到 2 节。纯"连发两条同步"到不了。

2. **进向事务的 stack 链接是在 work 出队之后才建立的**（`binder_thread_read`，4915 行）：
```c
	if (cmd != BR_REPLY && !(t->flags & TF_ONE_WAY)) {
		binder_inner_proc_lock(thread->proc);
		t->to_parent = thread->transaction_stack;
		t->to_thread = thread;
		thread->transaction_stack = t;
		binder_inner_proc_unlock(thread->proc);
	} else {
		binder_free_transaction(t);
	}
```
而 `t->work` 是在这个 case 的开头由 `binder_dequeue_work_head_ilocked()` **摘下**的。
`binder_proc_transaction()`（3044 行）只把 work 挂到 `thread->todo`/`proc->todo`/`node->async_todo`，
**不碰 `transaction_stack`**（`binder_enqueue_transaction_work_ilocked` 这个"两处一起挂"的helper 是 5.10+ 才有的）。

⇒ **不变式**：本机内核里没有一个 `t` 会同时位于"某线程的 todo"和"该线程的 transaction_stack"。
   §6 设想的两跳——
   ①`binder_thread_release → binder_send_failed_reply → free(t)`，
   ②`binder_release_work(&thread->todo) → free(t)` ——
   **需要那个不变式被破坏**，而 5.4.281 的这三处正好保证它不被破坏。
   `binder_thread_release` 的循环（5124 行起）只清 `from/to_*` 指针，不 free；
   `send_reply` 只在 `t->to_thread == thread` 时取栈顶一条。

3. 厂商 `rsc_binder_schedule_bg_work_ilocked`（`0xf61984`）**不是**按事务排队的延迟释放：
   它在 `binder_free_transaction` 内被调用，参数是 `x0 = t->[0x38]`（= `to_proc`）与 0，
   即**挂在 proc 上的单个 work**（proc 的异步空间回收），不会二次 free 一个 `t`。
   `t+0xb0` 那个 `work_struct` 在 `binder_free_transaction` 里由 `__cancel_work_timer` **取消**，而不是排队。

## 4. 还**没有**被判死的（别把这份文档读成"binder 全线关闭"）

- §3 的判据是**上游 5.4.281 源码**给出的；vendor 增量（`rsc_*`、`_rs.` 尾巴、`t+0xb0` 的 work）
  我只查了"它是不是二次 free 的来源"这一条，**没有逐指令比对 vendor 改过的 `binder_transaction`/
  `binder_thread_read` 是否还保留"先出队再上栈"这个顺序**。
- 嵌套/回调形状（第 3 节 1 的 `to_thread == thread` 分支）我**从没构造过**：它需要 our proc 先收到一条
  进来的同步事务，而 app 域要拿到"别人能调我们"的句柄，得靠第二个自有 APK 用 `bindService` 建立双向链
  （设备上已装 `com.apocalua.run`，可行）。这条路是 §3 唯一能长 `from_parent` 链的形状。
- 一个更硬的通用限制（与形状无关，永远成立）：**两次 free 若发生在同一条 syscall 内，用户态 spray 插不进去**。
  只有"free#1 在 `THREAD_EXIT`、第二跳在另一条路径（ms 级间隔）"这种形状才可能被抢槽命中。
- CVE-2026-64468/64469 的**补丁原文还没拿到**（子代理在查）。真正的漏洞形状应由修复反推，
  不应由我的推测承担——这是本文件存在的主要原因。

## 5. 上机台账（可复现）

| 探针 | 形状 | 量 | 被偷槽 |
|---|---|---|---|
| P53 | 50×N 条同步（错误 ABI，struct 在 +8） | 200/轮 | 0（判据对照组也=0，但该轮事务根本没发出） |
| P54 | ABI 判定（一次性调用，回显全字段） | — | 未审计 |
| P55 | 1 fd 上 layout 探测 + 12/48 条同步后退出 | 4 轮 | 0 |
| P56 | `{发 1 条同步 → 立刻 THREAD_EXIT}`×4 线程 | 迭代 53,925（有效 53,925）；喷槽 >850k | **0** |
| P57 | `{发 2 条同步 → 立刻 THREAD_EXIT}`×3 线程 | 迭代 65,518（"两条都成功" 62,112，其实第 2 条被守卫拒） | **0** |

对照组（不触发就审计）在每轮都是 0 ⇒ 判据本身没有噪声。

## 6. 对 PATH-TO-ROOT 的直接影响

`PATH-TO-ROOT-20260926.md` §5 的链条里 **[A'] double-invocation → [B] xattr 回收 → [C] unlink 任意写**
这一段的**前提被 §3 否掉**，因此整条链降级为"待补丁原文重新定形"，
在拿到 CVE 修复内容之前，**不要再按 §6 的 write-what-where 安排后续步骤**。
