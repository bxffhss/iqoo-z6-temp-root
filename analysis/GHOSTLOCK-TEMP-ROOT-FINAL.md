# 临时 root 收口报告：CVE-2026-43499 (GhostLock) 在 iQOO Z6 / 5.4.281-qgki 上的完整利用链

> 写作时间：2026-09-28 18:3x（**20:2x 补第四次复现**；**09-29 00:5x 补第五次复现，并按裸 Image/源码逐项复核勘误**）。
> 状态：**临时 root 已在真机达成并复现五次**，
> **★2026-10-18 追加指针（不改写上面的历史）**：本报告仍是"**临时 root 本体**（GhostLock 那一次内存写）"的复现文档；
> **对外/交付口径＝`kmod/DELIVERY.md` 第 0 节**（第二十版）。本报告里凡"每轮零次炸机、设备不重启""现有原语清不掉那个字节"这类
> **稳定性／可清理性**句子，都以文末 **§12** 的收窄为准——那是其后 22 发带外部 `.ko` 载荷的真机经验，不是对 09-28 那五轮的否定。
> 五次是**五个不同 boot**：
> `cm57/run_v2.log`（16:4x，slide `1506e00000`，cred 两发链）、
> `cm57/grind_v2.log` + 设备端 `cm57/_gv.log`（17:3x grind 第 1 轮，slide `1fbd200000`，cred 两发链；
> 记录另见 `GHOST-CRED-SWEEP-20260928.md` §20）、
> `cm57/run_g01.log` + 设备端 `cm57/run_g01_dev_pr.log`（18:19，slide `1850400000`，cred 四发链）——
> 后两个文件即本报告的一手出处；
> 第四次 = `cm57/verify_settled.log` + 设备端 `cm57/verify_settled_dev_pr.log`（20:14，slide `2ad2400000`，
> cred 四发链，见 §10 最后一条）；
> **第五次 = `cm57/verify_0929_run1.log` + 设备端 `cm57/verify_0929_run1_dev_pr.log`（09-29 00:5x，
> slide `168ea00000`，cred 四发链）** —— 这一轮是**第一次走 `nofresh`**：不冷启动，直接用一个
> `load1 = 1.21` 且本次开机从未 punch 过的 boot，**一次命中、整轮 190 s**（见 §10 最后一条）。
> 每轮零次炸机、设备不重启，permissive 与 cred 的脏字段都是易失的（重启即复原），不落任何持久化。
> 本报告是自包含的收口文档；增量推导过程在 `GHOST-CRED-SWEEP-20260928.md` §1–§21，
> 各阶段的一手反汇编/真机证据在 `GHOST-LSM-HOOKS-NULLING-20260927.md`、
> `GHOST-CHANNEL-DEPTH-REBASE-20260927.md`、`GHOST-FIRST-WRITE-20260927.md`。
>
> **命名注记**：`run_g01.log` 是 `cm57/grind.py` 第 1 轮的输出（文件名模板 `run_g%02d.log`），**不是**
> "g01 模式"；别处的 "g01" 另指一轮**失败**的调试轮（已定位为自身代码 bug，见 `GHOST-CRED-SWEEP-20260928.md` §19）。

---

## 0. 一页纸结论

| 项 | 值 |
|---|---|
| 漏洞 | **CVE-2026-43499 "GhostLock"**：`kernel/locking/rtmutex.c::remove_waiter()` 清的是 `current->pi_blocked_on` 而不是 `waiter->task->pi_blocked_on` |
| 本机 | iQOO Z6 (V2220A)，`Linux version 5.4.281-qgki-g2a88cd145def #1 SMP PREEMPT Wed May 7 12:07:39 CST 2025` aarch64 |
| 为什么受影响 | 上游修复 `3bfdc63936dd` 只回移到 6.1.175/6.6.140/6.12.86/6.18.27/7.0.4（v7.1）；5.4.y 已于 **5.4.302（2025-12-03）EOL**，从未收到该修复。本机 `remove_waiter@0xffffffc010378d58` 的反汇编是**修复前形态** |
| 危害 | 睡眠线程在 `FUTEX_CMP_REQUEUE_PI` 回滚路径上带回一个**指向自己内核栈的悬空 `rt_mutex_waiter`**（栈 UAF，VMAP_STACK 也拦不住，因为栈页没被释放，只是内容过期） |
| 利用需要三步 | ① 用 `rt_sigreturn` 的 fpsimd 回存通道把**伪造 waiter** 铺进那块栈的覆盖窗口；② 让内核在 `rb_erase` 里把它当红黑树节点摘除 ⇒ 得到**任意 4 对齐地址上的 8 字节写**；③ 把靶子的 `task->cred/real_cred` 指向 `init_cred` |
| 结果 | `uid=0(root) gid=0(root) groups=0(root) context=u:r:kernel:s0`、`CapEff=0000003fffffffff`（全 caps），且**读得动 `/proc/1/environ`、`/proc/sla/wlan_stats`、`/data/system/packages.xml`** |
| 每轮成本 | 一次冷启动 + 6 发 punch（`#1..#6`），整轮约 320 s（含重启与解 slide），后四发带"开打前算出的定量预言"；**第五次改用 `nofresh`**（打一个已稳定、本次开机从未 punch 过的 boot）⇒ 不重启、整轮 **190 s**、**一次命中** |

**发数口径**（全文统一）：`#1..#6` 数的是**总发数** = 相0 泄漏 1 发 + 相1 permissive 1 发 + cred 相 4 发。
早期日志里的"两发链/四发链"只数 **cred 相**（相3..6）⇒ 18:19 那一轮在本报告是"六发"、在 `run_g01.log`
自己的行文里是"四发"，`run_v2.log` 与 §20 轮是"总 4 发 = cred 两发"；指的是同两种链长，不是四次不同复现。

### 复现命令（设备已 recovered，需要重新 push）

```bash
# 主机侧：编译 + 冷启动 + 采 IP 解 slide + push + 跑 + 回读设备端日志
python cm57/auto.py "hammer hijack shape2 sen victim shell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 kids"
# 或自动重跑到命中（每轮含重启约 6 分钟）
python cm57/grind.py 3
# 想要交互式 root shell（stdin 是真 tty 时）把 shell 换成 ishell
```
mode 整串必须作为**一个**参数传（`auto.py` 只吃 `argv[1]`）。

> ★ **别在开机风暴里打**（2026-09-28 20:0x 实测）：`auto.py` 重启后只等 `getenforce` + 8 s 就开打，
> 而那时设备还在 dex2oat 风暴里（实测 `load1 ≈ 27–29`、top 里 **132% nice**、923 tasks），
> 连打 4 轮**全挂**（3 轮死在相0 首发、1 轮相0 泄漏成功后死在相1），每轮都是 `运行 18.x s rc=255`
> 且设备自愈。**先等 `load1 < 6` 再跑**（或加 `nofresh` 打一个已经稳定、且本次开机从未 punch 过的
> boot —— 判据：`uname -s` 仍是 `Linux`）⇒ 同一台设备、同一条命令，一次就成（§10 末条）。
> 节拍敏感是机理决定的：覆盖带是浅带，靠"铺完到 punch 之间微秒级不被中断重画"。

---

## 1. 漏洞：`remove_waiter()` 清错了对象

`kernel/locking/rtmutex.c`（本机 5.4.281）里：

```c
static void remove_waiter(struct rt_mutex *lock, struct rt_mutex_waiter *waiter)
{
    ...
    /* ★ 缺陷：清的是 current 的，不是 waiter->task 的 */
    current->pi_blocked_on = NULL;          /* 应为 waiter->task->pi_blocked_on = NULL */
}
```

- 在 `rt_mutex_slowlock()` / `__rt_mutex_slowlock()` 等**同步**路径上 `waiter->task == current`，看不出问题；
- 但在 **proxy** 路径上二者不同：`futex_requeue()` → `rt_mutex_start_proxy_lock()`（`FUTEX_CMP_REQUEUE_PI`）
  里 `waiter` 是**别的线程**（睡着等 futex 的那个）的栈上对象，`current` 是发 requeue 的线程。
