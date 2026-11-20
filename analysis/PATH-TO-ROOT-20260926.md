# 通往临时 root 的当前最优链（2026-09-26 定稿，自主决策产物）

目标：一次性、无持久化的临时 root（改 `struct cred`），设备 = 自有机主 iQOO Z6，
BL locked，SELinux enforcing，无 root，**命中即重启**（无任何内核日志通道）。

## 0. 本轮新确立的三块地基（全部一手）

1. **`binder_send_failed_reply` 缺 `t->work` 的 dequeue —— 已证实，不是推测。**
   按标签精确切出函数体 = **266 条指令**，其中 `__list_del_entry_valid` **0 处**、
   `__list_add_valid` 1 处（挂的是 `x20+0x88`，`x20 ∈ {t->from, t->from_parent}`），
   两处 `mov x0,x19` 都是 `bl binder_free_transaction`。
   而 `binder_thread_release@0xf510f0` **紧接着**调 `binder_release_work(proc, &thread->todo)`，
   `binder_release_work` 自己**会**正确摘链并 dispatch（`0xf634c4~0xf634e4`），
   transaction 分支 `mov x0,x26` **原样**当 `t` 传进 `binder_free_transaction@0xf63734`
   （**无 `container_of` 减法** ⇒ `work` 嵌在 `t+0x00`）。
   ⇒ 只要 `t->work` 当时在 `todo` 上，就是**同一个 `t` 被 free 两次**。
2. **存在"用户态尺度"的窗口**：本构建带 vendor 的延迟释放机制
   `rsc_binder_schedule_bg_work_ilocked@0xf61984`（读 `proc+0x30` 链表、受全局
   `0x13235888` 控制），且 transaction 自身在 `+0xb0` 挂 `work_struct`
   （`binder_free_transaction@0xf5f0bc` 对它调 `__cancel_work_timer`）
   ⇒ 第二跳可能来自 workqueue 上下文，而不是紧挨着第一跳 ⇒ **中间够我们喷洒**。
3. **app 域有"内容可控 + 尺寸可控 + 可回读"的 kmalloc 载体**：
   `fsetxattr(fd,"user.poc",val,L)` 对 L=8/40/100/200/240/256/1024 全部成功且 `fgetxattr` 逐字节一致
   （`trusted.*`/`security.*` = EPERM）；inotify 事件名同样可用且生命周期可控。

## 1. 链条（每一环都标了当前状态）

```
[A] 制造"带 pending 同步回复的线程死亡"        ← 未做，纯用户态可试
      用 p40 已确认的 A14 parcel 编码（interface token 4 个前置 dword）
      对 servicemanager 发 checkService 同步事务，然后 BINDER_THREAD_EXIT / close
[A'] 内核在缺 dequeue 的情况下对同一 t free 两次  ← 由 §0.1 推断，需实测
[B] 用 240 字节 user.* xattr 抢回 kmalloc-256 槽   ← 载体已证实存在
[C] 第二跳 binder_free_transaction(我们的字节) 里的
      ldp x9,x8,[x20] ; str x8,[x9,#8] ; str x9,[x8]        ← 指令已在真机镜像里核实
      ⇒ *(A)=B 且 A、B 两个 8 字节都由我们的 xattr 内容决定
      = **任意地址、任意 8 字节写**（不再是自减/清零那种受限形状）
[D] 用 [C] 的写做两件事：
      D1 泄露：把自有 ashmem `struct file` 的 f_op(+0x28) 写成 &acc_fops 静态地址
               ⇒ ioctl 的 `ldrsw x0,[pd+0x70c]/[+0x710]` 直接以返回值为通道
               ⇒ 4 字节/次的**堆读 oracle**（无 copy、不过 __check_object_size、不加锁）
               ⇒ 用它定位我们的 `struct cred` / 相邻对象
      D2 提权：按 D1 得到的地址，写 cred 的 {uid,euid} / {gid,egid} / {suid,sgid}=0
               以及（若仍被 SELinux 拦）`selinux_state.enforcing=0`
[E]  exec /system/bin/sh ⇒ uid=0 shell；退出即失效，无持久化
```
**KASLR**：`[C]` 之后我们需要 kernel 静态地址（`&acc_fops`、`selinux_state`）。
唯一可用通道 = **shell 域 perf 自采样**（app 域 `perf_event_open` = EACCES；跨进程采样 = EACCES；
`/proc/kallsyms` = EACCES），且 **slide 每次开机变** ⇒ 运行时现场测，再由我们把值喂给 app
（同一条 adb 会话里做完，符合"临时 root"的威胁模型）。

