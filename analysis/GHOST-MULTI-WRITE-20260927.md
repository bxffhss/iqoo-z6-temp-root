# 一发变 N 发：带内假 lock + 反向握手（真机 3 轮），以及 `*(C)=P` 对 .bss 不起作用这个悬案

## 0. 已经坐实的两件事（都是真机一手证据）

1. **"一个 boot 只能吃一发有效写"这个限制被解除了。**
   机制：`rt_mutex_dequeue/enqueue` 只把脏东西留在**假 lock** 里 ⇒ 只要假 lock 放在
   **我们每一轮都会重铺的覆盖带内**，下一轮的 `memset+copy_from_user` 就把它清回全 0 ⇒
   每次 punch 面对的都是一棵新树。实测：同一 boot 里
   `相0(泄漏 S) → 相1(第 2 发落地) → 相2(第 3 发落地) → 再连打 600 发不炸`，
   设备全程活着（`[DONE] 全流程结束(没炸)`，`getenforce` 仍 Enforcing）。
   ★ 旧结论"第二发必炸"的真正原因是**静态 uts 零洞打完就永久脏**，不是幽灵被消耗掉。

2. **载荷不能"铺好等人来打"，必须"临打前铺"。**
   覆盖层在浅区（距异常入口 SP 只有 0xE0..0x2E0 字节），W 所在 CPU 上任何 EL0 异常
   （250Hz 节拍 / IPI / 软中断）都会从同一个栈顶重新压帧 ⇒ 把这段重画掉。
   旧握手是 W 先铺好再置 `armed`，而 main 那时还在打日志（`say()` = open+write+**fsync**+close，
   ~200 µs）⇒ 真正被链走读到的是**节拍残渣**⇒ 链走照着垃圾指针解引用 ⇒ panic。
   这解释了 9/27 那两轮"第 1 发就炸"（我在 `say()` 前多插了一次 `read_cmdline` 基线，
   把首次 armed 变陈了）。
   ⇒ 改成**反向握手**：main 把所有杂活干完才置 `ready`；W 看到 ready 才铺、铺完立刻 `armed`；
   main 自旋（纯 load）到 armed 后**一个 syscall/日志都不插**直接 `sched_setattr`。
   改完之后：相1 第 2 发落地、相2 第 3 发落地（改之前是第 1 发就炸）。

## 1. 现在能确定的写原语形状（两条，同一次 erase）

`rb_erase` 的 `!left` 分支（设备同构建 `rb_erase@0x115446e0`，0x734..0x758）：
```
ldr  x10,[x0]          ; x10 = node->rb_parent_color   (= 我们铺的 w[0])
ands x8,  x10, #-4     ; parent = x10 & ~3
b.eq 7f0               ; parent==0 → root 分支（相0 用的就是这个：root->rb_node = right）
ldr  x11,[x8,#0x10]    ; ⚠️ 读 *(parent+0x10) ⇒ parent 必须**可解引用**
cmp  x11, x0 / b.eq    ; node 是不是 parent 的左孩子
str  x9, [x8,#8]       ; ★写① *(parent+8) = child(=node->rb_right)   ← 相2 实测可见
... rb_add_color(child,parent) ⇒ ★写② *(child) = (*(child)&3)|parent
```
⇒ 一次 punch 的两个写：
   - **写①：目的 = `w[0] + 8`，值 = `w[1]`**（真机证据：相2 里 `*(uts+0x18) = C` ✔ 看得见）
   - **写②：目的 = `w[1]`，值 = `w[0]`**（相1 里 `*(uts+0x10) = S-0x98` ✔ 看得见）
   - 相0 用的是 `w[0]∈{0..3}` 的 root 分支：`root->rb_node = w[1]` 且 enqueue 把 **S 写进 `tree->rb_leftmost`(=lock+0x10)** ⇒ 这就是 S 的来源。

## 2. （悬案已破 → 见 §4：区别不是写①/写②，而是**目的段别**；本节保留当日排查记录）