- 于是回滚走 `remove_waiter()` 时：树里的节点被摘了，**睡着那位的 `pi_blocked_on` 没被清**
  ⇒ 它醒来后带着一个指向**自己内核栈上已过期栈帧**的指针回到用户态。

**本机的存在性证据（一手，反汇编）**：`remove_waiter@0xffffffc010378d58` 的函数体里
`pi_blocked_on`（`task_struct+0x940`）的清零用的是 `mrs x20, SP_EL0`（= `current`），
**整个函数没有任何 `waiter->task` 装载**，链走尾参也传 `current`。同构建符号表
`analysis/kallsyms_g2a88cd145def.txt`（179,181 行）与设备 `uname` 逐字相同的构建，
并用 `_text` / `remove_waiter` / `binder_free_transaction` 三个真值自校验过。

**本机相关配置**（设备实测）：`CONFIG_FUTEX_PI=y`；`CFI_CLANG=y`（`CFI_PERMISSIVE` 未开）、
`SCS`、`PAN/UAO/SW_TTBR0_PAN`、`STRICT_KERNEL_RWX`、`VMAP_STACK=y` 都在；
`KASAN/LOCKDEP/DEBUG_SPINLOCK` 未开；`CONFIG_REFCOUNT_FULL`（kallsyms 里有
`refcount_*_checked`）；SoC 无 SVE（`cpuinfo` 无 sve）；无 `CONFIG_PROC_KCORE`；
5.4 没有 `randomize_kstack_offset`。app 侧可达面（`untrusted_app` 域）实测
`FUTEX_LOCK_PI / FUTEX_UNLOCK_PI / WAIT_REQUEUE_PI / CMP_REQUEUE_PI / rt_sigreturn / AF_UNIX` 全通。

---

## 2. 触发：把幽灵造出来（不需要竞争）

三个 futex 字必须**各占一页**（private futex 的 key = `(mm, 页对齐地址)`，同页会被当成同一个 futex ⇒ EINVAL/EFAULT），
且先在用户态写过。线程分工：

| 角色 | 动作 | 目的 |
|---|---|---|
| **W** | `FUTEX_LOCK_PI(C)` 拿到 C，然后 `FUTEX_WAIT_REQUEUE_PI(N, PI, 超时)` 睡下 | 它的栈帧就是幽灵的宿主 |
| **O** | `FUTEX_LOCK_PI(PI)` 拿到 PI，然后去 lock C ⇒ 阻塞在 W 持有的 C 上 | 构成环 |
| **main** | 对 C 发 `FUTEX_CMP_REQUEUE_PI(N, PI, cmpval)` | 触发 requeue；检测到环 ⇒ `-EDEADLK` ⇒ 回滚 ⇒ 幽灵成形 |

实测要点：
- **futex op 编号**：`WAIT_REQUEUE_PI=11`、`CMP_REQUEUE_PI=12` —— 这**就是**主线/NDK uapi 的编号
  （早期一度按 `9/10` = `WAIT_BITSET`/`WAKE_BITSET` 试过，行为不对，勿再混淆）。`CMP_REQUEUE_PI` 的
  arg4 是 `nr_requeue`（**不是 timeout**），arg6 = `cmpval`。
- W 用**绝对超时**（首轮 8 s、其后 3 s）睡；超时返回即留下悬空 `pi_blocked_on`（`st_ghost` 置位）。
- 幽灵形成后**不会被消耗**：同一颗幽灵上可以连打 6 发（相1 那笔写就是同一颗幽灵上的第 2 发落地的）。
  ⇒ **不需要重造幽灵**（重造时 requeue 往往直接成功而不是 `-EDEADLK`，白等 3 s）。

---

## 3. 覆盖层：`rt_sigreturn` 的 fpsimd 回存 = 用户数据 → 内核栈局部

幽灵的免费"写手"是这条**单向、全内容用户可控、8 字节对齐**的栈拷贝：

```
__arm64_sys_rt_sigreturn(0x30) → restore_sigframe(0x60) → restore_fpsimd_context(0x30+0x220=0x250)
    Σ = 0x340
    memset(sp, 0, 0x210)
    mov x0, sp; mov w2, #0x200; bl __arch_copy_from_user   ← 帧里 v[0..31] 原样入内核栈
```

- 校验只看 `head.magic == 0x46508001` 与 `head.size == 0x210`（**必须恰好**），不碰 `v` 的内容；
- 本机无 SVE ⇒ 走 `fpsimd_only` 那支（带 fpsimd 记录、不带 sve 记录）；
- 覆盖深度 **[0x131, 0x340] ⊇ rt_waiter 覆盖区 [0x269, 0x2B8]**；
- `ss_flags = SS_DISABLE(2)` 跳过 altstack 校验；用户帧 16 对齐，`access_ok` 长度 0x1250。
- 本程序里的坐标：`SR_RES = 0x250`（fpsimd 记录头所在）、`SR_FB = 0x260`（= `v[0]` 起点，载荷基址）。

**窗口 ↔ waiter 的换算（真机逐字节验证过）**：**窗口字节 = waiter 字节 + 0x48**，即 `rt_waiter` 起点
= 窗口第 **9** 个 8 字节字、`prio` 字 = 第 **17** 字（等价写法：waiter 第 `j` 字 ↔ 窗口第 `j + 9` 字；
定式见 `cm57/pr.c:283` 的 `SR_AT(j) = SR_FB + 0x48 + j`（推导块在 `pr.c:273-282`），来源是两条链的栈深差
`(E-0x298) - (E-0x2E0) = 0x48`）。
⚠ 早期文档与 `cm57/pr.c:10` 的注释写的 "`j = i − 0x88`" 是**加法算错的旧值**（`pr.c:281` 有记），照它铺
载荷会整体偏高；全文一律以 0x48 口径为准。`WAITER_WORD=9`，`WP_PRIO=119`。
载荷一次铺 5 份（`ncopy5`，步长 10 字）覆盖同余类，深度误差不影响正确性。三个还在被内核使用、
不能填 0 的字段（地雷 4）也在这里钉死：

```
w[3] = S + 0x18   ← waiter->pi_tree.pc 必须是 &pi_tree(内嵌空节点约定), 不能是 0
w[6] = init_task  ← waiter->task 不能为 0(rb_entry 偏移 0)
w[8] = 119        ← waiter->prio ≠ task->prio(120) ⇒ 链走不早退
```

**节拍**：覆盖带是**浅带**（距异常入口 SP 只有 0xD0..0x2E0 字节），会被该 CPU 的下一次异常重画
⇒ 必须"铺完纯自旋、微秒级间隔内 punch"（`hammer`），"铺完 sleep 再打"读到的必是 IRQ 残渣；
所有慢活（日志 `fsync`、`clone`）必须在置 `h_ready` **之前**做完。

---

## 4. 写原语：`rb_erase` 的两笔 store

链走走到 `rt_mutex_dequeue(lock, waiter)` → `rb_erase(&waiter->tree_entry, &lock->waiters)`，
而我们控制的 `waiter->tree_entry` 三个字段就是"节点"：`pc(+0x00)`（父指针，低 2 位编码颜色）/
`tree.right(+0x08)` / `tree.left(+0x10)` —— `rb_node` 的布局就是 `pc/right/left`，`cm57/pr.c:901-903`
（形状(3) 的载荷构造器）的 `w[0]/w[1]/w[2]` 与之逐字对应（`tree.left` 在 `+0x10`，不在 `+0x08`；
`pr.c:685-687` 那一处是 **DIAG/probe** 构造器，不是相0 真正用的）。

`rb_erase@0xffffffc0115446e0` 的关键路径（设备反汇编）：

