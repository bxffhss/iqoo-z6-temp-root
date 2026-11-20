# BINDER UAF 武器化评估 (CVE-2026-64468 / 64469)

**结论第一行：弱原语（只写零 / fixed-value NULL store）。** 两个 CVE 落在 freed 对象上的 store 全是**定值 0（8 字节指针置 NULL）或自增/锁 owner（非攻击者可控字节）**，没有 "controlled-value write"，与已被降级的 HID 线同一失败类别。建议降级为辅助，不作为主线投入。以下逐条给证据。一手源：`v5.4.302` `drivers/android/binder.c`（本地 `analysis/_uafsrc/t.c`）+ upstream 修复 diff（`analysis/_uafsrc/114a116aaa5f.patch`=64469、`f223d27a546c.patch`=64468）+ 本机 `C:\qemu_test\vmlinux_full.asm` 反汇编。

## 1. 精确写语义
freed 对象 = **`struct binder_transaction`**（不是 binder_thread）。两 patch 的 KASAN "Allocated by ... binder_transaction / Freed by binder_free_transaction" 佐证。设备上是 pre-fix：vendor `binder_free_transaction`（asm `0xffffffc010f5eff8`）在 `+0x14` 直接 `ldr x22,[x0,#0x38]`（读 `t->to_proc`）**未取 `t->lock`**，正是 64469 被删的那行；upstream fix 才补上 `spin_lock(&t->lock)`。窗口内落在 freed 对象上的 store：
- `binder_thread_release`（`t.c:5125-5135`）：`t->to_proc=NULL`(@0x38)、`t->to_thread=NULL`(@0x40)、`t->from=NULL`(@0x28)、`t->buffer=NULL`(@0x58) —— 全部 **8 字节写 0**（KASAN "Write of size 8"）。
- `binder_free_transaction`：`str xzr,[x8,#0x30]` 即 `t->buffer->transaction=NULL` —— **8 字节写 0，地址 = (t->buffer)+0x30**。
- 64468 的 store 是 `_raw_spin_lock` 对 **freed binder_proc** 的 inner_lock owner 字，**size 4、值为 cpu/tid，不可控**。

分类：属 (i) fixed-value write（恒 0）。唯一的 (ii) 变种是 `buffer->transaction=NULL`：若把 freed transaction 重分配成我们可控内容，则 `t->buffer`(@0x58) 变成攻击者地址 → **可控地址的 8 字节清零写**（type-confusion，非 64469 主 store）。**没有任何路径写入攻击者选择的非零字节。** 缓存：stock `sizeof(binder_transaction)=152`→kmalloc-192（advisory 值）；但 vendor 结构在 `lock@0x98` 之后仍被读到 `+0xb0/+0xd0/+0xd8/+0xe0`（latency + `rsc_binder` bg_work）→ 实际 size ≈ 0xF0=240 → **本机为 kmalloc-256（据最大字段偏移推导，UNVERIFIED 精确值；与 advisory 的 192 不一致，spray 类要按 256 校准）**。

## 2. Free/realloc 可控性
单非特权进程可：开 `/dev/binder` → 起线程 → 发**同步**事务自投递 → 在 from 侧线程退出/`BINDER_THREAD_EXIT`(`t.c:5437`) 触发 `binder_thread_release`，同时 peer 走 `binder_send_failed_reply→binder_free_transaction` 完成 `kfree(t)`（asm 有 `__cancel_work_timer` + latency-free，但未见新增 get/put refcount 阻止 free —— 保护性存疑，UNVERIFIED）。之后同 CPU 上可用 binder/普通 syscall 重分配该 kmalloc-256 槽。可控字节的同类结构候选（**均需实测 `/proc/slabinfo` 校准，标 UNVERIFIED**）：① 再一个 `binder_transaction`（自喷，最易但价值低）；② `struct sk_buff` head（部分字段可控）；③ `seq_file`（`/proc` 打开，size 固定非攻击者字节）；④ `tty_struct`（devpts，含 ops 指针）；⑤ `binder_node`/`binder_ref`。**关键缺陷**：能在同 size class 精确 offset(0x28/0x38/0x40/0x58) 放满攻击者字节的对象很少（Android 常 `unprivileged_bpf_disabled=1`，userfaultfd 仅用户态）——"让 NULL 落在有用字段" 本身不确定，这正是本线昂贵之处。