| 相 | C(=写②的目的) | 结果 |
|---|---|---|
| 相1 | `init_uts_ns+0x10` (.data) | ✅ sysname[12..19] = 我们给的指针 |
| 相2 | `saved_command_line` (.bss) | ❌ `cat /proc/cmdline` 一个字节都没变（601 发） |
| 相2 同时 | `*(P+8)` 的写①在 .data | ✅ sysname[20..27] = C 的地址 |

排查掉的假设：
- 地址算错？不是 —— `cmdline_proc_show@0x100be268` = `adrp x8,#0x12b27000; ldr x1,[x8,#0x600]`
  = `saved_command_line`，kallsyms 给 `ffffffc012b27600 B`，两份符号表一致。
- `.bss` 是 init 内存被释放？不是 —— `__bss_start=0x12b17a00 ≤ 0x12b27600 < __bss_stop=0x13245148`，
  而 `__init_end=0x12830000` 在更前面。
- SELinux 拦住读？不是 —— 基线本来就能读 192 字节。
- 而且**更早的 SHAPE=1 实验确实改写过 .bss**（`selinux_state=0x12b18000` 也在 .bss，那一轮 punch
  之后 main 死在 SELinux syscall 上 ⇒ 说明 .bss 写得动）。
⇒ 剩下的可能：(a) 写② 在 `*(child)` 目的为 .bss 时因**写序/合并**被写①遮蔽（同一函数里
   `str x9,[x8,#8]` 之后才 `ldr x11,[x9]`，若 `parent+8` 与 `child` 落在同一 cache 行/同页会被合并）；
   (b) 我们对 /proc/cmdline 的"读"其实来自另一处拷贝。
**未定，别再猜** —— 下一次开机用**有独立观察者的 .bss 目标**判决：`totalram_pages`
（`/proc/meminfo` 的 MemTotal 行是 shell 可读的十进制输出，改一下就能看见）。

## 3. 顺带钉死的两个内核内部事实（后面要用）

- `struct rt_mutex`（本机）：`wait_lock@0` / `waiters.rb_node@+8` / `waiters.rb_leftmost@+0x10`
  （由链走内联的 erase 反推：`rb_erase(node, tree+8)` 与 `str x0,[tree,#0x10]`）。
  ⇒ **假 lock 至少留 0x60 字节**；带内放 `S+0x60`（放 `S-0x48` 只有 0x48 字节，尾部会溢出到
  节点自己的字上 ⇒ 9/27 那次"第 2 发必炸"的另一个可能成因）。
- 链走里还有一对**值拷贝**（不是指针拷贝）：
  `ldr w10,[x19,#0xb4]; str w10,[x25,#0x40]` ⇒ `node->prio = task->prio`
  `ldr x11,[x19,#0x468]; str x11,[x25,#0x48]` ⇒ **`node+0x48 = *(task+0x468)`**
  ⇒ `x19 = waiter->task`（= 我们铺的 w[6]）、`x25 = node = task->pi_blocked_on`。
  ⇒ **这是一条"把任意可读地址 X 的 `X+0x468` 拷到 `node+0x48`"的读通道**，
  但前提 `node` 要落在**我们能读的地方** ⇒ 需要 `pi_blocked_on` 指进静态区，
  而 `pi_blocked_on` 属于"被打的那个 task" ⇒ 要 punch PID 1（init_task 是静态的）——
  shell 有没有 `sched_setattr(PID 1)` 的权限**未测**（DAC/SELinux 都要过）。
  ⚠️ 若可行：`node` 放 uts ⇒ `uname()` 就能读回 `*(X+0x468)` ⇒ 配合 X 可控 ⇒ **任意 8 字节读**。

## 4. ★★ 新规则(证据强度见下文)：**至今没有一次 `.bss` 落点被观察到生效**：**落点只能在 `.data`，`.bss` 会当场把机器打崩**（9/27 晚 6 轮真机）

把 6 轮的"落点段别 ↔ 结果"排在一起，规律是干净的二值：

