# 对 `IOCTL-CFI-165-AUDIT-20260926.md` 的一手复核与重新定性 (2026-09-26)

子代理的机械抽取是**准的**（我逐条抽验的指令都对得上），但它对"什么算原语"的排序**错了**，
而且错得很关键。本文给出复核证据 + 这条线真正的攻击配方。

## 1. 先纠正一个攻击架构层面的误解（省掉一个不必要的泄露需求）

要"顶掉 f_op"，**不需要伪造 `file_operations` 表**，也就不需要知道自己 ashmem 页的物理地址：
把 `file->f_op` 这 8 字节写成**某个真实驱动的 `.rodata` 里的 fops 静态地址**即可
（`&watchdog_fops`、`&acc_fops`…）。CFI 天然满足（目标本来就是合法函数、本来就在它自己的表里），
`file` 仍是我们自己的 ashmem `struct file`，只有 `private_data` 被对方按自己的类型解释。
⇒ **一次"8 字节 + 值 = 一个已知的内核静态地址"的写，就把 165 个别的驱动的 ioctl 全部变成可选入口。**
这是 [[ashmem-fop-write-channel]] 之前一直没点破的地方，也把 KASLR 的依赖降为"只要 slide"。

## 2. 我们自己能往 `private_data` 里放什么（决定"假对象"的可控范围）

一手确认（`ashmem_ioctl`，也是子代理报告的 W1）：
- `ASHMEM_SET_NAME` → 把用户串拷进 **`pd + 0xb` 起的 name 区**（`ASHMEM_NAME_LEN=256` ⇒ 覆盖 `0xb..0x10a`）；
  前置检查只有 `asma->file (pd+0x120) == NULL`。
- `ASHMEM_SET_SIZE` → `str x20,[x19,#0x128]`（8 字节任意标量）
- `ASHMEM_SET_PROT_MASK` → `str x20,[x19,#0x130]`

⇒ **可控字节 = `pd+0x0b .. pd+0x10a`（约 249 个，可放指针对）、外加 `pd+0x128`、`pd+0x130` 两个 8 字节标量。**
**`pd+0x10a` 之后一律不可控**（那是别人的对象/别的数据）。
这一条就是判"某个候选能不能用"的唯一标尺：**受害 handler 读指针的偏移必须落在可控区里。**

## 3. 逐条复核子代理的候选

### 3.1 `acc_ioctl @0xffffffc010ce507c` —— 机制为真，但"泄露"要分档
一手指令（`vmlinux_full.asm`）：
```
0ce5090: f9406c08   ldr  x8, [x0, #0xd8]      ← x8 = file->private_data (⇒ private_data = +0xd8)
0ce50c4: 91042114   add  x20, x8, #0x108      ← cmd 分支 1
0ce50c8: b5000254   cbnz x20, 0ce5110         ← 这个"守卫"是废的：x20 是算出来的地址，必非 0
0ce50f0: 91082114   add  x20, x8, #0x208      ← 其余分支 0x308/0x408/0x508/0x608 同形
0ce50e8: b9871100   ldrsw x0, [x8, #0x710]    ← 直接当 syscall 返回值
0ce5170: b9870d00   ldrsw x0, [x8, #0x70c]
0ce5110: aa1403e0   mov  x0, x20
0ce5114: 97ce9f5b   bl   <strlen>             ← 长度 = 内核里第一个 NUL 之前，无上界
0ce5118: 31000408   adds w8, w0, #0x1
0ce5130: 97e23421   bl   <__check_object_size> ← HARDENED_USERCOPY 的闸在这里
0ce5134: aa1303e0   mov  x0, x19 (arg)  / 0ce5138: aa1403e1 mov x1, x20 → 随后 copy_to_user
```
分档结论：
* **`pd+0x108` 那一档不是泄露** —— 0x108 落进我们的 name 区（`0xb..0x10a`），
  `strlen` 会在**我们自己写的串**上停下，`copy_to_user` 拷回去的还是我们自己的字节。
* **`0x208/0x308/0x408/0x508/0x608` 是真 OOB 堆读**（越出 ashmem_area 到相邻 slab 对象），
  但**过 `__check_object_size`**：`CONFIG_HARDENED_USERCOPY=y` ⇒ 越过对象边界会被拒并 `BUG`，
  而本机**没有任何内核日志通道**（[[device-observability-limits]]）⇒ 表现直接是重启。
  可用但要付一次重启，且泄露量被限制在"bucket 内"。
