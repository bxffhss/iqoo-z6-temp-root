# 可达面翻案 + GhostLock 定位 (2026-09-26 凌晨, Day 80)

> ## ⚠️ 09-26 04:5x 自我纠正（读错入口文档导致的重复劳动）
> 本会话开局读的是 `HANDOVER-20260925.md`，**没有先读真正的现状入口 `CONTINUE_HERE.md` /
> `CURRENT-STATUS.md` / `GAP-TO-ROOT-20260924.md`**，于是把 GhostLock 当成"本晚最高价值的新发现"。
> 事实是项目早已推进到：**pselect ghost 真机 errno 35 ✓、perf 破 KASLR ✓、KernelSnitch mm 泄漏 ✓、SLUB 喷射 ✓**，
> 卡点是**栈覆盖通道结构性不可达**（需覆盖深度 [0x288,0x298]，而所有直连栈写通道上限 ≈0x210；32 位 compat 亦证伪），
> 见 `GAP-TO-ROOT-20260924.md` §2 与 `GHOST-TRIGGER-SOLVED-20260924.md` §14。
> ⇒ 本文 §4 的"存在性证据"与 `p26_gl` 检测器**是重复确认，不必再跑**（信号已知，且有 oops 风险）。
> ⇒ 本文真正的净新增只有：§11 P30 入口面终表、§15 **binder CVE-2026-64468/64469 未修**
>    （项目此前从未考虑这条，`grep` 过全部文档确认）、§11/§6 ION heap 边界与 ashmem 改号、§11 CVE-2024-46740 已修。
>    其中 **binder 那对正对应 `GAP-TO-ROOT` §2 的选项 (a)"找一个非栈的写通道"** —— 堆上 UAF + Write of size 8。
> 教训已写进记忆：**动笔前先读 CONTINUE_HERE / CURRENT-STATUS**，别拿 HANDOVER 当现状。

承接 `KGSL-NOEXEC-P0-20260925.md` §12(kgsl 判死)。本文记录三件事：

① P22 的"app 能打开 /dev/ion"是**探测器的假阳性**，真实结论不同；② 用静态分析纠正 ioctl 号之后，
**/dev/ion 与 /dev/ashmem 都被证明是活的 app 可达内核面**；③ 本晚最高价值：找到 **CVE-2026-43499
(rtmutex `remove_waiter` 栈 UAF, "GhostLock")** 在本机的存在性证据，且它的入口 syscall 在 untrusted_app 域全部可达。

---

## 1. P22 假阳性的翻案(方法论教训)

`jni_p22.c:45-47` 是 `open(O_RDWR)` 失败后**回退** `open(O_RDONLY)`，而打印行不记录用的是哪一次。
于是 `/dev/ion` 被记成 `OPEN=ok`，我据此写下"ion 从 app 可读写"的结论 —— 错。实测(P23/P24)：

| 节点 | DAC | O_RDWR | O_RDONLY |
|---|---|---|---|
| `/dev/ion` | `crw-rw-r-- system:system` mode 664 | **-13 EACCES**(app 不在 gid 1000) | OK(fd=85) |
| `/dev/ashmem` | `crw-rw-rw- root:root` | OK | OK |
| `/dev/kgsl-3d0` | `crw-rw-rw-` | OK | OK |

app 侧身份实测：`u:r:untrusted_app_27:s0:c172,c256,c512,c768`，uid/gid 10172，
groups `9997 20172 50172 99909997`，`CapEff=0`，`Seccomp=2`。**没有** system/ion 组 ⇒ 写不进去。

> 铁律补充：**探测程序凡是"换 flag 重试后成功"，必须在结果里写出成功的那次用的是什么 flag。**

## 2. ioctl 号被厂商改过 —— 之前"全 ENOTTY/全 EINVAL"是猜错号码

静态分析(`ION-ASHMEM-STATIC-20260926.md`，子代理做，黑盒数据完全吻合)：

- `ion_ioctl@0xffffffc010edea68`：magic **'I'(0x49) 而不是上游 'i'**；先查 `_IOC_SIZE>24 → -EINVAL`
  (这正是我们整片 EINVAL 的来源)，只认 3 条完整 cmd，default 是 **-ENOTTY**。
