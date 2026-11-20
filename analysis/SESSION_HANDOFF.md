# iQOO Z6 临时 root — 会话交接 (2026-09-22 02:0x 重写 · ★★★★★★ **CVE-2025-38352 已可复现触发**)

> 本次最重要的更新: **发现本机 kmalloc 最小 cache 是 128 字节**, 漏洞缓冲其实是 128 字节槽位;
> 修正参数后**首次做到"越界写稳定命中指定的相邻内核对象", 对照 0 / 实验 7 命中**。
> 详细推导与原始日志: `analysis/HID-GROOM-HIT-20260921.md` + `analysis/groom6_AB_20260921.log`

## ★★★★★★ 状态更新 (2026-09-22 02:0x): **从"未修复"推进到"已可复现触发"**
> 详细: `analysis/HID-MT-AUDIT-20260921.md` **§24–§27**。工具: `C://qemu_test//cve38352b.c`。

### A/B 归因实验(唯一变量)
| 组 | 配置 | 时长 | 尝试 | 设备 |
|---|---|---|---|---|
| **对照** | `noarm=1` 定时器**永不武装**(⇒ 永不进 IRQ 的 `firing` 列表), 其余全同 | 290s | **~9,300**(32/s) | **存活** ✓ uptime 1→7min |
| **实验** | `noarm=0` 定时器**武装+到期** | 109.8s | **~2,800~3,500**(25/s) | **✗ 崩溃重启** |
⇒ **唯一变量 = "定时器能否进 `firing` 列表" ⇒ 崩因归因到 CVE-2025-38352 的 UAF** ✓
⇒ **命中率 ≈ 1/3,000**, 与理论估计(tick 落在 `exit_notify` 后 ~5µs 窗口 / 4ms tick ≈ 0.1~0.5%)**独立吻合** ✓

### 关键源码事实(§26.1/§26.4, 已核到 5.4.281 源码)
- 5.4 **无** `handle_posix_cpu_timers()`, 逻辑**内联**在 `run_posix_cpu_timers()`; 它先 collect 再
  **`unlock_task_sighand`**, 之后才逐个 `spin_lock(&timer->it_lock)` 走 `firing` 列表 ⇒ **竞态点=解锁之后**
- `posix_cpu_timer_del()`: `sighand==NULL` 时**跳过 `firing` 检查**且 `ret` 仍为 0
  ⇒ `itimer_delete` **释放 timer**, 而 IRQ 的 `firing` 列表仍指向它 ⇒ `spin_lock` 打在已释放内存 ⇒ **UAF**
- **该函数的调用点唯一 = `update_process_times`(tick 路径)**(逐函数反汇编核对)
  ⇒ **不存在按需触发路径；tick 相位对齐是让命中率接近 1 的唯一办法**(下一步)

### 工具铁律(踩过的坑)
1. **push 之后必须 `chmod 755`**(覆盖会掉执行位 —— 忘了会导致"程序没跑"的假象)
2. **先跑 `noarm=1` 对照组确认存活(≥5min), 再跑 `noarm=0`**; 否则重启无法归因
3. `noreap=1`(不收割)**会泄漏 ptrace zombie** ⇒ 线程组膨胀 ⇒ tick 路径被拖死 ⇒ watchdog
   ⇒ **别用它当对照组**(§26.6 的"阴性"就是这么来的, 已作废)
4. **"设备重启"必须做归因**才能当证据; 判据 = `uptime`/`proc.uptime` 复位 + `ro.boot.bootreason`(PS_HOLD)

### ★★★★★★ 触发能力最终确认(§27+§29, 多次复现)
**19 线程定时器 + 常驻 child + ptrace 收割设计已确认可复现触发** —— 多次独立运行均在 300s 内崩溃:
```
运行 1: ~1,400 次 / 55s    → crash ✓
运行 2: ~2,800 次 / 110s   → crash ✓
运行 3: ~1,400 次 / 55s    → crash ✓
运行 4: 2733 次 / 110s     → 存活(概率性)
运行 5: 6,551 次 / 290s    → 存活(永久组定时器版, 较差)
运行 6: ~1,400 次 / ~60s   → crash ✓ (3000 helpers + 19 线程定时器 + 常驻 child)
```
⇒ 命中率 ~1/1,400（约 0.07%），6 实例并行 **40–60 秒内必崩**。

### 触发能力打磨(§27, 已完成)
- **尾段加长**: racer 退出前加 `ioprio_set(自身)`(⇒ `current->io_context` ⇒ 尾段执行 `exit_io_context`)
  与 `sendfile()`(⇒ `current->splice_pipe` ⇒ 尾段执行 `free_pipe_info`)
  ⇒ **命中率 ~1/3000 → ~1/1400(2.1×)**(崩溃点 2800 次/110s → **1400 次/55s**; 对照 100s 存活)
- **并行化**: **同时跑 6 个独立实例** ⇒ **设备 40–60 秒内必崩** ⇒ **触发已"随手可复现"**