```
0x115446e0  ldp  x9, x11, [x0, #8]     ; x9 = node->right, x11 = node->left
0x115446e4  cbz  x11, 0x11544734       ; 左子为空 ⇒ 走"无左子"那一支
0x11544734  ldr  x10, [x0]             ; x10 = node->pc
0x11544738  ands x8, x10, #-4          ; parent = pc & ~3
0x1154473c  b.eq 0x115447f0            ; parent == NULL ⇒ 特殊分支(形状3 走这条)
0x11544740  ldr  x11, [x8, #0x10]      ; parent->right
0x11544744  cmp  x11, x0
0x11544748  b.eq 0x11544924            ; 本节点是父的右子 ⇒ 写 parent+0x10
0x1154474c  str  x9, [x8, #8]          ; ★ 第二笔: *(parent+8) = right
0x11544750  cbz  x9, 0x115447f8        ; right == 0 ⇒ 跳过第三笔
0x11544754  str  x10, [x9]             ; ★ 第三笔: *(right) = pc
0x11544758  ret
0x115447f0  str  x9, [x1]              ; 父空分支: *link = right ⇒ root->rb_node = T
0x115447f4  cbnz x9, 0x11544754        ; right != 0 ⇒ 这一支也照样执行 *(right) = pc
0x115447f8  tbz  w10, #0, 0x11544920   ; 节点是红的 ⇒ 不重平衡
```

> 这 15 条的地址是 2026-09-29 用 `analysis/kdis.py --img analysis/kernel_dev_g2a88cd145def.bin`
> 从**设备同构建裸 Image** 逐字复核的。本报告旧版把 `rb_erase+0x00` 的 `ldp` 误标成 `0x4740`，
> 并让 `0x4740`/`0x474c` 各出现两次 —— **指令与语义当时就是对的，只有地址不对**。

由 `parent = pc & ~3` 得三种可用形状（`pc` 的**低 2 位用来编码颜色/跳过位**）：

| 形状 | 载荷 | 效果 | 约束 |
|---|---|---|---|
| **(1) 纯零写** | `pc = dst−8`, `right = 0` | `*(dst) = 0`；`cbz x9` 跳过第三笔 ⇒ **只有一笔 store、无副作用、幂等** | 无（`pc = dst−8` ⇒ `dst = (pc & ~3) + 8`，目的只需 **4 对齐**） |
| **(2) 指针写** | `pc = dst−8`, `right = V` | `*(dst) = V` **且** `*(V) = dst−8` | **`V` 必须是可写的内核地址**（写进 `.text` 当场重启） |
| **(3) 空树/父空** | `pc = **1**`, `right = T`, `left = 0` | `root->rb_node = T` 且 `*(T) = 1`；随后 `rt_mutex_enqueue` 把**真 waiter 节点的地址**（= S，栈上）写进 **`T+0x10`**（g01 dump 实测：`1` 落在 `sysname+0x04` ⇒ `"Linux"` 的 `'x'` 变 `01`，`S` 落在 `sysname+0x14` = `T+0x10`） | **`pc` 的位 0 必须为 1**（`1 & ~3 = 0` 走父空分支，同时 `*(T)=1` = 把 T **涂黑**）；填 `pc = 0` 就是地雷 2 那颗炸弹 ⇒ **第一发就 panic**。**一个 boot 只能用一次**（之后那棵假树是脏的） |
| ~~(4)~~ | `left=T, right=0, pc=F` | `*(T)=F` 且 `*(F&~3+8)=T` | **实测会炸，已弃用** |

**红黑树颜色语义（踩过坑）**：Linux `RB_RED=0 / RB_BLACK=1` ⇒ `rb_is_red(x) ⇔ *(x)&1 == 0`。
往"新根节点"写 `1` = **涂黑**，父节点是黑的 ⇒ `rb_insert_color` 的 while 一次都不成立 ⇒ 直接返回。
反之写 0（红）会让它去解引用 `gparent = *(T)&~3 = 0` ⇒ **NULL 解引用 panic**（第一发就重启的经典成因）。

**假 `struct rt_mutex`**：链走会读 `waiter->lock`（`lock->waiters.rb_node`、`lock->owner`，
`lock->wait_list` 等 ~0x80 字节）。
- 第 1 发（相0）用它必须落在**镜像里坐实的静态零洞** ⇒ 本机选 `init_uts_ns`（`0xffffffc01292d350`）；
- 相 ≥1 的假 lock **搬进覆盖带内**（`S + 0x60`），每次 `rt_sigreturn` 重铺时顺手把它清零
  ⇒ 不必再找新的静态洞（这是"一发一 boot"松成"一个 boot 6 发"的关键）；
- 位置必须在 `S+0x60`：给 `rt_mutex` 留完整的 ~0x80 字节（放在 `S−0x48` 只有 0x48，lock 尾部会
  溢出到节点自己的字上）。

---

## 5. 三个前提条件

### 5.1 本次开机的 KASLR slide（每 boot 必变）

`analysis/slide_pc.py` + `cm57/pctl.py`：`perfips` 是**自采样**（自己循环 syscall 并对自己开 perf 事件），
所以"样本必然落在 `el0_svc_common` / `link_path_walk` / `__arm64_sys_*` 这些已知窄窗口"是构造性事实；
对每个 2 MB 对齐的候选 slide 统计"样本落在已知窄窗口内"的命中峰，取峰值档。
**判据不能是"热点名字像不像"**（会选错一个 2 MB 档；错 slide 与载荷地雷的症状完全一样：第一发就炸）。
本机 text 链接期 `_text = 0xffffffc010080000`，运行时 = `+SLIDE`。

需记住：**崩溃即重启 ⇒ slide 立即失效**，不能复用旧值；`auto.py` 每轮开头强制冷启动正是为此
（另外相0 的静态零洞用过就脏，同一 boot 里重跑泄漏相会踩脏树 ⇒ 必炸）。

### 5.2 自己的 `task_struct` 地址：`/proc/sla/*_stats` 的物理窗口

`/proc/sla/wlan_stats` 等的 `stats_map@0xffffffc010f73258` 是
`remap_pfn_range(..., __pa(private_data) >> 12, len, ...)` —— **从不读 `vma->vm_pgoff`**
⇒ `mmap` 的 offset 参数完全无效；真正的原语是"从 `__pa(private_data)` 起、长度任意的
**连续物理只读窗口**"（1 GB 映射成功，真 RAM ≈ 519 MB）。

窗口里含一张 **每任务一条** 的表：`{ task_struct *(+0), u32×8(+8..+0x3F), char comm[16](+40) }`，步长 72。
⇒ 用 `prctl(PR_SET_NAME, 每轮唯一标记)` 给靶子/自己盖戳，然后在窗口里按 comm 认出 `task_struct *`；
**同一个任务的多条记录必须给出同一个指针**（这就是交叉校验，`agree`）。

这一段**不需要额外 punch**（纯读）⇒ 在相1 拿到 permissive 之后立刻做，成本只有一次子进程扫描
（子进程算完就退，避免主进程 519 MB 常驻被低内存杀手收走）。

### 5.3 permissive（相1）

`selinux_state = 0xffffffc012b18000`（`.bss`，页对齐），`enforce = state + 1`
（证据：`sel_write_enforce@0x107adb84` 里 `adrp x0,selinux_state` + `strb w8,[x21,#1]`）。
形状(2) 写 `state.qword0`：`pc = state − 8`，`V = __log_buf` 内部死槽（`0xffffffc012b30020`）。

写进去的 8 字节是 `20 00 b3 12 c0 ff ff ff`，逐字节语义（`analysis/field_consumers.py` 别名追踪定的）：

| 偏移 | 字段 | 结果 |
|---|---|---|
| +0 | **名称未定**（同构建只确证：被 55 处 hook 前置 `ldrb` 读、清 0 会炸；上游该偏移为 `disabled`，也可读作 `initialized` 一族） | 0x20 ⇒ 非 0（保真） |
| **+1** | **`enforcing`** | **0 ⇒ permissive** |
| +2 | `checkreqprot` | 真（只会更宽松） |
| +3 | `initialized` | 真（保住） |
| +4..+7 | `policycap[0..3]` | 真（全 bool / 填充；8 字节字段不可能落在 +4..+7） |

