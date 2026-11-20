# CONTINUE_HERE · 2026-09-26 深夜（本会话收尾；**取代同日晚些的旧版 §5b/§6 叙述**）

## 0. 一句话现状
两条主线（binder UAF / GhostLock 栈覆盖）的**终点都需要同一个东西：一个可用的内核地址**。
今晚把"地址从哪来"彻底量化了：**app 域无任何内核指针泄露面；shell 自采样 perf 能拿到真内核 IP**
⇒ **全局关卡 = 任务 #11：拿到与设备同构建（`g2a88cd145def`, 2025-05-07）的符号表**。
我们手里的镜像是 `gbfef221370b4`(2026-06-18)，**同名函数地址会移动（binder 一族差约 1 MB）**
⇒ 旧会话按离线镜像解释出来的"base + 偏移"靶子**都要重算**。

## 1. 今晚被**推翻**的四条旧结论（别再据此行动）
1. ~~"binder 双 free 已被 119k 次实测否掉"~~ ⇒ **P56/P57 是无效实验**：它们用
   `mmap(PROT_READ, MAP_PRIVATE|MAP_ANONYMOUS, fd, 0)`，**MAP_ANONYMOUS 使内核根本不叫 `binder_mmap`**
   ⇒ `alloc.buffer_size=0` ⇒ 同步事务永远 `BR_DEAD_REPLY`（对端从未存在）。
   正确形式 **`PROT_READ|MAP_SHARED`**，改对后立刻拿到真 `BR_REPLY`。有效重做 = **P64：56,557 次、被偷槽 0、对照组 0**。
2. ~~"§6 的 write-what-where 只差一步确认可得"~~ ⇒ CVE 补丁原文表明真实形状是
   **进程侧 `binder_deferred_func` free(t)** 撞 **另一进程线程侧 `binder_thread_release` 读写 t**，
   不是 double-invocation；且本机源码有不变式"`t->work` 挂 todo 与 `t` 挂 stack **互斥**"
   （`binder_thread_read` 是先出队后上栈；`binder_enqueue_transaction_work_ilocked` 是 5.10+ 才有）。
3. ~~"app/shell 都拿不到内核指针"~~ ⇒ 说过头了。**shell 自身进程 perf 自采样可行**
   （`C:/qemu_test/perf_ips.txt` 63,739 条真内核 IP）。app 域确实拿不到。
4. ~~"可达面 = /dev 的 14 个节点"~~ ⇒ 口径不全：`O_RDONLY` 是 20 个，且**没扫 /sys**（已补：23 个 remoteproc 属性）。

## 2. 今晚新增的**一手地基**（可复用）
- binder ABI：`sizeof(binder_transaction_data)=64`；出向 `[u32 cmd][td @ +4]`（+8 布局被拒）；
  入向 `BR_NOOP` 占 8 字节、`BR_REPLY=0x80407203` 的 td 在 **+12**（`read_consumed=76=8+4+64`）。
- `binder_thread_write` 的 `while (ptr < end && thread->return_error.cmd == BR_OK)`
  ⇒ 一旦有 reply_error 残留，之后每次 write `ret=0/consumed=0`（这一个模型解释了 P54-P57 全部怪返回值）；
  `binder_transaction` 的守卫（非 oneway 且栈顶 `to_thread != 本线程`）**禁止同线程挂第 2 条同步事务**。
- app 域自引用 bootstrap 的两条死路：`BINDER_SET_CONTEXT_MGR` 四个节点全 EBUSY
  （`/dev/binder` 与 `binderfs/binder` 同 rdev）；反射 `ServiceManager.addService`
  ⇒ `SecurityException: App UIDs cannot add services.`（SM 按 uid 判）。正对照 `checkService("package")` 非空。
- KGSL：`/dev/kgsl-3d0` 可 O_RDWR；`GETPROPERTY(0xc0180902)` 的 `struct kgsl_device_getproperty`
  为 `{u32 param;u32 pad;u64 value;u32 sizebytes;u32 offsetbytes}`；id 0..95 全扫 → 16 个支持、**无内核 VA**。
