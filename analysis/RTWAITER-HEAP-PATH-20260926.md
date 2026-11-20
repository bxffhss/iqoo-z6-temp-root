# RTWAITER-HEAP-PATH (2026-09-26)

## 结论 (Verdict) — 先说答案

**NO。本内核里不存在任何让 dangling `pi_blocked_on` 指向 slab/heap 的路径。** 证据链闭合:

1. 全树唯一写 **非-NULL** `pi_blocked_on` 的点是 `task_blocks_on_rt_mutex()`(v5.4.281 `rtmutex.c:963`;设备二进制 `task_blocks_on_rt_mutex+0x110 = 0xffffffc010378aa0: str x22,[x20,#0x940]`),waiter 是**调用者传入的指针**,该函数自己不分配。
2. 该函数的调用者在二进制里只有 2 个 `bl`(均在 `__rt_mutex_start_proxy_lock` / `rt_mutex_start_proxy_lock` 内),而 proxy API 的调用者在**整个内核二进制里只有 3 处**(futex_requeue / futex_lock_pi / futex_wait_requeue_pi),三处的 waiter 全部实测为**栈局部变量**(`add x1, sp, #0x80` / `add x0, sp, #0x98`)。
3. **v5.4.281 根本没有 `rt_waiter_cache` / `rt_mutex_waiter_alloc()` / mempool** —— 我核对的 upstream v5.4.281 `kernel/locking/rtmutex.c`(52215 B,与本地 `k54src/` 副本逐字节相同)内 `kmalloc|kmem_cache|mempool` 命中数为 **0**;`rtmutex_common.h` 的注释直接写明 waiter *"is allocated on the kernel stack on of the blocked task"*。任务书里"5.4 有 mempool 堆 waiter"的前提是**错的**(v6.1、v6.13 源也同样没有)。设备侧交叉验证:`vmlinux_symbols.txt`/`embedded-kallsyms.txt` 无 `rt_waiter`/`waiter_cache` 符号,`/proc/slabinfo`(实机 read-only 抓取,275 行)无任何 waiter/rtmutex/futex cache。
4. `rt_mutex_start_proxy_lock`/`__rt_mutex_start_proxy_lock`/`rt_mutex_wait_proxy_lock`/`rt_mutex_cleanup_proxy_lock`/`rt_mutex_init_waiter` **都未导出**(0 个 `__ksymtab`,`__kstrtab_rt_mutex*` 仅 6 项 = lock/unlock/trylock/timed_lock/init/destroy)⇒ 任何 driver/`fs/`/vivo 模块都无法递进一个堆 waiter。
5. 全二进制 `str ... [x?, #0x940]`(qword)只有 38 处,其中真正落在 `task_struct.pi_blocked_on` 的只有 4 处:`copy_process+0x1dc`(fork 清零)、`try_to_take_rt_mutex+0x144`(用 task arg,正确)、`task_blocks_on_rt_mutex+0x110`、`remove_waiter+0x80`(CVE)。其余 34 处是别的 struct 的 0x940 偏移字段(veth_dellink、tcp_init_buffer_space、update_rq_clock_task、kgsl_pwrscale_init、snd_card_new…),已逐个用符号表定位排除。

⇒ **栈深度问题不能靠 SLUB spray 解决**;`[0x288,0x298]` 的目标是 `vmalloc` 栈页(`CONFIG_VMAP_STACK=y`),连 SLUB 对象都不是。此方向可以停止。

## 1. `TASK->pi_blocked_on = WAITER` 全站点 × 存储类别 × 调用路径

| # | 源位置 | 函数 / 值 | 设备地址 | waiter 来源 | 类别 | 是否产生 ghost |
|---|---|---|---|---|---|---|
| A | rtmutex.c:963 | `task_blocks_on_rt_mutex`, `= waiter` | `0xffffffc010378aa0` | 调用者指针(见下) | 见下 | 写入点本身 |
| B | rtmutex.c:898 | `try_to_take_rt_mutex`, `= NULL`(task arg) | `0xffffffc010378894` | — | — | 否(正确) |
| C | rtmutex.c:1078 | `remove_waiter`, `current-> = NULL` ★BUG | `0xffffffc010378dd8` | `mrs x20,SP_EL0` | — | **是** |
| D | fork | `copy_process`, `= NULL` | `0xffffffc0102db068` | — | — | 否 |

到达 A 的完整路径(waiter 存储):

| 路径 | waiter 实参(二进制实测) | 类别 | `waiter->task` vs `current` |
|---|---|---|---|
| `futex_requeue` → `rt_mutex_start_proxy_lock` @`0xffffffc0103e8a78` | `ldr x1,[x28,#0x40]` = 被 requeue 任务 `futex_q.rt_waiter` = **该任务栈 `sp+0x98`**(`0xffffffc0103eb3e4 add x0,sp,#0x98`) | **(a) 别的 task 的栈帧** | ≠ current ⇒ **ghost** |
| `futex_lock_pi` → `__rt_mutex_start_proxy_lock` @`0xffffffc0103ea980` | `add x1,sp,#0x80`(`0xffffffc0103ea974`)+ `rt_mutex_init_waiter(sp+0x80)` | (a) 自己的栈 | == current ⇒ 无害 |
| `futex_wait_requeue_pi` → `rt_mutex_wait_proxy_lock`/`cleanup_proxy_lock` @`0xffffffc0103eb574/594` | `add x1,sp,#0x98` | (a) 自己的栈 | == current ⇒ 无害 |
| `rt_mutex_slowlock`(rtmutex.c:1234 `struct rt_mutex_waiter waiter;`) | 栈局部;调用点在反汇编截断区(见 UNVERIFIED) | (a) 栈 | == current ⇒ 无害 |