- `ashmem_ioctl@0xffffffc010eee780`：magic **'w'(0x77)**；上游 `ASHMEM_*`(type 'A') 全部落到 default。

实测确认(P27，app 域，`/dev/ion` 用 **O_RDONLY** 的 fd)：

```
_IOR('I',9,4) = 0x80044909            → ret=0, out=2
_IOWR('I',8,24)= 0xc0184908 HEAP_QUERY → ret=0, 9 个 heap:
   system / secure_display / secure_heap / qsecom / user_contig / audio_ml / display / qsecom_ta / ion_system_heap
_IOWR('I',0,24)= 0xc0184900 ALLOC
   结构 {u64 len; u32 heap_id_mask; u32 flags; u32 fd_out}  ← 没有 align 字段, 与上游不同
   mask=1<<0(system) len=4096 → ret=0 fd_out=86 ; fstat size=4096 mode=600  ★成功★
   mmap(dbuf,8192) → EINVAL(申请长度 > buffer 4096; 下次用 4096 重试)
```

⇒ **结论：untrusted_app 可以在一个只读 ion fd 上分配 dma-buf**，handler 里 `filp` 从未被解引用
(无 `FMODE_WRITE`/`capable()`/uid 检查)，唯一门槛是 SELinux 的 `chr_file:ioctl`——实测放行。
secure/qsecom/audio_ml/display 这些 heap 是否也能从 app 分配 = **需要立刻验证的安全边界问题**
(QC 语义上 secure heap 不该给 untrusted_app)。

ashmem 侧(P27)：

```
SET_SIZE(arg 直接是数值!) 0x40087703 → ret=0
SET_NAME 0x41007701 → ret=0 ; GET_NAME 0x81007702 → 'poc-ash'
SET_PROT 0x40087705 → ret=0
mmap(fd,4096,RW,SHARED) → -1 EPERM      ← 单独立了一道 map 闸
对照组: 新 fd 不 SET_SIZE 直接 mmap → EINVAL(与 ashmem_mmap@0x10eeed38 的 size==0 分支一致)
```

⇒ ashmem 的 ioctl 表活着(厂商改号)，但 **app 拿不到映射**；PIN/UNPIN/`read_iter` 还没测到
(P27 把它们放在 `mmap 成功` 分支里，被跳过了)。价值降级为"可分配内核侧对象 + 可读"，不是映射原语。

## 3. syscall 可达性矩阵(P25，untrusted_app)

```
futex WAKE                0
futex LOCK_PI             0        ★ PI futex 子系统对 app 开着
futex UNLOCK_PI           0
futex WAIT_REQUEUE_PI     -1 ETIMEDOUT / EAGAIN   ★ 代理锁路径可达
futex CMP_REQUEUE_PI      0        ★ requeue-PI 可达(漏洞入口)
futex REQUEUE             0
pselect6                  0        (栈喷洒原料)
prctl SET_NAME            0 ; prctl SET_MM_MAP → EPERM(能力门)
socket(AF_INET,DGRAM)     EPERM    ← 本 app 无 INTERNET 权限
socket(AF_UNIX,DGRAM)     OK       ← sk_buff 喷洒仍可用
sched_setattr             -1 (errno 未映射, 需重测) ; sched_getattr EINVAL(结构体尺寸)
userfaultfd               ENOSYS(被 seccomp 挡) ; bpf EACCES
```

## 4. GhostLock = CVE-2026-43499，本机存在性证据

上游修复 `3bfdc63936dd`(v7.1-rc1) 原文核验(git.kernel.org)，修复前代码就是
`remove_waiter()` 里 `current->pi_blocked_on = NULL;` + 链走传 `current`，注释补的是
*"When invoked from rt_mutex_start_proxy_lock() waiter->task != current !"*。
backport 只到 6.1.175/6.6.140/6.12.86/6.18.27/7.0.4，**5.4 已 EOL(5.4.302, 2025-12-03) ⇒ 从未修**。