> ⚠ **`+0` 的字段名是推断，别当事实引用**：`GHOST-LSM-HOOKS-NULLING-20260927.md` §1/§9.1 只确证了
> "55 处 `ldrb` 读者 + 必须保持非 0"；上游该偏移通常是 `disabled`（受 `CONFIG_SECURITY_SELINUX_DISABLE`）。
> 若它真是 `disabled`，那么写 0x20 = 非 0 = **true** ⇒ 等于**顺带把 SELinux 整个关掉**（比 permissive 更强），
> 这也可能是"两道关卡放开"的另一个成因。**结论不变**（permissive 由 +1 那一位独立保证），但因果叙述应写成
> "改 `enforcing=0` + 顺带把 4 个惰性布尔置真（其中 +0 若为 `disabled` 则等效关闭 SELinux）"。
> 要定名就用 `analysis/field_consumers.py` 把 +0 的读者先定位出来。

配对的第二笔 `*(V) = pc` 落在 printk 环形缓冲的字节区（只被当字节读，走查器有界）⇒ 结构上无害。
**真机结果：连打 11 发设备不炸，permissive 反复复现。**

> `.bss` / `.data` 的差别：本机早期 6 轮里"目的在 `.data` ⇒ 落地且活着；在 `.bss` ⇒ 看不见效果或重启"，
> 但 §12 的自纠说明**真正机理是脏 `rb_node`**（复用同一块洞时 enqueue 会从上一轮的 T 继续下潜，
> 把载荷/随机值当节点指针解引用）。规则仍然实用：**只挑"看起来是 0"的洞，且每发换一块**。

---

## 6. 六发利用链（`cm57/run_g01.log`，本 boot slide = `0x1850400000`）

> 六发 = 相0 泄漏 1 发 + 相1 permissive 1 发 + cred 四发；`run_g01.log` 自己的行文把这轮的 cred 段叫作
> "四发"（口径见 §0）。下表 g01 列即 `cm57/run_g01.log`，设备端对照 `cm57/run_g01_dev_pr.log`。

| # | 相 | 形状 | 落点 / 值 | 判据（**开打前算出的定量预言**） | g01 实测 |
|---|---|---|---|---|---|
| 1 | 相0 | (3) | `pc = 1` ⇒ `*(T) = 1` 且 `root->rb_node = T = uts+0x08`；enqueue 下潜一步把真 waiter 地址写进 **`T+0x10`** | `uname()` 的 sysname 里出现**非镜像**的 `ffffff..` 指针 ⇒ 那就是 S（`sysname` 在 `uts+0x04`，所以要按 4 字节步进扫，否则系统性错过） | `S = ffffffc02c60bbd8` |
| 2 | 相1 | (2) | `*(selinux_state) = __log_buf 死槽` | `enforce` 文件整段原文变化；`/proc/sla/*_stats` + `/dev/ashmem` 从 EACCES 变可 open | 原文 `1 → 0`，2 道关卡放开 |
| — | 相2 | 读 | 无 punch：`/proc/sla` 窗口按 comm 认 `task_struct` | 同任务多条记录给同一指针 | `TASK = ffffffb5ee606900` |
| 3 | 相3 | (2) | `*(TASK+0x848) = init_cred`（`cred ← init_cred`） | 靶子自报 `getuid() == (TASK+0x840) >> 32` | 预言 **−75**，实测 **−75** |
| 4 | 相4 | (1) | `*(init_cred+4) = 0`（还原 uid+gid，`usage` 全程不动） | 靶子自报 `uid=0 && euid=0` | 命中（主观 root） |
| 5 | 相5 | (2) | `*(TASK+0x840) = init_cred`（`real_cred ← init_cred`） | `/proc/<v_tid>/status` 的 `Uid` 第一栏 == 同一个预言 | `Uid=-75,0,0,0` |
| 6 | 相6 | (1) | `*(init_cred+4) = 0` | `/proc` 的 `Uid`/`Gid` **八栏全 0** 且靶子自报 `0/0` | `Uid=0,0,0,0 Gid=0,0,0,0` |
| — | 相7 | — | 不 punch：由**靶子线程**亲自 `clone` 孩子 → `exec sh` | 孩子 `id` = `uid=0(root)` + 读得动 `/proc/1/environ` | ✅（见 §7） |

**为什么相3/相5 后面必须紧跟一发零写**：形状(2) 的第二笔 `*(V) = dst−8` 把 `dst−8`（一个内核指针）
盖在 `*(init_cred)` 上 —— 而 `*(init_cred)` 正是 `usage`(低 4 字节) + `uid`(高 4 字节)。
于是 `getuid()` 必然等于 `(dst−8) >> 32`：这正是相3/相5 的判据来源（一次同时证明**地址、几何、落地**三件事）。
相4/相6 用形状(1)（**没有第二笔**）只清 `init_cred+4` 起的 8 字节 = `uid+gid`。

**为什么相6 之后主观+客观一起干净**：`cred` 与 `real_cred` 指向**同一个对象**（我们把两个槽都指向了
`init_cred`），所以一次还原两边同时归 0。

**为什么靶子必须是"链走不碰的 task"**：早期 7 轮里直接把幽灵持有者 W 的 cred 换掉 ⇒ 当场重启 5 次。
孪生弹差分（同形状同值、只把目的换成自己带内的空字）证明"配对写盖住 `init_cred` 头 8 字"无害，
炸的是"换掉**正在被这条链走改动的那个 task** 的 cred"。⇒ 靶子改成一条**改过名的旁观 pthread**
（`gk<pid><tid>`，只做 `getuid()` 自报 + 睡一小会，完全不参与 futex/链走）。

---

## 7. root 的调用方法（可用性）

靶子线程在相7 亲自 `clone`（裸 `svc clone`，绕开 bionic 的 `pthread_atfork` 处理器）出孩子，
孩子继承的是靶子**刚被换成 `init_cred` 的那份 cred**：

```
[KID>out] KID 16145
uid=0(root) gid=0(root) groups=0(root) context=u:r:kernel:s0
init-environ: PATH=/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:…
packages.xml: OK            ← /data/system/packages.xml (0640 system:system)
sla-read: OK                ← /proc/sla/wlan_stats (enforcing 下 shell 连 stat 都 EACCES)
caps: CapEff: 0000003fffffffff
```

两种形态（mode 词控制）：

| 词 | 行为 | 用途 |
|---|---|---|
| `shell` | 孩子**不动管道**，原样继承拉起 `pr` 的那个 adb 会话的 fd0/1/2，跑一串**只读举证**后退出 | 自动化轮次（waitpid 1 s 就回来，不卡流程） |
| `ishell` | 同上；且 `isatty(0)` 成立时 `exec /system/bin/sh` | 真人在 `adb shell` 里手跑 ⇒ **挂在会话上的交互式 root shell** |

```
# 交互式 root（手动，设备上）
adb shell
cd /data/local/tmp
./pr <本次开机的 slide> hammer hijack shape2 sen victim ishell ph2=0 ncopy5 shots=25 maxr=8 nph=7 rounds=200 wcpu=6 mcpu=0 kids
```