## 3. Vendor offsets 复核
确认与给定一致：`binder_free_transaction` 用 `[x0+0x38]=to_proc`、`[x19+0x58]=buffer`、`[x8+0x30]=buffer->transaction`、proc `inner_lock` 取 `[x22+0x230]`。`binder_thread`：`is_dead@0x19c`+1 对齐 → **size≈0x1A0=416 → kmalloc-512**；其 free 在 `binder_thread_dec_tmpref→binder_free_thread→kfree`（`t.c:5081`），**注意 thread 的 free 与 64469 的 transaction UAF 是两个对象，别混**。vivo/QC "RSC/PEM" 插桩：`rsc_binder_proc_transaction/rsc_binder_transaction_group/rsc_binder_schedule_bg_work_ilocked/notify_pem_binder_state`；大量 `*._rs`/`*._rs.NNN` 符号是 **Shadow Call Stack/KCFI 编译器 clone 工件，不是运行期 refcount**。它们给 transaction 加了 latency 字段与一个 bg_work（free 时 `__cancel_work_timer`），**未改变 64469 的 free 顺序，也未新增能救命的引用计数**（UNVERIFIED：仅据 free_transaction 反汇编前段，未逐条走完 thread_release 的 vendor 分支）。

## 4. DEBUG_LIST / BUG_ON_CORRUPTION
核心 64469 store（`t->from/to_proc/to_thread=NULL`）是**裸指针赋值，不经 list helper → 不触发 DEBUG_LIST**。因此"写零"这一步不会被 =y 拦下。风险来自**次级路径**：`binder_free_txn_fixups` 对 `fd_fixups`(@0x80) 做 `list_for_each_entry_safe+list_del`（kzalloc 时已 INIT 为空 → 原对象安全；但若重分配后再次进 free 会踩**corruption→BUG()**）；`binder_send_failed_reply` 对 target_thread->todo `list_add`、`t.c:5137 else BUG()`、`BUG_ON(from!=t->from)`（`t.c:1884`）都会在被污染的对象上 **BUG()**。→ 可行的子路径要挑**只做裸赋值**的分支（`t->from==thread → t->from=NULL`，无 list 遍历、无 BUG 邻近），能拿到"一次干净 8 字节零写"，但仍然只是零。

## 5. 最小可判别实验（仅设计，不上机/不武器化）
从 uid=2000：开 `/dev/binder`，两个线程互发**同步**事务；一个线程卡在 `BINDER_WRITE_READ` 等回复，另一线程对 target 调 `BINDER_THREAD_EXIT`（或 `close`/线程 `exit`）让 release 与对侧 `binder_send_failed_reply→kfree` 抢同一 transaction，重复 10^3–10^5 次。**判据**：因本机无 KASAN，UAF 不会自动打印；
- 若 `dmesg` 出现 PC 落在 `binder_thread_release`/`binder_free_transaction` 的 Oops / `list_del corruption` / `BUG @ binder` → 证明**窗口存在且从 uid=2000 可达**（哪怕不可控，也算可达性确认）；
- 若仅 `BR_DEAD_REPLY`/ioctl 返回 `-ESRCH/-EPROTO` 且无 oops → 说明窗口被 vendor RSC refcount 或时序掩盖，实际不可用；
- hang/softlockup（卡在对 `to_proc+0x230` 的 `_raw_spin_lock`）亦是命中信号。
全程可被 `dmesg` 观察，最坏 oops→重启（用户已预批）。**不做任何 spray/覆写**，只确认"是否可达"。

## 6. 对"降级"判定的反驳（2026-09-26 05:1x，主控补充）

上文 §1/§5 把结论定为"弱原语 ⇒ 降级为辅助"。**这个结论不成立，理由是把"值不可控"和"HID 线"错误等同了。**

- HID 线被判死的原因是 **盲 + 相邻 + 只写零** —— 关键缺陷是**地址不可选**（只能写到相邻对象、且写什么不由我方决定）。
- 本线的核心 store 是 `t->buffer->transaction = NULL`（asm `str xzr,[x8,#0x30]`，`x8 = t->buffer`）：
  只要 freed `binder_transaction` 被我们**自己新发的事务**重占（`buffer` 指针指向事务数据段内、由我们决定的偏移），
  `x8` 就是**攻击者可控地址** ⇒ 得到"**向任意选定地址写 8 个零字节**"。
