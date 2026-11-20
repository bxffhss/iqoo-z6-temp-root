# binder UAF 的分叉点：被 free 的到底是哪个对象 (2026-09-26)

（子代理跑挂了没出报告，本文是我自己一手读完 7 个调用点 + free 尾部之后的结论。）

## 0. 结论（一句话）

**`binder_free_transaction` 里那些诱人的写（`str xzr,[t->buffer,#0x30]`、
`unlink` 三连写 `[x9,#8]/[x8]`、u32 自减）全部发生在 `kfree(t)` 之前**，
而且 7 个调用点在 `bl binder_free_transaction` 之后都没有再使用 `t`
⇒ **"t 被 free 后我们回收并填满它"单独成立并没有用**；
要拿到那些写，必须让 **同一个 `t` 被 `binder_free_transaction` 处理两次（double-invocation）**，
第二次才会从我们填的字节里读 `buffer`/`to_proc`/`fd_fixups` 链。
这把这条线的问题从"窗口时序"收窄成了一个**非常具体、可判定的问题**：
**这台机器的 binder 能不能对同一个 transaction 触发两次 free。**

## 1. 一手证据

### 1.1 `kfree(t)` 是函数里最后一个动作，之后直接进 epilogue
```
0f5f224: aa1303f5   mov  x21, x19                  ; x19 = t（入口就存好的）
0f5f228: f8480eb4   ldr  x20, [x21, #0x80]!        ; t->fd_fixups 链头
0f5f22c: eb15029f   cmp  x20, x21                  ; 空?
0f5f248: a9002296   stp  x22, x8, [x20]            ; LIST_POISON 写（写进 entry 自己）
0f5f24c: 97d79e55   bl   <kfree>                   ; kfree(fd_fixups entry)
0f5f274: a9402289   ldp  x9, x8, [x20]             ; ★unlink 形状：两个指针从 x20 读★
0f5f278: f9000528   str  x8, [x9, #0x8]            ;   *(A)=B  任意写
0f5f27c: f9000109   str  x9, [x8]                  ;   *(C)=D  任意写
0f5f284: aa1303e0   mov  x0, x19                   ; ★x0 = t★
0f5f288: 97d79e46   bl   <kfree>                   ; ★kfree(t)★
0f5f28c: 14000009   b    0xf5f2b0                  ; 直接跳出口，之后不再碰 x19
```
`0xf5f088` 的 `str xzr,[x8,#0x30]`（`t->buffer->transaction = NULL`）同样在此之前。

### 1.2 7 个调用点在 free 之后都没有再用 `t`
调用点（`bl 0xffffffc010f5eff8`）：
`0xf551d4`、`0xf56810`、`0xf56a54`、`0xf5baf4`、`0xf60c54`、`0xf60e9c`、`0xf63734`。
逐个读了紧随其后的 8 条：
* `0xf56a54` / `0xf5baf4` / `0xf63734` / `0xf60e9c` → 立刻 `b` 到别处或 epilogue，**无使用**；
* `0xf56810` → 从栈重载 `x21` 后 `b`，**无使用**；
* `0xf551d4` → 之后 `binder_free_buf(x25, x19, x28, 1)`，这里 `x19` 是 **buffer** 不是 `t`（该调用点所在函数把 buffer 传进 free_buf）；
* `0xf60c54`（在 `binder_send_failed_reply` 内）→ `mov x19, x20` 换到**下一个**对象继续走栈，**无使用**。

⇒ **本构建里 transaction 的"free 后被读"不来自它的直接调用方。**

## 2. 那么 CVE 说的是什么？—— 两类仍需继续查的形状

`binder_free_transaction(t)` 里的读全部来自 `t`，所以攻击面只可能是：

* **形状 A（double invocation）**：两条路径都拿到同一个 `t` 并各调一次 free
  （上游 64468/64469 的修复点正是"释放路径没有正确互斥"）：
  `binder_thread_release@0xf50ecc → binder_send_failed_reply@0xf60b14 → binder_free_transaction`
  与 `binder_release_work@0xf63418 → binder_free_transaction`
  **两条路能不能对同一个 `t` 都跑起来** —— 这是现在唯一值得追的问题。
  判据：`t` 从 `thread->transaction_stack` / `proc->processed_transaction` 摘链时是否持锁、
  摘链与 free 之间是否有窗口（`binder_transaction_buffer_release` 同理）。