| 相/模式 | 写目的地址所在段 | 结果 |
|---|---|---|
| 相0 泄漏(`root->rb_node=T`) | `init_uts_ns` **D**=.data | ✅ 落地，设备活着 |
| 相1(`c1uts`, `*(uts+0x10)=S-0x98`) | .data | ✅ 2~3 发就落地，活着 |
| 相1(`c1uts`, `*(uts+0x18)=C`) | .data | ✅ 3 发落地，活着 |
| 相2(`C=saved_command_line`) | **B**=.bss | ❌ 看不见 + 后来打崩 |
| 相2..7(`P=saved_command_line-8`) | .bss | ❌ 600 发全无变化 |
| `dst=avenrun`(`boot.py` 3 次独立开机) | .bss | ❌ **每次立刻重启** |

⇒ 结论（对以后所有载荷都是硬约束）：**这笔写的目的地址必须落在 `.data`/`.data..read_mostly`**；
落在 `.bss` 里就是同步异常（EL1 页权限错）⇒ 立刻 panic ⇒ 既看不见效果也丢掉整个 boot。
⚠ 用 **kallsyms 的类型字母**判段别：`D/d`=.data ✔可用；`B/b`=.bss ✗禁用；`R/r`=.rodata ✗。
⇒ **顺带作废两条旧路线**：
   - `selinux_state = 0xffffffc012b18000` 是 **`.bss`** ⇒ "把 enforcing 零写掉"这条路**根本不可用**
     （之前 SHAPE=1 那轮"写了但 main 死在 SELinux syscall"其实就是这个崩溃，不是副作用）。
   - `saved_command_line`(B) / `avenrun`(B) / `static_command_line`(b) 都在 .bss ⇒ **`/proc/cmdline`
     读通道整体作废**。
⇒ 好消息：`init_uts_ns`(D) / `modprobe_path`(D) / `kernel_config_data`(D) / `ashmem_misc`(D)
   这些 .data 里的东西都写得动，且写①/写②两条 store 对 .data 都实测有效。

## 5. 读通道现状（四条候选全部关闭，只剩"值拷贝"这一条没验）

| 候选 | 判据 | 结局 |
|---|---|---|
| `ctl_table.data` 改指 | `__register_sysctl_table` 会 `kzalloc+memcpy` 出**堆上的表副本** | ✗ 改静态模板无效，且堆地址要先有读能力（鸡生蛋） |
| `/proc/config.gz` | `ikconfig_read_current` 的源指针是 adrp+add 立刻算出的常量 | ✗ 没有可劫持变量 |
| 165 个 ioctl 把 `arg` 当内核指针 | `argptr_summary.txt` 全扫过，解引用都在 `copy_from_user` 之后 | ✗ |
| `/proc/cmdline` ← `saved_command_line` | 见 §5 | ✗ .bss |
| **链走里的值拷贝** | `str w10,[node,#0x40]` = `task->prio`；`str x11,[node,#0x48]` = `*(task+0x468)` | ⚠ **唯一没试的**：node 要落在 `.data` ⇒ 需要"被打的那个 task 的 `pi_blocked_on` 可写且地址已知" ⇒ 只有**静态 task**（init_task）满足 ⇒ **但 shell 无权改 PID 1 的调度**（实测 `renice -p 1` = EPERM ✗） ⇒ 这条路也基本关闭 |

⇒ **当前手里能确定可用的原语**：一 boot N 笔"**往 .data 里的 8 对齐地址写一个内核地址值**"
（每笔需要一个新幽灵 + 一次 S 泄漏；`cm57/boot.py` 负责在一列里连着打、炸了整列重来）。
⇒ 临时 root 还缺的就是**一个动态对象（自己的 task_struct / cred）的地址**。下一轮要解决的就这一件事。
   可试方向（按性价比）：① `root->rb_node = <.data 里某个真实 rb_root>` ⇒ 让 enqueue 把
   **真实内核节点的地址**写进我们能读的 .data 槽（`rb_add` 的 `*link = node` 与
   `leftmost` 更新写的都是"节点地址"，节点地址=内核堆地址 ⇒ **这就是不依赖任何读能力的堆泄露**）；
   ② `rb_next()` 的返回值会被写进 `tree->rb_leftmost`（`7e28: str x0,[tree,#0x10]`）——
   把 `tree` 指到 .data、`node->rb_right` 指到一个"真树根"，让 rb_next 沿着**真内存**走到一个真实节点，
   那个节点地址就成了我们的读值（前提是走链不炸：`*(X+0x10)` 得一直是合法指针）。