- "任意地址写零"**不需要可控值**就足以完成 Android 提权收口：把 `struct cred` 的
  `uid/euid/gid/egid/fsuid/fsgid/suid/sgid`（都是 4 字节、置 0 即 root）与 `selinux_enforcing` 逐个清零即可。
  这正是 **CVE-2019-2215（buf binder）** 的原语形状，该漏洞在野利用过两次、公开利用链即用
  `t->buffer->transaction = NULL` 这一条 zero-write 完成 commit-cred 的等价效果
  （P0 与作者公开分析：UAF 在 `binder_transaction_buffer_release`/`t->buffer` 悬垂）。
- 且本机条件比 2019 更好：项目**已经**有 perf 破 KASLR ✓、KernelSnitch mm 泄漏 ✓、SLUB 喷射 ✓
  （GHOST-TRIGGER-SOLVED 已真机验证），也就是"知道往哪写"和"把槽占回来"这两块砖**已经在架上**；
  本线的写原语还**不经 list helper ⇒ 不被 DEBUG_LIST/BUG_ON_DATA_CORRUPTION 拦**（§4 自己的结论）。

⇒ **修正后的判断**：这条线不应降级；它是目前唯一"非栈、可控地址、单次 8 字节零写"的候选，
而 A 线卡死的正是"没有可用覆盖通道"。**下一步只做一件事**：按 §5 的**非武器化**实验确认
"free 窗口从 uid=2000 / app 真的可达"（最坏 oops→重启，已获用户预批），
再决定投入。风险点照实记：vendor `RSC/PEM` 插桩给 transaction 加了 `bg_work`+`__cancel_work_timer`，
可能改变 free 时序（§3 自己标了 UNVERIFIED）——这正是要用实验而不是用推理关掉的问题。


**降级为辅助，不投入多会话主线。** 决定性理由：可获得的写原语是**恒零/锁 owner 字节**，非 HID 教训所缺的"可控值写"——把 cred patch 成 uid=0 需 (a) 一个 KASLR/heap 泄漏（项目当前没有）+ (b) 精确命中 `cred->uid` 的单次清零，单发、脆弱、且 KCFI+PAN+Shadow-Call-Stack 已在。即便 64469 变种的"可控地址零写"成立，也只是"能清一个已知地址"，不改变它是弱原语的事实。它相较 GhostLock 的便宜之处（无需栈喷洒）不足以补偿"值不可控"这一硬伤。留作：若将来拿到任意地址读/泄漏，此线可作为"把某 flag/refcount 清零"的备用 one-shot，届时再评估；当前优先级排在 GhostLock 之后。


## 8. p34/p35/p36 实测与**自我纠正**（2026-09-26 08:2x–08:4x）

先记三条一手事实：

1. **`binder` 的 mmap 只接受 `PROT_READ`**：给 `PROT_WRITE`（无论 PRIVATE 还是 SHARED）都是 **EPERM(1)**；
   只读 + SHARED/PRIVATE 都可以（旧探针用 `MAP_PRIVATE`，本次 `MAP_SHARED` 也成功）。
   我第一版往只读映射里 `memset` ⇒ 自己 SIGSEGV(rc=139)，与内核无关。
2. **权威 `BR_*`/`BC_*` 表已从 v5.4.281 uapi 取到**（`include/uapi/linux/android/binder.h?h=v5.4.281`）：
   `BC_TRANSACTION = _IOW('c',0,td)`；`BR_NOOP=_IO('r',12)=0x720c`、`BR_FAILED_REPLY=_IO('r',17)=0x7211`、
   `BR_DEAD_REPLY=0x7206`、`BR_REPLY=_IOR('r',3,td)=0x80407203`、`BR_TRANSACTION_COMPLETE=0x7207`。
   内核只按 `_IOC_NR` 派发 BC_*，所以旧探针里那个 dir 位写错的 `0x40406300`（_IOR 而非 _IOW）也能用。
