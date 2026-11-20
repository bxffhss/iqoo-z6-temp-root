# GHOSTLOCK-REFS (CVE-2026-43499 / IonStack) — 一手资料汇总
生成:2026-09-26 | 目标设备:vivo iQOO Z6 (PD2220), Android 14, 5.4.281-qgki (msm-5.4, SM7325), SPL 2025-04-01, 起点 `untrusted_app` / `shell`

## 0. 资料源清单
- IonStack Part II:https://nebusec.ai/research/ionstack-part-2 (公开日期 2026-07-07,标题:"GhostLock, a stack-UAF that has existed in ALL Linux distributions for 15 years")
- IonStack Part III:https://nebusec.ai/research/ionstack-part-3/ ("Rooting Android 17 with GhostLock")
- IonStack Part I:https://nebusec.ai/research/ionstack-part-1-cve-2026-10702/ — **注意:Part I 是 Firefox SpiderMonkey IonMonkey JIT 缺陷 CVE-2026-10702(`MObjectToIterator` alias-set 不健全 → GVN 消除 → UAF,`addrof`/`fakeobj`),与 rtmutex 无关**,属于浏览器入口点。Firefox 151.0.3 修复。
- 索引:https://nebusec.ai/research/ — **没有 Part IV**;CVE-2026-43501 "Route of Root"(https://nebusec.ai/research/cve-2026-43501-route-of-root/)是另一个 kernelCTF bug,不属 IonStack 链。
- CVE 记录:https://nebusec.ai/buglist/CVE-2026-43499/ — 描述 "a 15-year rtmutex/futex-PI stack use-after-free, from unprivileged syscalls to root",范围 2.6.39-rc1→7.1-rc1,严重级 HIGH。
- PoC:https://github.com/NebuSec/CyberMeowfia/tree/main/IonStack/CVE-2026-43499 与 .../poc/poc.c(WebFetch 未能取到源码正文 → 源码级细节 **UNVERIFIED**)。社区移植:fork https://github.com/theVakhovskeIsTaken/CyberMeowfia 、https://github.com/MhmRdd/CyberMeowfia/tree/lamu-perf-kaslr-leak 、Samsung https://github.com/BuSung-dev/Root-My-Galaxy 、https://github.com/BuSung-dev/CVE-2026-43501-S25U(实际为 S25U/6.6 路径,`UNVERIFIED`)。
- 上游提交:引入 `8161239a8bcc` (https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=8161239a8bcc);修复 `3bfdc63936dd4773109b7b8c280c0f3b5ae7d349` (https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/commit/?id=3bfdc63936dd4773109b7b8c280c0f3b5ae7d349)。
- v5.4 源码:https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/kernel/locking/rtmutex.c?h=v5.4.281
- 版本/EOL:https://ubuntu.com/security/CVE-2026-43499 ;https://endoflife.date/linux

## 1. remove_waiter() 的缺陷语句(已用 v5.4.281 源码核实)
v5.4.281 中(v5.4 文件同上 URL,逐字):
```
raw_spin_lock(&current->pi_lock);
rt_mutex_dequeue(lock, waiter);
current->pi_blocked_on = NULL;
raw_spin_unlock(&current->pi_lock);
...
rt_mutex_adjust_prio_chain(owner, RT_MUTEX_MIN_CHAINWALK, lock, next_lock, NULL, current);
```
修复 `3bfdc63936dd`(Keenan Dong,2026-04-08,"rtmutex: Use waiter::task instead of current in remove_waiter()",`Fixes: 8161239a8bcc`,`Cc: stable@vger.kernel.org`):
```
struct task_struct *waiter_task = waiter->task;
- raw_spin_lock(&current->pi_lock);
- rt_mutex_dequeue(lock, waiter);
- current->pi_blocked_on = NULL;
+ scoped_guard(raw_spinlock, &waiter_task->pi_lock) {
+     rt_mutex_dequeue(lock, waiter);
+     waiter_task->pi_blocked_on = NULL;
+ }
- rt_mutex_adjust_prio_chain(..., NULL, current);   + ..., NULL, waiter_task);
```
Commit message 列三问题:1) rbtree dequeue 未持 `waiter::task->pi_lock`;2) 真正 waiter 的 `pi_blocked_on` 未清 → "leaves a dangling pointer primed for UAF around";3) chain walk 用错 task。

## 2. 触发路径与线程/锁拓扑(Part II)
`FUTEX_WAIT_REQUEUE_PI` 使 waiter 睡眠 → 另一线程 `FUTEX_CMP_REQUEUE_PI` → 内核 `requeue` 调 `rt_mutex_start_proxy_lock()` → `__rt_mutex_start_proxy_lock()` → `task_blocks_on_rt_mutex(lock, waiter, task, ...)`,检测到死锁返回 `-EDEADLK` → 回滚 `if (unlikely(ret)) remove_waiter(lock, waiter);`。此时 `waiter->task != current`(current 是 requeuer),于是错误地清了 requeuer 的 `pi_blocked_on`,`waiter` 结构(alloc 在 waiter 线程内核栈上)被留在 `waiter->task->pi_blocked_on`。
作者拓扑:**3 个 futex 变量**(`f_pi_chain`, `f_pi_target`, `f_wait`)+ **3 线程**;waiter 持有 `f_pi_chain` 并睡眠,owner 持 `f_pi_target` 并阻塞在 waiter 之后,requeue 构出 PI 环 `waiter → f_pi_target → owner → f_pi_chain → waiter`,强制走回滚分支。