> **`ishell` 的前置与一条反向坑（2026-09-28 20:5x / 23:0x 实测，证据 `cm57/detach_*-run*.log`、`cm57/root_test.sh`）**
> - 唯一的开关是 `isatty(0)`（`cm57/pr.c:573`）⇒ 必须是**真 tty**：要么人在 `adb shell` 里手跑（预检
>   `adb shell tty` 要回 `/dev/pts/N`），要么用 `adb shell -tt` **强制分配 pty 并把命令喂进 stdin**：
>   `printf 'sh /data/local/tmp/root_test.sh; exit\n' | adb shell -tt "<… ishell …>"`（实测脚本以
>   `uid=0` + `CapEff=3fffffffff` 执行）。**非 tty 的管道不会读 stdin** —— 它走"跑一遍举证就退出"的分支。
> - **反向的坑更实用**：只要还有进程持有那个 pty 的 fd，这条 `adb shell` 命令就**不返回**
>   （实测被吊住 9.5 min / 13 min）。在会话里做长跑任务必须
>   `setsid nohup cmd </dev/null >>/data/local/tmp/x.log 2>&1 &`。
> - 对照组结论：**不脱 tty 的后台任务也不会被 SIGHUP 杀**（这条 adb 路径上没有控制终端挂断信号），
>   但换设备/内核未必成立，`setsid` 仍建议加。
> - 交互 shell 随会话结束而死、**不可重连**；再要就得重启 + 重解 slide + 重跑（相0 的零洞每 boot 一次）。

性质：**不落盘、不装 setuid 助手、不改任何持久配置**；permissive 与 `init_cred` 的脏字段都在内存里，
重启即全部消失。`ishell` 给的 shell 是 `u:r:kernel:s0` + 全 caps ⇒ 可以直接读 `/proc/1/environ`、
`/data/system/packages.xml` 这类平时够不着的东西（这也是"不只是 uid 数字，能力集真的跟着来了"的证据）。

**没有采用的两条"更持久"的路**（与用户"不留持久化"的要求冲突，明确不做）：
`core_pattern` 管道 helper（要往 `/data` 写脚本等崩溃触发；顺带一条 config 事实：本机
`CONFIG_STATIC_USERMODEHELPER=y` 且路径钉死 `/system/bin/vivo_coredump` ⇒ 这条路本来也走不通）；
任何预置的 setuid/`init.d` 类落地物。

### 7.1 第三条路（2026-09-29 实证，仍是易失的）：运行时 su 兼容层 = 给任意 app 免客户端授权

这条路**不落任何持久物**（tmpfs 挂载 + 内存里的 daemon，重启即全消失），但把"临时 root"变成了
"本 boot 内可反复、可给别的 app 用的 root 服务"，所以记在这里：

| 环节 | 本机事实 | 证据 |
|---|---|---|
| 落点 | zygote 继承的 `PATH` 里 **`/product/bin` 排第一且只有 3 个文件**（`f2fs_io`/`init.qti.display.sh`/`qvirtmgr`）⇒ cp 出来、`mount -t tmpfs -o rw,mode=0755` 覆盖、cp 回去、多出来的那个叫 `su` ⇒ **零破坏**。`/system/xbin`、`/odm/bin`、`/vendor/xbin` 在本机不存在，而 `/` 是 erofs **ro** ⇒ 连 `mkdir` 都做不了；`/system/bin` 499 项、`/vendor/bin` 402 项不能碰 | `cm57/round3_dev.log` 第 1-3 步（`mount_rc=0`）；⚠ `/product` 是符号链接 ⇒ `/proc/mounts` 里那行显示成 `tmpfs /system/product/bin` |
| app 看得见挂载 | zygote64 与 app 自己的 `mountinfo` 都含该 tmpfs 行（`… /system/product/bin rw,relatime master:71 - tmpfs …`，经 shared subtree 传播）⇒ 第三方 app 的 `Runtime.exec("su -c …")` **裸名就能命中** | `cm57/round3_dev.log` 第 5 步；`grep -c product /proc/<app>/mountinfo = 1` |
| 强证（root 会话早已结束，由 uid 2000 发起） | `/product/bin/su -c "…"` ⇒ `uid=0(root) … context=u:r:kernel:s0`、`Uid: 0 0 0 0`、`CapEff=0000003fffffffff`，并读到 `/proc/1/environ`；**同一条命令 uid2000 自己跑 = `Permission denied`**（两侧对照）。裸名 `env PATH=<app 的 PATH> sh -c 'command -v su; su -c id'` ⇒ `/product/bin/su` + `uid=0(root)` | `cm57/suverify_dev.log`、`cm57/suverify2.log`(A 段) |
| 授权依据 | daemon 侧 `SO_PEERCRED` 给出调用方 `uid/gid/pid` + `/proc/pid/cmdline` ⇒ 可做"按包名点头"的白名单（等价于 KSU/Magisk 的 manager），**不占额外 punch** | `cm57/sud_daemon.log` |
| 寿命 | 会话结束后仍可用（心跳 `uptime 426 → 667` 仍在涨；daemon 零重启；期间再次 `su -c` 成功） | `cm57/suverify*.log` + 设备端 `hb.log` |

两个付过学费的实现坑（`cm57/sud.c`）：**必须 `signal(SIGPIPE, SIG_IGN)`**（否则调用方提前退出后，daemon 往那个 socket 写一下就被静默打死 —— crash buffer 无记录、无 lmkd 痕迹，看起来像被系统杀；
实测约 4 分钟就没了），以及 **`struct ucred` 的字段顺序是 `pid` 在前**（搞错会让 uid/gid/pid 三值错位）。
外面再包一层监督循环 `setsid nohup sh -c 'while :; do sud --daemon; sleep 2; done' </dev/null >>log 2>&1 &` 做保险。

第三个已知限制（**尚未修**，日常用之前要处理）：daemon 现在是 `for(;;){ accept(); serve_one(); }` 的
**串行**结构 ⇒ 一个 app 长时间占着 su 会话（比如挂着交互式命令）会让其他 app 的请求排队等待，
这是"某个 app 卡住"的第二个潜在来源。修法就是 `accept` 之后先 `fork` 再 `serve_one`（父进程只负责收单）。

边界要说清：① 准入条件是**全局 permissive**（exec 那道 MAC 门只能靠它开，所以本 boot 所有进程的
SELinux 都不拦了）；② 给的是"命令以 root 跑"，app 进程自身仍是它自己的 uid（`Uid: 10183…` 实测未变）——
要"app 进程本身 uid0"仍得回 §6 的 cred 写法，且受 per-task 语义与每 boot 的发数预算限制；③ 重启全消失。
驱动脚本：`cm57/round3.sh`（推文件 → 冷启动 → 等 `load1<6` → `cm57/solve_only.py` 解 slide →
`printf 'sh 脚本; exit\n' | adb shell -tt "<… ishell …>"` → 回读设备端日志）。


---

## 8. 观测与判据原则（这套是本项目的血泪账）

1. **本机没有可用的内核事后日志**：`/dev/kmsg` 0660 root:system、pstore 拒读、`dmesg` 被 restrict、
   无 `/proc/kcore`。⇒ 程序每行 `open(O_APPEND|O_CREAT)+write+fsync` 到 `/data/local/tmp/*.log`，
   重启后仍读得到；另起观察线程每 200 µs `uname()` 并在变化时 `fsync` ⇒ 能在 panic 后、重启前抓到内核写入。
   **adb 的 stderr 在 panic 时会丢尾巴**（因此误判过好几次），判据一律读设备端日志文件。
2. **`getenforce` / `/sys/fs/selinux/enforce` 在本机不可当 permissive 判据**：`sel_read_enforce`
   走四级间接链 + 多值连印（实测内容 `"182"`），改完首字符变 `'0'` 但整串仍非零 ⇒ libselinux 仍报 Enforcing。
   ⇒ 判 permissive 用**行为级关卡**：`/proc/sla/*_stats`（enforcing 下连 `stat` 都 EACCES）与
   `/dev/ashmem`（0666 但 open EACCES）。
   ⚠ **`tracing_on`/`buffer_size_kb` 不是关卡**（它们 0666 且 shell 在 gid 3012 ⇒ enforcing 下也能写，
   早期拿它们当判据是恒真的，见 `cm57/macgate.c` 的只读基线）。
