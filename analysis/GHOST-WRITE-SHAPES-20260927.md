# rb_erase 三条路径 = 三种写形状(设备反汇编逐条坐实, 2026-09-27)

`rb_erase@0xffffffc0115446e0`(设备构建)。入参 `x0 = node`(= 悬空 waiter 在受害者内核栈里的
真实地址 S), `x1 = root = &lock->waiters.rb_node`。node 的三个字段完全由覆盖层载荷决定:
`pc = *(S+0x00)`, `right = *(S+0x08)`, `left = *(S+0x10)`。

```
0x…46e0  ldp x9,x11,[x0,#8]      ; x9=right, x11=left
0x…46e4  cbz x11 → 0x4734        ; 先走"left==NULL"一族
0x…4734  ldr x10,[x0]           ; x10 = pc
0x…4738  ands x8,x10,#-4        ; x8 = parent = pc & ~3
0x…473c  b.eq 0x47f0            ; parent==NULL 分支
0x…4740  ldr x11,[x8,#0x10]     ; parent->rb_left     ← 要求 parent 可读
0x…4744  cmp x11,x0 ; b.eq 0x4924
0x…474c  str x9,[x8,#8]         ; ★ *(parent+0x08) = right
0x…4750  cbz x9, 0x47f8
0x…4754  str x10,[x9]           ; ★ *(right) = pc
0x…4758  ret
---
0x…47f0  str x9,[x1]            ; ★ root->rb_node = right
0x…47f4  cbnz x9 → 0x4754       ; *(right) = pc  ⇒ 这就是"打 bootid/uts 那版"的零写
0x…47f8  tbz w10,#0 → 0x4920    ; node 黑 + child==NULL ⇒ **直接 ret, 不 rebalance**
0x…4920  ret
```

## 三条可用形状(比之前设计的约束弱得多)

**(1) parent≠NULL, right=0 ⇒ 干净任意"置零写", 没有树下潜!**
`pc = P(8 对齐, P 处可读)`, `right = 0`, `left = 0`
⇒ `*(P+0x08) = 0` 然后 `cbz→0x47f8` ⇒ 黑 ⇒ `ret`。**root->rb_node 未被改**(仍为 0)。
之后 [7] 的 enqueue 走"空树"分支: `root->rb_node = S`, `rb_leftmost = S`,
于是 [9] 出口 `leftmost != NULL` ⇒ 会 `wake_up_process(*(S+0x30))` ⇒ **task 字段必须给一个
安全的 task(实测取向: init_task; idle 任务 state=TASK_RUNNING 会在 `p->state & state` 处早退)**。

**(2) parent≠NULL, right=C≠0 ⇒ 两笔写: `*(P+0x08)=C` 且 `*(C)=P`。**
C 必须是**可写核地址**(可以就选我们的栈窗口 / uts 零洞, 让第二笔写进自己地盘 ⇒ 免费)。
⇒ 这是"把任意指针值写进任意对齐地址"的形状 ⇒ **劫持 ops/fops 指针**用这条。

**(3) parent=NULL, right=T ⇒ `root->rb_node = T` 且 `*(T)=pc`。**
这条会改 root ⇒ 紧接着 enqueue 从 T **下潜** ⇒ 才要求 T 的 +0x08/+0x10 邻居是 0
(上一轮打 `sysctl_bootid` 就是被这条约束炸的: bootid[8..15] 是随机 ASCII ⇒ 被当节点指针解引用)。
**⇒ 能用 (1)/(2) 就别用 (3)。**

## 由此得到的下一步载荷(M2, 形状 (1)/(2))

已知的静态可写目标(链接期地址, 加本次开机的 slide):
- `selinux_state = 0x12b18000`(**DISABLE=y ⇒ enforcing 在 state+1**)
  ⇒ 形状(1): `P = state - 8` ⇒ **`*(state+0) = 0`** ⇒ enforcing 归零 ⇒ `getenforce` 立刻变 Permissive
  (**这既是第一个"有语义的内核写", 又是肉眼可验证的判据, 且重启即恢复**)
- `modprobe_path`(形如 `/system/bin/modprobe`, .data 里可读回? 不读也行)
  ⇒ 形状(2) 写指针不如形状(1) 清零有用; root 化路线优先做"能读回的内核内存"通道(见下)。
- `init_uts_ns = 0x1292d350`: sysname@+0x04 "Linux", 后面 +0x09..+0x44 是**运行时恒 0 的洞**
  ⇒ 当假 rt_mutex(L=+0x20)/假 task/泄漏槽用, 且 `uname()` 原样返回 65 字节 ⇒ **可读回**
  ⇒ 一旦 `*(T+8)=S` 落地, 我们就拿到受害者内核栈的真实地址 ⇒ 后续所有自引用指针可算。

## 还没结掉的一件事(正在跑)

幽灵是否真的被链走读到 = 用"整窗填 120 / 半窗下毒 119"的**单比特判据**二分 prio 字下标
(`cm57/bisect2.py`)。这一步的教训(已写进 `GHOST-PUNCH-BISECT-VOID-20260927.md`):
探针必须让"两种结局都只有唯一解释" —— 之前把非探针区填 0 会把 `lock` 一起毒掉,
于是"炸"不再等价于"prio 未命中"。


## 追加(同日晚些, 真机): 幽灵存在性 + 覆盖性 **已证实**