* **`ldrsw x0,[x8,#0x70c] / [x8,#0x710]` 这一对才是好东西**：4 字节内核堆值**直接作为 ioctl 返回值**
  回到用户态，**无 copy、无 `__check_object_size`、无锁、无指针解引用** ⇒
  安全、可重复、每次 4 字节的跨对象堆读。这是目前整个审计里唯一"低风险原语"。
  （注意 `ldrsw` 是符号扩展 ⇒ 拿到的值有正负号，解析时按 int32 处理。）

### 3.2 `watchdog_ioctl @0xffffffc010df3638` —— 子代理把它排进 Class W 是错的
一手指令：
```
df3658: f9406c14   ldr  x20, [x0, #0xd8]      ← private_data
df3664: 9110c293   add  x19, x20, #0x430
df366c: 941d8f8b   bl   <mutex_lock>          ← 先锁 pd+0x430（不可控区！）
df3670: f9421694   ldr  x20, [x20, #0x428]    ← 把 pd+0x428 当 struct watchdog_device*
df3678: f9401288   ldr  x8,  [x20, #0x20]     ← 二级解引用
df367c: f9402516   ldr  x22, [x8,  #0x48]     ← 取出一个函数指针
df36a8: d63f02c0   blr  x22                   ← CFI 校验后的间接调用
```
`0x428`/`0x430` 都**远在可控区（≤0x10a）之外** ⇒ 这条路径第一步就去锁/读一块我们支配不了的内存，
结果是 oops/死锁而不是原语。**形态上它其实是"两级指针追踪 + 间接调用"（最强大的形状），
但在这台机器上不可用**，因为可控区太靠前、太小。⇒ 从候选里划掉。

### 3.3 子代理的其余 Class W（ashmem 自身、`binder_ioctl` 的 `str w8,[x21,#0x178]`、`sg_ioctl`、
`fastrac_device_ioctl` 小值写）**全部是"写进我们自己对象的固定偏移"**：
- ashmem 那三条是我们本来就被允许做的（SET_NAME/SIZE/PROT），零新增能力；
- `binder_ioctl` 写 `pd+0x178`、`fastrpc` 写 `+0x90/+0xa4` 等：`0x178` 在可控区之外，
  且写进一个我们自己根本不该有的字段 ⇒ 只是把我们的对象踩坏，**不构成对"别处"的写**。

## 4. 下一轮该按什么标尺筛（这才是真正的"写原语"类）

要找的是满足**全部**三条的 handler：
1. 入口**不**先解引用/加锁 `pd + k`（`k > 0x10a`）的字段；
2. 从 `pd + k`（`0x0b ≤ k ≤ 0x102`，即**我们能用 SET_NAME 放的字节**）取一个 8 字节"指针"；
3. 对该指针做 `str`/`stp`/`copy_to_user` ⇒ **write-what-where**（值来自 `arg`，目的地址来自我们写的字节）。

另外要留意的次优形状：`get_user(..., pd 派生指针)` = 可控地址**写内核堆**的反向（把内核值搬到我们指定处），
以及任何"把 `pd+k` 当 `struct xxx *` 后调 `xxx->ops->f(...)`" —— 后者是 CFI 约束下的间接调用跳板，
但受 §3.2 同样的"可控区太小"限制。

建议做法：把 `cfi_type_tables.txt` 里那 165 个函数批量抽体，只保留
"**第一个非 arg 派生的 load 落在 `pd + 0x0..0x10a`，且该 load 结果被用作 store 基址**"的函数，
其余直接扔。这条筛选可以在 `vmlinux_full.asm` 上纯离线做完，零风险。

## 5. 顺带钉死的一个偏移

`acc_ioctl`、`watchdog_ioctl`、`ashmem_ioctl` 都用 `ldr x?, [x0, #0xd8]` 从 `struct file *` 取
`private_data` ⇒ **`file->private_data = +0xd8`**（与 `file->f_op = +0x28` 并列，见
[[CFI-SAMETYPE-TABLES-20260926]] §4.1b；两者都来自一手指令，不是 `.rs` 推导）。
⚠ 仍然是"同 config 的离线镜像（gbef221370b4）里量到"，**没在真机 build 上重测过**。

## 6. 第二轮严格重筛（`IOCTL-CFI-WWTRIAge-20260926.md`）的复核结果

第二轮按 C1/C2/C3 重筛，判出 **165 个里只有 2 个满足全部三条**。这两个我逐条读了原文指令，
**都成立**，但第二轮的摘要**低估了前置条件**，修正如下。