3. **上一轮的结论作废**：我把 `0x720c` 当成 BR_FAILED_REPLY，于是把"30µs 信号打不进阻塞、
   `ret=0` 非 EINTR"解释成"servicemanager 回得太快 ⇒ 窗口不可达"。**错**：真实回执流是
   `BR_NOOP + BR_FAILED_REPLY(0x7211)` ⇒ 事务**根本没被受理**，从来就没有 pending 状态，
   拿它测时延没有意义。p35 的 2000/400 轮全部是**空转**，不能推出"窗口不可达"。

⇒ **binder 线现在的状态是"窗口尚未被证明可达，也尚未被证伪"**，卡在一个纯工具层问题上：
我们手搓的 `checkService/addService` parcel 被 servicemanager 拒绝（FAILED_REPLY）。
下一步不是继续猜 code/flags，而是**换一条确定能挂起的路**：用真实服务句柄（先拿一个正确编码的
`checkService("package")` 回 BR_REPLY + handle），再对它发一个**慢**调用（`dump`/`listPackages` 级别，
毫秒量级），才有可操作的 pending 窗口。
另一条更快的验证：`binder_probe.c` 的**空 parcel** 版本当年拿到过 `BR_REPLY` ⇒ 说明编码差异在
`data_size/offsets` 上，先用"空 payload + 正确 code"打通一次真回执，再逐步加负载。

**方法论落点**（已同步进用户记忆）：**判据的名字标错 = 结论方向错**。凡是把返回值/事件码翻译成人类结论的
地方，必须先用一手表核过再下判断——这是继"读不到 ≠ 值为 0"之后同一类错误的第二次实例。



## 7. 上机前置事实（p32 实测 + 通道排查，2026-09-26 08:0x）

## 7. 上机前置事实（p32 实测 + 通道排查，08:0x）（注：本节在文件中位于 §8 之后，按内容读）

**(a) 本机没有任何内核日志事后通道** —— 直接否决 §5 里"看 dmesg Oops"的判据设计：
`dmesg`(klogctl) 拒绝 · `/proc/kmsg` 拒绝 · `/dev/kmsg` DAC 是 `crw-rw-r--` 但读仍被 SELinux 拒 ·
`/sys/fs/pstore/` 目录不可进 · `/proc/last_kmsg` 不存在 · `/data/vendor/log` `/mnt/vendor/log`
`/data/tombstones` 全拒 · `/data/anr` 只剩一个 09-10 旧 ANR。
⇒ **以后所有 UAF 类实验只能设计"功能级判据"（errno / BR_* 序列 / 自有进程可见状态），不能依赖内核侧日志。**
这条对整个项目通用，不只 binder 线。

**(b) 当不了服务端**：`uid=2000 / u:r:shell:s0` 下 `/dev/binder`、`/dev/hwbinder`、`/dev/binderfs/binder`、
`/dev/binderfs/hwbinder` 都能 open + `BINDER_VERSION`(pv=8) + `SET_MAX_THREADS` + `mmap(128K,RO)` **成功**，
但 `BINDER_SET_CONTEXT_MGR` 一律 **EBUSY(16)**（servicemanager / hwservicemanager 已占）；
`BINDER_SET_CONTEXT_MGR_EXT` 一律 EINVAL(22)（探针传 `type=0` 没过 `BINDER_TYPE_HANDLE` 校验，属自身缺陷；
修正后 mgr 槽已被占 ⇒ 仍是 EBUSY）。`/dev/vndbinder`、`/dev/binderfs/vndbinder` **open 就 EACCES(13)**；
`ls /dev/binderfs` 目录本身也被拒。⇒ **"一进程内自投自收"不能靠注册 context manager 达成。**

**(c) 可行的窗口构造（不需要当服务端）**：64469 的 free 侧只要求"本线程发出的**同步**事务仍 pending 时
该线程走 `binder_thread_release`" ⇒ 最小构造 = 线程 T 对 handle 0 发 `BC_TRANSACTION`（`binder_probe.c`
早已证明可发），不读回复即 `BINDER_THREAD_EXIT`。**但代价必须说清**：对端是真实 servicemanager，
窗口真被打穿时污染的是关键系统服务 ⇒ 最坏不是我们进程死，而是 **framework/zygote 连带重启、所有 app 被杀**。
更稳的对端是自己 fork 的第二个进程 + 它注册的服务，但 shell 域 `addService` 是否被 SELinux 放行 **未测**。