本机反汇编(子代理，`GHOSTLOCK-PRESENCE-20260926.md`)：`remove_waiter` **没被内联**，独立符号
`0xffffffc010378d58`；`task_struct.pi_lock=+0x91c`、`pi_blocked_on=+0x940`；函数体内**完全没有**
`waiter->task` 的装载，`pi_lock` 基址与 `str xzr,[x20,#0x940]` 都用 `x20 = current`(`mrs SP_EL0`)，
尾部 `rt_mutex_adjust_prio_chain` 的第 6 参也传 `x20` ⇒ **修复前的形态，判定 VULNERABLE(~95%)**。
`CONFIG_FUTEX_PI=y`、`rt_mutex_start_proxy_lock/__rt_mutex_start_proxy_lock/rt_mutex_wait_proxy_lock/
futex_wait_requeue_pi/futex_requeue` 符号齐全 ⇒ 代理锁路径编译在内。

触发是**确定性的、不需要竞争**：`FUTEX_CMP_REQUEUE_PI` 在 requeuer 栈上放 `rtwaiter` 并替睡眠者 p 抢
PI 锁；PI 的 owner O 正阻塞在 p 持有的 C 上 ⇒ 链走成环 ⇒ `-EDEADLK` ⇒ 回滚 `remove_waiter` 清错任务
⇒ p 带着指向 R 已退出栈帧的指针回到用户态。检测器：p 随后对全新 futex 发 `FUTEX_LOCK_PI`，
`futex_lock_pi()` 开头 `if (current->pi_blocked_on) return -EDEADLK;` **只判空不解引用** ⇒ 返回
EDEADLK(35) 即为悬垂指针证据。程序 `C:/qemu_test/appdapk/p26_ghostlock.c`(已编好 `p26_gl`,静态 arm64)。
风险：检测之后 p 的 `pi_blocked_on` 仍是脏值，内核若走到解引用它的路径可能 oops ⇒ **设备可能重启**。

缓解措施实测(`analysis/devinfo/config-5.4.281-qgki.txt`, `/proc/config.gz` app 可读)：
`CFI_CLANG=y(+SHADOW)`、SHADOW_CALL_STACK 可用、STACKPROTECTOR、SW_TTBR0_PAN、PTR_AUTH、`RANDOMIZE_BASE=y`、
4K 页 VA39；**没有** KASAN、**没有** RANDOMIZE_KSTACK_OFFSET(5.4 还不认识这个缓解 ⇒ 栈偏移可预测，对攻击者有利)；
`DEVMEM 未编`、`/proc/kallsyms` 从 shell 不可读、`CONFIG_USER_NS` 不存在(所以 netns+userns 类链全废)、
`CRYPTO_USER_API*`/`AF_VSOCK` 未编。

## 5. 候选 CVE 复核(另一子代理，口径=先看 5.4 存在性再看可达性)

关键纠正：**SPL 不是判据，内核版本才是**。ASB 的 Kernel LTS 行要求 5.4 机型 ≥**5.4.284**(ASB 2025-05)
与 ≥**5.4.292**(ASB 2025-12)，本机 **5.4.281** 两条都不满足 ⇒ 未修面 = 5.4.282…5.4.302 的全部回移。
- **CVE-2024-46740** binder `offsets overwrite` UAF(5.4.284 才修, `drivers/android/binder_alloc.c`)：
  ASB 2025-05 对 Android-12/5.4 机型的要求项，**untrusted_app 零特权天然可达 /dev/binder**，真 UAF。
  与 GhostLock 同级优先，需要先在 vmlinux 里确认补丁缺失。
- FastRPC/adsprpc 簇(CVE-2025-21485/21486/27056/47351 等)：节点从 app 是 EACCES ⇒ 除非换域否则作废。
- CVE-2023-52935 khugepaged `->anon_vma` race(5.4.299 才回移)：`TRANSPARENT_HUGEPAGE_MADVISE=y` ⇒ 可达性成立，纯 syscall。
- CVE-2025-38079(algif_hash 双释放)/CVE-2025-38618(vsock)/CVE-2025-38500(xfrm,userns)：CONFIG 不在 ⇒ **本机不适用**。
- CVE-2025-21479/27038/21480(Adreno, SPL 2025-06)：SPL 2025-04 ⇒ 未修；但按 §12 的结论，app 拿不到 GPU 执行，
  若漏洞在 ioctl 软件路径仍需单独定位 —— 优先级低于上面几条。