**地址来源风险**：所有静态地址目前来自 **`gbef221370b4`(2026-06-18) 镜像**，真机是
**`g2a88cd145def`(2025-05-07)**；两者 `.config` **逐字节相同** ⇒ 结构偏移可信，
**函数/对象地址不可信**（13 个月厂商 commit 足够搬动）。⇒ 见任务 #11：
拿到真机同 build 镜像前，`&acc_fops`/`selinux_state` 这类**绝对地址**都还是估计值。
好消息：`[C]` 的写**只需要 `A` 指向我们已经在读的内存**（自己的 xattr/cred 区），
第一步可以做"只写自己附近、可回读"的验证而不必知道任何绝对地址。

## 2. 判据设计（这是以前最缺的东西）

**"槽被偷"探测器（不依赖内核崩溃、不需要绝对地址）**：
1. 一次性铺 N 个 240 字节 xattr，每个填**唯一 tag**（例如 `slot_id + CRC32`）；
2. 触发 `[A]`；等待（覆盖 `[B]` 的窗口）；
3. 全部 `fgetxattr` 回读，比对 tag。
   - 某个 xattr 的内容**被改写** ⇒ 我们的对象被内核当成空闲并重新分配出去 ⇒ **UAF/双 free 的强证据**；
   - 某个 xattr **读不回**（ENODATA）或长度变 ⇒ 同类证据；
   - 全部原样 ⇒ 至少"第二跳没有落在我们持有的槽上"（弱阴性，与窗口大小相关，要扫多轮/多 N）。
4. 关键：这个判据的**正信号不需要内核出错**，因此可以先跑"只探测不利用"的温和版本。

**`[C]` 落点的安全验证**（拿到写之后）：先用 `*(A)=B` 写一个**我们自己的 xattr 对象的字段**
（写前后各回读一次）⇒ 用"自己的可回读内存"证明任意写成立，再谈写 cred。

## 3. 执行顺序与风险声明

| 序 | 动作 | 风险 | 需要批准 |
|---|---|---|---|
| 1 | 写 P49：`[A]` 的正确 parcel + 线程退出 + `[B]` 喷洒 + §2 探测器（**只探测不写**） | 最坏 = oops/重启；**不会改任何内核状态**（写发生在内核自己的 double-free 里） | 否（重启已预批准） |
| 2 | 若 1 出正信号：加"写自己 xattr 字段"的落点验证 | 会写内核地址（我们自己的对象） | 否（自有内存） |
| 3 | 若要绝对地址（`&acc_fops`/`selinux_state`）：先跑 shell 侧 perf 定 slide + 尝试取真机同 build 镜像（任务 #11） | 无 | 否 |
| 4 | 写 cred / 关 enforcing（真正的提权动作） | **改内核全局状态**，最坏重启 | **是 —— 这一步我会停下来先问你** |

## 4. 本轮明确否掉/搁置的

- `show_fdinfo`(13 成员全只读) 与 `mmap`(4 成员，无 pfn 映射者) 两个 f_op 槽：**判死**。
- GhostLock 的栈覆盖：深度需求 `[0x288,0x298]` vs 直写上限 `≈0x210`，**结构性不可达**；
  其 (b)(c) 两选项此前已用证据关闭。
- KGSL 提交路径：legacy 与 GPU_COMMAND 只记账，**inert**。
- ION：可分配可映射（含 `qsecom` ≥75MiB 无上限），但页面**分配即清零**、无别名、无残留
  ⇒ 是**映射/耗尽**原语，不是读写原语（作为独立漏洞上报，见 `ION-HEAP-UNTRUSTED-ALLOC-20260926.md`）。
- 用 `__list_del_entry_valid` 调用计数做"存在性否定"：**方法作废**（助手全被内联 + 开写三连形态），
  改用标签定界的函数体 + 目标字段的开写 store（§10 of BINDER-UAF-WHO-IS-FREED）。

## 5. P49 实验日志（"槽被偷"探测器）—— 两轮均为**空结果**，不是阴性结论

