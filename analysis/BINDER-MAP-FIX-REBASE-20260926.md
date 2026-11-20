# binder 地基重做：映射形式错误 ⇒ 之前所有 binder 实验的对端都不存在（2026-09-26 19:20）

> 这一份**推翻并重建**了今晚前面所有 binder 结论的实验前提。
> 被影响的文档：`BINDER-DOUBLE-FREE-CLOSED-20260926.md`（其 §5 台账整列作废，静态部分仍有效）、
> `PATH-TO-ROOT-20260926.md` §6 作废声明里引用的动态证据。

## 1. 一手错误与一手修正

| 探针 | 用的映射 | 后果 |
|---|---|---|
| P49–P57 | `mmap(PROT_READ, MAP_PRIVATE\|MAP_ANONYMOUS, fd, 0)` | **MAP_ANONYMOUS 让内核直接建匿名映射，`binder_mmap` 从未被调用** ⇒ `proc->alloc.buffer_size=0` ⇒ 任何要落到我们进程里的 buffer 都分配不出来 ⇒ 同步事务一律 `BR_DEAD_REPLY`；`read_size>0` 时"线程 park"的观测也因此不可信 |
| P62 | 两种形式都试 | `PROT_READ + MAP_SHARED` **成功**（libbinder 的真实用法）；`PROT_READ\|PROT_WRITE + MAP_SHARED` = EPERM（P55 结论仍成立） |
| P63 | `PROT_READ + MAP_SHARED` | 立刻拿到**真正的 `BR_REPLY`（0x80407203）** ⇒ app 域裸 fd 是一个完整可用的 binder 客户端 |

⇒ **P56 的 53,925 次与 P57 的 65,518 次"竞速"从未有过活的对端**，那两个"被偷槽=0"
不是阴性结论，而是**无效实验**。我今晚已经第三次犯"把探针自伤读成被测对象性质"的错
（前两次：ashmem 的 `SET_PROT(0)`、`BC_*` 当 ioctl 用的 EACCES）。

## 2. 修正后的新地基（全部一手）

1. **BR_REPLY 记录格式**：`read buffer` 里 `BR_NOOP(0x720c)` 占 8 字节，随后
   `[u32 cmd=BR_REPLY][无 pad][struct binder_transaction_data @ +12]`；
   实测 `read_consumed = 76 = 8 + 4 + 64`。
2. **`BINDER_SET_CONTEXT_MGR` 在 4 个可访问节点上一律 `EBUSY(16)`**
   （`/dev/binder`、`/dev/binderfs/binder`、`/dev/hwbinder`、`/dev/binderfs/hwbinder`；
   `st_rdev` 显示 `/dev/binder` 与 `/dev/binderfs/binder` **是同一个设备**，`/dev/hwbinder`
   与 `/dev/binderfs/hwbinder` 同为另一设备；`/dev/vndbinder` 与 `binderfs/vndbinder` = EACCES）
   ⇒ **没有"空的 binder 上下文"可以让我们自己当 handle 0** ⇒ 自引用 bootstrap 只能靠外部进程回送。
3. **`ServiceManager.addService`（反射，2 参与 3 参重载）** ⇒
   `java.lang.SecurityException: App UIDs cannot add services.`（SM 自己按 uid 判定）
   ⇒ 与裸驱动走哪个 code 无关，**这条路按 uid 焊死**。
   （正对照：同一次运行里 `checkService("package")` 返回非空 `IBinder`，说明反射与 SM 通路本身正常。）
4. `code=2` 对 handle 0 的回复是 `data_size=4, offsets_size=0`（**只有一个 int32 状态，没有对象**）
   ⇒ code 2 **不是** checkService；真正的 `checkService/getService` code 还没定位（见 §4）。
5. **`BINDER_SET_MAX_THREADS` 之前一直传 0**，现在改传 4（P63/P64 起）。

## 3. 用**有效**实验重跑一遍的结论（P64）

形状：`{对 handle 0 发 1 条同步事务（不读回复）→ 立刻 BINDER_THREAD_EXIT}` × 3 线程，
主线程持续 240B `user.*` xattr 喷槽，每轮跑"被偷槽"审计。

| 轮 | 迭代 | 发送成功 | 喷槽 | 被偷槽 |
|---|---|---|---|---|
| 0 | 28,234 | 28,234 | 442,000 | **0** |
| 1 | 14,025 | 14,025 | 426,000 | **0** |
| 2 | 14,298 | 14,298 | 442,000 | **0** |
| 3–4 | 进行中 | — | — | — |

对照组（不触发就审计）**同为 0**。⇒ 这回是**第一次真正有对端的阴性结果**，
与 `BINDER-DOUBLE-FREE-CLOSED` §3 的静态不变式（`t` 不会同时挂在同一线程的 todo 与
`transaction_stack` 上）**互相印证**：`binder_thread_release` 家族的"线程带 pending 回复死亡"
在这台内核上**不产生二次 free**。

## 4. 因此 binder 线还剩什么（诚实清单）

- **还剩的、形状与 CVE-2026-64469 一致的那条**：释放侧必须是**进程**死亡的
  `binder_deferred_func → binder_release_work → binder_send_failed_reply → kfree(t)`，
  使用侧是**另一个进程**的 `binder_thread_release`。两端都要在我们手里 ⇒
  需要"外部进程调用我们的节点"。app 域可行的做法（按代价排序）：
  ① 同一 APK 声明 `android:process=":p2"` 的第二进程 + Intent/Service 传 `IBinder` 回送；
  ② 注册一个**真回调**（`IThermalService`/`ISensors`/`IUsageEvents` 等 app 可注册的监听器），
     让 system_server 主动调用我们的节点；
  ③ 在 `onTransact` 里对**框架自己的** binder fd 发 `BINDER_THREAD_EXIT`
     （fd 号可以从 `/proc/self/fd` 里找到 `-> /dev/binder` 那一项）——
     这样"线程带着未回复的进来的事务死亡"完全可控，不需要裸 fd。
     **③ 看起来最便宜且最直接**，因为它天然满足"进来的事务挂在我们线程的 stack+todo 上"。
- 需要先把 code 定位对（扫 1..8 找 `offsets_size>0` 的那个）。
- 之前那份"任意地址 8 字节清零写"的可得性，仍受 §BINDER-CVE-SHAPE 第 3 节的
  **纳秒级分支→store 窗口**限制；真正的收益点在"两个进程/两个 syscall"的排布上。