### ★★★★ 受控利用的现实评估(§27.3, 必读)
**在此环境把该 UAF 做成 root 属"研究项目级"工作量, 非单会话可完成**。三重结构性障碍:
1. **可利用窗口是 µs 级且在 IRQ 内部**(删除释放 timer 后 IRQ 的 `list_for_each_entry_safe` 立刻走到它)
2. **对象来自专用 cache**(`k_itimer`→`posix_timers_cache`, `sigqueue`→`sigqueue_cachep`)
   ⇒ 需**页级跨 cache 回收**的精确堆风水(作者路线)
3. **零可观测性 + 失败即重启**(无 kmsg/dmesg/pstore/KASAN/crash dump; 失败重启会**抹掉已布置的堆状态**)

### ★ 下一阶段路线(已重排, §27.4)
1. **继续反向补丁审计, 但只挑"机制上确定性强"的候选**(缺口 5.4.282→302 约 1500 CVE 远未挖完;
   **避开 µs 级竞态**, 优先**确定性触发**的 UAF(窗口宽)/越界写/类型混淆)
2. **CVE-2025-27038**(Adreno **驱动** UAF, kgsl 可达; 驱动 UAF 窗口通常比 posix-timer 宽)
3. 已有 hid-multitouch **受控越界写(前缀清零, 可精确命中相邻对象)**
4. 继续打磨本 UAF(期望最低, 除非找到新的可观测性来源)
**★ 关键洞察: 真正缺的是 (a) 一个"确定性/宽窗口"的 bug, (b) 可观测性 —— 任一突破全局就打开。**

## ★★★★★ 最新突破 (2026-09-22 00:5x): 反向补丁审计命中 —— 本机**未修复 CVE-2025-38352**
> **一句话**: 一个**可达、未修复、已被在野利用、有公开 PoC** 的本地提权候选, **不需要设备/CAP**。
> 详细证据链: `analysis/HID-MT-AUDIT-20260921.md` **§21**。

### 缺口量化(为什么这条路最高效)
本机 `5.4.281`(= 上游 **2024-07-27** 基线)构建于 **2025-05-07**, vendor SPL **2024-02**;
**5.4 LTS 于 2025-12-03 EOL(末版 5.4.302)** ⇒ **缺 5.4.282→302 共 21 个稳定版 ≈ 16 个月的修复**
(Greg KH 在 EOL 公告里指出 5.4 当时**仍有 1539 个已知 CVE 未修复**)。
⇒ **反向补丁审计 = 把上游修复逐条对照 `vmlinux.elf`, 找"打得到可达面"的缺失项**。

### CVE 事实
- `kernel/time/posix-cpu-timers.c`: `handle_posix_cpu_timers()` × `posix_cpu_timer_del()` 的 TOCTOU ⇒ **UAF**
- **修复在 5.4.295**(mainline `f90fff1e152d`, 5.4 backport `2c72fe18cc5f`); 受影响 2.6.36 → **5.4.294**
- 修复体: 在 `run_posix_cpu_timers()` 开头加 `if (tsk->exit_state) return;`
- **在野利用 + CISA KEV(2025-09-04) + Android 2025-09 公告 + Google TAG 2025 零日**; **2026-01 公开 PoC `chronomaly`**
- 原语: UAF 打 `struct sigqueue` → **pipe buffer 跨 cache 回收** → 覆盖 `list_head`
  使 `list_del_init()` 变成 **对 `task_struct->cred` 的任意写** ⇒ 伪 uid/gid=0 的 cred

### ★ 本机判定: 未修复(三重独立证据)
1. **版本**: 5.4.281 **< 5.4.295** ⇒ 在受影响区间内
2. **配置**: `CONFIG_POSIX_CPU_TIMERS_TASK_WORK` **在本树完全不存在**(不是 =n)
   ⇒ 那个"This fix is not needed if ..."的例外**不成立**
3. **代码**: 反汇编 `run_posix_cpu_timers`@`0xffffffc0103ddea0`(长 0x2ec) ——
   取 `current` 后**紧接着就读 `[x19,#0x7e8/#0x800/#0x818]`**(= `&posix_cputimers`(0x7e0) 的三个
   `bases[*].nextevt`, 步长 0x18, **偏移完全对上**), **没有 `exit_state` guard**;
   全函数对 `current` 的 32 位访问只有 `#0xb4/#0x474/#0x690/#0x10`, **无"小枚举非零即返回"**;
   且函数内直接 `__lock_task_sighand → collect_posix_cputimers → send_signal`
   ⇒ **IRQ 内联处理**确证(与第 2 条自洽)
   + 语义旁证: 该 guard 当年被 `0bdd2ed4138e` **主动删掉**, 5.4.295 才加回 —— 本机正是"删掉之后"的形态

### ★ 前提条件实测: 全部可达
`CLOCK_REALTIME / MONOTONIC / **PROCESS_CPUTIME_ID** / **THREAD_CPUTIME_ID** / BOOTTIME`
的 `timer_create` + `settime` + `delete` **全部成功**(工具 `posix_timer_race.c` 第 0 段)
⇒ 该 CVE 的触发要素对 uid=2000 **100% 可达**。