先行定义: 真正的资源单位是"幽灵"，不是 boot

三次"第 2 发有时落地有时炸"、以及"相2..7 各打 600 发一个字节都没动但也都不炸"
这两组互相矛盾的现象，只有一个解释全部说得通：

**`rt_mutex_adjust_pi()` 在成功走完一次链走之后会把 `task->pi_blocked_on` 清掉
⇒ 幽灵被**消耗**掉了。**

⇒ 于是：
- 第 1 发有效写落地之后，后面几百发的 `sched_setattr` 全都在
  `if (!waiter) return;` 那里**空转** ⇒ 既不会写任何东西，也**当然不会炸**
  （这就是"3608 发没事"的真实原因，不是"载荷很安全"）。
- 而"偶尔炸的第 2 发"是**唯一那一发真的又走进了链走**（幽灵还没被清干净/被别的
  路径重新置上），此时假 lock 已经被第 1 发涂脏 ⇒ 分支取决于脏树 ⇒ 抛硬币。
- 所以**"一 boot 一发"应更正为"一幽灵一发"**：想要第 N 笔有效写，就必须在它之前
  **重新造一个幽灵**（重跑一遍 lock C / lock PI / WAIT_REQUEUE_PI / CMP_REQUEUE_PI
  拿到 EDEADLK 的编排），并且重新泄漏一次 S（同一线程同一条 futex 路径 ⇒ S 的
  栈内偏移固定 `top-0x428`，实测三轮都是 `…bbd8` ⇒ 同一 boot 内 S 不变 ✔）。

#下一步的编排（按"一幽灵一发"重排，别再按"一 boot 一发"设计）

```
repeat N 次:  造幽灵(EDEADLK) → W 超时返回 → 反向握手铺带 → punch → 读判据
```
每轮都要重做 W 的 `futex(FUTEX_LOCK_PI)/WAIT_REQUEUE_PI` 状态机（现在的 `waiter_thread`
只在启动时造一次幽灵），这是**必须写的代码**，否则后面所有相都是空转。

## 7. 本轮还没回答的问题（下一轮直接测）

* `.bss` 落点到底可写不可写：判据实验（`avenrun` ↔ `/proc/loadavg` 第一列）**连续三轮
  都没跑到**，因为"第 2 发"本身就是抛硬币，而它按现在的编排注定只能发一次有效写。
  ⇒ 改成 §5 的编排之后，用一次 `punch(avenrun-8, S+0x100)` 直接判。
* 若 `.bss` 可写 ⇒ `saved_command_line` 读通道复活 ⇒ 任意读 ⇒ 走 `task->cred` 路线。
* 若 `.bss` 不可写 ⇒ 需要另找"静态可写 + 世界可读输出"的指针型变量（本轮已把
  `ctl_table`(堆拷贝)、`/proc/config.gz`(编译期常量)、ioctl(内核指针参数) 全部关闭）。
## 9. 每 boot 的"有效写额度"怎么数（实测 + 镜像坐实）

* **静态假 lock 一个 boot 只能用一次**（第 2 次调用就踩脏树 ⇒ panic）。
  真机证据：`stackreuse.py` 同一 boot 连跑 2 次"只做泄漏"的调用，第 2 次 rc=255 直接重启
  （唯一变量就是 uts+0x20 那块洞已经被上一次涂成 `rb_node=T / leftmost=S`）。
