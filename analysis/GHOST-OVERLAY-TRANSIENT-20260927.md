# GhostLock 覆盖层是**易失的**: 为什么所有对照都一模一样地炸(2026-09-27)

## 0. 一句话

`rt_sigreturn` 的 fpsimd 回存确实把 0x210 个用户可控字节写进了受害者内核栈,
但它写的是**异常入口 SP 往下 0x140..0x340 的"浅带"** —— 而这段地址在受害者回到用户态
之后就是**空闲区**: 下一次任何发生在该 CPU 上的**异常**(250Hz 时钟节拍、设备 IRQ、
受害者自己的下个 syscall)都从同一个入口 SP 重新往下压栈, 整段重画。
⇒ "铺完载荷再 usleep(200ms) 然后 punch"读到的**必然**是 IRQ 残渣, 不是我们的字节。

## 1. 静态几何(全部用设备构建 g2a88cd145def 反汇编实测, 不是推算)

链 A(受害者 W 睡着时, 悬空 waiter 的真实位置):

```
__arm64_sys_futex          sub sp, sp, #0xc0     (0x103eb870)
do_futex                   sub sp, sp, #0xd0     (0x103e6874)   ← bl, 不是 tail
futex_wait_requeue_pi      sub sp, sp, #0x1a0    (0x103eb2d8)
  add x26, sp, #0x98   /  add x2, sp, #0x98  →  rt_mutex_wait_proxy_lock(lock, to, &rt_waiter)
Σ_A = 0x350;  rt_waiter ∈ [E-0x2B8, E-0x268)   (E = syscall 入口 SP)
```

链 B(覆盖通道):

```
__arm64_sys_rt_sigreturn   stp x29,x30,[sp,#-0x30]!
restore_sigframe           sub sp, sp, #0x60     (0x102b6774)
restore_fpsimd_context     stp ...,[-0x30]! ; sub sp,sp,#0x220   → 帧 0x250
  mov x0,sp ; mov w2,#0x210 ; bl memset           (0x102b84c0)
Σ_B = 0x340;  目的地 = [E-0x340, E-0x130)
```

⇒ 覆盖带 `[0x140,0x340)` **包含** waiter `[0x268,0x2B8)`; 映射 `窗口字节 i = waiter 字节 j + 0x88`
⇒ prio(waiter+0x40) 在窗口字节 0xC8 = **第 25 字**, waiter 起点 = **第 17 字** —— 静态模型自洽 ✓

## 2. 但这张图恰恰证明了它是"浅带"

E 是**每次 syscall 都相同**的入口 SP。所以 `[0x140,0x340)` 不是某个私有区域, 而是
"任何异常进来后第 3~8 层框会踩到的地方"。arm64 5.4 **没有** IRQ 栈
(`config_dev.txt`: 无 `CONFIG_IRQ_STACKS`; `CONFIG_VMAP_STACK=y`),
从 EL0 来的中断直接在当前任务的内核栈上跑 `el0_sync → handle_arch_irq → ...`,
几层就跨过 0x268。HZ=250 ⇒ 每 4ms 至少一次; 设备 IRQ 更密。
⇒ **载荷的存活时间 = 微秒级**。

## 3. 于是前面所有"对照"都必须重读

| 运行 | 载荷 | 结果 | 之前怎么解读 | 现在的解读 |
|---|---|---|---|---|
| probe 全区 120 | 全窗=120 | 炸 | "prio 字不在窗内" | 读到的是 IRQ 残渣 ⇒ 与载荷无关 |
| probe 全区 139 | 全窗=139 | 炸 | 同上 | 同上 |
| nospray | 不铺 | 炸 | "punch 幽灵本身就炸" | 同上(都是残渣) |
| shape1 w17 | 假 waiter | 炸 | "几何错" | **slide 错了 2MB**(见 §4) |

⇒ §3 的四次"炸"**没有一次**能证伪覆盖模型; 但也**没有一次**能证实它。
判据必须换成"铺完立刻打"的同步节拍(`cm57/pr.c` 的 `hammer` 模式:
W 铺完就纯自旋不做任何 syscall, main 看见旗标立刻 sched_setattr, 间隔 ~µs)。

## 4. 附带修掉的两个真 bug(都会单独杀死整条线)

1. **`/proc/<tid>/stat` 第 18 字段 = `p->prio - 100`, 不是 p->prio**
   (设备实测 nice 0 进程该字段是 `20`)。旧探针把 20 当 prio 填进窗口 ⇒
   `rt_mutex_adjust_pi` 里 `cmp waiter+0x40, task+0xb4` 永远不等 ⇒ 每次必进链走 ⇒
   每次必炸。**"整窗填 120 应当存活"这个前提之前从未真正成立过。**
2. **slide 之前是按"热点名字像不像热路径"选的**, 候选之间只差 2MB, 错位的候选
   也会把样本映成另一批**同样看起来合理**的符号(kmem_cache_*/avc_lookup/…)。
   9/27 那次 shape1 用的 slide 就是错的 ⇒ `fake_lock` 落在未映射地址 ⇒ 第一发就炸,
   与几何/节拍无关。
   ⇒ 换成**正对照**: 用 `perf_kaslr_mmap`(它对自己采样, 循环 `getpid()`)拿到
   纯 syscall 路径的核 IP, 然后扫所有 2MB 对齐的 slide, 取
   "落在 `el0_sync..el0_svc..ret_to_user` 入口区 + `__arm64_sys_getpid` + `el0_svc_common`
   窗口里"的样本数最大的那一档(`analysis/slide_pc.py`)。
   随机放一个 slide, 几百个样本落进 ~5KB 窗口的期望值是 0.1 个 ⇒ 峰是决定性的。

## 5. 顺带坐实的事实(有价值的正面结论)

* `rt_mutex_adjust_pi@0x10377ac0`: 整条 punch 路径**第一次**碰幽灵就是
  `ldr w10,[x8,#0x40]`(waiter->prio) 和 `ldr w9,[x19,#0xb4]`(task->prio) 的比较;
  `__sched_setscheduler` 在那之前只读 `pi_top_task`(0x938), **不读** `pi_blocked_on`
  ⇒ 只要 prio 命中就干净返回, 一个指针都不解引用(见 `GHOST-FIRST-TOUCH-20260927.md`)。
* `rtmutex.c:668-707`: requeue 路径里 `rt_mutex_dequeue(lock, waiter)`(=rb_erase)
  是**无条件**执行的, 不需要 `waiter == rt_mutex_top_waiter(lock)`
  ⇒ 三条 rb_erase 写形状不需要"先知道 S"就能触发(修正 `GHOST-WRITE-SHAPES` 的顾虑)。
* punch 必须真的改变 nice: `policy` 与 `nice` 都不变时 `__sched_setscheduler` 走
  `goto unlock` 短路, **不会**调 `rt_mutex_adjust_pi` ⇒ hammer 要 18/19 交替。
* 幽灵本身是真的: 每轮日志都有 `幽灵已成形(EDEADLK)` + W 的
  `WAIT_REQUEUE_PI ret=-1 errno=110`(=超时返回, 带着悬空 pi_blocked_on 回到用户态)。
