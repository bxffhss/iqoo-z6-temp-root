# 链走第一触点 = 只读 waiter->prio(设备反汇编坐实, 2026-09-27)

## 1. punch 路径上"第一次碰幽灵"的是哪一条指令

`rt_mutex_adjust_pi@0xffffffc010377ac0`(设备构建 g2a88cd145def, 逐条):

```
0x…7ad4  add  x21, x0, #0x91c        ; &task->pi_lock
0x…7ae0  bl   _raw_spin_lock_irqsave
0x…7ae4  ldr  x8,  [x19, #0x940]     ; x8 = task->pi_blocked_on   ← 幽灵指针
0x…7aec  cbz  x8 → 出
0x…7af0  ldr  w9,  [x19, #0xb4]      ; task->prio
0x…7af4  ldr  w10, [x8,  #0x40]      ; ★ waiter->prio  ← 唯一被读的幽灵字段
0x…7af8  cmp  w10, w9
0x…7afc  b.ne → 0x7b20(继续走链)
0x…7b00  tbz  w9, #0x1f → 出         ; 非 dl_prio 时**压根不比 deadline**
0x…7b20  ldr  x20, [x8, #0x38]       ; next_lock = waiter->lock (只取值, 不解引用)
```

⇒ 只要把 `waiter->prio`(偏移 0x40)填成**等于** `task->prio`, 整条 punch 就在解引用
任何幽灵字段**之前**干净返回。这是探针判据成立的根因。

## 2. 上游没有别的解引用(先前担心的 rt_mutex_get_top_task 路线被排除)

`rt_effective_prio()` 在 `__sched_setscheduler` 里被内联, 设备形态是:

```
0x10331ab0  ldr x8, [x19, #0x938]     ; p->pi_top_task   ← 不是 pi_blocked_on!
0x10331ab4  cbz x8, …
0x10331ab8  ldr w8, [x8, #0xb4]       ; pi_top_task->prio
0x10331abc  cmp w8, w20 / csel w20, w20, w8, gt
```

即这个 5.4 用的是 **pi_top_task 指针缓存**, 不读 waiter; 而且全函数(0x10331594 起 620 条)
里 **没有一条 `#0x940` 的装载**(`analysis/sched_setscheduler_dis.txt`)。
⇒ 覆盖层里的 pc/right/left/task/lock 在 prio 字命中时永远不会被读 ⇒ 单比特判据是干净的。

## 3. punch 必须真的改变 nice(否则整条路径被短路)

`__sched_setscheduler` 开头:

```c
	if (unlikely(policy == p->policy)) {
		if (fair_policy(policy) && attr->sched_nice != task_nice(p))
			goto change;
		...
		retval = 0;
		goto unlock;            ; ★ unlock 路径**不调** rt_mutex_adjust_pi
	}
```

⇒ 用 nice=0 去 punch 一个 nice=0 的线程 = 空操作(不会走到 adjust_pi)。
punch 必须把 nice 改掉(本项目用 0→19)。

## 4. 推论: 基础值 = punch **之后**的 p->prio, 不能手算

`rt_mutex_adjust_pi` 是在 `__setscheduler()` 更新完 `p->prio` 之后才被调, 此时

```
p->prio = rt_effective_prio(p, normal_prio(p)) = min(120+nice_new, p->pi_top_task->prio)
```

本项目拓扑里 W 持 C、O 阻塞在 C ⇒ O 就是 W 的 `pi_top_task` ⇒ 基础值 = `min(139, O->prio)`。
O 若为 nice 0(=120) ⇒ 基础值 120; 若 W 实际上没被提升 ⇒ 139。
⇒ **必须实测**, 不能假设(旧探针硬写 120 就是这个坑)。实测口 =
`/proc/self/task/<tid>/stat` 第 18 字段(内核 prio, 含提升)。

## 5. 撤回:`GHOST-WRITE-SHAPES-20260927.md` 末节"幽灵存在性已证实"**作废**

那 5 个数据点(`[0,64)` 炸、`[0,32)` 炸、`[32,48)` 炸、`[48,56)` 炸、`[56,60)` 炸)出自
`cm57/bisect2.py`, 它有两个各自致命的缺陷:

1. **分支写反**: `run()` 返回的是"存活"; 存活应 `lo=mid`, 代码写成了 `hi=mid`
   ⇒ 它一直在追与结论相反的那半边(所以才会出现"每个区间都炸"这种自相矛盾的数据)。
2. **判据不干净**: 它用"日志里有没有 `punch 已返回`"来判存活/炸, 于是
   "程序在 punch 之前就退了(没拿到 EDEADLK / slide 求错 / W 没锁上 C)"被一律算成"炸"
   ⇒ 三个"炸"完全可能是同一类无效运行。
   加上基础值 120 本身没被对照组验过(§4), **"全区下毒必炸"从来没被证明过**。

⇒ 结论:**幽灵是否真的被链走读到, 目前是未证状态**; 覆盖通道 [0x130,0x340) 与
目标深度 [0x269,0x2B8] 的交集仍然是*静态*推断。
新的判据/对照在 `cm57/bisect3.py`(步骤 A 对照组必须存活 ⇒ 基础值对;
步骤 B 全区下毒必须炸 ⇒ 幽灵存在 + 覆盖够得到; 步骤 M/C 钉 prio 字下标)。