⇒ **在拿到功能级判据之前不要跑这个实验。** 判据候选（下一步先定这个，而不是先写代码）：
① `BINDER_THREAD_EXIT` 之后的 `close` / 下一次 `BINDER_WRITE_READ` 的 errno 与 `BR_*` 序列是否可与"无 UAF"路径区分；
② 用第二个自有进程当对端，以"N 轮后对端存活率/异常退出率"作统计判据。


## 9. p37/p37b 窗口探测：**null 结果，且设计上不成立**（记为方法教训，不是证据）

跑了一次极小冒烟（3 轮 × 并发 8，kill_delay 5ms）后判定这个实验**不能得出任何结论**，四条独立理由：

1. **判据是瞎的**：`ppid_of keymint` 从未匹配到进程（`/proc/*/cmdline` 里没有含 "keymint" 的项，
   `/vendor/bin/hw/` 下也没有 keymint 二进制）⇒ 我们根本不知道对端进程是谁，"pid 变化"这条正信号无从谈起。
2. **KeyMint 疑似懒启动/懒停止服务**：第一次 `service call` 能拿到 `Parcel(Error 0xc3)`，之后再 `service check`
   变成 `not found` ⇒ **"进程消失"是正常生命周期行为，不是被我们打崩**，混成假阳性/假阴性。
3. **负结果本就无信息量**：Android 上"进程带着 pending 同步 binder 事务被 SIGKILL"是**天天发生的常规事件**
   （任何 app 被 lmkd 杀掉时都在这条路径上）。所以"跑了 N 轮没出事"完全不区分"窗口没打开"和"窗口打开但没撞上重叠"。
4. **没有内核侧观察通道**（§7a），所以真正的命中（Oops/`list_del corruption`）看不见，只能看见设备重启。

设备状态确认：`uptime` 连续 9:52 无重启、load 正常 ⇒ 这次冒烟**没有造成损害**。

### 修正后的可行设计（下一步该做的是这个，而不是继续加大 p37 的轮数）
在**我们自己的 APK 里用两个进程**构造可控对端，把上面四个缺陷全部消掉：
- 进程 B（`android:process=":remote"`）暴露一个真实的 `IBinder`；进程 A 通过**框架 AIDL** 拿到它的代理
  ⇒ **parcel 编码由 framework 负责**，不再手搓（消掉 §8 那类 FAILED_REPLY 假象）。
- B 的 binder 方法里 `Thread.sleep(300ms)` ⇒ **我们精确控制"对端处理耗时"**，A 的同步事务因此**确定性地 pending 数百毫秒**
  ⇒ 窗口从"µs 级撞运气"变成"ms 级可控"。
- A 在 sleep 期间被 SIGKILL（或自身 pthread 退出后调 `BINDER_THREAD_EXIT`）⇒ 走 `binder_thread_release(thread->transaction != NULL)`。
- 判据变成**自有进程可见**：B 端那次调用本该收到 failure reply，若观察到 B 崩溃/tombstone 里出现 binder 路径、
  或 A 死亡后 B 侧长时间挂死/异常，即为命中；tombstone/logcat 可用 `run-as` 与 `logcat -b crash` 读 ⇒ **有真实 oracle**。
- 影响面完全关在我们自己的 app 进程里，不再碰 vendor HAL 与 system_server。

代价：要写一个两进程 + AIDL 的 APK（比 shell 脚本重，但这才是能出结论的形态）。




## 10. binder 线的最终结构性判断（2026-09-26 08:5x，主控）

把 §9 的"两进程 AIDL"设计推到底之后，发现它**并不能给出一条可操作的窗口**，原因是链路上有三处互相打架的约束：

1. **`BINDER_THREAD_EXIT` 必须"同一个 fd"**。要造 `binder_thread_release(thread->transaction != NULL)`，
   执行退出的是**发出同步事务的那个线程自己**，而且它用的必须是我们**自己 open 的 `/dev/binder` fd**
   （只有这样才能在它被 EINTR 打断后立刻对它发 `BINDER_THREAD_EXIT`）。
