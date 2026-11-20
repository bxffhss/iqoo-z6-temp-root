# iQOO Z6 临时 Root — 新会话启动文档

## 一、设备与环境
- 设备: iQOO Z6 / V2220A (PD2220), SM7325, 8核 (4×A55 + 4×A78 Adreno642L)
- 内核: 5.4.281-qgki-g2a88cd145def (2025-05-07 构建, vendor SPL 2024-02-01)
- Android 14, BL locked, SELinux enforcing, uid=2000(shell)
- shell 组: 2000,1004(input),1007(log),1011(adb),1015,1028,1078,1079,3001-3006,**3009(readproc)**,**3011(uhid)**,**3012(readtracefs)**
- adb: `C:/adb/platform-tools/adb.exe -s <DEVICE_SERIAL>`
- NDK: `J:/Users/Administrator/AppData/Local/Android/Sdk/ndk/27.3.13750724/.../aarch64-linux-android35-clang -O2 -static -pthread`
- 符号化 vmlinux: `G:/项目/Windows管理/usb/临时root/vmlinux.elf` (179170 符号)
- 符号表文本: `G:/项目/Windows管理/usb/临时root/analysis/vmlinux_symbols.txt`
- 内核配置: `C:/qemu_test/device_config.txt` (来自 /proc/config.gz)
- **铁律: push 后必须 chmod 755 (覆盖会掉执行位); bash 下必须 export PATH="/usr/bin:/bin:$PATH"**

## 二、★ 核心发现: CVE-2025-38352 在本机未修复且可触发

### 2.1 漏洞
`kernel/time/posix-cpu-timers.c` — `handle_posix_cpu_timers()` 与 `posix_cpu_timer_del()` 的 TOCTOU 竞态 ⇒ UAF
- 修复于 **5.4.295** (mainline f90fff1e152d, 5.4 backport 2c72fe18cc5f)
- 本机 **5.4.281** < 5.4.295 ⇒ 未修复
- 在 CISA KEV (2025-09-04), Google TAG 确认针对 Android, 2026-01 公开 PoC "chronomaly"

### 2.2 三重证据确认未修复
1. 版本: 5.4.281 < 5.4.295
2. 配置: `CONFIG_POSIX_CPU_TIMERS_TASK_WORK` 符号在本树不存在(那个"不需要修复"的例外不成立)
3. 反汇编: `run_posix_cpu_timers`@`0xffffffc0103ddea0`(0x2ec/187条) 取 current 后**紧接着读**
   `[x19,#0x7e8/#0x800/#0x818]`(= `&posix_cputimers`(0x7e0) 三个 bases[*].nextevt, 步长 0x18),
   **无 exit_state guard**; 函数内直接 `__lock_task_sighand`→`collect_posix_cputimers`→`send_signal`
   ⇒ IRQ 内联处理确证

### 2.3 漏洞机制(5.4.281 源码级)
```c
void run_posix_cpu_timers(void) {
    struct task_struct *tsk = current;
    if (!fastpath_timer_check(tsk)) return;
    if (!lock_task_sighand(tsk, &flags)) return;   // ① 成功(sighand 未 NULL)
    check_thread_timers(tsk, &firing);              // ② 收集定时器, 设 firing=1
    check_process_timers(tsk, &firing);
    unlock_task_sighand(tsk, &flags);               // ③ ★ 解锁 —— 竞态点在这之后
    list_for_each_entry_safe(timer, next, &firing, ...) {
        spin_lock(&timer->it_lock);                 // ⑥ 如果 timer 已被释放 ⇒ UAF
        list_del_init(&timer->it.cpu.elist);
        cpu_timer_fire(timer);                      // ⇒ send_sigqueue → 可能 BUG_ON
        spin_unlock(&timer->it_lock);
    }
}
// 并发侧:
static int posix_cpu_timer_del(struct k_itimer *timer) {
    sighand = lock_task_sighand(p, &flags);
    if (sighand == NULL) {          // ④ ★ 任务已被收割(release_task) ⇒ 锁失败
        WARN_ON_ONCE(...);          //    ⇒ 跳过 firing 检查!
    } else {
        if (timer->it.cpu.firing) ret = TIMER_RETRY;  // ← 正常: 看见 firing ⇒ 不释放
        else cpu_timer_dequeue(ctmr);
        unlock_task_sighand(p, &flags);
    }
    if (!ret) put_task_struct(p);   // ⑤ ret=0 ⇒ 调用方 itimer_delete 释放 timer ⇒ UAF
}
```