* **形状 B（thread/proc 才是被 free 的对象）**：`t->to_proc`(X) 与 `t->to_thread` 指向的对象若先被 free，
  我们的写入落进"被回收的对象内部固定偏移" ⇒ **只能踩我们自己的对象，零收益**；
  除非该对象内部**又有一个我们可控的指针**被解引用（`binder_proc` 里 `inner_lock@0x230`、
  wait queue、todo list 都是 list/锁 ⇒ 一旦被我们填满就是 unlink 型任意写）。
  注意这条路的回收尺寸是 **kmalloc-512（`binder_thread`≈0x1A0）**，
  而 P48 证明 xattr 载体可以精确开到 512 桶（L=1024 都成功）。

## 3. 与上一轮判断的差别（自我纠正）

上一轮我在 §4/§5 里写"`str xzr,[buffer,#0x30]` 若 t 被回收就升级成任意地址清零写"——
**方向对，但漏了前提**：那次 store 在 `kfree(t)` **之前**，所以它不是"UAF 里的写"，
而是"double-free 第二跳里的写"。少写这个前提会让人高估这条线的成熟度。

## 4. 下一步（收窄后的唯一问题）

**读 `binder_thread_release` + `binder_release_work` 这两条路对同一个 `t` 的摘链/置空顺序**，
判"形状 A 是否可达"：具体要看 (a) `t` 被放进 `todo`/`work` 链表时是否已从 `thread->transaction_stack` 摘掉；
(b) 摘链是否始终在同一把锁内；(c) `binder_send_failed_reply` 会不会把一个仍在链上的 `t` 交给 free。
产出应是一张"t 的生命周期 × 谁持指针"表，而不是一篇长文。

## 5. 本轮另两条被确认的事实（已同步进 `RECLAIM-VECTORS-APP-20260926.md`）

* 对 `X = t->to_proc` 的访问里，`X+0x44 / 0x68 / 0x69` **全是读门**，写只有
  `X+0x64` 的 u32 自减与 `X+0x230` 的锁字；且 `__wake_up` 只在计数**恰好归零**时执行 ⇒ 可绕。
* 第二个自减点打在**固定 .data 全局**（`0xffffffc013235000 + 0x884`，vendor 计数器），不是可选落点。

## 6. 正向结果：链的走法本身就制造"对已 free 对象再调一次 free"

`binder_send_failed_reply@0xf60b14` 的循环尾部（原文）：
```
0f60c18: 9108c2a0   add  x0, x21, #0x230
0f60c1c: 9417f5f8   bl   <_raw_spin_unlock>          ; ★先放掉 inner_lock★
0f60c24: 97ffff62   bl   <binder_thread_dec_tmpref>
0f60c38: f9401a74   ldr  x20, [x19, #0x30]           ; ★在锁外读链头(from_parent/parent)★
0f60c54: 97fff8e9   bl   <binder_free_transaction>   ; 然后 free 掉 x19
0f60c58: b9457b48   ldr  w8, [x26, #0x578]           ; 下一轮把 x20 当作新的 t 继续
```
⇒ 顺序是 **`unlock → 读 parent 指针 → free 当前`**，下一轮再拿那个**在锁外读到的 parent** 去
`binder_free_transaction`。只要那个 parent 在两步之间被另一条路 free 掉（另一侧进程的回复路径、
或同一个 thread 的 `todo` 表被 `binder_release_work@0xf63418` 处理——它里面也有
`bl binder_free_transaction` @`0xf63734`），**第二跳就是在已释放的 kmalloc-256 对象上跑 free**。