**探测器基础设施已验证可用**：
- `预建槽文件 2000/2000`、`基准喷洒成功 2000/2000`（**每个 xattr 必须放独立文件**：
  同一 inode 只能挂很少的 xattr，上一版 4000 槽只成功 16 个 ⇒ 判据形同虚设）
- **对照组（不触发直接审计）= 异常槽 0 / 丢失 0 / 短读 0** ⇒ "setxattr 240B 后 getxattr 读回"
  这条通道本身干净，正信号若有则是真信号。
- tag 全非零字节的约束已实现（否则内核 freelist 写 0x00 会被 `name` 截断而误判）。

**但触发器 100% 失败**：
```
[victim r0..r7] BC_TRANSACTION 成功=0 失败=13300~200000 首错 errno=13(EACCES)
                BINDER_THREAD_EXIT ret=0 errno=0        ← binder fd 本身是可用的
```
`TF_ONE_WAY` 和同步 (`flags=0`) **两种都试过，都是 EACCES** ⇒ 与 async 无关。
设备节点也不是问题：`/dev/binder` 就是 `-> /dev/binderfs/binder` 的符号链接（`binder_device:s0`），
而我们开的正是它；`/dev/binderfs/` 目录 shell 都不可列。
⇒ 诊断：**SELinux 拒 `binder:transaction`（或 `binder:call`），对象是 handle 0 = servicemanager，
来源是 `u:r:untrusted_app_27`**（`-EACCES` 在 `binder_transaction()` 里正是
`security_binder_transfer_binder()` 的返回值）。

**关键反差（也是下一步的钥匙）**：同一个 app 里 `ServiceManager.getService("package")`
在 P40 **成功返回过真 IBinder** ⇒ **从 Java/libbinder 出发的事务是被允许的**，
只有我们裸 `ioctl(BC_TRANSACTION)` 打 handle 0 被拒。

## 6. P50 设计（自主决定的下一步，未执行）

**不要用 handle 0**。用**框架已经替我们拿到的真 handle**：
`getService` 返回的 `BinderProxy` 的 `mObject`(long) 指向 native `ABp`，
其 **handle 整数字段在 +8/+12 附近**（AOSP `struct ABp { jobject; int32_t orig_proc; int32_t handle; }`），
用 JNI 反射读 `mObject` 再解引用即可取出。
**handle 是按进程分配的** —— 框架是在**我们自己的进程里**拿到它的，
所以我们那个 `/dev/binder` fd **可以直接用这个 handle**（这正是之前"框架 handle 不可用"结论的修正点：
之前用的是**另一个进程**(shell)的 fd，才不可用）。

于是 P50 = 在**专用 native 线程**里：
1. Java 侧先 `getService("package"/"activity")` 拿 handle（走被允许的路径）；
2. native 线程用我们的 fd 对该 handle 发**同步** `BC_TRANSACTION`（`system_server` 对
   `untrusted_app_27` 是允许的邻居），**不调 BINDER_WRITE_READ**；
3. 立刻 `BINDER_THREAD_EXIT` ⇒ 线程带着 pending 回复死亡 = §1 的 [A]；
4. 主线程在 2↔3 前后各喷一轮 240B xattr，然后跑 §2 的"槽被偷"审计。

**判据仍然成立**：对照组必须为 0；被偷槽 > 0 即"内核把我们持有的对象当成空闲"⇒
双 free 的强证据，**且这条判据本身不要求内核崩溃**。
风险：若双 free 真实存在，探针期间可能直接 oops/重启（重启已预批准）。

## 5b. P50/P51/P52 的诊断与一次关键自我纠正

1. `BINDER_VERSION` 要用**设备权威头的 magic `'b'`** ⇒ `ret=0, protocol_version=8` ✓
   （P49/P51 那次 EINVAL 是我用了 NDK 头的错 magic，**不是发现**）。
2. 把 `BC_ENTER_LOOPER`/`BC_REGISTER_LOOPER`/`BC_TRANSACTION` 当**独立 ioctl** 发 ⇒ 全部 EACCES(13)，
   且 **handle=0 与 handle=7（不存在）给出同一个 EACCES** ⇒ 拒绝发生在句柄解析之前。
