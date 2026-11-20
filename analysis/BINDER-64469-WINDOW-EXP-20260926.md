# BINDER CVE-2026-64469 窗口实验 — 2026-09-26（iQOO Z6 / 5.4.281-qgki / uid=2000）

判定：**Phase 0 门未过 ⇒ Phase 2 未执行（0/8 次）⇒ 本轮结论 = 构造不成立（非阴性，是机制侧不成立）**。设备未重启、未受任何影响。

## ① Phase 0：parcel 编码门

先纠正环境坑（重要，会误导后续会话）：`adb shell 'cat > /data/local/tmp/x'` **会截断二进制**（2 225 840 B → 25 995 B，且谎报成功）。本次改用 `MSYS_NO_PATHCONV=1 adb push` + 之后必须 `chmod 755`（push 覆盖会丢 exec 位，报 `can't execute: Permission denied`），md5 两侧一致。

逐字段的确切发法（已验证能被内核接受）：
- `BINDER_WRITE_READ`，`write_buffer = [u32 BC_TRANSACTION][struct binder_transaction_data]`（本 build `sizeof=64`）：`target.handle=0`、`cookie=0`、`code=N`、`flags=TF_ACCEPT_FDS(0x10)`、`sender_pid/euid=0`（内核自己覆写）、`data_size`、`offsets_size=0`、`data.ptr.buffer=堆指针`（**发出方向不必在 mmap 内**，实测可用）、`data.ptr.offsets=0`；`read_buffer` 也在堆上，回复数据由内核放进 `PROT_READ` 的 mmap 区。
- Parcel：`int32 0`(strict-mode policy) `[+可选 uint32 stability]` + `String16("android.os.IServiceManager")`（`int32 charcount` + `(count+1)` 个 UTF-16LE unit + 补到 4 对齐）+ 参数。
- 收尾必须 `BC_FREE_BUFFER`（payload = 回复 buffer 指针）。

结果：**拿到真 `BR_NOOP + BR_TRANSACTION_COMPLETE + BR_REPLY(0x80407203)`**，且 reply 是被 dispatch 的：`code=0` 与 `code≥15` 返回 4 字节 `0xffffffb6`（`-EBADMSG` = `STATUS_UNKNOWN_TRANSACTION`），`code=1..14` 全部返回 4 字节 **`0x80000001` = `STATUS_UNKNOWN_ERROR+1` = `STATUS_BAD_TYPE`**（见 NDK `android/binder_status.h`）。Android 14 的 `android.os.IServiceManager` 恰有 13–14 个方法（`libbinder.so` 里 `AIDL::cpp::IServiceManager::{addService,getService,checkService,listServices,registerForNotifications,unregisterForNotifications,tryUnregisterService,isDeclared,getDeclaredInstances,getUpdatableNames,getConnectionInfo,getServiceDebugInfo,registerClientCallback}`；descriptor 是 UTF-16 常量，已用 python 从 `libbinder.so` 扫出，确认字符串无误）。

即：`STATUS_BAD_TYPE` 恒等于 servicemanager 的 **interface-token / stability 校验（或 leftover-data 检查）在读参数之前就失败**，与 name、code、前缀都无关。变体覆盖：15 种 layout（policy±stability × descriptor UTF-16/UTF-8 × name UTF-16/UTF-8 无NUL/带NUL补位 × 无 token）× code 0..14 × 5 个 name × 19 个 stability 值（0/1/2/3/4/5/6/7/8/A/C/E/F/78/F0/780/1F0/80/100/1000），>500 次**只读**调用，**从未出现 `offsets_size>0` 或 `BINDER_TYPE_HANDLE`**。控制组：`service check package` = found、`service list` = 327 services，说明是"我们手搓的 parcel"这一层过不去，而不是身份/SELinux（自身域 `u:r:shell:s0`）。`/dev/vndbinder` 对 shell 是 EACCES，无法做 vndservicemanager 对照；NDK r27 sysroot 无 `android/binder_manager.h`，`AServiceManager_checkService` 对照也没做成。**按指示：门未过即 STOP。**

副产品（有价值的机制观测 + 源码依据）：`binder_ioctl_write_read@5208` 只在 `read_size>0` 时才调 `binder_thread_read`。实测第一版工具（read_size>0 但只取到 TRANSACTION_COMPLETE）ioctl **立即返回、不阻塞**，即"调用方线程被同步事务卡住 ⇒ 无法自己调 `BINDER_THREAD_EXIT`"这一约束，可以用 **write-only BINDER_WRITE_READ（read_size=0）流水线发同步调用**绕过。机制问题本身解决了。

## ② Phase 1：v5.4.281 源码结论（`analysis/binder_v5.4.281.c`，完整，md5 三次一致）