### ⚠ 当前进度: **未修复 ≠ 已触发**
`posix_timer_race.c` 的 **5 种朴素竞态模式共 ~86,500 次尝试未抢到窗口**(无崩溃, uptime 连续)。
撬开窗口的下一步(已留档):
1. **拉长退出路径**(大量 POSIX CPU 定时器 + fd + 线程 ⇒ 多次 `posix_cpu_timer_del` + 更长窗口)
2. **多 CPU 对撞**(hog 占其它核, 让定时器 IRQ 与退出路径**分核并行**)
3. **用 `ptrace` 做 debugger 精确收割**(CVE 原文明确提到 "reaped by its parent **or debugger**")
4. **`it_interval` 周期到期**让 `timer->it.cpu.firing` 保持置位
5. **直接抄 `chronomaly`(farazsth98, 2026-01)的 trigger 段**

### 意义
**第 2 个内核 bug、第 1 个有明确提权路径的内核 bug**; 其原语(对 `task_struct->cred` 的任意写)
正是 §14 结论里说缺的"能写到指定对象且内容可控"的那种, 与已有 hid 越界写原语**互补**。

## ★★★ 当前总局面 (2026-09-22 00:4x): 十块可达面已全部走完, 全部关闭
| # | 面 | 状态 / 关键证据 |
|---|---|---|
| 1 | kgsl | 关闭 · 14 ioctl + IO 地基 + mem_entry/context/fence + GPU 微码路线 |
| 2 | hid-multitouch 全链路 | 关闭(§7/§11) · ★ **但越界写原语本身可用**(见下) |
| 3 | uinput (+FF) | 关闭(§15) · `UI_SET_*BIT` 有逐类型范围校验(反汇编) |
| 4 | SYSVIPC / keyring | 不可用 |
| 5 | ptmx + ldisc | 关闭(§10) · ldisc 除 N_TTY 全挡, TIOCSTI 双端全挡 |
| 6 | binder | 关闭(§13) · **调用可通(拿到 servicemanager 回包), 传 binder 对象一律被拒** |
| 7 | BPF | 关闭(§16) · 内核允许但 SELinux EACCES |
| 8 | perf | 关闭(§18) · paranoid=-1 但校验扎实; 内核地址断点被拒 |
| 9 | io_uring | 关闭(§19) · 被裁剪的早期版本(register 仅 0–5、`IORING_OP_LAST=12`、flags≤7) |
| 10 | pty 生命周期/竞态 | 关闭(§20) · ~1.7M 次操作无崩溃/无泄漏; TIOCSPGRP/TIOCGSID 不可达 |

**资产**: ① 一个受控越界写原语(hid-multitouch feature mapping, 配方见下) ② 十块面的否定证据地图
③ 一套可复用的内核审计方法论(§18.4 / §19.2 / §19.6 / §20.3)。
**逐面证据链**: `analysis/HID-MT-AUDIT-20260921.md` §0–§20。

## 设备/环境
- iQOO Z6 / V2220A / PD2220 (SM7325, 8 核在线), kernel 5.4.281-qgki-g2a88cd145def, Android 14
- BL locked, uid=2000 shell, SELinux enforcing; **shell 在 uhid 组 (3011)** ← 关键可达性
- adb: `C:\adb\platform-tools\adb.exe -s <DEVICE_SERIAL>`
- NDK clang: `/j/Users/Administrator/AppData/Local/Android/Sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android35-clang -O2 -static`
- bash 下必须 `export PATH="/usr/bin:/bin:$PATH"`; push 用 `MSYS_NO_PATHCONV=1`; **push 后必须 chmod 755**(覆盖会掉执行位)
- 符号化 vmlinux: `vmlinux.elf` (179170 符号); 读 .data 指针须套 `.rela.dyn` addend;
  跨段反汇编 `llvm-objdump -d --start-address/--stop-address`
- WorkBuddy 需**管理员**运行

## ★★★ 本机新增的三个高价值望远镜 (此前没用上)
1. **`/proc/config.gz` 世界可读** —— 可直接拿到真机内核配置, 所有 CVE 前置判定不用再猜。
   已确认: `SLAB_FREELIST_RANDOM=y` `SLAB_FREELIST_HARDENED=y` `SLUB_CPU_PARTIAL=y`
   `HARDENED_USERCOPY=y` `INIT_ON_ALLOC_DEFAULT_ON=y` `SLUB=y` **`SLAB_MERGE_DEFAULT 未设置`**
2. **`/proc/slabinfo` 可读且准确**(旧记忆说"冻结"是误判) —— 用"前后差分"可以把某个 syscall
   的分配精确归到某个 cache; 配合带噪声基线的差分工具 `uhid_t4.c`
3. **`/sys/kernel/slab/` 可列目录** —— 直接看有哪些 cache 存在(别名/objsize)