### 6.1 `i2cdev_ioctl @0xffffffc010188280` —— 干净，但值被钳到 ≤0x3ff
```
01882b4: f9406c14   ldr  x20, [x0, #0xd8]     ; x20 = private_data
01882d0: f10ffe7f   cmp  x19, #0x3ff          ; ★值上限 1023★（第二轮写成 "arg<2^31"，不准）
01882d4: 54000648   b.hi 0x18839c             ;   >0x3ff → 拒
01882d8: f102027f   cmp  x19, #0x80
01882dc: 54000063   b.lo 0x1882e8             ;   arg<0x80 直接过（不碰 pd+0）
01882e0: 79400288   ldrh w8, [x20]            ;   arg∈[0x80,0x3ff] 才读 pd+0（只是读，不是解引用）
01882ec: (cmd 必须 == 0x703 = I2C_SLAVE)
0188324: f9400e88   ldr  x8, [x20, #0x18]     ; ★基址 = *(pd+0x18)，在可控窗口内★
018832c: b9006d13   str  w19, [x8, #0x6c]     ; ★4 字节写，值 ≤0x3ff（高 2 字节必为 0）★
```
⇒ 原语 = **`*(u32*)(X + 0x6c) = V`，X = 我们放在 `pd+0x18` 的任意内核 VA，V ∈ [0,0x3ff]。**
C1 全程只在 `pd+0x0`(读) / `pd+0x18`(取指针) 上活动 ⇒ 通过。
副作用：写 4 字节会把 `X+0x6e..0x71` 一起清 0（对"关掉一个 flag/计数"很有用，对"精确改 1 字节"是负担）。

### 6.2 `snd_compr_ioctl @0xffffffc010fa5a8c` —— 最强，但有**两道必须绕过的闸**
```
0fa5abc: f94016e8   ldr  x8, [x23, #0x28]     ; 取"指针"
0fa5acc: 910f2100   add  x0, x8, #0x3c8       ; ★闸 1★
0fa5ad0: 9416c672   bl   <mutex_lock>         ;   进任何分支之前先去锁 *(pd+0x28)+0x3c8
0fa5afc: f94012e8   ldr  x8, [x23, #0x20]
0fa5b00: b9400108   ldr  w8, [x8]             ; ★闸 2★ 二级解引用
0fa5b04: 350022a8   cbnz w8, 0xfa5f58         ;   **(pd+0x20) 必须 == 0 才继续
0fa5b08: 52801081   mov  w1, #0x84            ; memdup_user(arg, 132) → 用户数据进内核新对象
0fa5cd0: f94012e8   ldr  x8, [x23, #0x20]
0fa5cd8: b9000109   str  w9, [x8]             ; ★*(u32*)X = 用户可控值★
```
全函数对 `pd` 的访问偏移只有 **0x18 / 0x20 / 0x28 / 0xb0 / 0xb4** ⇒ C1 确实干净（第二轮这点没错）。
但两道闸必须在"我们填进 name 区的那 8 个字节"里同时满足：
`*(pd+0x28) = 某个可写的内核全局 - 0x3c8`（`mutex_lock` 会**改写**它；指向一个我们不介意被踩的
零值全局即可通过，但 `mutex_unlock` 之后还会写第二下），以及 `*(pd+0x20) = 某个当前为 0 的 u32 的内核 VA`。
⇒ 原语 = **`*(u32*)X = V`（V 直接来自用户 132 字节结构），但每次 ioctl 会顺带把一个真实全局当锁来踩。**
"值完全用户可控"这一条比 i2cdev 强，"要多踩一个全局"这一条比 i2cdev 脏。

**两条共同的前提（第二轮没写）**：往 `pd+0x18`/`+0x20`/`+0x28` 里放的必须是一个**合法内核 VA**
⇒ 必须先有 KASLR slide（[[device-observability-limits]]：只有 shell 自采样 perf 能拿，且每次开机变）。
一旦有 slide，能放的地址就包括整个 kernel image（含 `.data`/`.bss`）——
**这已经把"改 cred 里的某个字段"变成了可达目标**，只是每次 ioctl 只能写 4 字节且要小心落点。

### 6.3 定性总结（更新这条线的账）
- **非栈写通道的下游不再空了**：`f_op = &i2cdev_fops` + `I2C_SLAVE` 就是 4 字节受控写；
  但**先决条件仍是那次"8 字节写 `struct file` 的 `f_op`（+0x28）"** —— 还是得由 [[binder-uaf-2026]] 供。
- 换句话说：**现在的瓶颈没变，但"有了写之后能干什么"第一次有了肯定答案。**