`binder_thread_release@5094` 只遍历 **`thread->transaction_stack`@5116**（全程持 `proc->inner_lock`，逐项持 `t->lock`），两类事务被判失败/清理：
- **to-branch（我线程是被调方）**`5135-5142`：`t->to_proc=NULL; t->to_thread=NULL; t->buffer->transaction=NULL; t->buffer=NULL; t=t->to_parent`；栈顶那个另存为 `send_reply`，在 `inner_lock` 释放后经 `5177 binder_send_failed_reply(send_reply, BR_DEAD_REPLY)` 处理。
- **from-branch（我线程是调用方）**`5144-5145`：`t->from=NULL; t=t->from_parent`。
- `thread->todo` 由 `5178 binder_release_work` 处理 → `BINDER_WORK_TRANSACTION → binder_cleanup_transaction@2007`：有 `target_node` 且非 one-way 才 `binder_send_failed_reply`，否则**直接 `binder_free_transaction`（无任何锁）**。
- **one-way 方案 = 不成立**：`3402-3405 if (!reply && !(tr->flags & TF_ONE_WAY)) t->from = thread; else t->from = NULL;`，且压栈只发生在 `3798/3810-3811` 的非 one-way 分支。one-way 事务 `t->from==NULL`、不进发送方 stack，只躺在 target 的 `proc/thread->todo`、`node->async_todo` 里；目标进程死亡时 `binder_deferred_func→binder_release_work→cleanup→free` 把它释放，但那一刻**我们的退出线程对它零引用** → 无重叠。"busy 单线程 target + one-way 队列积压"这个候选被源码否决。
- **真正落在 freed 对象上的 store**：to-branch 里 `t->to_proc = NULL (5136)` **之后**还要碰同一对象：`t->buffer->transaction = NULL`（写）、`t->buffer = NULL`（写）、读 `t->to_parent`、以及 `5148 spin_unlock(&last_t->lock)`（对 `t->lock@0x98` 的写）。而 free 侧 `binder_free_transaction@1925` 是在**无锁下读 `t->to_proc`**（修复 `114a116aaa5f` 正是把这一行包进 `spin_lock(&t->lock)`，patch 文本已核对）；一旦 to_proc 已被清成 NULL，该函数跳过 `binder_inner_proc_lock(target_proc)`，`kfree(t)` 与 walker 完全失同步——与 commit 的 KASAN（"Write of size 8 … binder_thread_release+0x5d0 / Freed by … binder_release_work→binder_send_failed_reply→binder_free_transaction→kfree"）完全一致。from-branch 相对被保护：reply 路径 `3785-3797` 的 `target_thread->is_dead` 检查与 `binder_pop_transaction_ilocked` 都在发送方 `inner_lock` 内，与 walker 互斥。
- **blast radius / target 选择**：不适用。要把 (a) walker 在 to-branch + (b) 另一 CPU 无锁 free 同时凑齐，uid=2000 必须**能收到同步调用**（即持有 binder node）：`BINDER_SET_CONTEXT_MGR(_EXT)`=EBUSY、`addService` 明令禁止、`/dev/vndbinder` EACCES、binderfs 只有 binder/hwbinder/vndbinder 三个已被占用的设备、系统服务的回调注册属于越界且风险自行升级。因此没有选定 target，也没有跑任何 race。

## ③ Phase 2 记录

**未执行，尝试 0/8。** 未调用 `BINDER_THREAD_EXIT`，未做 kmalloc-256 refill（socket/sendmsg），未创建 pre-crash 日志文件（没有需要预写的风险 ioctl）。逐次记录表：空。
最终判定：**构造不成立**（Phase 0 门未过是独立、先行的停线理由）。

## ④ 这条线还值不值得投

不值得：除非先获得"能让 uid=2000 接收 binder 调用"的落点（root、可 `addService`、或 vendor 白名单回调），CVE-2026-64469 在本机只能停在"pre-fix 代码确实在、但从 shell 侧凑不出并发失同步的两条腿"，预算应转向写原语可控的方向（如 GhostLock）。

## ⑤ 设备最终状态

`/proc/uptime = 53221.66 330989.50`（会话开始时 49758.22，单调递增 ⇒ **未重启**）；`boot_id = 9b8ace4b-b08a-4ba0-8e5a-eecfc0446292`；`servicemanager` pid 714、`system_server` pid 1592 全程存活；SPL `2025-04-01`，Android 14 / vivo 14.1；`getenforce=Enforcing`。全程只做了只读 binder 查询与 `BINDER_VERSION`(protocol=8)。

产物：`analysis/bexp/{binder_util.h, phase0.c, phase0b.c, phase0c.c, phase0d.c, phase0e.c, phase0f.c, ndkcheck.c, include/linux/android/binder.h}`、`analysis/binder_v5.4.281.c`、`analysis/bexp/libbinder.so`（从设备 pull，用于 descriptor 取证）。