而 `binder_thread_release` 侧的结构与 §1 完全对上：
```
0f510c8: bl <_raw_spin_unlock>      ; 放锁
0f510d4: bl <synchronize_rcu>
0f510dc: mov w1, #0x7205            ; ★BR_DEAD_REPLY（一手确认事件码）★
0f510e4: bl <binder_send_failed_reply>   ; ← x22 = 从 transaction_stack 取的 t
0f510f0: bl <binder_release_work>(x19+0x48)  ; ← 同一时间还处理 thread->todo
0f510f8: bl <binder_thread_dec_tmpref>(x19)
```
**`t` 在设计上同时挂在两处**：`thread->transaction_stack`（这里走）与 `thread->todo`
（`t->work`，被 `binder_release_work` 走）。上游的修复正是要求这两处摘链在 `t->lock` 下完成，
而本机 `binder_free_transaction` **入口第一条实质指令就是 `ldr x22,[x0,#0x38]`、全程没有碰 `t+0x98`**
（`t->lock`）——与 [[binder-uaf-2026]] 记的"缺锁"一致。

### 6.1 于是第二跳给我们的是什么
一旦第二跳发生在**我们用 `fsetxattr("user.poc", 240 字节)` 抢回来的槽**上，
那次 `binder_free_transaction` 里的读全部来自我们写的字节：
* `[t+0x58] = buffer` ⇒ `str xzr,[buffer+0x30]` = **任意地址 8 字节清零写**；
* `[t+0x80]` = fd_fixups 链头 ⇒ `ldp x9,x8,[x20]; str x8,[x9,#8]; str x9,[x8]` =
  **unlink 三连 = 标准 write-what-where**（两个不同地址、两个不同值）；
* `[t+0x38] = X` ⇒ u32 自减 `X+0x64` + 锁字 `X+0x230`，且 `X+0x44/0x68/0x69` 是我们可以设的门。

### 6.2 还差一步才能说"确定性"（下一轮要查的唯一事项）
**`t` 从 `transaction_stack` 摘链时，是否同时也把它从 `thread->todo` 摘掉？**
若某条错误分支只摘一处（上游修复对应的就是这些分支），则两条路会对同一个 `t` 各 free 一次
⇒ **不需要拼时序**；否则需要一个"另一侧同时 free 掉 parent"的窗口。
查法：在 `binder_send_failed_reply`/`binder_transaction_buffer_release`/`binder_pop_transaction`
里找对 `t+0x48`(`work`) 的 `list_del`/`INIT_LIST`，与对 `thread->transaction_stack` 的置空配对比较。

## 7. §6.2 那一查的结果（含一次自我纠正）

我先说"函数里没有 `__list_del_entry_valid`"、随后又数出 2 处，**两次都不准**，实情是标签边界问题：

```
从 `binder_send_failed_reply` 起点数 2200 行，`__list_del_entry_valid` = 2 处
  地址 0xffffffc010f61aec 与 0xffffffc010f61ba0
  但 objdump 给这两处标注的最近前导符号是 <rsc_binder_schedule_bg_work_ilocked+0x184 / +0x240>
  ⇒ 它们属于**相邻的另一个函数**，不在 send_failed_reply 体内
```
⇒ 正确表述：**`binder_send_failed_reply` 自身体内 0 处 `__list_del_entry_valid`**，
只有 `__list_add_valid`（把失败回复的 work **挂进**链表）与两处 `binder_free_transaction`
（`0xf60c54`、`0xf60e9c`）。而 `binder_free_transaction` 里那条 unlink 三连作用在
**`[t+0x80]` 的 fd_fixups 链**上，不是 `t+0x48` 的 `work`。

**所以**：这条路径"free 掉 `t`，却没有一处把 `t->work` 从 `thread->todo` 摘掉"这一条**证据成立**；
紧接着 `binder_thread_release@0xf510f0` 就调 `binder_release_work(x20, x19+0x48 /*&thread->todo*/)`，
而 `binder_release_work` 内也有 `bl binder_free_transaction@0xf63734`。

**但仍不能就此宣布"确定性双 free"**，缺的是最后一环的事实：
**走到 `0xf510e4` 之前，`t` 是否本来就在 `thread->todo` 上**
（上游语义：只有 `t->work.type == BINDER_WORK_TRANSACTION` 且已排到该 thread 的 todo 时才在）。
补这一环要么读 `binder_transaction`/`binder_transaction_received` 的入队点，
要么用真机行为反证。**这一环没补上之前，不要把 §6.1 的原语当成已到手。**

## 8. 对 §7 结论的降级（同一轮内的第二次自我纠正）