3. **能自动化的判据只许匹配目标进程的真实输出行**（例：孩子的 `id` 原始输出行），绝不能匹配我们自己
   的提示语文字（曾因此把一轮"没提权"判成命中）。**同时也别给判据加"行首锚点"**：举证孩子与父进程
   共享同一个 stdout fd，两边的行会互相插进对方中间（真机原文 `getenforce: [KID>out] ★★★ …`、
   `uid=0(root)uid=0(root) gid=0(root) gid=0(root) …`）⇒ 旧判据 `^\[KID>out\].*uid=0\(root\)`
   在 **stdout 与设备端 `pr.log` 上都会失配**，2026-09-28 20:1x 因此把一次**真命中**报成了 MISS。
   同一份日志、三个判据的正对照：

   | 日志 | 真实结果 | `^\[KID>out\].*uid=0\(root\)` | 裸 `uid=0\(root\)` | `uid=0\(root\).*context=u:r:kernel:s0` |
   |---|---|---|---|---|
   | `run_g01_dev_pr.log` | 成功 | **False（假阴性）** | True | True |
   | `grind_v.log` | 失败（孩子报 2000） | False | **True（假阳性）** | False |
   | `_v7.log` 等其它失败轮 | 失败 | False | False | False |

   ⇒ 现行判据（`cm57/grind.py` 的 `KIDWIN`）= `uid=0\(root\).*context=u:r:kernel:s0`：既带上"孩子真的
   跑在 kernel 域"这层上下文，又耐交织（提示语里没有这个串；uid=2000 的孩子报的是 `u:r:shell:s0`）。
4. **凡"用某节点当判据"，先在未攻击状态下量一遍基线**（`macgate.c` 一次跑动就否掉了两条恒真判据）。
5. **三个独立命题要分开证**：`(TASK+0x840)>>32` 的预言只同时保证"地址对 + 几何对 + 这一发落了"，
   它**不**保证"cred 真的被换了"——后者要靠相4 之后的 `getuid()==0` 与孩子的 `id`。
6. **跑之前先看设备忙不忙**：punch 的成败取决于"铺完到 punch 之间微秒级不被中断重画"（浅带），
   开机风暴期（`load1` 二三十、`nice` 占用高、dex2oat 在跑）实测 **4/4 挂**，`load1 < 6` 之后 **1/1 成**
   ⇒ 把"等 load 落定"当成和"解 slide"同级的前置条件（§0 复现命令下的 ★ 有具体做法）。

---

## 9. 地雷清单（每一条都烧过真机）

1. **假 lock 的落点必须"看得见且为 0"**，且**每发换一块**：残留的 `lock->waiters.rb_node = T`
   会让下一发的 enqueue 从 T 继续下潜，把载荷当节点指针解引用 ⇒ panic。
2. **往新根节点写的值必须位 0 = 1（涂黑）**，否则 `rb_insert_color` 解引用 `gparent = 0` ⇒ NULL panic。
3. **形状(2) 的 `V` 必须是可写内核地址**：早期用"窗口里 cred 众数"换算回链接期落在 `.text` 的
   `cfi_jt` ⇒ 配对写打进 `.text` ⇒ 当场重启。⇒ 真值一律用 `kallsyms + 正对照 slide` 算。
4. **`waiter->pi_tree` 必须是 `&pi_tree`（内嵌空节点约定）不能是 0**，`tree.pc` 也必须 ≠ `S`
   （否则 `RB_EMPTY_NODE` ⇒ dequeue 直接返回，写根本不发生）。
5. **`/proc/<tid>/stat` 第 18 字段 = `p->prio − 100`**（不是 `p->prio`）；拿错会把探针填成必炸的填充。
6. **`policy` 与 `nice` 都不变时 `__sched_setscheduler` 走 unlock 短路，压根不调 `rt_mutex_adjust_pi`**
   ⇒ hammer 必须 18/19 交替改 nice。
7. **一次全量物理扫描几十秒 ⇒ 主进程会在 ~140 s 被安卓低内存杀手 SIGKILL**（rc=137）。
   ⇒ 常规路径只扫 comm 记录（`sla_child_scan` 的 `aux=0`），anchor/众数/零页只在 DIAG 相里算。
8. **一条 futex 一页**（private futex 的 key = 页对齐地址），三个 futex 字不能同页。

---

## 10. 局限与诚实记账

- **`init_cred` 不是"干净的"**：相3/相5 的配对写把它的 `uid` 短暂弄脏成残渣值，相4/相6 再清回 0，
  最终状态与真值一致（uid=0/gid=0）。但 **`usage`（refcount）是否与原值逐位相同没有验证过** ——
  载荷刻意只写 `+4` 起 8 字节来避开它；本机是带检测的饱和 refcount，即使归零也不会误释放
  （kallsyms 里有 `refcount_*_checked`）。这一条属于"设计上避开 + 没观测到异常"，不是"已证明等价"。
- **★ 相0 的副作用（2026-09-29 补，一手 logcat）**：相0 的泄漏本质是把 `0x01` 写进
  `init_uts_ns.name.sysname[4]`（`"Linux"` 的 `'x'` 变 `01`），于是**本次开机 `uname()` 的 sysname 就是
  `Linu\x01`**。ART 的 `artd` 里有硬断言 `CHECK(strcmp(uts.sysname,"Linux")==0)` ⇒ 它一启动就
  SIGABRT，实测崩溃缓冲区里 **11/11 全是 `>>> /apex/com.android.art/bin/artd <<<`**，
  表现为"**需要 dex 编译/校验的 app 打开后闪退或卡住**"（已编译过的没事，所以只是"有些"）。
  ⇒ 这不是被风控杀、也不是 SELinux 的问题，而是**我们的读通道借用了人家会断言的字段**。
  两个处置：① 收尾就 `reboot`（sysname 是易失的，重启立刻恢复 `Linux`）；② 要把这个窗口当日常用，
  **得把相0 的落点从 `sysname` 挪到 `nodename`/`domainname`**（`pr.c` 的 `TGT_ABS`/`tgt=` 已支持），
  并按规矩重跑一轮真机验证（挪落点会动到泄漏判据的扫描逻辑）。
  ⚠ 用现有原语**清不掉**这个字节：形状(1) 只能写 0（写 0 之后 sysname 变成 `Linu\0…`，断言照样失败），
  形状(2) 写的值必须是可写内核地址（不是 `0x78`）⇒ "任意**值**写"才谈得上现场修复。
- **每 boot 一轮**：相0 用的静态零洞用过就脏（而且 KASLR slide 每 boot 变、崩溃即重启）
  ⇒ 不能在同一 boot 里重跑整条链。
- **可靠性**：换成 `victim` 靶子后，**五个不同 boot 成功**（16:4x `run_v2.log`、17:3x `grind_v2.log`/
  `_gv.log`、18:19 `run_g01.log`、20:14 `verify_settled.log`、09-29 00:5x `verify_0929_run1.log`）；但**"连续"要打个折**：18:19 与 20:14 之间夹着
  **4 轮开机风暴期失败**（`verify_0928_1955.log`、`verify_run2/3/4.log` ⇒ 见 §0 ★ 与下面"时间窗"条），
  更早的 `v5`/`v6` 与一轮 `g01` 的失败已定位为
  **自身代码 bug**（`GHOST-CRED-SWEEP-20260928.md` §19），不是通道失效。更早 6 轮里相3 死 5 次（那时靶子是
  W 自己，孪生弹差分见同文档 §15）。真正的风险发是相3/相5 两发指针写，零写两发实测幂等无副作用。
- **permissive 不等于"想做啥都做"**：`kprobe_events`(0644 root:readtracefs)、`/proc/kcore`(不存在)、
  `/dev/mem`(不存在)、`dmesg`(要 CAP_SYSLOG) 这些门是 **DAC/capability** 门，permissive 一律无效。