用"单比特判据"跑(`cm57/bisect2.py`, 基础填 120=真 prio⇒[3] 早退⇒存活; 探针区填 119⇒继续走
⇒`lock` 读到 119 这种无效指针⇒必炸):
- 全区下毒 [0,64) ⇒ **炸** ⇒ 链走确实读到了我们喷的字节 ⇒ **幽灵存在 + 覆盖层够得到它**
- 下毒 [0,32) ⇒ **炸** ⇒ prio 字在窗口前半(二分继续收窄中)

⇒ 本节"形状(1)"的载荷(`pc = selinux_state-8, right = 0`)在 prio 字下标定好后就是可打的:
`*(selinux_state+0)=0` ⇒ `getenforce` 立刻 Permissive(肉眼可验, 重启即恢复)。
打之前先确认: `task` 字段 = init_task(idle, state=TASK_RUNNING ⇒ wake_up_process 早退),
`lock` = init_uts_ns 零洞(恒 0, 可 uname 读回), prio 填 119(不等 120 ⇒ 放行到 [7])。

## 4. 【同夜补充】这套原语到底能写什么值 —— 三条形状 + 一条硬边界

由 `rb_erase@0x115446e0` 的反汇编逐条列出（node = 我们的 S，`child` = rb_right 或 rb_left）：

| 形状 | 载荷写法 | 落地效果 | 前提 |
|---|---|---|---|
| (1) 纯零写 | `pc=dst-8`, `right=0`, `left=0` | `*(dst)=0`，**没有第二笔**（0x750 `cbz x9` 跳过） | `*(dst+8)!=S` |
| (2) 指针写 | `pc=dst-8`, `right=V`, `left=0` | `*(dst)=V` **且** `*(V)=pc` | **V 必须可写** |
| (3) 小整数写 | `pc∈{0,1,2,3}`, `right=T`, `left=0` | `*root=T`（假 lock 在带内 ⇒ 无害）**且** `*(T)=pc` | 走 parent==NULL 分支 ⇒ 目的只能 4 对齐 |
| (4) ★新发现 | `right=0`, `left=T`, `pc=F` | **0x764 `str x9,[x11]` = `*(T)=F`（F 可以任意！）** | 但随后 ② 会写 `*(F&~3+8)` |

⇒ **硬边界（把"函数指针劫持"这条经典路直接封死）**：形状(4) 虽然能把任意值写进任意可写目的，
但它的第二笔一定会去写 **`值+8`** 那一格 ⇒ 只要"值"是 `.text` 里的函数地址，那一笔就是
权限错误 ⇒ oops。**结论：本原语能装进任意对齐槽位的"值"只有 0 / 1..3 / 可写地址三类。**

⇒ 唯一绕开这条边界的做法：**不通过写去放函数指针，而是让内核去读我们自己铺的表** ——
把某个**静态链表头**改指向带内载荷，于是内核把带内字节当结构体用，其中的"函数指针槽"
由 `rt_sigreturn` 覆盖层直接铺成真实函数地址（不经写原语 ⇒ 不受上面边界约束）。
本机可用的静态链表头样例（一手 kallsyms）：

- `formats @ 0xffffffc0129ac020`（type d = **.data 可写**）= `fs/binfmts.c` 的 `LIST_HEAD(formats)`
  ⇒ `execve` 走 `search_binary_handler` 会 `list_for_each_entry` 遍历它，并调用
  `entry->load_binary(bprm)` ⇒ 我们把 `formats.next` 指向带内，伪一个 `struct linux_binfmt`，
  `load_binary` 槽填**与 `int(*)(struct linux_binprm *)` 同 KCFI 类型**的真实函数。
  ⇒ 剩下的问题是"同类型函数里有没有能推进提权的"（`load_script` 之类只能做普通 exec ⇒ 目前**未找到**
  直接给 root 的同类型候选；`analysis/cfi_type_tables.txt` 是按类型哈希分组的，需按
  `load_elf_binary` 所在那一组整组过一遍）。

⇒ 与之对照：`security_hook_heads`（清空 ⇒ 炸）、`selinux_state`（改一个字节 ⇒ 顺带改坏邻居 ⇒ 炸）
都不适用；**"改数据结构的指针、让内核自己走我们铺的表"是目前唯一还没被真机否掉的机制类**。

## 5. 顺带把"静态表 → 带内伪结构"这条路能调用的函数集查清了（一手 KCFI 表）

`analysis/cfi_type_tables.txt:13776` —— `linux_binfmt.load_binary` 的类型组（本机 10 个成员）：

```
load_misc_binary | remove_arg_zero | prepare_binprm | search_binary_handler |
load_script | load_elf_binary | flush_old_exec | load_elf_binary.91 |
selinux_bprm_set_creds | cap_bprm_set_creds
```

⇒ 若把 `formats@0xffffffc0129ac020`(.data 可写) 的 `next` 指进带内，`execve` 就会调用我们铺的
这 10 个之一（拿 `bprm` 当参数）。逐个判定后**没有一个是直接给 cred 的**：
`flush_old_exec` 会 `commit_creds(bprm->cred)`，但 `bprm->cred` 里的 euid 只有在被执行文件
**root 属主 + setuid 位**时才会变 0 ⇒ 而 Android user 版**没有 setuid-root 可执行文件**（改用
file capabilities），而 `setxattr(security.capability)` 又需要 `CAP_SETFCAP` ✗。
⇒ 结论：这条路本身不直接产 root；它的价值是"**能带着 `bprm` 进入这 10 个函数**"，可作为后续
组合件（例如与别的静态表/类型组配合），但目前没有可闭环的用法。