3. **真相：`BC_*` 不是 ioctl，必须打包进 `BINDER_WRITE_READ` 的 write buffer。**
   本机 vendor `binder_ioctl` 对未知 `'c'` 命令返回 `-EACCES`（stock 返回 `-ENOTTY`），
   于是我把"自己调用形式错了"误读成"SELinux 拒 app 发事务"。
   ⇒ **§5 的"触发被拒"结论作废：P49 两轮从来没有真正发出过任何 binder 事务。**
   教训：errno 只能解释成"在我这次的调用形式之下"的结论。
4. P52 最后一块用了正确形式（write buffer 里 `BC_TRANSACTION`+struct），但同时 `read_size>0`
   ⇒ 线程 **park 在 `binder_thread_read`** 里再没返回（探针因此无输出；设备未重启，uptime 连续）。
   park 本身反证该 fd 是一个真 `binder_proc`。

## 5c. P53 = 修正后的真正触发实验

- 发事务改用 **`BINDER_WRITE_READ(write_buffer=[BC_TRANSACTION][binder_transaction_data],
  write_size=8+64, read_size=0)`** ⇒ 不 park、且**永不消费回复** = 要的 pending 同步事务。
- 同线程紧接着 `ioctl(fd, BINDER_THREAD_EXIT)` = §1 的 [A]。
- 主线程前后各喷一轮 240B `user.*` xattr（**一文件一 xattr**，已验证 2000/2000），
  再跑 §2 的"槽被偷"审计；**对照组必须先为 0**。
- 正信号两级：① `write_consumed` 增长（或之后能读到 `BR_TRANSACTION_COMPLETE`）⇒ 事务真进驱动；
  ② `被偷槽 > 0 且对照组 = 0` ⇒ 双 free 成立 ⇒ §1 的 [C]（unlink 三连 = 任意地址任意 8 字节写）落地。

---

## 6. 【作废声明 2026-09-26 晚】§0.1 / §0.2 与 [A']→[C] 整段作废

一手依据见 `BINDER-DOUBLE-FREE-CLOSED-20260926.md`，三条：

1. **§0.1 的"缺 dequeue 所以同一 t 被 free 两次"依赖一个在本机不成立的前提。**
   `binder_thread_read@4915` 是在 work **已经出队之后**才把 `t` 挂上 `thread->transaction_stack`；
   `binder_proc_transaction@3044` 只挂 todo、**不**挂 stack（"两处一起挂"的
   `binder_enqueue_transaction_work_ilocked` 是 5.10+ 才引入的）。
   ⇒ 不变式：**没有一个 t 会同时位于某线程的 todo 与该线程的 stack** ⇒ §0.1 的两跳不可能同时成立。
2. **"发 2 条同步事务就能长 out 一条 from_parent 链"是错的。**
   `binder_transaction@3321` 有守卫：非 oneway 且 `thread->transaction_stack` 非空且栈顶
   `to_thread != thread` ⇒ `BR_FAILED_REPLY` 直接拒。P56/P57 里 `consumed` 走满只证明
   write loop 前进，**不证明 transaction 对象被建立**（判据弱点，已在 §2 记下）。
   同一守卫设下的 `thread->return_error.cmd != BR_OK` 又使之后每次 write `consumed=0`
   （`binder_thread_write@4001` 的 while 条件）——这一个模型解释了 P54/P55/P56/P57 全部返回值。
3. **§0.2 的 vendor 延迟释放不是第二跳来源**：`rsc_binder_schedule_bg_work_ilocked(x0=proc, …)`
   挂在 **proc** 上（异步空间回收），`t+0xb0` 那个 work 在 free 时是被 `__cancel_work_timer` **取消**。

上机台账：P56 = 53,925 次「1 条同步 + 立刻 THREAD_EXIT」；P57 = 65,518 次「2 条同步 + 立刻 THREAD_EXIT」；
喷槽合计 >1.3M；**被偷槽始终 0，且每轮对照组同为 0**。

⇒ §1 链条的 [A'] 与 [C] **降级为"待 CVE 补丁原文重新定形"**；在拿到修复内容之前，
不再按 write-what-where 排下一步。**未被否掉**的部分：§0.3 的 xattr 回收载体、
app 可发真 binder 事务这一新地基（§1 表）、以及"必须让本线程先收到一条进来的同步事务"
这条唯一还能长链的形状（需要第二个自有 APK 用 bindService 建立双向调用，未做）。