* ⇒ **每次调用换一块洞**。`init_uts_ns` 里镜像坐实的"全 0 且无重定位"的段（可直接当假 lock）：
  ```
  uts+0x010..0x040 (48B)   uts+0x050..0x080 (48B)
  uts+0x0a0..0x0c0 (32B)   uts+0x110..0x148 (56B)
  ```
  前两块落在 `sysname` 的 65 字节里 ⇒ `uname()` 直接读得回（现在的 `read_sysname` 只 dump 96 字节）;
  ⚠ 想多用后面两块，把 `read_sysname()` 扩成同时 dump `nodename/release/version/machine`
  （`struct utsname` 五个字段都是 65 字节，`uname()` 原样拷 ⇒ 一共 ~325 字节可读回）。
  ⇒ **一个 boot 的有效写额度 ≈ 4 笔（扩展到五个字段后 ≈ 6 笔）**，每笔一次进程调用。
* ⚠ **S 是否跨进程稳定 = 还没测到**（第 2 次调用在报 S 之前就炸了）。
  这是"三次棋读出堆指针"方案的前提：
  `p1 泄漏 S` → `p2 把 *(uts洞+0x10)=S 当 leftmost 预置` → `p3 让 rb_next 把真节点地址写进同一格`。
  若 S 跨调用不变 ⇒ 该方案成立（`boot.py` 的列式重跑已经备好）；
  若变 ⇒ 就得把三步压进**同一进程内的三颗幽灵**（要给 waiter 线程重排：每笔写前重新
  lock C / lock PI / WAIT_REQUEUE_PI / CMP_REQUEUE_PI 造幽灵 + 重新泄漏 S）。

## 10. 运行时 `init_uts_ns` 零段真表（`pr 0 peek`，不打 punch；镜像版是错的）

字段步长实测 **65 字节**，`sysname@uts+0x04 / nodename@+0x45 / release@+0x86 / version@+0xC7 / machine@+0x108`
（镜像里 release/version 是 `"5.4.281-perf"`/`"#1 SMP…"`，真机是 `"5.4.28"`+`"1#1 SMP PREEMPT …"`
⇒ **厂商在 boot 里改过 `name` ⇒ 任何"我记得这里是 0"都必须用 `peek` 现场量**）。

| 8 对齐零段 | 长度 | 能当假 lock? | 能当写目标 T? |
|---|---|---|---|
| `uts+0x0c .. 0x44` | 56B | ✅ 第 1 次调用用 `lk=0x20`（rb_node@0x28, leftmost@0x30 都在里面）| ✅ `T=0x08` |
| `uts+0x54 .. 0x84` | 48B | ✅ 第 2 次调用 `lk=0x54`（rb_node@0x5c, leftmost@0x64）| ✅ `T=0x6c`（`T+0x10=0x7c` 与 `T+0x40=0xac` 都是 0 ⇒ enqueue 下潜会安全终止）|
| `uts+0xa4 .. 0xc4` | 32B | ✅ 第 3 次 `lk=0xa4` | ❌ 没有满足 `T/T+8/T+0x10/T+0x40` 全 0 的 T |
| `uts+0xf4 .. 0x104` | 16B | ❌ 太短 | ❌ |
| `uts+0x114 .. 0x144` | 48B | ❌（要放 lock 得 rb_node@+8/leftmost@+0x10 都在内才行：`lk=0x114` 可以）| ⚠ `T=0x114` 的 `T+0x40=0x154` 在 uts_ns 尾部（user_ns 指针）⇒ 下潜会解引用真指针 ✗ |

⇒ **结论：一 boot 只有 ~2 个干净的"泄漏槽"**（lock+T 都要求连续 0x50 字节零）。
⇒ 所以"每次进程调用都要先泄漏一次 S"这条路最多 2 笔写/boot。
⇒ **真正的下一步是代码活：在一个进程里造多颗幽灵**（每笔写前重跑
`lock C → lock PI → WAIT_REQUEUE_PI → CMP_REQUEUE_PI(EDEADLK)` 的编排 + 一次泄漏 + 一次写），
这样一个 boot 能吃到 6~10 笔写，`rb_next` 三步棋才有空间。`waiter_thread` 现在只造一次幽灵，
要改成"每回合重造"，并且每回合的 S 都重新泄漏（同线程同路径 ⇒ S 恒定，见实测 `…bbd8 = 栈顶-0x428`）。