## 3. Stack-UAF 的产出
悬垂指针 = 目标 task 的 `pi_blocked_on` 指向已释放栈帧中的 `rt_mutex_waiter`。回收/喷涂:
- Part II(x86_64 / kernelCTF):`prctl(PR_SET_MM, PR_SET_MM_MAP)` 把可控 `user_auxv` 拷到栈上、确定性地覆盖被释放的 waiter 帧;备选 `clone`/`setsockopt`/`keyctl`/`pselect`。链走触发用 `sched_setattr`。
- Part III(Android 17):改用 **`pselect`** —— 原话大意 "copies our fd_set bitmaps onto the kernel stack, right over the freed frame"。
- 伪造 waiter 由 `sk_buff` 载荷承载(loopback IPv6 UDP,`sendmsg` 路径),用**时序侧信道**定位 `sk_buff` 数据位置;字段用途:`tree`/`pi_tree` 两个 rb_node 被构造成在 `rb_erase`/dequeue 时触发写;`task` 指向 `&init_task`(利用固定的 linear-map / 非执行 kernel alias,避免 chain walk 解引用崩溃);`lock` 指向注入的 dummy mutex 以满足校验并产生**一次受限指针写**(Part III 未再提 `sched_setattr`;`sched_setattr` 出自 Part II → 标 **UNVERIFIED**)。
- 原语提升:受限写重定位 `boot_id` sysctl 的 `.data` → 读 `/proc/sys/kernel/random/boot_id` 即把 16 字节内核地址格式化为 UUID,得到 KASLR slide;再借 `ASHMEM_SET_NAME` 把 ashmem 私有数据当 configfs buffer 处理,hijack `ashmem` file_operations 为结构兼容的 `configfs` handler → 受限内核任意读(读映射页)/写(写内部 buffer)→ 最终清 seccomp filter、替换 cred、置空 SELinux enforcing。Part II 的最后一级是写 `/proc/sys/kernel/core_pattern`;Android 路径不用它。

## 4. 必须击穿的 Android 加固(Part III)
- Clang **CFI**:除非返回/参数类型完全一致否则拒绝 → 用"函数签名兼容的 ops 替换"(ashmem↔configfs)绕过,而非 JOP。
- **KASLR**:x86 约 50 万签名;ARM64 因上游关闭 linear-map 随机化而暴露固定 non-executable alias,可用物理别名指向 `init_task`;真实泄漏靠 `boot_id` 原语。
- **`randomize_kstack_offset`**(commit `40a25d59e85b`,v5.18+)一旦开启,可靠性降到 "1/8 或 ~1.5%"。
- **SELinux/seccomp**:在获得内核 R/W 之后才清除(enforcing flag 归零 + 解 filter + 全 cap)。参考 Samsung RKP 讨论 https://blog.longterm.io/samsung_rkp.html。
- `PR_SET_MM_MAP` 需 `CAP_SYS_RESOURCE`,app/shell 均无 → Android 段用 `pselect` 取代。
- 测试机型/版本:**Android 17** 上验证:Pixel 10、Galaxy S25U、**vivo PD2405**、Moto G05、Redmi K80 Ultra。未提及 Android 14 / 5.4 / Qualcomm msm 分支 → **UNVERIFIED**。PoC 起始域为受限 app 沙箱(需打开 `/dev/ashmem*` 节点),无需 adb。

## 5. 影响范围表述
Part II:范围 `v2.6.39-rc1 … v7.1-rc1`,前置 `CONFIG_FUTEX_PI=y`;Part II 明确只覆盖 x86_64 Linux,Android 绕过留给后续。Ubuntu https://ubuntu.com/security/CVE-2026-43499:CVSS v3.1 7.8 / v4.0 8.5;各分支修复含 **focal 5.4.0-234.254**(Canonical 自行 backport 进其 5.4),jammy 5.15.0-187,noble 6.8.0-136;上游 commit id 与上文一致。https://endoflife.date/linux:upstream **5.4 最后一版 5.4.302(2025-12-03)**,早于修复日期 2026-04-08 → **上游 linux-5.4.y 永不会收到 fix**;但 5.4.281-qgki 是否被 vivo 私有 backport **UNVERIFIED**。ASB 是否收录该 CVE:抓取失败 → **UNVERIFIED**。

