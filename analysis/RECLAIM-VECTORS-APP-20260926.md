# app 域的 kmalloc 回收载体实测 (P48, 2026-09-26)

## 0. 为什么这一步是承重的

本轮先测出 **`binder_free_transaction@0xffffffc010f5eff8` 的释放走 `kfree`**（函数体里 3 处
`bl <kfree>`，**没有任何 `kmem_cache_free`**）：
```
f5f220: 97d79e60  bl 0xffffffc010546ba0 <kfree>
f5f24c: 97d79e55  bl 0xffffffc010546ba0 <kfree>
f5f288: 97d79e46  bl 0xffffffc010546ba0 <kfree>
```
⇒ 这台机器的 `struct binder_transaction` **不在专用 `binder_transaction_cachep` 里**
（上游 5.4 是 `KMEM_CACHE(binder_transaction,0)`，本 vendor 构建显然改成了 kmalloc）。
`sizeof≈0xF0` ⇒ 落 **kmalloc-256**。

这件事直接决定 binder UAF 的可行性等级：
* 专用 cache ⇒ 只有 binder 自己能在那个 cache 里分配，**回收几乎没法用可控内容填**；
* kmalloc-256 ⇒ **任何 app 可触发的、大小落在 (192,256] 的通用内核分配都能抢这个槽**。

## 1. 实测：app 域确实有"内容可控 + 尺寸可控 + 生命周期可控"的 kmalloc 载体

`jni_p48.c`（`u:r:untrusted_app_27`，uid=10172，SELinux enforcing，无 root），全部一手 errno：

| 载体 | 结果 | 为什么能当回收用 |
|---|---|---|
| **`fsetxattr(fd,"user.poc",val,L)`** | **L=8/40/100/200/240/256/1024 全部 SET=ok**，`fgetxattr` 回读**逐字节一致** | 5.4 `fs/xattr.c` 的 `do_setxattr()` 只在 `L > sizeof(kern_val)=64` 时才 `kmalloc(L)` ⇒ **L∈(192,256]（如 240）就是 kmalloc-256，内容 100% 我们给，syscall 结束即 `kfree`**（填刚被 UAF 释放的槽） |
| `user.<250 字节长名>` | ret=0 | 名字也走 `kmalloc(name_len)` ⇒ 第二个可控尺寸分配点 |
| `trusted.*` / `security.*` | **EPERM(1)** 全部 | 需要 cap，符合预期；**只有 `user.*` 命名空间可用** |
| **inotify 事件名** | `inotify_init1`=fd、`add_watch` wd=1、读到 1120 字节、**首个事件 `len=208`、name=我们造的 200 串** | `kmalloc(sizeof(event)+len)` ⇒ 16+208=224 ⇒ **又一个 kmalloc-256 载体，且生命周期由队列控制**（不 read 就一直占着，read/close 才释放） |
| AF_UNIX SOCK_DGRAM + abstract `bind` | socket ok、`bind`=0 | `sendmsg(240)` 失败是**我的探针写错了**（DGRAM 未连接且没给 `msg_name` ⇒ ENOTCONN 107），**不是被拦**；下轮补 connect/带地址版本 |
| AF_INET UDP `sendto(240)` loopback | **=240 成功** | skb/head 也是通用分配候选 |

⇒ **结论：UAF 的"回收 + 填可控内容"这一半，在 app 域有至少两个已验证的载体**
（`user.*` xattr 与 inotify 事件名），不再是我之前只是"断言"的"喷洒在自己进程内完成"。

## 2. 但要清楚还没解决的两件事（别把这张表当成功）

1. **判据**：xattr 能回读的只有**我们自己刚写进去的那份**（同一条 xattr），
   不能读别人的对象 ⇒ 抢槽之后"写有没有生效"仍然没有观测通道（[[device-observability-limits]]）。
   真正能用的是"生效后可被行为观察到"的落点（例如把一个 flag/计数改掉，让某个后续 syscall 的 errno 变）。
2. **窗口**：`binder_thread_release` 那条路要产生 *free 之后* 的写，仍然要求事务真的 pending、
   且 free 与写之间的时序能拉开（本轮没推进这块；`0x720c=BR_NOOP` 那次误判的教训仍然适用）。
   写形状本身本轮量清了：**`t->to_proc`(偏移 0x38) 被当成指针用** ——
   `add x20,x22,#0x230; _raw_spin_lock` + `ldr w8,[x22,#0x64]; subs w8,#1; str w2,[x22,#0x64]`
   ⇒ 若 `to_proc` 被我们填成任意内核 VA，得到的是
   **"对 `X+0x64` 的 u32 自减（可重复！）+ 对 `X+0x230` 的锁字写"**，不是任意值写。

## 3. 下一步（按性价比排序）

1. 把 **u32 自减 + spin_lock 双写**当原语来设计落点（不是当"任意写"）：
   `X+0x64` 自减可重复 ⇒ 例如把某个引用计数/长度/布尔域一步步拧到目标值；
   先离线在 `analysis/kernel` 里找"自减一个字段就能改变行为且能被 errno 观测"的落点候选。
2. 补一个 P49：AF_UNIX `connect+sendmsg` 版本，以及"同一 size 连续 alloc/free N 次"
   的槽复用密度测试（用来估抢槽成功率）。