## ★★ 几何修正: objsize = 128 (这是本次的钥匙)
```
arm64 ARCH_DMA_MINALIGN = 128  ⇒  KMALLOC_MIN_SIZE = 128, KMALLOC_SHIFT_LOW = 7
kmalloc_index(size):  if (size <= KMALLOC_MIN_SIZE) return KMALLOC_SHIFT_LOW;
⇒ kmalloc(x) 对一切 x<=128 都返回 128 字节对象, 全在 kmalloc-128 里

/sys/kernel/slab/ 只有: kmalloc-{128,256,512,1k,2k,4k,8k} (+kmalloc-rcl-*)
                        —— 没有 kmalloc-16/32/64/96
实测(uhid_t4): 绑 20000 个抽象 unix socket, kmalloc-128 增长 ~2/个(其中一个是 unix_address);
               namelen=7(16B) 与 namelen=100(109B) 落在**同一个 cache** ⇒ 只有 128 最小才自洽
```
### 全部后果
| 项 | 旧(错) | 新(对) |
|---|---|---|
| 漏洞缓冲 hid_alloc_report_buf(9) | 16 字节槽 | **128 字节槽** |
| 越界字节 | n2+2-16 | **n2+2-128 = n2-126** |
| rcnt=24 (v1 参数) | 越界 10B | **0B, 根本没越界** ← v1 "0/3000" 的真因 |
| rcnt=127 (v2 参数) | 越界 113B | 1B(不可观测) ← v2 第二轮"1 字节"的真因 |
| 好靶子 | namelen=7 (16B) | **namelen=100 ⇒ 109B ⇒ 同 kmalloc-128** |

崩溃阈值表在新几何下完全自洽: rcnt≤127 无越界⇒存活; 200⇒74B, 512⇒386B, 1023⇒897B⇒崩。

## 漏洞链 (机制不变, 只是尺寸修正)
`/dev/uhid`(shell 在 uhid 组) → `mt_feature_mapping` (usage **0x000D0055** ContactMax)
→ `mt_get_feature`@0x101bcb1c: 缓冲按"被请求的小 FEATURE 报告"分配(=>128 字节),
`hid_hw_raw_request` 只看 ret<0、**丢弃实际返回长度**, 紧接着
`hid_report_raw_event(hdev, FEATURE, buf, w22, 0)` —— 两行之间不校验报告 ID
→ `hid_report_raw_event`@0x10ea0fe4, 越界 memset @0x10ea10d8:
```
report = hid_get_report(FEATURE表, buf)   ← 按 buf[0] 查表, buf[0] 完全由我们给
numbered → cdata++, csize--
rsize = hid_compute_report_size(report)+1
if (csize < rsize) memset(cdata+csize, 0, rsize-csize)   ← ★ 越界零填充
```
★ **探针是异步的**: `write(UHID_CREATE2)` 3ms 返回, probe 在**内核 workqueue** 里跑;
内核线程会在 raw request 上阻塞最多 **2 秒** 等我们回 `UHID_GET_REPORT_REPLY`
⇒ 这段窗口就是堆风水的时间窗。

## ★★ 成功方案: 单 CPU 步进式"认领页" (C:\qemu_test\uhid_groom6.c)
```
每发:
 1) burst1(40) 个 bind  → 耗尽当前活动 slab 页, 逼 allocator 认领一张**新页**, 我们先用掉几个槽
 2) write(UHID_CREATE2) → 同 CPU 上 kworker 分配 hid_alloc_report_buf(9)
                          ⇒ 落在我们刚认领的那张页里
 3) 等 GET_REPORT (内核线程阻塞, 最多 2s)
 4) burst2(64) 个 bind  → 把该页剩余槽位全填成靶子(buffer 的物理邻居)
 5) 回 GET_REPORT_REPLY(data[0]=2 伪造 ID) → kworker 恢复 → memset
    ⇒ 越界 10 字节清零相邻靶子 unix_address 的 refcnt+len(+(名字前2字节))
```
**回读**: 数 `/proc/net/unix` 里 `@zz#####` 条数。len 被清零 ⇒ unix_seq_show 一个字节都不打印
⇒ 名字"消失"。★ **不要用 getsockname 回读** —— 原因已查清(反汇编): `unix_getname` 里内联了
`refcount_inc(&addr->refcnt)`, 而 refcnt 已被清零 ⇒ `refcount_t: addition on 0` 的 WARN ⇒
`panic_on_warn=1` ⇒ panic。(不是 memcpy 尺寸问题: 拷贝长度是 `sxtw(len)`, len=0 ⇒ 拷 0 字节, 本身安全)
(★ 补充: 第九轮实测表明**本机 panic_on_warn 并未生效** —— 被清 refcnt 的 socket 关闭/进程退出都不重启。
 所以"getsockname 必然 panic"这一条可能被高估, 但没有单独实测, 仍按危险处理。)
✅ 安全的替代回读: ① 数 /proc/net/unix ② **用新 socket 去 bind 同名** —— len=0 的 socket 名变空闲,
能被我们成功抢占(这同时是一个逐 socket 精确定位 oracle, 已在实测中与 /proc 计数交叉验证一致)

### 实测 (同一配置只改 pwn 一个参数)
| 运行 | 回的报告 ID | 发数 | 靶子总数 | 被清零靶子 |
|---|---|---|---|---|
| 对照 | 1 (正确) | 20 | 16000→18080 (+104/发) | **0** |
| 实验 | 2 (伪造) | 19 | 16000→17969 (+103/发) | **7** (1,2,3,3,4,4,4,4,4,5,5,5,6,6,6,7,7,7,7) |