(b) slab/heap、(c) static/global、(d) 内嵌于堆对象:**0 例**。`struct futex_pi_state` 只有 `pi_mutex` 指针;`futex_q.rt_waiter` 是**指针字段**不是内嵌对象;`binder_transaction` 等无 waiter。

## 2. 能走到 `remove_waiter` 且 `waiter->task != current` 的路径

`remove_waiter` 在二进制里只有 2 个 `bl`:`0xffffffc010378d04`(`rt_mutex_start_proxy_lock` 失败回滚)与 `0xffffffc0103790d0`(`rt_mutex_cleanup_proxy_lock`)。`rt_mutex_wait_proxy_lock` 不调 `remove_waiter`。⇒ **只有 futex_requeue 一条路径能造 ghost**(与项目已复现的 `requeue=-35/EDEADLK` 一致)。

## 3. Spray-bucket 分析(仅作"如果存在"的收尾)

`sizeof(struct rt_mutex_waiter)` arm64/5.4(`CONFIG_DEBUG_RT_MUTEXES` 未开)实测布局:
`tree_entry`@0x00(rb_node 3 qword)、`pi_tree_entry`@0x18、`task`@0x30(`stp x20,x19,[x22,#0x30]`)、`lock`@0x38、`prio`@0x40、`deadline`@0x48 ⇒ **0x50 = 80 B**。

实机 slabinfo:**没有 `kmalloc-8/16/32/64/96` 桶**,最小通用桶是 **`kmalloc-128`**(active≈48.4 万,极繁忙)⇒ 假想 80B waiter 会落 `kmalloc-128`。同尺寸(`SLAB_MERGE_DEFAULT` 未设,只能同 size)不可控/半可控候选:`skbuff_ext_cache`(128)、`pid`(128)、`eventpoll_epi`(128)、`tcp_bind_bucket`(128)、`bridge_fdb_cache`(128)、`trace_event_file`(88)、`task_delay_info`(88)、`names_cache`(88)、`blkdev_ioc`(112)。**全部与本案无关**,因为没有堆 waiter 可填。

## 4. 假说检验(反向佐证):链走确实把写导向 waiter 内指针

`rt_mutex_adjust_prio_chain`(`0xffffffc010377bb4`)中 `x25 = waiter`(`ldr x25,[x19,#0x940]` @`0xffffffc010377cd4`),随后 `mov x0,x25; bl rb_erase`(`0xffffffc010377de4/10377e30`)、`str w10,[x25,#0x40]`、`str x11,[x25,#0x48]`、`str xzr,[x25,#0x10]` ⇒ 若对象在堆,"任务书假设"成立。**但对象只在栈,且 `VMAP_STACK=y`,SLUB spray 在物理上无法触及。**

## 5. 最便宜的单个黑盒测试(建议只做这一个,然后收束)

深度-vs-spray 差分实验(现有 ghost 触发器即可,无需新原语):同一 requeue→ghost 序列跑 A/B 两组 —— A 组只做大量 128B kmalloc 喷(如 socket option / epoll_create / 大量 fd),B 组不喷;每组 500 次,记录 `FUTEX_LOCK_PI`/后续 `requeue` 的 **errno 级 oracle**(EDEADLK/-35 vs EOVERFLOW/-75 vs hit)。预测:**hit-rate 对喷量完全不敏感,只对触发前一次 syscall 的栈深敏感** ⇒ 用一次性数据正式否证 heap-resident waiter 假说。crash-tolerant,reboot 已预授权,无 kmsg 依赖。

## UNVERIFIED

- `vmlinux_full.asm` 在 `0xffffffc01152ce20` 处被**截断**(tail 不完整),故 `.text.unlikely` 内 `rt_mutex_slowlock$…@0x1155bcdc` / `__rt_mutex_slowlock@0x1155c348` 的反汇编未取得;其 waiter 由源码 `rtmutex.c:1234` 栈局部确定,且该副本无新分配路径 ⇒ 风险极低但未二进制确认。
- 设备源码树不可得(无 `rtmutex`c 副本;本地 `k54src/kernel/locking/rtmutex.c` 与 upstream v5.4.281 **逐字节相同**,即"vendor 未改动此文件"只是文件名推断)。但第 4/5 节的**二进制**证据不受此影响:若 vivo/RSC 补丁新增堆 waiter 写入点,必然表现为多出的 `[x?,#0x940]` qword store 或新 `bl <task_blocks_on_rt_mutex>` —— 实测都没有。
- `CONFIG_SLUB_MIRROR=y`(vivo 补丁)可能改变对象布局/freelist 行为,未验证。
