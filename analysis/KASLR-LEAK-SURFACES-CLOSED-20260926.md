# KASLR 泄露面穷举：app 与 shell 都没有可用的内核指针来源（2026-09-26 19:30）

`/proc/cmdline`（shell 可读）**没有 `nokaslr`** ⇒ 内核 text 与线性映射都被随机化，
任何"写内核地址"的最后一步都必须先有一个内核指针。本轮把常见面全部测过：

## 1. app 域（uid 10172 / untrusted_app，P58 + P59 + P65）

| 面 | 结果 |
|---|---|
| `/proc/kallsyms`、`/proc/iomem`、`/proc/ioports`、`/proc/modules`、`/proc/slabinfo`、`/proc/vmallocinfo`、`/proc/config.gz`、`/proc/kmsg`、`/proc/1/maps` | **EACCES** |
| `/dev/binderfs/binder_logs/{state,transactions,transaction_log,failed_transaction_log,stats,proc}` | **全部 EACCES**（这条最可惜：里面本来是内核指针） |
| `/sys/kernel/notes`、`/sys/firmware/devicetree/base/chosen/kaslr-seed` | **EACCES** |
| `/dev/kmem`、`/dev/mem`、`/proc/kcore`、`/sys/kernel/debug/*`（debugfs 未挂到可见路径） | ENOENT/EACCES |
| `perf_event_open` | EACCES（`perf_event_paranoid=-1` 也没用） |
| `/proc/self/wchan`（含 8 条分别卡在 nanosleep/futex/poll/read/sigwait/epoll/**binder read** 的线程） | **恒为 0** |
| `/proc/self/task/<tid>/syscall`（P65，含阻塞在 readv 的线程） | **9 个字段全是用户态值**（`0x74…/0x77…`），arm64 这条不导出 ksp/内核 pc |
| `/proc/self/maps` | 可读（正对照，证明探测逻辑本身有效） |

## 2. shell 域（uid 2000）

`kallsyms`/`dmesg`(klogctl)/`iomem`/`sys/kernel/notes`/`binder_logs` 目录/`kaslr-seed` = **EACCES**。
可读的只有 `/proc/slabinfo`（堆整理情报）与 `/sys/kernel/tracing/{trace,tracing_on,buffer_size_kb}`
（**0666**，但缓冲里只有 `tracing_mark_write` 的 ATrace 标记，`grep -c ffffff = 0`，无 IP；
`current_tracer` 写不进去 ⇒ 没法切到 function tracer 造 IP）。

## 3. 结论与影响

0. **【本文写完后的自我更正 —— 重要】**"shell 也拿不到内核指针"这句是**错的**：
   本项目 09-24/09-25 已经用 **shell 自己进程内的 `perf_event_open` 自采样**
   （`perf_event_paranoid = -1`，`/c/qemu_test/perf_ips.txt` 存有 **63,739 条真内核 IP**，
   形如 `ffffffd12a39f2a0`，与离线镜像的 `ffffffc010…` 明显不同段）拿到过内核 text 地址。
   今晚我只复测了"读文件类"面就下了全称结论，是把"我没测"写成了"不存在"。
   ⇒ **KASLR base 事实上可得（经 adb shell）**；真正缺的是
   **"设备同构建的符号地址"** —— 本机是 `g2a88cd145def`(2025-05-07)，
   我们手里的镜像是 `gbfef221370b4`(2026-06-18)，**同名函数的地址在两个构建之间会移动**
   （binder 一族就差了约 1 MB），所以"base + 我们镜像里的 `selinux_enforcing` 偏移"是**错的靶子**。
   ⇒ **任务 #11（取设备同构建的 boot/内核符号表）现在是全局最高优先项**，
   可行路径：vivo 公开内核源码 (source.vivo.com / 其镜像) 按 `2a88cd145def` 取 `System.map`，
   并用 perf 采到的 IP 校验重建是否对得上；BL locked ⇒ 直接 `dd` 设备 boot 分区不可行。
1. 在 #11 完成之前，**任何依赖绝对内核地址的终点都不可执行**；
   所以探针优先级同时保留一条不依赖地址的路线：**"能落到我们知道位置的对象的写/读"**。
2. 这直接影响两条旧链的排序：
   - `PATH-TO-ROOT` 的 `[D1] f_op = &acc_fops`（需要 `acc_fops` 的**绝对地址**）
     即使写原语到手也**仍然不够**；
   - 反而**"写 0 到我们自己拥有的对象内部某个字段"**这种不需要地址的形状价值上升
     （例如把某个 `struct file` 的 `f_mode`/`f_flags`、或 `dentry`/`inode` 计数器改掉）。
3. 顺带确立：`/sys/kernel/tracing/tracing_on`、`trace`、`buffer_size_kb` 是 **0666**
   （app 是否也能写尚未测；若能，就是一个"往内核 ring buffer 里灌可控字符串"的原语，
   配合任何越界写可作为**可读的回显信道**）。

## 4. 本轮被否掉的自我推断（记进方法论）

- ~~"P56/P57 被偷槽=0 是 binder 无双 free 的证据"~~ ⇒ 无效（映射形式错，对端不存在），
  已由 P64 用**活对端**重做（见 `BINDER-MAP-FIX-REBASE-20260926.md`）。
- P65 的 mode=2 `request_key()` 让探针自身崩溃（tombstone 只导出了**用户态** pc，无信息量），
  不影响 mode=1 的结论。


## 5. 追加两轮（同晚，P69/P70）：`/sys` 与 KGSL 属性也扫完

- **P70（sysfs，700 个候选）**：app 能开的只有 **23** 个，全是 remoteproc 的属性
  （`/sys/devices/platform/soc/*/subsysN/{name,state,crash_count,last_crash_reason}`），
  读到的内容里没有内核指针（`命中=0`）。⇒ 我之前的"可达面"枚举只扫 `/dev` 是**不完整的**，
  补扫 `/sys` 之后结论才成立：**sysfs 也不给地址**。
  副产品（有用）：`subsys*/crash_count` 与 `state` 对 app 可读 ⇒
  这是一个**合法的非崩溃观测信道**，但只覆盖 modem/adsp/cdsp/gpu-zap 等子系统，覆盖不到内核 oops。
- **P69（KGSL，`/dev/kgsl-3d0` 可 O_RDWR）**：把 `IOCTL_KGSL_DEVICE_GETPROPERTY`(0xc0180902)
  的 param id **0..95 全扫**（`sizebytes=64`，buffer 预填 0xcc 以便区分"内核真写了"）：
  只有 **16** 个 id 支持（其余 `ENODEV(19)`，id 39 是 `EOPNOTSUPP(95)`），
  回写的值全是 GPU id/尺寸/位图一类（如 id=21 → `0x016dc094`），**没有任何 8 字节内核 VA 样式值**；
  `IOCTL_KGSL_GETPROPERTYINT`(0x80080905) 在这台机器上 **0 次成功**（不存在）。
  ⇒ 子代理在离线镜像里标出的两个"待定"点（`adreno_prop_device_shadow` 的
  `[dev+0x40]→+0x28` 与 `device_info` 的 `[x0+0x12c8]→+0x38`）**在真机上没有对应的 GETPROPERTY id**
  ⇒ 它们要么由别的 ioctl 派发，要么根本不可达 ⇒ KGSL 属性线**不再作为 KASLR 来源**。
  （抽查记录：我核了两条引用指令原文，`kgsl_ioctl_helper@0x10a8657c-8c` 的
  `__check_object_size(...,2,1)` + `_copy_to_user(x20, sp+8, x21)`，
  以及 `adreno_prop_device_shadow@0x10ab0bfc-30` 的 `cmp w8,#0x18 / csel x19=min(size,24) /
  _copy_to_user(x0=[x1,#8], x1=sp, x2=x19)` —— 子代理引用的指令与原文一致。）

## 6. 现在的事实边界（写给下一轮，别再重复测）

| 面 | 结论 |
|---|---|
| `/proc` 类内核指针（kallsyms/iomem/binder_logs/notes/devtree/kmem…） | 全部 EACCES（app 与 shell 都测过） |
| `wchan` / `task/<tid>/syscall` 参数 | 恒 0 / 全用户态值 |
| `/dev` 全枚举（464，两种 flag） | O_RDWR 14 个、O_RDONLY 20 个；试读无指针 |
| `/sys` 定向枚举（700） | app 只开 23 个 remoteproc 属性；无指针 |
| KGSL GETPROPERTY 全 id | 无指针；GETPROPERTYINT 不存在 |
| **shell 自身 perf 自采样** | **可行且历史上成功过**（`perf_ips.txt` 63,739 条真内核 IP）⇒ **base 可得，但符号表必须与设备同构建（任务 #11）** |


## 7. 再追加（P71，同晚 20:49）：最后一个"内核数组拷回用户"候选也实测为负

- `IOCTL_KGSL_GPU_AUX_COMMAND`（离线镜像里 nr=0x57，其 `adreno_ioctl_preemption_counters_query`
  的 `_copy_to_user` 源是 `[dev+0x2ba0] → +0x8` 的**另一个内核分配的 256B 数组**）：
  用 **dir(RW/R/W) × size(8..64 步长 8) 共 24 种 `_IOC` 组合**扫 ⇒ **0 次成功**（全 EINVAL/ENOTTY/ENODEV）。
  ⇒ 该 ioctl 在本构建里要么不存在、要么 nr/size 与离线镜像不同（正是 #11 的已知风险的实例）。
  同时 `subsys2/{state,crash_count}` 前后均为 `ONLINE / 0` ⇒ 这一批 ioctl **没有**打到 GPU zap
  （也顺带验证了那条新的"子系统崩溃"观测信道可用）。
- `/proc/log/state`、`/proc/vivo_rsc/appmem{,d}`（vivo 自有节点）：目录可列，**文件连 stat 都不行**（shell 亦 EACCES）。
- `/sys/kernel/slab/*/alloc_calls`（SLUB 会打印**调用点代码地址**，是经典 KASLR 泄露位）：
  属性**存在**（说明 `CONFIG_SLUB_DEBUG` 在），但 `alloc_calls`/`allinfo`/`objects` 全部 **EACCES**，
  且没有 `alloc_traces`（需要 `slub_debug` 启动参数）。
- `/sys/fs/pstore/`、`/proc/last_kmsg`、`/dev/kmem`、`/dev/mem`：分别 EACCES / 不存在 / 不存在 / 不存在。
- `/sys/module/*/sections/.text`：**不存在**（该内核的模块 sysfs 没暴露 sections）⇒ 拿不到模块基址。

## 8. 最终边界（本晚定稿）

**设备侧没有任何现成的内核地址来源**（app 与 shell 都测过，覆盖面：`/proc` 全部相关节点、
`/dev` 464×2 flag、`/sys` 700 定向 + slab + pstore + module sections、perf(app)、
KGSL 全部可读属性 + aux ioctl）。
**唯一已知的地址来源 = shell 自身进程 perf 自采样**（历史实证 63,739 条），
但它只能给"运行时地址"，要把它变成**可用靶子**必须满足两件事之一：
① 拿到设备同构建（`g2a88cd145def`）的符号表/`boot.img`（任务 #11）；
② 或找到一种**不需要绝对地址**的落点（本轮已把可达面上所有"内核数据拷回用户"的点测空，
   所以 ②现在只能靠**漏洞本身**制造，而不是靠现成接口）。


## 9. 【突破 22:40】设备同构建的符号表已经拿到

用户提供 `L:\Downloadð安全浏览器505071414071dfa136cf8a81bdb35e36c52b4bab39d.zip`
（6.79 GB 卡刷包，updater-script 断言 `PD2220MA`）。解出其中 `boot.img`：
- `Android boot header v0`，kernel 44,661,248 字节，`Linux version 5.4.281-qgki-g**2a88cd145def**`
  + `#1 SMP PREEMPT Wed May 7 12:07:39 CST 2025` ⇒ **与设备 `uname -a`/`uname -v` 逐字相同**。
- 与 `analysis/kernel`（`gbef221370b4`）**md5 不同** ⇒ 确实是另一份构建。
- 用 pip 上的 `vmlinux_to_elf-1.3.6` 的 `kallsyms_finder` 提取内嵌 kallsyms：
  **先拿旧镜像做自校验** —— 输出 179,171 行且 `_text=ffffffc010080000`、
  `remove_waiter=ffffffc010378d58`、`binder_free_transaction=ffffffc010f5eff8`
  **三个已知真值全部吻合** ⇒ 管线可信；然后跑新 kernel ⇒ **179,181 行**，
  已存为 `analysis/kallsyms_g2a88cd145def.txt`（kernel 本体存 `kernel_dev_g2a88cd145def.bin`）。

**关键靶子（设备构建的链接期地址）**

| 符号 | 地址 |
|---|---|
| `_text` / `_stext` / `_etext` | `ffffffc010080000` / `…81000` / `ffffffc0115a0000` |
| **`selinux_state`** | **`ffffffc012b18000`（类型 B = .bss，页对齐）** |
| `security_hook_heads` | `ffffffc01222b400` |
| `commit_creds` / `prepare_kernel_cred` | `ffffffc01031f154` / `ffffffc01031f67c` |
| `init_cred` / `init_task` | `ffffffc01293d528` / `ffffffc01292e200` |
| `avc_has_perm` | `ffffffc01079fa6c` |
| binder 一族 | `binder_free_transaction=…f5ef24`、`binder_send_failed_reply=…f60a40`、`binder_thread_release=…f50df8`、`binder_release_work=…f63344` |
| `i2cdev_ioctl` / `acc_fops` / `ashmem_fops` | `…188260` / `…121aa618` / `…121d24a8` |

**两个必须更正的说法**：
1. ~~"两个构建之间函数地址差约 1 MB"~~ ⇒ **错**。实测：`_text/_stext/_etext`、
   `commit_creds`、`prepare_kernel_cred`、`init_cred`、`init_task`、`remove_waiter` **地址完全相同**；
   只有实际改过源码的文件位移小量（binder −0xD4/+0x12C、i2cdev −0x20、fops −0x80）。
   ⇒ 我们过去几个月在旧镜像上做的**大部分**地址工作本来就基本可用。
2. `selinux_state` 在 **.bss**，且 arm64 KASLR 是**整个 image 一起平移** ⇒
   **只要有一个内核 IP 就能同时定住 text 与 .bss 的靶子**（slide 唯一）。

**剩下的唯一技术缺口** = **本次开机的 slide**。已具备：shell 自采样 perf（历史实证）+
现在的静态表 ⇒ `calib_base.py` 类工具可以把采到的 IP 归算到具体符号并解出 slide。
下一步：① 用 `llvm-objdump` 反汇编新 kernel 的 `avc_has_perm` 等，实测 `enforce` 在
`selinux_state` 内的**字段偏移**；② 采一批 fresh perf IP 解 slide；③ 之后才谈写。


## 10. 终点靶子已经算到位（22:55，全部一手）

工具：新增 `analysis/kdis.py`（对**裸 Image** 的符号感知反汇编/引用扫描，capstone 版；
`llvm-objdump` 会把裸 kernel 误认成 coff-arm64 而什么都不输出）。
**它的正确性已用两个必然大量引用的全局验证**：`security_hook_heads` 520 处、`selinux_state` 323 处。
（期间修掉我自己的一个 ADRP bug：目标必须基于 **页对齐的 PC**，即 `(pc & ~0xfff) + (imm<<12)`。）

**`struct selinux_state` 在本机 `g2a88cd145def` 上的实测字段表**（来自 `sel_read_enforce` /
`sel_write_enforce` 的反汇编，`strb w8,[x21,#1]` 是写 enforce 的唯一位置）：

| 偏移 | 字段（推断） | 证据 |
|---|---|---|
| `+0x00` | `initialized`（bool，**必须保持 1**） | `sel_read_enforce` 只读 +1，而 +0 从不被 enforce 路径写 |
| **`+0x01`** | **`enforce`（bool）** | `adrp x0,selinux_state` → `ldrb w22,[x21,#1]` → **`strb w8,[x21,#1]`**（`sel_write_enforce@0x107adb84`） |
| `+0x03` | 另一个严格性布尔（`ignore_denies`/`checkreqprot` 一族） | `ldrb w9,[x8,#3]` 出现 6 处 |
| `+0x10` | `policy`（RCU 指针，**不能清零**否则下次访问 oops） | `ldr x8,[x8,#0x10]` + `cbz` 判空（`security_compute_av` 区域 @0x1079fdec） |
| `+0x78` | policy 内部表指针 | `ldr x8,[x8,#0x78]` 15 处 |

⇒ **任何"8 字节清零写"的理想落点 = `selinux_state + 1`**：一次写同时清掉 `enforce` 与
其后几个严格性布尔（全 0 更宽松），且**不会**碰到 `initialized(+0)` 与 `policy(+0x10)`。
静态地址（链接期）：`selinux_state = 0xffffffc012b18000` ⇒ **`enforce = 0xffffffc012b18001`**；
arm64 KASLR 是整个 image 一起平移 ⇒ **运行时 = 0xffffffc012b18001 + slide**，
而 slide 只需**一个**内核 IP 即可定住（shell 自采样 perf 提供）。

## 11. 现在剩下的唯一一步（下次开始就做它）

**求本次开机的 slide**：
1. 用现成 shell 侧 perf 工具（`C:/qemu_test/perf_diag`、`perf_probe` 等，paranoid=-1、自采样）采一批内核 IP；
2. 拿 `analysis/kallsyms_g2a88cd145def.txt` 解 slide：对 2MB 对齐的候选 s，检验"所有 IP − s 都落在
   `[_stext, _etext]` 内且各自落在某个符号区间内"（`calib_base.py` 就是这个思路，现在喂的是**同构建**的表）；
3. 校验：解出的 s 应让 `0xffffffc012b18001 + s` 落在 `.bss`（`__bss_start..__bss_stop` 区间内，
   这两个符号表里都有），且 `avc_has_perm + s` 落在 text 内。

⚠️ 到这一步"能不能写"仍然是零：我们**还没有任何写原语**。slide 只是把终点准备好。


## 12. 【第二次自我更正】slide 并没有真的解出来（方法判据是恒真的）

`analysis/solve_slide.py` 第一次跑出自称"一致"的 slide，我据此以为关卡已过 —— **错**。
**独立复采立刻证伪**：两次采集解出的 slide 相差 `0xa6e8`（42 KB），却都报告
"1018/1020、1019/1020 一致"。原因很直接：
> **内核 text 里符号区间是首尾相接铺满的（没有空洞）** ⇒ "每个样本减去 s 后都落在某个符号区间内"
> 等价于"落在 `[_stext,_etext]` 窗口内" ⇒ 这个判据对**几乎所有** s 都成立，是恒真的。

而且 arm64 的 KASLR 位移是相对 **2MB 对齐的运行时基址**，而链接期 `_text=0xffffffc010080000`
本身 **不是 2MB 对齐**（低 21 位 = 0x80000）⇒ 我一开始想用"低 21 位相同"去猜 s 的做法也天然失效
（s 的低 21 位固定是 `0x180000` 那一类值，不是 0）。

**结论**：现在手里的是 = 设备同构建的完整符号表 ✓ + `enforce` 字段偏移 ✓ +
**运行时基址只定到 2MB 量级**（对写 `.bss` 里的 `selinux_state+1` 远远不够：2MB = 512 页，写错即崩）。

**真正锐利的判据（下次就用这个，已想清楚怎么做）**：
用**指令合法性**而不是符号区间做约束 —— 对候选 s（4 字节粒度，窗口 = 粗 fit ± 2MB）要求
"每条样本地址 a 处的 4 字节 `a-s` 在镜像里是一条**可执行指令**（非 0、非 padding 的
`udf #0`/`b .`、且下一条也解码合法）"。text 里函数对齐填充占百分之几，
1000 条独立样本同时满足的随机 s 通过率 ≈ `0.95^1000 ≈ 0` ⇒ 唯一解。
实现只要两步：先用 20 条样本粗筛（10⁶ 级候选，纯整数查表），再对幸存者用全样本确认。


## 13. slide 路线的**量化否定**（23:05，别再重复尝试）

把"代码词表"判据实现并跑通（`analysis/solve_slide2.py`，两处坑已修：
① 索引要减镜像基址；② 内核地址 > 2^63，**绝不能 `astype(np.int64)`**，否则变负数后溢出）。
测量结果：
- 设备 text 里 **非零字比例 0.997**，`(word>>26)` 的顶层指令类 **61/64 都在用**
  ⇒ 单个"词是否像代码"的判别力只有 ~0.3%＋3/64；
- 于是 60 条样本全部通过的候选有 **2,771,884 / 2,775,855 = 99.86%** ⇒ 判据基本恒真，
  脚本给出的"slide"其实是窗口里第一个候选，**无意义**。

**可达到的最好精度**：用"最大簇必须整体落进 `[_stext,_etext)`"这一条硬约束，
本次开机把 slide 限制在 **约 10.5 MB 的窗口**里（4 字节粒度 277 万个候选）。
对写 `.bss` 里的 `selinux_state+1` 来说，10.5 MB = 2688 页，**完全不可用**。

⇒ **结论（写死）**：`perf 自采样 IP + 静态镜像` 这条路**得不到字节精度的 KASLR base**。
   想要精确地址，只能要一个**真正的信息泄露漏洞**（把内核指针交到用户手里），
   而不是靠"猜对齐"。所以下一步应该回到"在可达的 6 个驱动面里找内核指针外泄"，
   或者接受"盲写 + 重试"这种会刷机的策略（不推荐）。

## 14. 但仍然有两项**确定的净收益**（下次直接站在它们上面）

1. **设备同构建的完整符号表**：`analysis/kallsyms_g2a88cd145def.txt`（179,181 行）
   + 镜像本体 `analysis/kernel_dev_g2a88cd145def.bin`；提取管线 `vmlinux_to_elf.kallsyms_finder`
   已经过三真值自校验。以后任何"这个函数/全局在哪"的问题都是查表，不再是猜测。
2. **`enforce` 的字段偏移**：`selinux_state + 1`（一手反汇编证据：`sel_write_enforce@0x107adb84`
   里 `adrp x0,selinux_state` + `strb w8,[x21,#1]`）；并确认 `+0` 是 `initialized`、`+0x10` 是 policy 指针
   ⇒ 一个"8 字节清零写"落在 `selinux_state+1` 恰好同时清掉 enforce 与相邻严格性布尔而**不碰** policy/initialized。
   另外新增可复用工具：`analysis/kdis.py`（裸 Image 的符号感知反汇编/全局引用扫描，
   正确性用 `security_hook_heads` 520 处引用验证过）。


## 15. 用同构建符号表做的第一次实用收益：帧大小全等 + 一个**没被测过的深通道候选**

工具 `analysis/framecmp.py`（比对两构建里同一函数的 prologue `sub sp, sp, #imm`）。

- **ghost 链与全部已知写通道：16/16 帧大小完全相同**
  （`do_sys_poll=0x3d0`、`do_select=0x1c0`、`core_sys_select=0x1c0`、`futex_wait_requeue_pi=0x1a0`、
  `futex_requeue=0x150`、`__rt_mutex_slowlock=0x50`、`pselect6=0x60`、`vfs_readv=0xf0`、
  `vmsplice=0x100`、`recvmmsg=0x60`…）
  ⇒ **09-24 量出的"要覆盖 [0x288,0x298] vs 上限 0x210"可以原样沿用**，不必重算（我本想验它是否失效）。
- **新发现：`sendmmsg` 一家不在旧通道清单里**（旧清单只有 `sendmsg ≤0x1B0`、`recvmmsg 0x1D0`）：
  `__arm64_sys_sendmmsg=0x1e0`、`__sys_sendmmsg=0x200`、`____sys_sendmsg=0x80`、`__sys_recvmsg=0x170`。
  这几帧里放的是**用户可控的 qword**（`struct mmsghdr` / `struct user_msghdr` 的
  `msg_name`/`msg_iov`/`msg_control`/各 len），且 `__sys_sendmmsg` 的循环变量在栈上跨多次迭代。
  ⇒ **待量**：这些栈槽相对"受害者睡在 `futex_wait_requeue_pi` 时的 sp"的实际深度，
     以及 ghost 写能否把 *可控语义*（prio/deadline 之类）摆到那里而不是摆成废指针。
     注意：这属于"写什么值 / 写到哪一层"两个问题里的**层深**问题，与 KASLR 无关。
- 两个工具坑（已修，记着别再犯）：① capstone 的 `op_str` 不含助记符；
  ② 我第一次用"含 `sub` 的样例字符串"自测 ⇒ 自校验输入与真实调用点不同，没抓到 bug（这正是本档反复出现的那类错误）。


## 16. GhostLock 层深：把两个"未量"候选真的量了一遍（设备构建，一手反汇编）

目标窗口（旧会话已量，本次比对帧大小证明**可直接沿用**）：悬空 `rt_waiter` 占
**深度 `[0x248, 0x298]`**（相对 syscall 入口 S0，地址 = S0 − 深度），
需要"单向（只读入、不回写）+ 长度 ≥0x50 + 深端 ≥0x298"的缓冲正好盖住它。

| 候选通道 | 实测(设备构建 g2a88) | 结论 |
|---|---|---|
| **`perf_event_open`** 的 `struct perf_event_attr`(128B) | `__arm64_sys_perf_event_open` 只是 `stp x29,x30,[sp,#-0x10]!` 的转发桩；`attr` 在 `__do_sys_perf_event_open`，其帧 **0x160** ⇒ Σ = 0x10+0x160 = **0x170** | **太浅，排除**（旧文档列为"未量"）。而且它只在 shell 域可达（app 的 perf_event_open = EACCES） |
| **`sendmsg` 族** 的 `sockaddr_storage`(128B) | `copy_msghdr_from_user` 出现在 `__sys_sendmsg`(帧 **0x1B0**) 与 `0x111d38e4`；**`_copy_from_user`(即 sockaddr) 落在 `____sys_sendmsg`**（帧 0x80，@0x111d341c）⇒ Σ = F(`__arm64_sys_sendmsg`) + 0x1B0 + 0x80，其中 F(wrapper) 量到 **0x1e0**（帧），其范围内另有一处 `sub sp,#0x200` 归属未定 | **方向反了：不是太浅而是太深**（Σ ≳ 0x3B0 ⇒ 缓冲深度约 `[0x330,0x430]`，远超 `[0x248,0x298]`）。旧笔记猜的"≈0x190 太浅"是错的 |

**这次量测真正改变的是问题的形状**：可用的"深度旋钮"有两个（通道侧 Σ、以及 waiter 侧的 futex 链），
现已知的三档是：`pselect6 [0x198,0x210]`（差 **0x38**）、waiter 窗口 `[0x248,0x298]`、
`sendmsg sockaddr ≳[0x330,0x430]`。⇒ **中间那一档（0x248~0x298）才是搜索目标**：
要么找一个 Σ 落在 `0x2C8~0x320` 的单向缓冲，要么把 waiter 窗口整体下移到 sendmsg 能覆盖处。
**待办**：① 定下 `0x111d37a0` 那个 `sub sp,#0x200` 到底属于哪个函数（决定 Σ 的准确值）；
② 量 `recvmmsg`/`getrandom`/`ioctl`/`readahead` 等仍在增帧方向的通道；
③ 量 futex 侧有没有"多一层帧"的合法变体（`FUTEX_WAIT_REQUEUE_PI` 的不同入口、`__arm64_compat_sys_futex` 是否可达）。

> 纪律提醒（写给下一轮也写给我自己）：本轮我几次把"帧大小相同"误当成"结论必同"，
> 也把旧笔记的**估计值**（sendmsg ≈0x190）当成了量值 —— 表中凡标"实测"的都是从反汇编指令读出来的，
> 其余是待办。