- 方法论：**攻击面筛选第一层是 `open()`（含 O_RDWR 与 O_RDONLY 两种、`/dev` 与 `/sys` 两处），不是 CFI 类型集**。

## 3. 下次开始的正确顺序
1. **#11（决定一切）**：拿同构建符号表。设备 cmdline 给了准确版本号 `product.version=PD2220_A_14.2.9.1.W10`、
   `fingerprint.abbr=11/RP1A.200720.012`、内核 `5.4.281-qgki-g2a88cd145def`（2025-05-07 构建，clang 11.0.2 r383902b，
   `.config` 与我们手里镜像**逐字节相同**）⇒ 去 vivo 开源门户拿该 commit 重导出 `System.map`；
   **校验方法**：把重建符号表与 `perf_ips.txt` 的 IP 对相位，对得上才算数。BL locked ⇒ `dd` boot 分区不可行。
2. 若 #11 短期拿不到：**只做不需要地址的原语**（任务 #18）——
   `logger_read` 未初始化字节（P68 试读没数据、静态看长度与实写一致 ⇒ 弱）；
   `IOCTL_KGSL_GPU_AUX_COMMAND` 的 preemption 计数器 256B 数组（真机值域未测，**下次可测**）；
   fd 表落点（`struct file` 与 fd 数组同 slab，但**需要一个已知的 UAF 写**才谈得上，目前没有）。
3. binder 若继续：唯一形状是"**两个端点都在我们手里 + 进程退出**"（任务 #17，未测的最小切口是
   在 Java `onTransact` 里对框架 binder fd 直接 `ioctl(BINDER_THREAD_EXIT)`；fd 号可在 `/proc/self/fd` 找）。
   **注意**：即使触发成功，那两次 free 若在同一条 syscall 内，用户态 spray 插不进去（见 §BINDER-DOUBLE-FREE）。

## 4. 资产与工具（本晚新增/修订）
- `C:/qemu_test/ioctl165_inv.txt`：165 个 `unlocked_ioctl` handler 的被调函数表（一次 awk 全量扫 333 MB 反汇编）。
- `C:/qemu_test/appdapk/bi.sh`：编译+打包+**自动点掉 vivo 安装拦截页**+启动（旧 `install.sh` 会被拦截页永久阻塞）。
  用法 `./bi.sh jni_pXX.c pXX`，然后**必须** `am force-stop` + `logcat -c` + 再 monkey 启动（安装后的自启动经常不生效）。
- `C:/qemu_test/appdapk/devnodes.txt`、`sysnodes.txt`、`syskeep.txt`：清单（shell find 得到）。
- 探针：`jni_p61.c`(addService/句柄)、`p62.c`(SET_CONTEXT_MGR×映射形式)、`p63.c`(真 BR_REPLY)、
  `p64.c`(活对端双 free 竞速+句柄解析)、`p65.c`(syscall 字段泄露)、`p66/67/68.c`(可达性)、
  `p69.c`(KGSL 属性)、`p70.c`(sysfs 扫描)。
- 文档：`BINDER-MAP-FIX-REBASE-20260926.md`、`BINDER-DOUBLE-FREE-CLOSED-20260926.md`、
  `BINDER-CVE-SHAPE-FROM-PATCH-20260926.md`、`APP-REACHABLE-NODES-AND-IOCTL-FILTER-20260926.md`、
  `KASLR-LEAK-SURFACES-CLOSED-20260926.md`（含自我更正）、`PATH-TO-ROOT-20260926.md` §6 作废声明。

## 5. 设备状态与健康
uptime 20:55+，**本晚约 24 万次 binder 事务与 160 万次喷槽没有触发重启**；SELinux Enforcing；
`/data` 剩 9.1G；已 `force-stop` 探针并清 `/data/local/tmp/*.apk`。
**未做且需先征求用户同意**：写 `struct cred`、清 `selinux_state.enforcing`。