2. **framework 路径拿不到那个 fd**。用 `AIBinder_transact`/`bindService` 拿代理虽然编码正确，但
   (a) libbinder 的 `talkWithDriver` 内部**遇 EINTR 自己重试**，我们从外面根本打不断它；
   (b) 也没有公开接口能取出它底层 binder fd ⇒ §9 设想"编码交给 framework + 自己做 THREAD_EXIT"
       **两者不可兼得**。所以要么自己 open fd（回到手搓 parcel），要么走 framework（放弃 THREAD_EXIT）。
3. **窗口要有用就得"慢对端"，而慢对端我们从两边都造不出来**：
   - 自己注册服务（`addService`）需要**先拥有 node**，而 app 侧拿 node 的正规途径是 `bindService`
     （节点在自己进程里，但句柄在**另一个 binder proc 上下文**里，跨不到我们手搓 fd 上）；
     且 servicemanager 的 `addService` 对非 system uid 的可行性**尚未用正确编码测过**
     （p36 那次因缺 **interface token** `i32 0 + s16 android.os.IServiceManager` 而拿到 BR_FAILED_REPLY，作废）。
   - 用第三方系统服务当慢对端：要正确编码它某个**毫秒级**方法的入参（KeyMint 的 generateKey 之类），
     而且这些进程还有"懒启动/懒停止"噪声（§9 的 p37b 就栽在这上面）。

**再加上判据缺失**（本机无任何内核日志通道，命中只能表现为"对端进程重启"或"设备 oops"，
而对端 pid 变化又被懒加载污染）⇒ **每次实验的信息量极低，而编码/句柄工程是多会话量级**。

### 结论（对我自己在 §6 的反驳做一次收口）
- 我 §6 的反驳**在"原语强度"上成立**：可控地址 8 字节零写 ≠ HID 的盲相邻零写，类别上够得着 CVE-2019-2215 那条收口。
- 但**"能否从非特权上下文稳定打开足够宽的窗口"这一环，在本机比原设想贵得多**，且当前没有可信判据。
- ⇒ **正式把 binder 从"主线候选"降为"待条件满足再启"**，条件写死为三条，满足任一条即可重启此线：
  ① 拿到一次"正确编码的 `checkService` ⇒ BR_REPLY + 真句柄"（证明手搓 parcel 可控）；
  ② 证实 shell/app 能 `addService`（那就自己造慢对端，窗口宽度可任意）；
  ③ 出现一个可见的功能级 oracle（例如对端服务不是懒加载、且其崩溃能被我们稳定观测）。

### 我的建议（供选择）
把接下来的力气放回 **A 线从未系统排查的 (b)/(c)**，因为 A 线**已经有真机验证的"punch 必中"**
（链走会解引用我们伪造的 waiter）：
- **(c) 把 punch 当信息泄露通道而不是写通道**：只要能"读回"链走过程中被 deref 的地址内容，
  就把"未知 KASLR/堆布局"变成已知，而这正是 binder 零写线与所有其它线共同缺的那块砖。
- **(b) 换一条产生悬空 `pi_blocked_on` 的路径**，让悬空对象落在**可达深度**而非 `[0x288,0x298]` 的栈上
  ——例如让 `rtwaiter` 来自 `mmap` 的堆缓冲/其它 syscall 的定长栈帧，从根上绕开覆盖通道限制。



## 11. ★ 权威 binder 请求编码（p40 实测，用框架自己 marshall 出来的）

上一个子代理死在 Phase 0：它按**老式布局** `int32 0 + String16(描述符)` 发包，servicemanager 回异常，
然后它转去暴力扫 64 个 transaction code（日志里 `phase0`…`phase0f`、`code=53..64` 一片 `reply=4 word=ffffffb6`），
方向彻底走偏，59 分钟 / 98 次工具调用后连接中断，**没交报告**。教训：**编码这种东西不能靠猜，要拿框架当权威源**。

做法（可复用，零风险）：在 app 的 JNI 里用公开 API 把请求包出来再 `marshall()` 出字节 ——
`android.os.Parcel` 的 `obtain / writeInterfaceToken / writeString / marshall / recycle`。
源码 `C:/qemu_test/appdapk/jni_p40.c`，产物 `trace_p40.txt`。

`checkService("package")` 的**完整请求数据**（92 字节，小端 dword 序列）：