§7 说"函数体内 0 处 `__list_del_entry_valid` ⇒ 没人把 `t->work` 摘出 `thread->todo`"——
**这个推理不成立**，两条一手理由：

1. **入队/出队助手在本构建里全部被内联**：
   `grep binder_(enqueue|dequeue|pop)` 在 `embedded-kallsyms.txt` 里**一个符号都没有**
   （只有 `binder_transaction_buffer_release@0x10f5d64c` 存活）。
   ⇒ "看不到对这些 helper 的调用"根本不等于"没有出队动作"。
2. **`list_del` 在这份二进制里常见开写形式**：`binder_free_transaction` 自己就用
   `ldp x9,x8,[x20]; str x8,[x9,#8]; str x9,[x8]` 直接改链（§1），不经过 `__list_del_entry_valid`
   （只在需要合法性检查时才走 helper）。
   ⇒ 判"有没有出队 `t->work`"必须去找**对 `t+0x48/0x50` 的开写 store**，而不是数 helper 调用。

另外本轮还排掉一个我以为存在的强证据：`binder_send_failed_reply@0xf60e00` 那次
`__list_add_valid` 挂的是 **`x20+0x88`** 这个 list_head（随后
`str x22,[x20,#0x50]`、`stp x21,x23,[x20,#0x88]`、`str x22,[x23]`），
**不是 `t+0x48` 的 `work`** ⇒ 它不是"把已 free 的 t 重新链回活链表"，
所以**"确定性双 free"这条更简单的路没有成立**。

### 现状（诚实版）
* §6 的"锁外读 parent 再 free"**仍然成立**，但它只给**竞态窗口**，不给确定性双 free。
* 要判"确定性"，正确的查法已换形：**在释放路径上找对 `t+0x48`/`t+0x50` 的开写 store**
  （形如 `stp x_, x_, [x19, #0x48]` 或 `str x?, [x?, #0x8]` 配合基址来自 `x19+0x48`），
  而不是数 `__list_del_entry_valid`。
* 静态这条路到此边际收益下降；再往前要么读 `binder_transaction` 的入队点全貌（大工程），
  要么走真机行为反证（有 oops 风险，需先取得批准）。

## 9. 用"开写形态"重查的结果（两条确定事实 + 一条仍然开放）

先记下方法教训：我按 `[x?, #0x48]`/`add x?,x?,#0x48` 在 binder 段查 `work`，**两处都是 0 命中**——
因为 **`0x48` 是 `to_parent`**（一手偏移表里就写着），我拿了一个错偏移去查。真实情况由
`binder_release_work` 的循环头给出：

```
0f634b0: f9400268   ldr  x8, [x19]              ; x19 = &thread->todo（list head）
0f634b4: eb13011f   cmp  x8, x19
0f634b8: 9a8803fa   csel x26, xzr, x8, eq       ; 空表 ⇒ x26=0
0f634c4: 97e36cb0   bl   <__list_del_entry_valid>
0f634cc: a9402349   ldp  x9, x8, [x26]          ; ★开写 del★
0f634d0: f9000528   str  x8, [x9, #0x8]
0f634d4: f9000109   str  x9, [x8]
0f634d8: f900035a   str  x26, [x26]             ; ★INIT_LIST_HEAD★
0f634e4: f900075a   str  x26, [x26, #0x8]
0f634dc: b9401b59   ldr  w25, [x26, #0x18]      ; work->type 在 entry+0x18
0f63730: aa1a03e0   mov  x0, x26                ; ★把 x26 直接当 t 传给 free★
0f63734: 97ffee31   bl   <binder_free_transaction>
```

**事实 1**：`binder_release_work` **确实**在 dispatch 前把 work 摘链并 `INIT_LIST_HEAD`
（helper 校验 + 开写 del 都在）。⇒ "从 todo 走的那次 free 是干净的"，
不构成"同一 work 被 release_work 处理两次"。

**事实 2**：transaction 分支里 `mov x0, x26` **没有 `sub`/`container_of`** ⇒
本构建 `work` 就嵌在 **`binder_transaction + 0x00`**（`type` 在 +0x18，vendor 布局把 entry 与 type 之间
塞了字段）。这修正了我之前"work 可能在 +0x48/+0xa0"的猜测，也说明
**todo 链表上的地址 == transaction 对象地址本身**（回收时不必再减偏移）。