## 6. 最小 syscall 集合(Part II 明确 + Part III 增补)
`futex`(`FUTEX_WAIT_REQUEUE_PI` + `FUTEX_CMP_REQUEUE_PI`,必要时 `FUTEX_LOCK_PI`/`FUTEX_WAIT`) · `sched_setattr`(链走触发) · `pselect6`/`pselect6_time64`(栈喷涂) · `socket`+`sendmsg`(UDP/IPv6 loopback,`sk_buff` groom) · `setsockopt` · `open/read/write`(`/proc/sys/kernel/random/boot_id`) · `ioctl`(`ASHMEM_SET_NAME`) · 辅助 `clone`/`keyctl`/`prctl(PR_SET_MM_MAP)`(仅 x86 路径)。无 root、无 device-specific 节点需求(除 ashmem)。time64 变体未见点名,arm64 只有 `*_{time64}` 形式 → 按号存在性验证。

## 对 5.4.281-qgki + untrusted_app 的适用性判断
| 前置条件 | 判断 | 廉价确认测试 |
|---|---|---|
| `remove_waiter()` 未 backport | **极可能成立**:5.4.281 基线含 bug(源码已逐字核实);上游 5.4.y 已 EOL | 反编译本机 vmlinux 的 `remove_waiter`,看是否清 `current->pi_blocked_on`(本地已有 `pd2220-5.4.281`/`vmlinux.elf`);查 vivo changelog 是否含 "waiter::task" |
| `CONFIG_FUTEX_PI=y` | 很可能(gki 5.4 默认 on,若 `CONFIG_RT_MUTEXES`) | `futex(FUTEX_LOCK_PI)` 返回码 != `ENOSYS/EOPNOTSUPP`;或 `/proc/config.gz` grep FUTEX_PI |
| app seccomp 允许 `futex`(全部 op) | **高置信成立**:filter 只按 syscall 号匹配,bionic 自身依赖 futex;PI op 不构成额外号 | app 内直接跑 requeue-PI 三线程拓扑,看是否 `SIGSYS` |
| `pselect6_time64` 可用(喷涂) | 未知;app 策略常见包含 `select/ppoll`,`pselect6` **UNVERIFIED** | app 内 `syscall(__NR_pselect6_time64, …)` 观察 `errno==ENOSYS/EPERM` vs 正常返回 |
| `sched_setattr` 可用 | **存疑**,app 策略很可能 `errno` | 同上直测;若封死,备选链走触发 = `FUTEX_UNLOCK_PI`/`setpriority`(需自行验证是否进入 `rt_mutex_adjust_prio_chain`) |
| `socket/sendmsg` 建 `sk_buff` | 较可能(app 允许 AF_INET/INET6);无 INTERNET 权限时 loopback 可能被 SELinux/防火墙拦 | app 内 UDP loopback sendmsg 自检;`shell` 域(adb)几乎无限制 |
| `PR_SET_MM_MAP` 备选喷涂 | **不可用**(需 `CAP_SYS_RESOURCE`) | `prctl(PR_SET_MM, PR_SET_MM_MAP)` 期望 `EPERM` |
| `/dev/ashmem` + `ASHMEM_SET_NAME` | Android 14/5.4 上通常仍存在,但 vivo 可能限制 app 访问;Part III 依赖此 fops 目标 | app 内 `open("/dev/ashmem")` + ioctl 结果;失败则需另找 vendor 对象(如本地已在攻的 kgsl/ion) |
| KASLR / linear-map alias → `init_task` | **有利**:5.4 arm64 无 linear-map 随机化、无 non-exec alias 特性,若 `CONFIG_RANDOMIZE_BASE` 未开则更简单 | 检查 `/proc/kallsyms`(kptr_restrict)与 `/proc/iomem` 判断是否随机化 |
| `randomize_kstack_offset` | **有利:不存在**(该特性 v5.18 才引入,5.4 不可能开启)→ 喷涂可靠性高于 Android 17 | `grep RANDSTRUCT / CONFIG_GCC_PLUGIN_RANDSTRUCT` 一并确认布局差异 |
| rt_mutex_waiter 字段偏移 | 需重算:5.4 与 6.x 结构体布局不同,`tree/pi_tree/task/lock/pi_lock` 偏移须从本机 vmlinux 取 |pahole / `vmlinux.elf` DWARF 取 `struct rt_mutex_waiter` 偏移 |
| core_pattern 作为终点 | **不可用**(app 无写权限)→ 必须走 fops/cred 改写路径 | 尝试 open `/proc/sys/kernel/core_pattern` 期望 EACCES |
| CFI 兼容 ops 替换 | msm-5.4 qgki 可能无 clang CFI(`CONFIG_CFI_PERMISSIVE` 也可能 off),若无关更简单 | 查 config;若 CFI on,需按签名匹配的 ops 候选清单 |
| SPL 2025-04 早于披露(2026-07) | 成立:设备不可能含 ASB 修复 | 已由 SPL 元数据确认 |

结论:内核侧触发面(futex requeue-PI 回滚)在 5.4.281-qgki 上**逐字确认存在**,且缺少 5.18+ 的 kstack-offset 加固,喷涂条件理论上优于 Part III 的 Android 17;真正的风险点在 **`pselect6`/`sched_setattr`/`/dev/ashmem` 三项在 vivo app 域是否可达**,以及 5.4 结构偏移需重算。`shell` 域(adb)先验证全链最省成本。