```
dw0 = 0x80000000
dw1 = 0xffffffff
dw2 = 0x53595354        ← 描述符哈希(Android 的 interface-hash 特性, 不是随便填的 0)
dw3 = 0x0000001a        ← 描述符长度 = 26 字符
   然后 26×UTF-16LE "android.os.IServiceManager" + NUL(2B)
dw = 0x00000007         ← 参数名长度 = 7
   然后 7×UTF-16LE "package" + NUL(2B)
尾部补齐 4 字节零
原始字节流:
00000080ffffffff545359531a00000061006e00640072006f00690064002e006f0073002e0049005300650072007600690063
0065004d0061006e00610067006500720000000000070000007000610063006b00610067006500000000000000
```

- **只有名字没有 token 的形态**（=我上一轮 p36 发的东西）是 20 字节：`07000000 70006100 63006b00 61006700 65000000` ⇒ 必被拒。
- 关键差异就是**开头那 4 个 dword**；老资料里的 `writeInt32(0)` + String16 在 Android 14 上是错的。

## 12. 另一条被否掉的悲观前提

`trace_p40.txt`：**app 域反射 `android.os.ServiceManager.getService("package")` 成功返回真 IBinder**
（`SM getService("package") → <<<< 拿到真 IBinder(app 域可用)`）。
⇒ "非特权进程拿不到服务句柄"是错的；句柄可在**框架侧**取得。
剩下的老问题依然是：**框架句柄属于 libbinder 那个 binder proc 上下文，我们自开的 raw fd 是另一个上下文，用不了它**
（这条仍未推翻）。所以 64469 实验要么 (i) 全程用 raw fd + 上面这份权威编码自己 `checkService`，
要么 (ii) 干脆不碰 binder 通道，把 binder 的**原语**留给"框架侧 handle + 我们自己的 ghost 线程"那条混合路。

下一步（已派子代理，零风险）：用第 11 节的权威字节在 raw fd 上做 `BC_TRANSACTION(code=2)`，
判据 = **解出 `BR_REPLY` 且 reply 里出现 `BINDER_TYPE_HANDLE`(0x7f77)**；拿不到就把失败点写清并停。



## 追加（2026-09-27 深夜，读 `binder_v5.4.281.c` 一手确认）：竞态的"两个进程"从哪来

`binder_open@5588` 每 open 一次就 `proc = kzalloc(...)` 新建一个 `binder_proc`（`proc->tsk`
只是指向 `current->group_leader`，那段 `binder_procs` 遍历只是分配唯一 pid 号，**不是按 mm 复用**）
⇒ **同一进程里 open 两次 /dev/binder = 两个互不相干的 binder_proc**。

这条事实带来两个后果（都是好消息）：

1. **"walker 侧与 free 侧必须不同 `inner_lock`"这个硬条件，在同一进程内就能满足**：
   walker 拿着 callee proc 的 `inner_lock`，而修复前的 `binder_free_transaction@1925` 因为
   `t->to_proc` 已被 walker 清成 NULL，**跳过 target_proc 的锁、只在 `t->lock` 下 kfree**
   ⇒ 与 walker 完全失同步 ⇒ 不需要"另一个真进程"来当 free 侧（KASAN 报告里的调用链就是这条）。
2. **但"被同步调用"仍然需要一个跨进程的 node 引用**，而 node 引用的合法传递只有两条路：
   servicemgr 注册（app/shell 都被拒）或 **Intent 携带 IBinder（自有进程之间，纯 app 级特性）**
   ⇒ 所以**"一个 APK、两个进程(`android:process=":b")"是必需且充分的最小形状**，task #17 已按此改写。

要小心的实现坑（写下来免得下次重学）：EXIT 的那个线程必须是**持有 node 的那个 binder_proc** 的线程。
JNI 里再 `open("/dev/binder")` 会得到**另一个 proc**，接不到 framework 的事务 ⇒ 正确做法是
`dlopen("libbinder.so")`（我们手里已有 `analysis/bexp/libbinder.so`）用**进程单例 `ProcessState::self()`**
（= framework 那个 fd），让自己的 native 线程 `getAndExecuteCommand()` 收下一笔同步事务，
然后**让该线程退出**（`IPCThreadState` 的 TLS 析构会发 `BINDER_THREAD_EXIT`）⇒ walker 就在带着
未回复事务的 `transaction_stack` 上跑。