### 2.4 竞态三条件(缺一不可)
1. tick 落在 `exit_notify()` 之后、`do_task_dead()` 之前的微窗口(⇒ exit_state≠0 且 task 仍运行)
2. IRQ 循环尚未处理到该 timer(firing 列表中未被 list_del)
3. 此刻 task 已被 `release_task()` 收割(⇒ sighand=NULL ⇒ 删除跳过 firing 检查)

## 三、触发器(已确认可复现)

### 3.1 最终工具
- 文件: `C:/qemu_test/cve38352b.c` (已编译为 cve38352b)
- 参数: `./cve38352b <helpers> <attempts> <firemax_us> <widen> <secs> <waitmax_us> <noreap> <noarm>`
- 推荐配置: `./cve38352b 3000 500000 1500 1 290 0 0 0`
- 铁律: ①push 后必须 chmod 755 ②先跑 noarm=1 确认存活(≥5min) ③noreap=1 会泄漏 zombie

### 3.2 已确认的触发结果
```
对照(noarm=1, 定时器不武装): 290s / ~9,300 次 → 存活 ✓ (无法触发 CVE)
实验(noarm=0, 定时器武装):   109.8s / ~2,800 次 → 崩溃重启 ✓
尾段加长后:                  ~1,400 次 / 55s → 崩溃重启 ✓
6 实例并行:                  40–60 秒内必崩 ✓
```

### 3.3 触发设计(基于 5.4.281 源码 + 反汇编)
- **1500-3000 个 helper 线程**: block SIGUSR1 + 阻塞在 pipe read
  ⇒ `complete_signal()` 遍历整组 ⇒ 放大 IRQ 处理时间到 4-5ms
- **18 个 stalling 定时器 + 1 个 UAF 靶子**: `CLOCK_THREAD_CPUTIME_ID` + SIGEV_SIGNAL(SIGUSR1)
  ⇒ 全部在同一 tick 被收集进 firing 列表
- **racer 线程**: 被 parent `PTRACE_ATTACH`(⇒ 非 autoreap), 退出后进入 zombie,
  parent `PTRACE_DETACH` ⇒ `release_task()` ⇒ `sighand = NULL`
- **deleter 线程**: 在 parent DETACH 前 20µs 调 `timer_delete(UAF_timer)`
  ⇒ `posix_cpu_timer_del` 的 `lock_task_sighand` 失败 ⇒ 跳过 firing 检查 ⇒ 释放 timer ⇒ UAF

## 四、利用所需全部参数

### 4.1 slab 参数(/proc/slabinfo 实测)
```
posix_timers_cache    248 obj  |  264 B/obj  |  31 obj/slab  |  2 pages/slab(8192B)
sigqueue              408 obj  |   80 B/obj  |  51 obj/slab  |  1 page/slab(4096B)
```

### 4.2 task_struct 关键偏移(从反汇编推得)
```
current 获取:       mrs x19, SP_EL0
posix_cputimers:    0x7e0  (bases[0].nextevt = 0x7e8, 步长 0x18)
task_struct::flags: 0xb4  (bit31 测试)
```

### 4.3 UAF 原语(一旦命中)
```
IRQ 循环在已释放的 k_itimer 上执行:
  spin_lock(&timer->it_lock)         → it_lock 偏移待确定
  list_del_init(&timer->it.cpu.elist) → elist.next/prev 可控 ⇒ 两个任意地址写:
      *(prev + 8) = next    // 写 1
      *(next + 16) = prev   // 写 2
  timer->it.cpu.firing = 0
  cpu_timer_fire(timer)              → send_sigqueue(timer->sigq) → sigq 也已释放
      → BUG_ON(!(q->flags & SIGQUEUE_PREALLOC))  ← 若 sigq 也被回收可绕过
      → list_add_tail(&q->list, &p->pending.list) ← 第三个任意写
```

### 4.4 exploitation 路线(下一步要做的)
```
Phase 1: timer_create × 248 (填满 8 slabs × 31 obj)
Phase 2: timer_delete × 248 (全部释放 ⇒ 8 页归还 buddy)
Phase 3: pipe + F_SETPIPE_SZ(8192) + write × 32 (每页放 ~31 个伪造 k_itimer)
Phase 4: racer(ptrace 收割) + timer_delete(UAF 靶子)
         ⇒ IRQ 在伪造 k_itimer 上执行 list_del_init
         ⇒ elist.next/prev 可控 ⇒ 两个任意地址写
         ⇒ 写 task_struct->cred = fake_cred_addr
         ⇒ fake_cred: uid/gid = 0 ⇒ setuid(0) ⇒ root
```
**注意**: Phase 3 的 spray 数量不能太多(会耗尽 timer_create 需要的内存页), 建议 8-16 页

## 五、可观测性(tracefs)

