# 下一步载荷设计: 假 fops 放在已知栈带里 + 一次指针写劫持 ashmem_misc.fops

(候选函数的取证在 `CFI-FOPS-TARGETS-20260927.md`, 由另一个搜索任务写)

## 1. 为什么是这条路(而不是先把 SELinux 打成 permissive)

* permissive **不等于 uid 0**; 目标要的是 root, 所以 SELinux 那一步只是中间站。
* 今天已经证明的两件事正好是这条路的两块地基:
  1. **已知地址 + 可控内容**: 泄漏出的 `S = ffffffc0325fbbd8`, 覆盖带 `[S-0x48, S-0x48+0x200)`
     里每个 8 字节都是我们填的 ⇒ 可以直接在带里摆一张**完整的假 `struct file_operations`**,
     每个槽填"同 CFI 类型的真函数地址" ⇒ 过 kCFI, 也不需要 ROP(SCS 也管不到, 因为我们
     不劫持返回地址, 只劫持**间接调用目标**)。
  2. **一次"指针形状"的写**: `*(C) = P` (形状(2), 配对的那笔 `*(P+8)=C` 落在我们自己的带里 ⇒ 无害)。
     ⇒ 正好用来把 `ashmem_misc.fops` 写成 `S+k`。
* 为什么必须过"假 fops"而不是直接把某个 fops 槽改成**代码地址**: 形状(2) 能写的值必须是
  **可读的核地址**(它同时被当作 `parent` 解引用 `parent+0x10`), 而 `.text` 地址虽然可读,
  但配对写会落到 `.text`(STRICT_KERNEL_RWX)⇒ 当场 panic。值必须是**可写地址** ⇒
  指向我们自己摆好的表 ⇒ 表里再放代码地址。这一步是**结构性的**, 不是偷懒。

## 2. 具体载荷(形状(2) + 带内假表)

```
C   = ashmem_misc + 0x10            (link 0x12a55960+0x10, .data 可写, miscdevice.fops)
P   = S + 0x0A0                     (带内偏移, 我们的假 fops 起点; 可写 ✓ 可读 ✓)
假 fops(在带里, 偏移 P+0x00 起):
   +0x00 owner          = 0                     ⇒ misc_open 的 fops_get() 跳过 try_module_get
   +0x08 llseek         = <noop/默认同类型>
   +0x10 read           = <同类型真函数>
   +0x14... 见 CFI-FOPS-TARGETS 的排名
   +0x40 unlocked_ioctl = ★ 目标函数(与 ashmem_ioctl 同 CFI 类型, 329 选 1)
   +0x58 open           = <同类型真函数, 用来把 filp->private_data 造成我们想要的形状>
注意: `misc_open` 会把 `file->private_data = &ashmem_misc`(真的 miscdevice), 不是 ashmem_area;
      任何依赖 `private_data` 类型的前提必须在取证时核掉。
```
配对写 `*(P+0x08) = C` 会落到假 fops 的 `llseek` 槽 ⇒ 无害(那一格我们本来就能自己填)。

## 3. 一发一命中的现实约束

* 一次 punch 只吃得**一发有效写**(打完 `FAKE_LOCK` 那块 uts 零洞就脏了, 第二发会走歪树)。
  ⇒ 每个 boot 只有一次写机会; `hammer` 只负责"在覆盖层还活着的时候把这发射出去"。
* 所以落点必须一次选对: 先做**克隆验证**(把假 fops 完全照抄真 `ashmem_fops` 的语义,
  打完后 `ioctl(/dev/ashmem)` 行为不变 ⇒ 证明劫持成立且不炸), 再换成攻击型槽。
  克隆验证还顺带证明: 我们的 `.owner=NULL` + `private_data` 假设成立。

## 4. 到 uid 0 的两条终局(取证的子任务在跑)

* **A(泄漏→写 cred)**: 若某个同类型函数能给出"内核任意读" ⇒ 读出自己的 `task_struct`,
  然后用**同一发指针写**把 `task->cred`/`task->real_cred` 写成 `&init_cred`(静态地址, 指针形状 ✓)
  ⇒ uid 0 + 全 cap, **不需要执行任何内核代码** ⇒ 最干净的临时 root。
* **B(直接写 cred 链)**: 若只能给出"内核任意写(值受限于指针形状)", 仍然可以用它把
  `cred->uid` 那一格写成指向 `init_cred` 的指针? ✗ 不是指针形状 ⇒ 走 A。