- **时间窗 / 失败率**：幽灵的覆盖带是浅带，靠 hammer 节拍维持；真实机上是每轮 6 发、毫秒级窗口。
  2026-09-28 20:0x 第一次拿到与环境相关的定量数据：**开机风暴期 4/4 挂**（`load1 ≈ 27–29`、top 里 132% nice、
  923 tasks），等 `load1 < 6` 之后 **1/1 成** ⇒ 失败的主因是"该 CPU 上有别的活把微秒级窗口掀掉"，
  不是几何或 slide（两者的失败症状本来就一样，见 §5.1）。**09-29 00:5x 补上低负载档的第二个点**：
  `load1 = 1.21` + `nofresh` ⇒ **1/1 成** ⇒ 目前累计"低负载档 2/2、开机风暴档 0/4"。仍**没有**统计学意义上的失败率测量
  （要做的是"不同负载档 × N 轮"的一张表）。
- **★ 第四次真机复现（2026-09-28 20:14，`cm57/verify_settled.log` + 设备端 `cm57/verify_settled_dev_pr.log`）**：
  slide `2ad2400000`；相3 预言 `uid=-102` 实测 `-102`；相5 `/proc/17792/status` = `Uid=-102,0,0,0`；
  相6 `/proc` `Uid=0,0,0,0 Gid=0,0,0,0`；靶子亲生孩子报 `uid=0(root) gid=0(root) groups=0(root)
  context=u:r:kernel:s0`、`CapEff=0000003fffffffff`、`Seccomp=0`，并读动 `/proc/1/environ`、
  `/data/system/packages.xml`、`/proc/sla/wlan_stats`；`uptime 494 s` **全程没重启**。
  **外部旁证**（不经本程序、另开一条 adb shell 读到）：`getenforce=Permissive`、`/sys/fs/selinux/enforce`
  = `0`、`/proc/sla/wlan_stats`（enforcing 下 EACCES）读得出字节 ⇒"内核状态真被改了"不只靠程序自报。
  收尾照 §11 步骤 4 做完（rm + reboot ⇒ `getenforce` 回到 Enforcing）。
- **★★ 第五次真机复现（2026-09-29 00:5x，`cm57/verify_0929_run1.log` + 设备端 `cm57/verify_0929_run1_dev_pr.log`）**：
  **第一次不冷启动** —— 开工前实测 `uname -s` 仍是 `Linux`（本次开机从未 punch 过 ⇒ 相0 的静态零洞干净）、
  `load1 = 1.21`、Enforcing，用 `python cm57/auto.py "nofresh hammer hijack shape2 sen victim shell …"`，
  **一次命中**。slide `168ea00000`；相0 `S = ffffffc02b903bd8`（假 lock = `S+0x60` = `…bc38`）；相1 `enforce`
  原文 `1 → 0`（目的 `0x12b18000`、值 `0x12b30020` 换算回链接期与 kallsyms 逐字相同）；`TASK = ffffff9c6118d780`
  ⇒ 相3 预言 `uid = (TASK+0x840)>>32 = 0xffffff9c = -100`，**实测 -100**；相4 `uid=0/euid=0`；
  相5 `/proc/20548/status Uid=-100,0,0,0`；相6 `Uid=0,0,0,0 Gid=0,0,0,0`；靶子亲生孩子
  `uid=0(root) gid=0(root) groups=0(root) context=u:r:kernel:s0` + `CapEff=0000003fffffffff` + `Seccomp=0`，
  读得动 `/proc/1/environ`、`/data/system/packages.xml`、`/proc/sla/wlan_stats`；`[DONE] 全流程结束(没炸)`，
  运行 190.5 s，设备 `uptime 4192 s`（本轮开始前 3950 s ⇒ **单调递增，全程没重启**）。
  **外部旁证**（另开一条 adb shell，uid 仍 2000）：`getenforce = Permissive`、`/sys/fs/selinux/enforce = 0`、
  enforcing 下连 `stat` 都 EACCES 的 `/proc/sla/wlan_stats` 直接读得出字节。
  **这一轮顺带独立证实了本次复核的两处勘误**：① 打完后 `uname -s` 的原字节是 `4c696e75 01`
  （`"Linux"` 的第 5 字节 `'x'` 被形状(3) 的 `pc = 1` 改成 `01` ⇒ 若填 `pc = 0` 就是 §9 地雷 2 那颗炸弹）；
  ② dump 里 `1` 在 `sysname+0x04`、`S` 在 `sysname+0x14` = **`T+0x10`**（与修正后的 §4/§6 一致）。
  判据同样只认 `uid=0\(root\).*context=u:r:kernel:s0`：两份日志上该判据为真，而带行首锚点的
  `^\[KID>out\].*uid=0\(root\)` **又**给出假阴性（真机原文仍是 `getenforce: [KID>out] ★★★ …` 这种交织，§8.3）。
  **收尾已照 §11 步骤 4 做完**：`rm /data/local/tmp/{pr,sp,pr.log,ipk.txt}` + `adb reboot` ⇒ 重启后
  `getenforce = Enforcing`、`uname -s` 回到干净的 `Linux`（那个 `0x01` 字节随重启消失）、
  `/proc/sla/wlan_stats` 与 `/dev/ashmem` 两格**重新 EACCES**（§8.2 的行为级关卡回到基线）⇒ 零持久化残留。

---

## 11. 复现步骤（从零到 root，含依赖）

```bash
# 0) 主机侧要求：adb(DEV=<DEVICE_SERIAL>)、NDK clang、python
#    （本机 Git Bash **没有 `python3`**，只有 `python`）；设备端 `/data/local/tmp/perfips` 常驻（09-26 起），
#    `pr`/`sp` 由 auto.py 每轮 push
#    同构建符号表 analysis/kallsyms_g2a88cd145def.txt（kallsyms_finder 从 boot.img 提取，179,181 行）

# 1) 编译
NDK/.../bin/aarch64-linux-android35-clang.cmd -O2 -g0 -fPIE -pthread -Wall \
    -Wno-unused-parameter -Wno-unused-function cm57/pr.c -o cm57/prbin

# 2) 一条命令跑完整轮（冷启动 → sp 自检 → perf 采样解 slide → push → 跑 → 回读设备日志）
#    ★ 先等设备 load1 < 6 再跑（开机风暴期打 = 4/4 挂，见 §0 复现命令下的 ★）
python cm57/auto.py "hammer hijack shape2 sen victim shell ph2=0 ncopy5 shots=25 maxr=8 nph=7 \
                     rounds=200 wcpu=6 mcpu=0 kids"
#    多轮自动重跑到命中：python cm57/grind.py 3   （⚠ 它会覆盖 cm57/run_g01.log，跑前先备份）
#    ★ `nofresh`（跳过冷启动，直接用当前 boot）必须是 mode 串的**第一个词** ——
#      `cm57/auto.py:134/150` 是按 `startswith('nofresh')` 判定并从串首剥掉的。
#      用它的唯一前提：本次开机**从未 punch 过**（判据 `uname -s` 仍是 `Linux`；一旦相0 落地，
#      sysname 的第 5 个字符会从 'x' 变成 0x01）且 `load1 < 6`。slide 每 boot 变 ⇒ `nofresh` 仍要重解。

# 3) 成功的样子（设备端 /data/local/tmp/pr.log）
#    相0 泄漏到 S=...  →  相1 enforce 1→0 + 2 道关卡放开  →  TASK=...
#    相3 预言 uid=-NN 逐位命中  →  相4 uid=0/euid=0  →  相5 /proc real=-NN  →  相6 八栏全 0
#    孩子 exec `id` ⇒ uid=0(root) ... context=u:r:kernel:s0（判据见 §8.3：别看行首 [KID>out]）

# 4) 收尾（用户要求"不留持久化"）
adb reboot                        # permissive 与 init_cred 脏字段都是易失的
adb shell rm -f /data/local/tmp/{pr,pr.log,sp,ipk.txt}
adb shell getenforce              # 应回到 Enforcing
```

### 文件清单