## 6. P28 实测：ION 从 app 的 heap 边界(★这是本晚第二条独立结论★)

`/dev/ion` 用 **O_RDONLY** 的 fd，逐 bit 分配 4096 并对返回的 dma-buf fd 做 `mmap(RW,SHARED)`：

| heap(bit) | ALLOC | CPU mmap |
|---|---|---|
| 0 `system` | ✅ fd | ✅ 写读回一致；1MB 也能分配+映射 |
| 1 **`secure_display`** | ✅ fd | ✅ |
| 2 `secure_heap` | ❌ ENODEV | - |
| 3 **`qsecom`** | ✅ fd | ✅ |
| 4 `user_contig` | ❌ ENODEV | - |
| 5 **`audio_ml`** | ✅ fd | ✅ |
| 6 **`display`** | ✅ fd | ✅ |
| 7 **`qsecom_ta`** | ✅ fd | ✅ |
| 8 `ion_system_heap` | ❌ ENODEV | - |

⇒ **untrusted_app 可以从 `qsecom` / `qsecom_ta` / `secure_display` / `display` / `audio_ml` 这些
系统级/TEE 相邻 heap 拿到内存并 CPU 读写**。这本身就是一条值得单独上报的边界违规
(它们语义上不该对 untrusted_app 开放)，同时给了我方一个**比 ashmem 更好用的原语**：
可控、可 CPU 映射、可 1MB 大小的内核侧缓冲 ⇒ GhostLock/binder 链里的 groom/spray 落点。

ashmem 侧(P28)：`SET_SIZE(65536)` ✅，但 `PIN/UNPIN`(0x40087707/08) 两种结构都 **EINVAL**、
`read(fd)` **EBADF**、`SET_PROT(≠0)` **EINVAL**，且**任何 mmap 形态(RW/RO/PRIVATE)都是 EPERM**
⇒ 厂商版 ashmem 给 app 单独焊死了映射路径；`SET_PROT(0)` 成功但无帮助。
**判定：ashmem 对 app = ioctl 表活着但拿不到内存映射，降级为次要面；映射原语改用 ION。**

## 7. GhostLock 一手资料定位(子代理，`GHOSTLOCK-REFS-20260926.md`)

Nebula "IonStack" 三部曲：Part I = CVE-2026-10702(Firefox IonMonkey JIT, 浏览器入口，与本链无关)；
**Part II = GhostLock 的 kernelCTF/x86_64**；**Part III = "Rooting Android 17 with GhostLock"**
(实测机型含 Pixel 10 / S25U / **vivo PD2405** / Moto G05 / Redmi K80 Ultra —— 有 vivo 先例)。
公开 PoC 路径 `NebuSec/CyberMeowfia/IonStack/CVE-2026-43499/poc/poc.c`(文件内容本次未能取到, UNVERIFIED)。

链的形态(照 Part III)：dangling `pi_blocked_on` → `pselect` 的 fd_set 位图回收栈帧 → 伪造 waiter 藏在
`sk_buff` → `tree/pi_tree` 的 rb_erase 受限写 → `boot_id` sysctl 改指拿 KASLR 泄漏 → **ashmem→configfs
`file_operations` 替换** → 内核任意读写 → 剥 seccomp / 换 cred / 清零 SELinux enforcing。
对本机的适配要点：① Part III 用 ashmem 作落点，而本机 ashmem 不能 mmap ⇒ 换 ION dma-buf；
② 本机是 5.4，**不存在 `randomize_kstack_offset`**(5.18+ 才有) ⇒ 栈喷洒命中率应显著优于作者 Android17 的
1/8~1.5%；③ 但 `RANDSTRUCT` 偏移需用本机 vmlinux 重算，且 kCFI+SCS+PAN+PAC 全在；
④ `PR_SET_MM_MAP` 需 CAP_SYS_RESOURCE(Part II 用法)本机不可 ⇒ 只能走 pselect 那条(Part III 已证可行)；
⑤ 我们的 app **没有 INTERNET 权限所以 AF_INET 被 SELinux 拒**，但 AF_UNIX 可用；作者的 sk_buff 走
loopback IPv6 UDP ⇒ 直接在 manifest 里加 `ACCESS_INTERNET` 即可(untrusted_app 带该权限就有 tcp_socket)。