另记两个本轮踩到的工具坑：
* `adb push` 在 Git Bash 下会把远端 `/data/local/tmp/pr` 重写成 `K:/Git/data/local/tmp/pr` 并**谎报成功**
  ⇒ 一律用 python `subprocess` 直接调 adb（记忆里有条目，这次又中了一次）。
* 驱动脚本在设备 panic 期间必须 `wait-for-device` 再读日志，且**只能读设备端 `pr.log`**
  （adb stdout 在崩溃时丢尾巴；`/data` 跨重启保留 ⇒ 事后还能读到崩前最后一行）。

## 11. 对 §4 的**自我纠正**（别把那条当公理）

写完 §4 之后又跑了一轮，发现那条规律**证据不足**，两个混淆因素都没排除：
1. **`avenrun` 根本不是干净的判决目标**：`/proc/loadavg` 的三个数由内核**每 5 秒**用
   ` avenrun[i] = calc_load(avenrun[i], ...)` **重写** ⇒ 即使我们写中了，几秒内也会被抹掉
   ⇒ 那 3 轮"没变化 + 后来重启"**证明不了 .bss 不可写**，只能证明"这个判据选错了"。
2. **重启与"第二发踩在被消耗/被弄脏的状态上"混在一起**：同一批实验里
   `c1uts`（目的地 `.data`）在**同一个幽灵**下第 2、3 发都能落地 ⇒ 至少说明"第二发不一定炸"；
   而 avtest/dst 那几轮的炸，发生在 `.bss` 目的地**并且**是第二次 punch ⇒ 归因未定。
⇒ **目前能担保的只有**：目的地 = `init_uts_ns`(.data) 的写**反复可观察地落地**（≥5 次，含同幽灵的第 2/3 发）；
   目的地 = `.bss` 的写**至今 0 次可观察成功**（但判据/归因都没做干净，不能当"不可写"定论）。
⇒ **下一次的一元判决实验（照抄即可）**：
   目标 `saved_command_line`（.bss，**没人会重写它**，观察者 `/proc/cmdline` 即时可读）；
   写值 = 带外死帧地址（`S-0x98`）⇒ 落地则 `cat /proc/cmdline` 立刻变成那一小段字节；
   **punch 之后不要 sleep、立刻读**（`probe=/proc/cmdline` + 只打 1~3 发就判定）；
   并且这一发要是**该 boot 的第一发有效写**（前面不插任何别的 punch），排除脏状态。
   ⇒ 若这样还不出现 ⇒ `.bss` 不可写成立（并且 `/proc/cmdline` 读通道 + `selinux_state` 路线一起作废）；
   ⇒ 若出现 ⇒ §4 改回"只是判据/脏状态问题"，读通道复活，直接推进到"读 task→写 cred"。

## 12. "第二发为什么会炸"终于有机制解释了（不是 .bss，是脏 `rb_node`）