| 文件 | 作用 |
|---|---|
| `cm57/pr.c` | 完整利用程序（触发 + 覆盖层 + 六发相表 + 会话 shell），~3200 行 |
| `cm57/auto.py` | 单轮全自动：编译 → 冷启动 → `sp` 自检 → perf 解 slide → push → 运行 → 回读日志 |
| `cm57/grind.py` | 反复跑到命中判据（判据 = 孩子的 `id` 原始行 `uid=0(root).*context=u:r:kernel:s0`，**不吃行首锚点**，见 §8.3） |
| `cm57/pctl.py` + `analysis/slide_pc.py` | 正对照求 KASLR slide |
| `cm57/macgate.c` | 只读 MAC 关卡基线（一次跑动否掉两条恒真判据） |
| `cm57/detach_test-run*.log`、`cm57/detach_v2-run1.log`、`cm57/root_test.sh` | `ishell` 的 tty/pty 行为与"root 之后怎么长跑"的对照实测（§7 那条 ★ 的出处） |
| `analysis/kallsyms_g2a88cd145def.txt` | 与设备逐字同构建的内核符号表（179,181 行） |
| `analysis/kdis.py`/`framecmp.py`/`stackdepth.py`/`field_consumers.py`/`find_pair_targets.py` | 反汇编与偏移推导工具 |
| `analysis/GHOST-CRED-SWEEP-20260928.md` | 增量推导全过程（§1–§21），本报告的一手出处 |
| 证据（五个不同 boot） | `cm57/run_v2.log`（16:4x）· `cm57/grind_v2.log`+`cm57/_gv.log`（17:3x）· `cm57/run_g01.log`+`cm57/run_g01_dev_pr.log`（18:19）· `cm57/verify_settled.log`+`cm57/verify_settled_dev_pr.log`（20:14）· `cm57/verify_0929_run1.log`+`cm57/verify_0929_run1_dev_pr.log`（09-29 00:5x，`nofresh` 首次） |
| 失败轮留档（开机风暴期 4 连挂） | `cm57/verify_0928_1955.log`、`cm57/verify_run2.log`、`cm57/verify_run3.log`、`cm57/verify_run4.log` |

---

## 12. 一句话总结

**漏洞给了一个"悬空的内核栈对象"，`rt_sigreturn` 给了"往那块栈里写 0x200 字节用户数据"的能力，
`rb_erase` 把这两件事合成了一支"任意 **4 对齐**地址上的 8 字节写"（目的 `dst = (pc & ~3) + 8`，写值本身
是 8 字节；形状(1) 只落一笔）。剩下的全是工程：解 KASLR、在
`/proc/sla` 的物理窗口里认出自己的 `task_struct`、然后四发把 `cred`/`real_cred` 指向 `init_cred`
并把被配对写弄脏的 `uid/gid` 擦回 0 —— 一个 boot 六发 punch，孩子 `exec sh` 就是 `uid=0(root)`。**


---

## §12 2026-10-18 勘误与收窄（一手出处都在这份仓库里，不是回忆）
这一节只处理**本报告里关于"稳定性 / 可清理性 / 成功率"的三句**——它们在 09-28～09-29 写的时候是对的，其后 22 发带外部 `.ko` 载荷的真机经验把它们**收窄或推翻**了。逐条给原文证人，便于以后谁复核。

**① 「用现有原语清不掉这个字节」（§里关于 `uts.sysname` 被打成 被打成 `Linu` ＋一个 NUL 字节、断言照样失败那句）——★已被推翻。**
一手：`kmod/w103_evidence/w405_ksu_stage.log` 第 79 行
```
[23:18:33]   UTS ★sysname 已写回 Linux(复读通过；新起的 app 进程应当不再 abort)
```
其后同一段还有三行 `uts: sysname=[Linux] 正常，不动`（23:18:34／23:19:10×2）。⇒ 自 rc51 起，**载荷自己会把 `sysname` 写回并复读校验**（`echo 1 > /proc/ksu_fixuts` 那条腿），所以"清不掉"只在**不带载荷的裸 punch 窗**里成立。易失性那句仍然对（重启也恢复）。
**规矩的写法**：测量型断言（`uname -r`/`uname -s` 之类）失败时，要分清"**没有原语**"与"**有原语但这一发没跑它**"——本报告当年是前者，现在是后者已解决。

**② 「每轮零次炸机、设备不重启」——收窄成"这条利用本身不重启；重启压力来自我们的载荷"。**
09-28 那五轮是纯 cred/permissive 写，确实零炸机。其后带 `.ko` 的 22 发里，窗口**设计上以 `adb reboot` 收尾**（临时 root 不留过夜），并且量到过一次**我们自己的 root sh `fork-exec` 风暴把窗口跑到一半打成 `HARD_RESET/PS_HOLD`**（PMIC 硬复位，一手账 md `ROUTE-B-OFFSET-INVERSION.md` §6.198；`pstore` 是空的 ⇒ 只能靠 `bootreason`＋采样器终值＋`dmesg.live` 尾部密度三件只读事判读）。⇒ 跑长窗口前先挂风暴计数器（`/proc/stat` 的 `processes` 每 boot 累计，**只能同 boot 自比**，别记绝对阈值）。
另外一句要提前给：**`persist.sys.boot.reason.history` 看不见 raw `reboot(2)`**（那条 property 由 init/用户态写）⇒ `cold,charger` 只能否证"框架式重启"，**不能**否证"某个 root 进程直接调了 `reboot` 系统调用"（§6.245）。

**③ 「低负载档 2/2、开机风暴档 0/4」——样本数现在可以扩，但要加一条新限定。**
今天 22 发全部走 `kmod/go.sh` 那条"reboot → 等 `load1 < 6` → punch"的链（本会话样本：`负载够低：load1=3 up=331`）。计数口径：**今日 22 发＝21 有效＋1 空枪**（第 18 发 `w400_go_run_dryfire.txt`：MAC 确实翻成 `Permissive`、采样腿 `up=881..894`，但 stage/`insmod` 没发生 ⇒ **无数据、不记账、重打**，§6.322①）。⇒ "等 `load1<6` 再打"这个起窗条件现在有 **21 个正样本**。
**新限定（原来没写）**：**punch 成功 ≠ 整条载荷会跑**。`post` 腿在部分 boot 里整程不到（§6.184/§6.199），而且"空枪"还有第四种成因＝**探测器自己误判**（135 发那次：`[SEN]` 那行包含翻转**之前**的行 ⇒ 读成"翻过"，后来把探测器改成 `SAWPER` 三段闩锁，§6.290）。所以判"这一发 punch 到底成没成"，要靠**同 boot 内的时刻序列**（谁先谁后）而不是某一个关键字是否存在。

**④ 「不落任何持久化」——仍然对，但要写明两个会被误认成残留的东西。**
(a) `/data/local/tmp/kd`（改道落点，`apk_data_file` 标签）在**基线态 shell 连 `mv`/`:` 截断都被拒**（同 owner 的 `shell_data_file` 能删 ⇒ 挡路的是标签不是 owner），只能在窗口内由 root 腿删；**现成免费路线**：收尾时 `ROOTPROBE=1 I_KNOW=1 bash kmod/w161_teardown.sh`，它会把"删之前/删之后"两份 `ls -lZ` 落盘（§6.329④）。
(b) `/data/adb/ksud` 会**被官方 Manager 自己重装**（#71），不是你留下的持久配置。⇒ 交付文档里"零持久化"这句的准确写法是：**零持久化配置**；上面两项各有来源，别算进"利用了但没清干净"。

**⑤ 一句给未来读者的定位**：本报告证明的是"**这个 boot 能拿到一次易失 root**"；把它变成"**官方 KernelSU Manager 零改动可用**"的那条链（自编译 `.ko` 装载、CFI 桩写回、名单与授权、以及"少一条参数就分钟级复位"这条**仍未解释**的墙）在 `kmod/DELIVERY.md` 第 0 节，账目编号到 **§6.330**、发数 22。