## 9. P29 实测：ION 页池**没有**残留泄漏；AF_INET 打通

给 APK 加 `ACCESS_INTERNET`(普通权限, 自签包直接生效)后：`socket(AF_INET/AF_INET6, SOCK_DGRAM)` **成功**
⇒ GhostLock 链里的 `sk_buff` 落点条件具备（`sendto(UDP 127.0.0.1:40041,4096)` 返回 -1, errno 未被
ename 表覆盖, 需下轮补映射；注意即便 sendto 失败, 内核也已经分配过 sk_buff）。

ION 残留数据测试（脏化 24×4096 → unmap+close → 再取 24 块**只读**）：
`system / display / qsecom / qsecom_ta / secure_display / audio_ml` 六个 heap 全部
**非零缓冲=0、我方脏标记=0、内核样指针=0**。原因在配置里就写着：
**`CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y`**（`INIT_ON_FREE` 未开但分配即清零）⇒ **页池这条路不是泄漏源**，
不必再花成本；KASLR 泄漏要另找（Part III 走 `boot_id` sysctl 改指那条）。
注：栈页不受此开关影响 ⇒ GhostLock 的栈帧回收喷洒仍然可行。

## 10. 本轮的处置纪律

2026-09-26 03:2x 就"是否立刻在真机跑确定性触发+检测器"征询用户，**未获答复** ⇒ 未执行任何有状态的内核触发。
检测器 `p26_gl`(静态 arm64, 已编译) 与结论保真设计（每行 fsync）就绪，等批准。


## 11. CVE-2024-46740 判定：**已修**（binder offsets-overwrite 关闭）

子代理静态核验（`BINDER-CVE-2024-46740-20260926.md`，~90% 置信）：补丁只有 **1 行**
`object_offset > tr->data_size ||`，加在 **`drivers/android/binder.c` 的 `binder_transaction()`**
（不是 binder_alloc.c）里遍历 offsets 的那个循环；5.4.y 回移 `5a32bfd23022` 落在 **5.4.284**
（内容级核对：v5.4.281/282/283 无、v5.4.284 起有）。本机 `binder_transaction@0xffffffc010f57838`
偏移 `+0x2e84` 处能看到那三指令指纹：`ldr x8,[x24,#0x20]`(`tr->data_size`) / `cmp x3,x8` /
`b.hi → 错误尾(0x10f5b180: w22=-0xE, return_error_line=0x114b)` ⇒ **guard 在，app 打不到**。

**这条把判据彻底校准了**：该 CVE 属 ASB **2024-11** Kernel 表，而本机 SPL=**2025-04-01** 已覆盖 2024-11
⇒ vivo 确实按 ASB 内核表 cherry-pick 了（哪怕基线版本还是 5.4.281）。所以：

| 修复所属 ASB 月 | 相对 SPL 2025-04 | 本机状态 |
|---|---|---|
| ≤ 2025-04 | 已覆盖 | **默认已修**（个别可抽查） |
| ≥ 2025-05 | 未覆盖 | 默认未修（如 5.4.284/5.4.292 那批 Kernel LTS 要求项） |
| 从未进 ASB（上游修于 5.4.y EOL 之后） | 无从覆盖 | **必然未修** ← GhostLock 属这类 |

⇒ 最高性价比的搜索空间收窄成一句话：**"上游在 2025-12(5.4 EOL)之后才修、且 untrusted_app 零特权可达"的 bug**。
CVE-2026-43499 正好落在这个集合的中心。