泄漏相(T=uts+0x08, lock=uts+0x20)之后，那块静态洞里剩下：
```
  uts+0x08 = 1        (rb_recolor 写进 T 的值)
  uts+0x18 = S        (enqueue 把 S 挂成 T 的左孩子)
  uts+0x28 = T        (lock->waiters.rb_node = T)      ← ★脏在这里
  uts+0x30 = S        (lock->waiters.rb_leftmost = S)
```
下一发如果**复用同一块洞**：`rt_mutex_dequeue` 摘完之后 `rt_mutex_enqueue` 会从
`rb_node = T` 下潜 ⇒ 比 key 读 `*(T+0x40)` ⇒ 再取 `T` 的左/右孩子 = `S` ⇒ 于是**拿我们这一轮
新铺的载荷当"树"继续下潜**，读到什么完全取决于上一轮的 `w[1]/w[2]` ⇒ 一旦哪个非 0 又被当指针
解引用 ⇒ panic。**这就是"第二发踩同一块洞必炸"的真实机理**，与段别无关。
反过来 `tgt=0x12b275f0` 那次第一发就炸，也是同一类错误：`.bss` 里我**没法预先保证
`T/T+0x08/T+0x10/T+0x40` 全 0**（peek 只 dump 到 uts+0x148，看不见 .bss 邻居），
enqueue 下潜时把一个随机非 0 值当节点解引用了 ⇒ 所以那一次**不能算".bss 不可写"的证据**。
⇒ **规则补一条**：写目标 T 必须满足 `T, T+0x08, T+0x10, T+0x40` 都可读且**语义上是 0/自己铺的字节**；
   只在 uts(镜像+peek 双重可见)里挑 T，别在看不见的段里挑。

## 13. 下一步的三发棋（都在 .data，都在"看得见的零段"里，已按上面的坑修正）

1. **p1 泄漏**：现状不变（lock=uts+0x20, T=uts+0x08）⇒ 得到 S，并且 `uts+0x30 = S` 顺手把
   "leftmost 已经等于节点"这个条件**在 hole1 上**做成了（但 hole1 的 rb_node 脏了，见 §12）。
2. **p2 预置**：换 **hole2**（`uts+0x54` 起，实测运行时全 0；T2=`uts+0x6c`）。载荷里
   `parent = (hole2+0x10)-8`、`child = S` ⇒ 写① 把 **S 写进 `hole2+0x10`（= rb_leftmost）**，
   写② 把 `hole2+0x08` 写进 `*(S)`（带内，无害，下一轮重铺清掉）。
   ⚠ p2 自己是从 hole2 的树里摘节点，此时 `hole2.rb_node = 0` ⇒ `parent≠NULL` 分支 ⇒ 干净。
3. **p3 读**：lock = hole2（此时 `rb_leftmost == S == 节点` ⇒ 命中 `*leftmost == node` 分支）
   ⇒ 内核执行 `rb_next(node)`，而我们把 `node->rb_right` 指向
   **`X = init_task + 0x6a8`**（`X+0x10` 正好是 `init_task.tasks.prev` = 最后创建的 task）
   ⇒ `rb_next` 沿 `*(X+0x10)` 走一跳，若 `*(task+0x10)`（flags/ptrace）为 0 就停 ⇒
   返回值 = **真实 task_struct 地址**，被 `str x0,[tree,#0x10]` 写回 **hole2+0x10** ⇒
   `uname()` 直接读回来。⚠ 若那一跳不为零就是走进野指针 ⇒ 当场 panic（可接受，重启再来；
   也可以换成别的 X：任何 `X+0x10` 是可读且 `*(X+0x10)+0x10 == 0` 的静态地址都行）。
4. 拿到 T0=task 之后：`dst = T0+0x848`（cred）`val = init_cred` 一笔、`dst = T0+0x840` 一笔 ⇒
   `commit_creds` 都不用，直接让内核下次取凭证时读到 init_cred；然后由**那个 task** execve。

## 14. 给 §12 补一条精确性更正

事后核 uptime：`tgt=0x12b275f0` 那一轮**设备并没有重启**（同一 boot 一直活到现在）。
所以那一轮既不是"panic"也不是"落地"，而是**日志在 punch #1 之后就再没有输出**
（进程没打印 ×  ⇒ 说明它没走到 ROUNDS_MAX 判定，怀疑卡在自旋/被 adb 超时杀掉 ⇒ 未定）。
⇒ 因此关于 `.bss` 的**唯一干净事实**是：4 次以 `.bss` 为目的地的尝试，
   **没有一次产生可观察效果**；而 3 次以 `init_uts_ns`(.data) 为目的地的尝试**每次都立刻可见**。
   "`.bss` 不可写/写了没意义"目前仍是**工作假设**，不是结论；§13 的三发棋不依赖它（全在 .data）。