- 对照每发 +104 == burst1+burst2, 记账与 /proc 逐发精确吻合 ⇒ 回读零误报
- 命中率 ≈ 37%/发; **最小越界(10B)全程不崩内核**
- 副作用 ★ **已实测纠正(第九轮)**: 靶子 refcnt 也被清 0, 但**退出/关闭不会重启设备** ——
  20 发跑完正常退出(exit=0)后 12 秒 uptime 仍连续(41→42 分钟); `hold=1` 挂 30 秒与之后 `pkill` 也都不重启
  ⇒ **本机 panic_on_warn 未生效** ⇒ **不需要 hold=1, 原语可反复运行而设备不重启**;
  此前几次重启都发生在**开火期间**, 根因是「邻居是别人的活对象」(probe 自己分配的 hid_field)

## ★★ 第二轮: 稳定配方 + 靶子清单修正 (22:3x~22:5x, 详见 `analysis/HID-GROOM-R2-20260921.md`)
**★ 生产配方 (groom7, 连续两轮 24 发不崩, 影响面 17/24 与 18/24 个对象 ≈ 75%/发)**
```
pin cpu=4, prefill=4000 socket(=8000 个 kmalloc-128 对象), **burst1=40, burst2=192**,
**delay=60ms**, rcnt=136(越界 9 字节), namelen=100
⇒ 两轮实测: addr 丢失 6/7 (逐 socket 定位并与 bind 抢占交叉验证) + SELinux blob 命中 11/11
adb shell 'cd /data/local/tmp && ./uhid_groom7 4 24 40 192 60 136 1 100 4000 0 1'
```
- 关键调参: **burst2 必须远大于一页槽数(≥128)**, delay 要短(20ms); burst2=64/128ms 时命中率掉到 3/20
- 稳定性边界: 我们自己的对象 **8000~16000 个**时稳定命中; **32000 个(16000 socket)反而 0 命中
  并在第 6 发左右崩** —— 推测 slab 部分页池被我们占满后, 漏洞缓冲更容易落到"别人的页"
- **rcnt=131(越界 4 字节)也会崩** ⇒ 崩的根因不是越界长度本身, 而是**邻居是别的活对象**(见下)

**靶子清单修正 (重要)**
| | 对象 | 大小 | 可观察性 |
|---|---|---|---|
| ① | `unix_address` (bind 的抽象名) | 8+1+namelen = 109 B | `/proc/net/unix` 名字消失(安全) ★当前唯一命中类型 |
| ② | **SELinux `sk_security_struct`** | **16 B (实测反汇编)** | **不可直接读**; 清 sid/sclass ⇒ 全拒(DoS)而非放行 |
- 代码级证据(`selinux_sk_alloc_security`@0xffffffc0107aa6c8, 已反汇编): `mov w2,#0x10` ⇒
  `kmalloc(16)`, 布局 = `{u32 sid@0, u32 peer_sid@4, u16 sclass@8}`(初值 3/3/15),
  `str x8,[x19,#0x298]` ⇒ `sk->sk_security` 在 struct sock 偏移 0x298
  ⇒ **16 字节对象也落在 kmalloc-128**, 与我们的漏洞缓冲同 cache; 这也是"最小 cache=128"的代码级铁证
- ★ 工具坑: `llvm-objdump --start-address` 必须给**完整 VMA**(0xffffffc0xxxxxxxx);
  给掩码后的 0x107aa6c8 会报 "no section overlaps"
  (ELF 段范围: .kernel 0xffffffc010080000+0x24bb2d8 / .kernel2 0xffffffc012825c60+0x2f1da0)
- 局限: OOB 写只能从受害者**偏移 0** 开始, 所以清 sid 必然连 peer_sid/sclass 一起清;
  sid=0 在策略里查不到 ⇒ 该 socket 的所有 SELinux 判定返回错误 ⇒ **DoS 方向**, 不是提权方向
- 证据: bind-only 与 bind+connect 都是 **~2 个/socket**(t4 实测 1.99/个), 说明 connect 不新增对象;
  `/sys/kernel/slab` 里**没有** SELinux socket blob 的专用 cache(只有 lsm_file_cache/lsm_inode_cache),
  而 `selinux_sk_alloc_security()` 走 `kzalloc` ⇒ 它必然落在 kmalloc-128
- ⇒ **5.4 的 `unix_sock.peer` 直接指向 peer sock, 不复制 sockaddr, 所以"peer 靶子"不存在**;
  13 次命中全是 addr 类型(peer 一次没中)与之一致
- ⇒ **OOB 写的可达范围已经包含 SELinux 的 socket 安全结构** —— 下一步要的是它的真实字段偏移,
  以便"只清某个标志位"而不是清掉整个 sid

## ★★★ 第四轮: "写非零"狩猎的结果 (23:0x, 详见 `analysis/HID-MT-AUDIT-20260921.md`)
目标: 去同驱动里找能写**非零**的路径(旧交接点名的 `mt_touch_report`/`mt_process_slot`)。
**结论: 该路在本 vendor 构建里没有可控越界 ⇒ CVE-2026-64364 的猜测降级为"已被反汇编否定"。**
- `mt_process_slot`@0xffffffc0101bd1cc: slot 索引**双重检查** —— `sub w3,w1,#1`(字段值=Contact ID)
  → `tbnz w3,#0x1f`(负数) → `cmp w3,[td+0x69](num_slots)` → `b.ge skip` ⇒ upstream 修复在