## 12. P30：app 域入口面终表（SIGSYS 安全网让一次探针跑完不被截断）

给探针装 `SA_SIGINFO` 的 SIGSYS 处理器 + `sigsetjmp/siglongjmp` 后，app 里可以安全地把
所有"可能被 seccomp 判死刑"的 syscall 一次测完（崩溃点变成一行日志，`si_code=1=SYS_SECCOMP` + `si_syscall`）。

| 入口 | 结果 | 对候选 CVE 的影响 |
|---|---|---|
| `keyctl` 219 / `add_key` 217 | **SIGSYS 杀** | CVE-2026-74567(keyring 越界读) **从 app 作废** |
| `io_uring_setup` 425 | **SIGSYS 杀** | io_uring 整面作废（`CONFIG_IO_URING=y` 也没用） |
| `kcmp` 272 / `move_pages` 239 / `mbind` 235 | **SIGSYS 杀** | NUMA 定向喷洒不可用 |
| `perf_event_open` | **-1 errno=14 EFAULT**(NULL attr) | ⇒ **perf 从 app 是通的**，属意外收获，后续单独摸 |
| `process_vm_writev(self)` | **ret=8 开放** | 自进程写，价值一般 |
| `userfaultfd` / `bpf` | 38 ENOSYS / 13 EACCES | 判死（与 P25 一致） |
| `AF_NETLINK/NETLINK_ROUTE` | fd 可建，`bind` **EACCES** | 半开 |
| `NETLINK_SOCK_DIAG` / `AF_TIPC` / `AF_ALG` / `AF_NFC` / `AF_KEY` / `AF_PACKET` / `AF_CAN` / `AF_BLUETOOTH` / `AF_XDP` | **EACCES** | **CVE-2026-64563(rhashtable: 需 sock_diag 或 TIPC) 从 app 作废** |
| `AF_INET6/DGRAM` | **开放** | CVE-2026-31415 入口 |
| `AF_INET6/RAW` / `AF_INET/RAW` | errno=1 EPERM | 无 raw 能力 |
| `AF_RXRPC` | 97 EAFNOSUPPORT | 未编，符合 CONFIG |
| `setsockopt(TCP_MD5SIG)` | 92 ENOPROTOOPT? (实测 92) | 6xx 那条 TCP_MD5SIG 候选从 app 不可用 |
| `sendto(UDP 127.0.0.1)` / `sendto(UDP [::1])` | **ret=16 两次都成功** | loopback v4/v6 真通 ⇒ sk_buff 与 IPv6 cmsg 两条路都实打实可用 |

⇒ 收窄后的活跃候选只剩三条：**GhostLock(futex，确定性栈 UAF，主链)**、
**CVE-2026-31415(IPv6 sendmsg cmsg `__u16` 回绕，单 syscall 零竞争，入口已实测)**、
**binder CVE-2026-64468/69 对（判定中）**。其余 2026 集合项被 seccomp/SELinux/CONFIG 结构性砍掉。

（`TCP_MD5SIG` 的 92 = `ENOPROTOOPT`；说明该 build 的 TCP 未开 MD5SIG 支持，与 CONFIG_TCP_MD5SIG 一致。）

## 14. CVE-2026-31415（IPv6 cmsg 回绕）：码在，**但对 app 关闭**

子代理静态判定（`IPV6-CVE-2026-31415-20260926.md`，一手源已核）：
补丁 `4e453375561f`(Eric Dumazet, 2026-04-01, `Fixes: 333fad5364d6`/2005) 的做法不是加硬上限，
而是 `if (opt->dst1opt) opt->opt_flen -= ipv6_optlen(opt->dst1opt);`；回移 5.10.253/5.15.203/6.1.168/
6.6.134/6.12.81/6.18.22/6.19.12/7.0，**5.4 无**，且 v5.4.302 源码里仍是裸 `+=` ⇒ 存在性确证。
本机反汇编铁证：`ip6_datagram_send_ctl@0xffffffc011387ca0` 处
`ldrh w10,[x28,#0x8]` → `add w9,w10,w9` → **`strh w9,[x28,#0x8]`**（16 位半字累加，无先前回减）。