3. 窗口时序那一半仍要回到 `p34/p35/p37` 的失败教训上：先确认真有 pending 的同步事务，
   再谈 `BINDER_THREAD_EXIT`。

## 4. 把写形状读全了（`binder_free_transaction` 0xf5f050..0xf5f0b8 原文）

```
f5f050: b94066c8   ldr  w8, [x22, #0x64]        ; x22 = t->to_proc (=X)
f5f054: 71000502   subs w2, w8, #0x1
f5f058: b90066c2   str  w2, [x22, #0x64]        ; ★可重复的 u32 自减★
f5f05c: 540014e4   b.mi  <printk 错误路径>       ; 结果<0 → 走错误分支（必须保证 ≥0）
f5f060: 35000102   cbnz w2, 0xf5f080            ; ★结果≠0 就跳过 __wake_up★
f5f064: 3941a6c8   ldrb w8, [x22, #0x69]        ; 只有恰好归零时才读 X+0x69
f5f06c: 9101c2c0   add  x0, x22, #0x70
f5f07c: 97cfd16e   bl   <__wake_up>             ; 归零时才会去走 X+0x70 的等待队列
f5f080: f9402e68   ldr  x8, [x19, #0x58]        ; x19 = t ⇒ x8 = t->buffer
f5f084: b4000048   cbz  x8, 0xf5f08c
f5f088: f900191f   str  xzr, [x8, #0x30]        ; ★★8 字节清零写，基址=一个指针字段的值★★
f5f0b4: f9401e75   ldr  x21, [x19, #0x38]       ; 又读一次 to_proc
```

三条被低估的事实：

1. **`__wake_up` 是条件执行**（只有计数**恰好归零**才跑）⇒ 只要挑一个当前值不是 1 的计数，
   整条等待队列解引用就**根本不会发生**。对 `X` 的"形状要求"因此比我担心的弱得多。
2. **真正的原语是 0xf5f088 的 `str xzr, [x8, #0x30]`** —— 一次**8 字节清零写**，
   目的地址 = 某个"指针字段"+0x30，且只被 `cbz`（非空）挡着。
   这才是 KASAN 签名 "free 后 Write of size 8" 的那条指令所属的族。
3. 但要拿它当"任意地址清零"，前提是**那个被解引用的指针字段位于已被释放、且我们能重新填满的内存里**。
   这里 `x8 = t->buffer` 是从 **`t` 自己**读的，而 `t` 此刻尚未被 `kfree`（kfree 在 0xf5f220 之后）
   ⇒ **本条 store 不构成"对已释放对象的读"**；这条 CVE 真正被复用/悬空的是
   **`binder_thread` / `binder_proc`**（`t->to_proc`/`to_thread` 在锁外被读，见 §2.2 与
   `binder-uaf-2026`）。
   ⇒ 正确的靶子是：**回收被释放的 `struct binder_thread`**（5.4 里 thread 走 `kmalloc(sizeof(*t))`，
   `sizeof≈0x1A0` ⇒ **kmalloc-512**），随后任何 `to_thread->…` 的 store 就变成
   "写 `我们选的地址 + 固定偏移`"。而 §1 的 xattr 载体尺寸可以覆盖 512 桶
   （P48 里 L=1024 也 SET=ok ⇒ 300..512 任意值都能拿来精确占 kmalloc-512）。

**下一步 #13 的准确问法**（改写）：不是"哪里放一个自减"，而是
**"`binder_thread` 被 free 之后，还有哪些代码路径会把它当活的 thread 用、并对 `thread + 固定偏移` 做 store"**
—— 在 `vmlinux_full.asm` 里以 `binder_thread_release`/`binder_send_failed_reply`/
`binder_transaction_buffer_release` 为起点找全部 `[x?, #const] = …` 形态的 store，
并按"偏移 + 值来源"列表；每个候选都要标出它是否落在 `__wake_up` 条件之后（可绕）。

## 5. 补充（同轮，0xf5f0b4..0xf5f12c 与 `binder_send_failed_reply` 头部）

对 `X = t->to_proc` 的**其余访问全部是"读门"**，不是写：
`ldrb [X+0x68]`（非 0 则整段跳过）、`ldr w8,[X+0x44]`（选分支）、`ldrb [X+0x69]`（决定要不要 `__wake_up`）。
另外 `binder_send_failed_reply@0xf60b14` 的第一条实质指令就是
`ldrb w8,[x0,#0x64]; tbnz w8,#0x0 → 0xf60f20`（**从 `t+0x64` 读一个早退门**）。
还发现第二个自减点，但它打在**固定的 .data 全局**上（`adrp 0x13235000` + `ldr/sub/str [x8,#0x884]`），
且被 `[t+0xb0] → [+0x88]` 的门挡着，不是可选落点。

⇒ 推论（比 §4 更强）：**如果被复用的对象是 transaction 本身**，那么攻击者不止能定一个写落点，
而是**同时掌握这条路径上几乎所有分支门**（`t+0x58` 给写基址、`t+0x38` 给 `X`、
`t+0x64/0x68/0x69/0x44` 给门），`str xzr,[buffer,#0x30]` 就升级成"**任意地址 8 字节清零写**"。
**所以"被 free 的到底是 transaction 还是 thread"是这条线现在的唯一分叉点** ——
已派子代理用 5 个函数的范围定死它（`analysis/BINDER-UAF-WHO-IS-FREED-20260926.md`）。