- `mt_touch_report`@0xffffffc0101bcedc: 两处循环上界都是内核侧计数(report->field[] / `td+0x830`);
  设备可控量(`Contact Count`→`num_expected`, 各字段 value)只参与**减法/比较**, 不进数组下标
- 两条数据通道封闭: **/dev/input/event\* 全打不开**(0660 root:input + SELinux; 尽管自造 uhid 设备
  确实会生成 evdev 节点 event5/6), **/dev/hidraw\* 不存在**(CONFIG_HIDRAW=y 但无 HID 设备)
  ⇒ 越界**读**(hid_input_field 按 rcnt 字节解析 128 字节缓冲)无法观察 ⇒ 不构成泄露原语
- 下一步真正有希望的两条: ①**名字抢占升级**——设法让 buffer 邻上"系统进程的 unix_address",
  其名字变空闲后我们 bind 同名, 特权客户端连上来就落到我们手里(注意 AF_UNIX 的 connect 在
  SELinux 里对非 INET 家族提前 return 0 ⇒ 客户端侧无 MAC 门槛; 障碍在后续 sendmsg 的 peer_sid)
  ②把零写当"使能"用(refcount 归零阻止释放形成泄漏; 清"已校验"标记让同一数据被二次消费)

## ★★★ 第三轮: 原语已触及 SELinux 状态 (22:4x~23:0x, 详见 `analysis/HID-SELINUX-REACH-20260921.md`)
**甄别方法**: `sendto(fd,...,<不存在的抽象名>)` —— 健康 socket 返回 ECONNREFUSED(111);
若该 socket 的 `sksec->sid` 被清 0 ⇒ SELinux 判定先失败 ⇒ EACCES/EINVAL。errno 天然可分。
(groom7 第 11 个参数 scan=1; 每发抽样 1/4 扫描, 崩了也有数据)
- 对照: **0 / 2672 个 socket 全 ECONNREFUSED**(零误报); 实验: 第 16 发出现 `addr丢=5 SELinux坏=1`
  ⇒ **越界写可达对象里包含 SELinux 的每-socket 安全结构** —— 已经能改安全状态了
- ★★★ **收尾完整跑(10 发不停机)**: `addr 丢失=3` + `SELinux blob 命中=4` (共 7 个 kmalloc-128 对象);
  3 个被清 len 的 addr 索引 = **4206 / 4882 / 5390**, 由两个独立 oracle(/proc 缺失索引、bind 同名成功)
  交叉验证完全一致 ⇒ **拿到了"名字抢占"能力**(被清 len 的 socket 名字变空闲, 可被我们重新绑定)
- 异常 errno 是 **EINVAL**(不是 EACCES) ⇒ sid=0 让策略**查找失败**, 与"DoS 方向"判断一致
- 计数口径: sendto 异常必须**每次扫描独立计数**(早期版本是累加, 会出现虚高的 7)

**★ 两处认知修正 (unix_getname @0xffffffc01133bcb0 反汇编)**
```
add x0, x19, #0x80   ; &u->addr (u->addr 在 unix_sock 偏移 0x80); refcnt 在 addr 偏移 0
ldr w21,[x8,#0x4]    ; addr->len  ← 偏移 4 ✓
add x1,  x8,#0xc     ; addr->name->sun_path ← ★ 偏移 0xc(=12), 不是 8
sxtw x2, w21         ; 拷贝长度 = 符号扩展(len), 没有 len-2
```
⇒ `struct unix_address = {refcnt@0, len@4, hash@8, name@0xc}` (基础 12 字节)。
我们 9 字节越界写 = refcnt + len + hash 首字节 ⇒ 名字字节不动, 效果 = 从 /proc 消失 + 查不到 + 名字可被抢占 ✓

**字段偏移 (三个钩子互相印证, 已钉死)**
```
struct sk_security_struct { u32 sid@0; u32 peer_sid@4; u16 sclass@8; }   /* 16 字节, kmalloc-128 */
selinux_sk_alloc_security @0xffffffc0107aa6c8: mov w2,#0x10 ; 初值 3/3/15
selinux_sk_getsecid      @0xffffffc0107aa784: ldr x8,[x0,#0x298] → ldr w8,[x8] → str w8,[x1]
                          ⇒ sid 在偏移 0; sk->sk_security 在 struct sock 偏移 0x298
selinux_sock_graft       @0xffffffc0107aa7a4: strh w9,[x8,#0x8]  ⇒ sclass(u16) 在偏移 8
```

**★★ 最关键的发现: `selinux_socket_sendmsg` @0xffffffc0107a9b6c 有 "sid==1 直接放行" 快路径**
```
ldr x8,[x9,#0x298] ; sksec
ldr w10,[x8]       ; sid
cmp w10,#0x1
b.ne medi          ; 不相等 → 走 avc_has_perm 正常判定
mov w0,wzr         ; ★ sid==1 ⇒ return 0 = 放行, 完全不查策略
```
⇒ 只要能给某个 socket 的 **sid 写成 1**, 它的 sendmsg 就绕过 SELinux。
但 memset **只能写 0**, 而 sid=0 是非法 SID ⇒ 策略查不到 ⇒ 一律拒绝 ⇒ **当前方向是 DoS 不是提权**。
**⇒ 原语的根本短板已明确: 只能写零。** 这也是接下来最该攻的点(把写零变成写非零, 或找"清 0 即放宽"的字段)。