**但它不是我们的目标**，两条独立否决理由：
1. 该 `IPV6_DSTOPTS` 分支入口是 `ns_capable(net->user_ns, CAP_NET_RAW)`
   （源码 `datagram.c:899` + 反汇编 `mov w0,#0xd; bl ns_capable; tbz → -EPERM` 双向确认），
   **untrusted_app 没有 CAP_NET_RAW 且本机 `CONFIG_USER_NS` 未开** ⇒ P30 那条 loopback `sendto` 成功
   只证明"普通 UDP 通"，不证明"带 cmsg 的分支进得去"。
2. 即便进去，上限是 `skb_push()` 在 `memcpy` 之前 `skb_under_panic()/BUG()` ⇒ **纯 DoS，不是可控 OOB 写**
   （CNA 与作者均只标 DoS）。

⇒ **作废**。教训：net 系候选必须逐个查 **per-option 的 CAP_NET_RAW / ns_capable 闸**，
"能建 AF_INET6 + loopback 通"不等于"cmsg 分支可达"。



## 15. binder CVE-2026-64468 / 64469：**两条都判 VULNERABLE，app 原生通道**

裁决报告 `BINDER-2026-64468-64469-20260926.md`。补丁（Carlos Llamas，作者日 2026-06-19，合入 2026-07-03，`Cc: stable`）：

- `114a116aaa5f` = **CVE-2026-64469** "binder: fix UAF in binder_thread_release()"，`Fixes: 7a4408c6bd3e`；
  改法就是把 `struct binder_proc *target_proc = t->to_proc;` 这一行**包进 `spin_lock(&t->lock)`**。
- `f223d27a546c` = **CVE-2026-64468** "binder: fix UAF in binder_free_transaction()"，`Fixes: a370003cc301`，
  `Reported-by: Alice Ryhl`；用 `atomic_inc(&target_thread->tmp_ref)` 钉住 `t->to_thread`。
  它是 114a116 的**子提交**（上下文里已含 114a116 的 hunk）。
- 回移矩阵（逐 tag 独立核对，两者都是各分支 binder.c 的最顶两条）：5.10.261 / 5.15.212 / 6.1.178 / 6.6.145 /
  6.12.96 / 6.18.39 / 7.1.4 / mainline 7.2。**5.4.y 最后一笔 binder.c 是 2025-10-29，分支终点 v5.4.302=2025-12-03** ⇒ 结构上收不到。

我自己的两条独立抽查（不只看子代理）：
1. 本机 `binder_free_transaction@0xffffffc010f5eff8` 的**第一条实质指令**就是 `ldr x22,[x0,#0x38]`（`t->to_proc`），
   前后都没有 `spin_lock([t,#0x98])`；后面那次 `_raw_spin_lock(x22+0x230)` 锁的是 **`proc->inner_lock`**，
   不是补丁所要求的 `t->lock` ⇒ **正是 114a116 删除前的那一行**。（前一版子代理说"比上游更旧"是不准的，就是 pre-fix 本体。）
2. CVE 记录一手确认存在：`cveawg.mitre.org/api/cve/CVE-2026-64469` 标题 = "binder: fix UAF in binder_thread_release()"。

⇒ **本晚结论：现在是两条并行主线**
① **GhostLock**（rtmutex 确定性栈 UAF；要 pselect 栈回收 + KASLR 泄漏；有 Android 公开链）；
② **binder 64468/64469**（`binder_transaction` 在 kmalloc-192 里的 slab UAF + "Write of size 8"；
入口 `/dev/binder` 是 **app 零特权天然通道**，喷/收都在自己进程内，**不需要栈喷洒也不需要 KASLR 泄漏就能拿到写**）——
从工程代价看 ② 很可能比 ① 便宜，值得作为并行的第二条。
（两条的"触发"都有 oops 风险，动之前都要批准。）



## 16. 下一步(2026-09-26 04:4x 更新)