**仍然开放（最后一环被 sharpen，不是被解决）**：
直接 free 那条路（`binder_thread_release@0xf510e4 → binder_send_failed_reply → binder_free_transaction`）
在 free 之前有没有把 `t->work`（= `t+0x00` 的 entry）摘掉？
* `send_failed_reply` 体内确实 **0 处 `__list_del_entry_valid`**，
  但它在 `0xf60e00` 处有一次 **开写 list_add**：`str x22,[x20,#0x50]` + `stp x21,x23,[x20,#0x88]`
  + `str x22,[x23]` —— 挂的节点在 **`x20+0x88`**、链表头在 **`x20+0x50`**。
  若 `x20 == t`，那被挂的是 t 的**第二个**内嵌 work（+0x88，和 §1 里 `[t+0xb0]` 交给
  `__cancel_work_timer` 的 vendor 后台 work 同一区域），**不是** `t+0x00` 的 todo entry；
  若 `x20` 是别的对象，则另说。
* ⇒ 判死这一环只需要一件事：**确认 `0xf60df0~0xf60e10` 里的 `x20` 是谁**
  （回溯它的赋值：来自 `[x19,#0x30]` 还是 `x19+const`）。
  这一步做完，才能说"直 free 有没有留下挂在 todo 上的悬空 entry"。

**所以 §8 的降级结论不变**：目前只证明"存在锁外读 parent 再 free"的**竞态窗口**；
"确定性双 free"**未证明**。但 `work@t+0x00` 这个事实把最后一查缩成了**一个寄存器的来源问题**。

### 9.1 那个寄存器的来源已查到，结论是"仍未证明，但问题被定位到最后一格"

`binder_send_failed_reply` 体内对 `x20` 的全部赋值只有两处：
```
0f60b84: f9401674   ldr x20, [x19, #0x28]    ; x20 = t->from        (struct binder_proc*)
0f60c38: f9401a74   ldr x20, [x19, #0x30]    ; x20 = t->from_parent (struct binder_transaction*)
```
⇒ `0xf60e00` 那次开写 `list_add` 挂的节点是 **`x20 + 0x88`**（链表头在 `x20+0x50`），
**不是** 事实 2 定位到的 **`t+0x00`** todo entry
（若 `x20==t`，挂的是 t 的**第二个**内嵌节点 +0x88，与 §1 里交给 `__cancel_work_timer` 的
vendor 后台 work 同一区域；若 `x20==t->from` 则是 proc 自己的链表，与 `t->work` 无关）。
⇒ **直 free 那条路既没有摘 `t+0x00`，也没有把它挂回去**——它对 `t->work` 的链表状态**完全无动作**。

于是最后一问被压缩成一个纯状态问题：
**当 `binder_thread_release` 从 `thread->transaction_stack` 取到 `t` 时，`t+0x00` 这个 entry
是否同时挂在 `thread->todo`（或某个 proc 的 todo）上？**
答"是" ⇒ `binder_release_work` 之后会对**已 free 的 `t`** 再调一次 `binder_free_transaction`
⇒ §6.1 的 unlink 三连 + `str xzr,[buffer+0x30]` 全部落地为真原语；
答"否"（上游语义里 `transaction_stack` 上的 t 通常**不在** todo，todo 上放的是 reply/async work）
⇒ 只剩 §6 的**竞态窗口**，没有确定性双 free。
**这一问要靠读 `binder_transaction`（入队点）或真机行为才能定**；本轮到此为止。

## 10. 本轮方法账（避免下次再犯）

1. 用"数 helper 调用"做**存在性否定**不成立（内联 + 开写形态），见 §8。
2. 用"从函数起点数 N 行"当函数边界不成立（objdump 按最近前导符号标注），见 §7。
3. 用**猜的字段偏移**去查指令形态会得出假的"0 命中"：`0x48` 其实是 `to_parent`，
   `work` 在本构建嵌在 **`t+0x00`**（`type` 在 entry+0x18）。
   ⇒ **查偏移要么从 `container_of`/入队点反推，要么先核一手**，不能沿用记忆里的未标注值。