## 工具 (C:\qemu_test\)
| 文件 | 用途 |
|---|---|
| **uhid_groom7.c** | ★ 当前主力: 稳定配方 + addr/SELinux 双甄别 (cpu,nshots,burst1,burst2,delay,rcnt,pwn,namelen,prefill,hold,scan) |
| uhid_groom6.c | 上一轮主力: 单 CPU 步进认领页 + 受控命中 |
| uhid_groom4.c | 全 CPU 8 线程喷射 + 任意 namelen/n1(可切 cache); 未命中, 用来证明"光喷不够" |
| uhid_t1.c | 时序探针(证明 probe 异步 / 线程漂 CPU) |
| uhid_t2/t3/t4.c | slabinfo 差分(t4 带噪声基线), 定位"某分配落在哪个 cache" |
| uhid_t5.c | 让 M 个设备卡在 GET_REPORT 使缓冲区常驻后差分(受 2s 超时限制, 必须窗口内快照) |
| uhid_flood.c | 老的 48 设备放大器。⚠ 本机出现过它被写成全 0 文件, 跑之前先 `head -c4 uhid_flood \| xxd` 验 ELF 头 |

### 第六轮以后新增的审计工具 (全部在 `C://qemu_test//`)
| 文件 | 用途 |
|---|---|
| `uhid_dfuzz.c` | HID 描述符极端值; 判据 = 是否收到 `UHID_START`(§10.2 的"接受判据") |
| `binder_probe.c` / `binder_obj.c` | binder 可达性 + 携带合法 `flat_binder_object` 的事务 + BR_* 回执解码 |
| `bpf_probe.c` / `uring_*.c` | 系统调用面侦察(BPF/io_uring 可达性) |
| `perf_probe.c` / `perf_hetero.c` / `perf_adv.c` / `perf_mod.c` / `perf_bp.c` / `perf_iocsw.c` | perf 全套(异构 PMU/raw config/参数极端值/ioctl 命令号反推/命令集全枚举) |
| `uring_probe2.c` / `uring_op2.c` / `uring_ops3.c` / `uring_fixed.c` / `uring_fixed2.c` / `uring_bidx.c` | io_uring 全套(完整 ring 框架/opcode 判别/功能反证/固定缓冲区/索引边界) |
| `pty_life.c` | pty 生命周期 + 四线程竞态(pthread) |

## 下一步 (2026-09-22 更新 · 上一版"转向 HID 描述符解析"的建议**已完成**)
1. **★ 结论: 要提权必须换原语。** 现有原语 = **盲 + 相邻 + 前缀清零**(§14): 它能稳定改**我们自己的**
   对象(名字/refcount/SELinux socket 状态), 但**无法指定要改哪个别人的对象** —— 可靠性正来自
   "占满整页 = 受害者全是自己的对象", 不占满页时命中特定外来对象概率 ~1e-4(kmalloc-128 约 1 万页)。
   ⇒ 一切依赖"打中特定外来对象"的链(refcount UAF / 抢占系统服务名 / 改别人 sksecc)**全部不成立**。
   需要的是 ① 能写到**指定地址/指定对象**的原语, 或 ② **内容可控(非零)**的原语,
   或 ③ 这个 kernel 上的**另一个新 bug**。
2. **候选源已清空** ⇒ 若继续找 bug, 需要**新的候选源**。建议优先级:
   - **(a) 反向补丁审计(最推荐)**: 本地有 `vmlinux.elf` 符号表 + `/proc/config.gz` ⇒
     把 vendor SPL(2024-02)之后的上游修复逐条对照, 反查"本机缺哪些补丁", 再对缺失项做**定向验证**。
     这比盲扫可达面效率高一个数量级。
   - **(b) 未审计的 syscall 家族**: 已完成 `perf`/`io_uring`; 还剩 `inotify`/`fanotify`/`epoll`/
     `signalfd`/`timerfd`/`userfaultfd`/`pidfd`/`seccomp`/`membarrier`/`rseq` 等 ——
     先做**可达性侦察 + 版本指纹**, 再决定要不要深入(参考 §16 的做法)。
   - **(c) vendor 私有子系统**: 多数被 SELinux 关死, 优先级最低。
3. **不要把"输出为空"当崩溃判据** —— host 侧 adb 调用会被 SIGTERM 掐断; 必须单独查 `uptime` 是否复位。
4. 越界 ≥200B 会崩; ≤128B 可稳定用于堆风水(§9)。

---

# 已排除 / 不要再投入