### 5.1 可用项
- `/sys/kernel/tracing/trace` **可读**(内核环形缓冲)
- `/sys/kernel/tracing/tracing_on` **可写**
- `/sys/kernel/tracing/buffer_size_kb` **可调**
- `/sys/kernel/tracing/events/sched/{sched_process_free,sched_switch,sched_wakeup,sched_process_exit}/enable` **可写**
- 已验证: `sched_process_exit` 和 `sched_process_free` 能看到 racer 的 exit 和 free 事件

### 5.2 不可用项
- `current_tracer`(function tracer) / `kprobe_events` / `signal/*` / `timer/*` / `syscalls/` — 全被拒
- `/dev/kmsg` / `/proc/kmsg` / `dmesg` / `/sys/fs/pstore` / `oops_count` / `warn_count` — 全被拒
- `/vendor/firmware/` / `/data/bbkpanic` / `/metadata` / `/cache` / `/mnt/vendor/persist` — 全被拒
- `logcat -b kernel` — 空白(kernel buffer 未启用)

## 六、已排除的面(10 块全关 + 候选排除)

| 面 | 状态 |
|---|---|
| kgsl | 关闭(14 ioctl + IO 地基 + 微码 A6xx 不适用) |
| hid-multitouch | 关闭(解析有防护) — 但**越界写原语可用** |
| uinput | 关闭(UI_SET_*BIT 范围校验) |
| SYSVIPC/keyring | 不可用 |
| ptmx+ldisc | 关闭(ldisc 除 N_TTY 全挡, TIOCSTI 挡) |
| binder | 关闭(调用可通, 传对象被挡) |
| BPF | 关闭(SELinux EACCES) |
| perf | 关闭(校验扎实, 内核断点被拒) |
| io_uring | 关闭(被裁剪: register 0-5, opcode 0-11, flags≤7) |
| pty 生命周期 | 关闭(~1.7M 次无崩溃无泄漏, TIOCSPGRP 不可达) |
| **CVE-2025-38352** | **★ 未修复 + 可复现触发** |

### 已排除的候选 CVE
- CVE-2025-37803 (udmabuf): CONFIG_UDMABUF is not set
- CVE-2025-37797/-37823 (hfsc qdisc): 需 netns+CAP
- CVE-2025-37795 (mac80211): 需 Wi-Fi 发包, REJECTED
- CVE-2025-37838 (hsi/ssi_protocol): HSI 驱动不存在
- CVE-2025-23142 (SCTP): CONFIG_IP_SCTP 未编译
- CVE-2025-23150 (ext4): /data 是 f2fs
- CVE-2025-37804 (io_uring iowq): REJECTED
- CVE-2025-21479/-21480 (Adreno 微码): A6xx 机制不适用
- CVE-2024-26923/-36972 (AF_UNIX GC): 早在 5.4.281 基线内

## 七、剩余待挖
- 5.4.294~302 批次: ~73 个 CVE 待过滤(来源: HKCERT/SUSE 公告)
- CVE-2025-27038 (Adreno 驱动 UAF): 未排除, 需 vendor 技术细节
- QCOM vendor 私有 CVE (2024-03→2025-05): kgsl 可达

## 八、方法论(可复用)
1. **反向补丁审计**: 把上游修复逐条对照 vmlinux.elf, 找"打得到可达面"的缺失项
2. **三重判定**: 版本号 + 配置符号 + 反汇编代码 = 三重独立证据
3. **符号预筛**: 前缀匹配(含 CFI `$hash` 后缀)判断"漏洞代码在本树是否存在"
4. **功能反证**: 用可观测副作用判定路径是否可达(如 CLOSE 是否真关了 fd)
5. **双值形态判别**: fd=-1 给 EBADF + 合法 fd 给 EINVAL = opcode 未实现
6. **严格 A/B 归因**: 唯一变量 + 对照组必须存活才能归因
7. **接受判据**: write() 成功 ≠ 描述符被接受(异步路径需等待确认)

## 九、关键工具文件(全部在 C:/qemu_test/)
| 文件 | 用途 |
|---|---|
| **cve38352b.c** | ★ 触发器(常驻 child + ptrace 收割 + 19 线程定时器) |
| cve38352x.c | 完整利用尝试(排空+占位+触发, 需调试) |
| posix_timer_race.c | 早期朴素竞态版 |
| perf_*.c (6个) | perf 全套审计 |
| uring_*.c (6个) | io_uring 全套审计 |
| pty_life.c | pty 生命周期与竞态 |
| binder_*.c (2个) | binder 审计 |
| uhid_*.c (多个) | HID 审计与触发器 |
| tty_probe.c | ptmx/ldisc 侦察 |