## 15. 链已接成一发进程（相0泄漏→相1预置→相2读→相3/4提权），但**泄漏相本身有 ~25% 直接把机器打崩**

第一次真机跑链：`auto.py "hammer hijack shape2 ncopy5 maxr=5 nph=3 rounds=120"` ⇒
**日志停在 punch #1**，`androidboot.bootreason=HARD_RESET/PS_HOLD` ⇒ 泄漏相这一发就 panic 了。
统计今天一整天同一份泄漏载荷：`punch#1 命中` 至少 6 次，`punch#1 就炸` 3 次 ⇒ **约 75% 单发成功率**。
载荷/地址全都逐次核过是对的（同一段代码前几轮刚成功过），所以这不是配置错，是**时序**：
覆盖层在"铺好 → 被链走读到"之间被该 CPU 上的异常重画了一次 ⇒ 链走照垃圾指针解引用。

⇒ 下一次跑链之前先做这两件事（都不难）：
1. **把 W 钉到一个安静的小核**（`sched_setaffinity` 到 CPU0-2 里最闲的那个），
   main 钉到另一个核；少一个核上的 IPI/软中断就多一份存活率。
   再顺手 `mlockall`/关掉 W 的一切非必要 syscall。
2. **一次进程调用只保留必要相数**：先只跑到相2（拿 task 地址）就收工，
   确认读通了再把相3/4 接上；每次跑完整链失败就是白烧一个 boot（~70s），可以接受但别叠加风险。
3. 备选（如果 75% 存活率不够）：**把泄漏相换成"多份不同深度同时铺"**（现在 5 份是在同一窗口里平铺，
   改成用 5 个不同的 W 线程各自铺一份 + 谁先被读到谁算），这样单发命中率和存活率都上去。

## 16. 链第一次跑通前两相（真机，钉核 `wcpu=6 mcpu=0`，设备全程存活）

```
相0 泄漏  : punch#1 命中 ⇒ S = ffffffc034433bd8
相1 预置  : 载荷 C=S, P=uts+0x5c (=hole2+0x10-8) ⇒ 写① 把 S 写进 hole2 的 rb_leftmost
            punch#2 命中 ⇒ uname dump 的 0x60 处 = d83b4334c0ffffff = S ✓✓✓
回合切换  : × 造幽灵失败(30 次没拿到 EDEADLK) ⇒ 停在相2, 但 [DONE] 正常、设备活着
```
⇒ **同一进程内的"第二笔有效写"第一次成功落地**（此前只有"同一进程两相靠运气"的 c1uts 那次），
   而且是在钉核之后第一发就不再炸 ⇒ §15 的两条缓解措施方向是对的。
⇒ 现在唯一的阻塞点变成**"重造幽灵"**：第二轮的 `FUTEX_CMP_REQUEUE_PI` 不再返回 EDEADLK。
   ⚠ 我的 `make_ghost()` 只认 EDEADLK、把别的 errno 吞了 ⇒ **下次第一件事：把 ret/errno 打出来**
   （大概率是 EAGAIN/EINVAL/0(成功入队) 之类，一看就知道该改哪儿）。
   候选修正（按可能性排）：
   1. **每回合换一组全新的 futex 页**（C/PI/N 是启动时一次性分配的 3 页；第一轮在里面留下了
      `q.requeue`/`pi_state` 残渣 ⇒ 第二轮的 requeue 走的路径不再是"成环"）；
   2. O 线程每回合重新 `FUTEX_LOCK_PI(PI)` 并重新阻塞到 C（现在 O 只跑一次，它是否还在
      "阻塞于 C"这个前提可能已经破了 ⇒ 环不存在 ⇒ 当然没有 EDEADLK）★这个最可能；
   3. `nr_requeue=1/nr_wake=1` 的语义在第一轮之后要求 N 上有等待者 ⇒ W 确实睡了，但要确认
      W 睡的是**同一个 N**（W 每回合同一个 N ✗ 见修正 1）。