1. **跑 `p26_gl` 检测器** —— 等用户批准（见 §10）。
2. ~~CVE-2024-46740 binder offsets-overwrite 静态核验~~ ✅ **已做，结论=已修，关闭**（见 §11）。
   顺带把判据校准成"修于 5.4.y EOL 之后 + app 零特权可达"这一条收窄的搜索空间。
3. ION 原语工程化：把可用 heap 的分配+映射封成可复用 spray 例程；测 binder 传 dma-buf fd 与 `DMA_BUF_IOCTL_SYNC`。
4. ~~manifest 补 `ACCESS_INTERNET`~~ ✅ 已做并已验证 AF_INET/AF_INET6 可建 socket（§9）。
5. 补 `sendto` 的 errno 映射（101 ENETUNREACH / 113 EHOSTUNREACH / 13 EACCES…），确认 loopback UDP 真能发出去。
6. `kgsl` 线维持判死；工具链 `build.sh/install.sh/read.sh` 已加 force-stop 后启动（避免存活进程导致探针不重跑）。




## 13. ★★ 自我纠正：ashmem 对 app **可用**（P44 实测，推翻本文 §2/§6 的"mmap 被 EPERM 焊死"）

本文前面所有"ashmem 的 mmap 一律 EPERM ⇒ 降级为次要面"的结论**是错的**，错因是探针自己的调用顺序。

**静态侧其实早就给了答案**（`ION-ASHMEM-STATIC-20260926.md`）：`ashmem_mmap@0xffffffc010eeed38` 的 EPERM 分支在
`0xeeeda0`，条件只有 `if ((vma->vm_flags & ~area->prot_mask) & 0x7)`（`prot_mask` 在 `area+0x130`），
**里面没有 `capable()`、没有 uid、没有 SELinux** ⇒ 它是 PROT 语义闸，不是权限闸。

**P44（app 域 `untrusted_app_27`，每步都用全新 fd）**：

| 测试 | 结果 |
|---|---|
| T1 `SET_SIZE(64K)` → `mmap(RW,SHARED)`，**完全不碰 SET_PROT** | **★成功★**，写读回一致 |
| T1 → `mprotect(RWX)` | **ret=0** ⇒ app 可拿到 **W+X** 内存 |
| T1b 同一 fd 二次映射(RO) | 成功，且与第一次**内容一致**（同一 shmem 对象 ⇒ 有别名语义） |
| T2 不 SET_SIZE 直接 mmap | EINVAL(22)（=静态分析的 `area->size==0` 分支，对得上） |
| T3 `SET_SIZE` → `SET_PROT(v)` → mmap | v=0/1/2/4 → **EPERM**；v=3(READ\|WRITE)/7 → **仍成功** |
| T5 `open(O_RDONLY)` → SET_SIZE → mmap(RO) | 见 `trace_p44.txt` |

**我之前的两个错误**：① P27/P28 的顺序是 `SET_SIZE → SET_NAME → SET_PROT(0) → mmap`，
`SET_PROT(0)` 自己把 `prot_mask` 清零，于是撞上那条 EPERM，被我读成"驱动给 app 单独焊死映射"；
② P28 里 `SET_PROT(1/2/3/7)` 全回 EINVAL，被我读成"厂商只接受 0"——实际是**已建立映射之后不允许再改 prot**
（全新 fd 上这些值全部 ret=0，见 P44/T3）。

**对项目的影响（正向）**：`/dev/ashmem` 在 app 域就是可用的内核侧可映射缓冲，且**能升执行权限、能拿第二个别名**
⇒ 并发会话 P42 提的 `ashmem → configfs file_operations 替换` 这条写通道，**其 ashmem 前置成立**。
本文 §2/§6 中"ashmem 不可用/降级"的字样以本节为准。
（ION 那条边界违规结论不受影响，两者独立。）

**方法论（第 3 次同类错误，必须记住）**：判据被自己前一步的调用制造出来 ——
"读不到 ≠ 值为 0"、"回退重试成功 ≠ 原意图成功"、**"我调过的 setter 会让后面的观测变成假的"**。
凡是"A 设置 → B 观测"的实验，**A 和 B 都必须各自有对照组，且 A 要能单独关掉**。