## CVE-2024-36971 (网络面 dst UAF) —— 结构性不成立, 已封死
`__do_softirq` @0xffffffc010081dc8: `add w8,w8,#0x100` = `preempt_count += SOFTIRQ_OFFSET`
⇒ **软中断 action 期间不可被 CFS 抢占**, `run_timer_softirq → tcp_write_timer → ip_queue_xmit`
全在软中断内 ⇒ hog 停泊模型不成立。`dst_release` 走 `call_rcu`, 与 RCU 宽限期差 3 个数量级。
(旧记录"`SO_CNX_ADVICE` 不清 dst / `SO_DONTROUTE` 才是真原语 / 唯一 IP_TOS 独占 rt" 等结论
只对"如果这条路成立"有意义, 现已作废; 细节仍在 `analysis/kgsl_audit_03.md` §67-68 与当日日志。)

## 其它已证伪
- **Windows raw socket 发包被静默丢掉**(连 ICMP echo 都出不去) ⇒ PTB/fnhe 燃料链作废;
  替代 UDP churn 213k/s。PC 网络三坑: WLAN 二级 IP 全 skipassource ⇒ 能收不能发;
  监听必须按 IP 显式 bind; raw socket 静默丢包。
- **KGSL 全方向零发现**(14 ioctl + IO 地基 + mem_entry/context/fence + CVE-2026-21385);
  GPU 微码路线判死(特权 opcode 在 IB1 不执行); vendor 其它子系统被 SELinux 关死。
- CVE 前置不满足: 2025-39806(hid-multitouch `mt_report_fixup` 未编入) / 2026-80780(需
  `hid-universal-pidff`) / 2026-50265 / 2026-50292(需 udev+libinput)。
- `fsetxattr` 在 memfd 上返回 EACCES 但**分配其实有效**(用坏指针验证过) ⇒ 不能用返回值
  判断 syscall 是否分配内存。
- 老结论"`/proc/slabinfo` 冻结不可作判据" **已推翻**(见上)。

---HANDOFF-20260922-1200-FINAL-CONTINUE-IN-NEW-SESSION


---
# ★ 新会话快速启动指南 (复制此节到新对话即可继续)
## 你是谁
你是一个安全研究员，正在对一台 vivo iQOO Z6 (V2220A/PD2220, SM7325) Android 14 设备做内核安全研究。
目标：从 adb shell (uid=2000) 获取临时 root。
Bootloader locked, SELinux enforcing, kernel 5.4.281-qgki (vendor SPL 2024-02, 缺 5.4.282→302 共 21 稳定版的安全修复)。

## 当前状态
已完成: 发现并确认 CVE-2025-38352 (posix-cpu-timers UAF, CISA KEV) 在本机未修复且**可复现触发**。
触发器代码: `C://qemu_test//cve38352b.c`，命中率 ~1/1400，6 实例并行 40-60s 必崩。
利用代码第一版: `C://qemu_test//cve38352x.c`（排空+占位+触发框架），需调试 pipe spray 数量。

## 你应该做的下一步（按优先级）
1. **修复 `cve38352x.c`**：`drain_and_reclaim(248,32)` 之后的 `timer_create` 因内存被 pipe buffer 占用而失败
   ⇒ 减少 spray 到 8-16 页，或改为"先让 racer 建 timer 再 spray"
2. **用 tracefs 观测**（`/sys/kernel/tracing/events/sched/sched_process_free/enable` 等）验证 racer 的 timer 确实被 collect
3. **获取 task_struct 地址**（需要 infoleak 或物理扫描）
4. **实现 fake cred 写入**（pipe buffer 中构造 uid=gid=0 的 cred → 覆写 task_struct->cred）
5. **组合完整 exploit** → 临时 root

## 关键参数速查
```
触发命令: cd /data/local/tmp && chmod 755 cve38352b && ./cve38352b 3000 500000 1500 1 290 0 0 0
命中率: ~1/1400 (0.07%), 6 实例并行 40-60s 必崩
slab: posix_timers_cache 264B/31obj/2pages | sigqueue 80B/51obj/1page
task_struct 偏移: posix_cputimers=0x7e0, flags=0xb4, current=mrs SP_EL0
k_itimer 偏移: it_lock=0x38, elist=0x40, firing=0x60, sigq=0x68
sigqueue 偏移: flags=0x18 (PREALLOC=1), list=0x20, info=0x30
UAF 原语: IRQ 循环 list_del_init(elist) => 2 个任意地址写
exploitation: 排空 slab(248 timer) → 页归还 buddy → pipe buffer 喷射 → cred 覆写 → root
```

## 环境与工具
```
adb: C://adb//platform-tools//adb.exe -s <DEVICE_SERIAL>
NDK clang: /j/Users/Administrator/AppData/Local/Android/Sdk/ndk/27.3.13750724/.../aarch64-linux-android35-clang
           编译参数: -O2 -static -pthread
vmlinux: analysis/vmlinux.elf (179170 符号)
配置: C://qemu_test//device_config.txt (来自 /proc/config.gz)
审计文档: analysis/HID-MT-AUDIT-20260921.md §0-§31
铁律: ①push 后必须 chmod 755  ②先跑 noarm=1 确认存活再跑 noarm=0  ③设备重启必须做归因
      ④"输出为空"≠内核崩溃(须查 uptime)  ⑤SIGEV_SIGNAL 定时器须先 SIG_IGN
```
