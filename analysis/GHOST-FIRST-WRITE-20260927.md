# ★ 第一笔内核写落地 + 栈地址泄漏(真机, 2026-09-27, 设备没重启)

## 0. 结果

`cm57/pr.c` 的 `hammer shape2` 一发命中(`tries=1 hit=1`), 之后进程跑到 `[DONE]`,
`uptime 351s` ⇒ **设备活着**, 而 `uname()` 读回的 `init_uts_ns.name.sysname` 变了:

```
4c696e75 01000000 00000000 00000000 00000000 d8bb5f32c0ffffff 0000000000000000
   "Linu"  ^^^^^^^^ 写进去的 1                                              = S(第一份)
58d352bad3ffffff d8bb5f32c0ffffff 00...0000 6c6f63616c686f7374("localhost")
   ^^^^^^^^^^^^^^ = T(root->rb_node)        ^^^^^^^^^^^^^^^^^^ = S(第二份=rb_leftmost)
```

三个量全部对得上静态模型:

| 量 | 预测 | 实测 |
|---|---|---|
| slide | 由正对照给出 | `13a7c00000` |
| T = LK_UTS+slide+0x08 | `ffffffd3ba52d358` | **一致** |
| S(悬空 waiter 真身) | — | `ffffffc0325fbbd8` |
| E = S+0x298 | 栈顶 `ffffffc0325fc000` − `0x190` | **自洽**(pt_regs 0x128 + 入口开销 0x68) |

⇒ **GhostLock 在这台 5.4.281-qgki 上做出了一次"任意 8 字节对齐写 + 内核栈地址泄漏"。**
覆盖层在被链走读到的那一瞬间确实是活的, 深度模型(窗口字节 i = waiter 字节 j + 0x48,
prio 在窗口第 17 字, waiter 起点第 9 字)是**对的**。

## 1. 为什么前几发都炸、这一发不炸: `rb_insert_color` 的"父节点颜色"地雷

链走 [7] 是 `rt_mutex_dequeue` → `rb_erase` → **`rt_mutex_enqueue`** → **`rb_insert_color`**。
`rt_mutex_enqueue` 把新节点涂成 **RED**(Linux 里 `RED ⇔ __rb_parent_color 的 bit0 == 0`),
然后 `rb_insert_color` 第一件事是看**父节点**的颜色:

```c
	while (parent && rb_is_red(parent)) {        /* rb_is_red(x) = !(*(u32-ish)x & 1) */
		gparent = rb_parent(parent);      ← 读 *(parent) & ~3
```

* **SHAPE=0**(`pc=0`, `right=T`): erase 走 parent==NULL 分支 ⇒ `root->rb_node = T` 且 `*(T)=pc=0`。
  接着 enqueue 从 `root=T` 下潜 ⇒ 新节点的 parent = T; 而我们刚把 `*(T)` 写成 **0** ⇒
  `rb_is_red(T)` 为真 ⇒ 进循环 ⇒ `gparent = *(T)&~3 = 0` ⇒ **解引用 NULL ⇒ panic**
  ⇒ 这就是"每一发都死在第 1 发"的真实原因, 和覆盖层活不活**无关**。
* **SHAPE=1**(`pc=selinux_state-8`, `right=0`): erase 干净, `*(selinux_state)=0` 也确实写了,
  但那一笔把 `enforcing/disabled/policy_inited/...` 一整 qword 全清了 ⇒
  **punch 自己返回了**, 死在 main 下一个碰 SELinux 的 syscall(`openat /sys/fs/selinux/enforce`)。
  旁证: 同形状的 `benign`(prio 命中 ⇒ 不走链走)能连过 #1 #2 两发, 说明链走本身跑完了。
* **SHAPE=2**(本次): 把写进 T 的值取成 **1** ⇒ `*(T)&1 = 1` ⇒ 父节点是**黑的** ⇒
  `rb_insert_color` 的循环一次都不进, 只把 S 自己涂黑(写受害者栈, 无害) ⇒ **全程安全**。
  并且 enqueue 走"空树/右槽为 0"就终止 ⇒ 不更新 `rb_leftmost`... 实测 `rb_leftmost=S`
  也写了(在 sysname[44]) ⇒ [9] 出口仍然干净(`[x8,#0x38]` 读回的就是我们给的 FAKE_LOCK ✓)。

## 2. 现在手里有什么

1. **可控的内核栈数据区**: 绝对地址已知(`S`), 可控长度 0x200(窗口 `[S-0x48, S-0x48+0x200)`),
   由受害者线程的 `rt_sigreturn` fpsimd 回存写入; 只要"铺→被读"的间隔在 µs 量级就是活的。
2. **两形状写原语**(都经设备反汇编逐条坐实):
   * 形状(3)+`pc∈{0..3}`: 往**任意对齐地址 C** 写 `pc`(即只能写 0/1/2/3), 顺带 `root->rb_node=C`;
   * 形状(1) `pc=C-8, right=0`: 往 **任意对齐地址 C** 写 **0**, 不碰 root, 之后 enqueue 只污染
     `FAKE_LOCK` 那一块(uts 零洞) ⇒ 干净零写;
   * 形状(2) `pc=P(可读写核地址), right=C`: `*(C)=P` 且 `*(P+8)=C` ⇒ **写指针值**。
3 **KASLR slide** 每次开机由正对照自动求出(`cm57/pctl.py` + `analysis/slide_pc.py`)。
4. 一次 punch 只能吃**一发有效写**(打完假树就脏了), 且 `hammer` 的命中判据是 `uname()`/`enforce` 变化。

## 3. 下一步(按"临时 root, 不落地持久化")

地雷清单(每条都是本轮踩过的):
* 写进目标的值会影响**后续 enqueue/insert_color 的分支** ⇒ 选值要保证父是黑的、槽是 0 的;
* 一次清一整个 qword 会顺手清掉邻居字段(selinux_state 那次就是) ⇒ 落点要挑"整字都该是 0"的位置;
* `hammer` 里 main 每发之后都会 `uname()`+读 enforce ⇒ 如果写坏了 SELinux 相关全局, 死的是 main。

候选路线(择一, 都需要"写指针值"= 形状(2)):
* **A. 提权靠 `selinux_state.enforcing`**: 用形状(1) 零写**只含 enforcing 的那个对齐字**
  (须先用 `pahole`/反汇编确认它和哪些 bool 同字, 避免 SHAPE=1 的老坑);
* **B. `file->f_op` → 假 fops**: 假 fops 就摆在 `[S-0x48, S+0x188)` 里(绝对地址已知!),
  每个槽都填 CFI 同类型表里的真函数(`analysis/cfi_type_tables.txt` 14,257 张),
  再用形状(2) 把一个活 `struct file` 的 `f_op` 改指过去 ⇒ 进内核执行任意"同类型"函数
  ⇒ `commit_creds(prepare_kernel_cred(0))` 型提权;
* **C. `modprobe_path`**: 要写 ASCII, 形状(2)/形状(1) 都不便(需要"字符串值"),
  更稳的做法是先把 `modprobe_path` 那个字**零写**成 ""(空路径)再看行为, 或改用 B。
