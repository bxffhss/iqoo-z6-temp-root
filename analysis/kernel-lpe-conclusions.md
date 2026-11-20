# iQOO Z6 (PD2220A) 内核提权 — 结论记录

- 设备: vivo iQOO Z6 PD2220A, SoC SM7325 (Snapdragon 778G / Adreno 642L)
- 内核: 5.4.281-qgki (镜像 `gbfef221370b4`), Android 14
- 状态: SELinux enforcing, 无 root (`persist.sys.is_root=0`, `blackroot=true`), kptr_restrict 拒读, uid 无 system
- 记录时间: 2026-09-15

## 宗旨

记录已用实测证据判定"不可用"的内核写原语与可达性边界,避免后续重复排查。

---

## A. 补丁基线(决定选线)

- vendor(内核驱动侧)SPL = **2024-02-01**; framework SPL = 2025-04-01; kernel 5.4.281-qgki。
- 含义: **common 内核较新,但 vendor 驱动(KGSL/secure_buffer 等)停在 2024-02** → 2024-02 之后至今(2026-09)的高通/内核 CVE 大概率未打。
- 两条可用路线: KGSL 图形面(shell 可达)与 mem_protect 族(shell 不可直达)。

---

## B. 已判死的内核写原语(GPU 图形面)

### 1. GhostLock / CVE-2026-43499 (futex PI UAF, pselect 路由)
- 现象: 每次 race `calls=1 success=0`,`step=33`(route not verified)→ `route_signal=false` → 内核读写不落地。
- 波及: KPHYS 17 候选×physmap 零命中零崩溃;WTARGET 直写镜像 VA 无效;覆盖 DDR 0x80000000–0xd0000000。
- 判定: 硬件几何限制(waiter_node words_per_set),GhostLock README 列为 "Not Feasible"。

### 2. GPUAF / CVE-2024-23380 (KGSL VBO UAF)
- 实测修正: `GPUMEM_ALLOC_ID`(0x34)返回真实 id(BMO=0x1,VBO=0x2)+ gpuaddr。早期"24 字节无 id"判定错在只测了旧 `GPUMEM_ALLOC(0x2f)`。
- 但仍不可用: kallsyms **无 `kgsl_ioctl_gpumem_bind_ranges`/`kgsl_sharedmem_vbo`/`kgsl_memdesc_add_range`** → 本代缺 VBO bind_ranges 区间树原语;`BIND_RANGES`(0x37)合法 id 下仍 EINVAL(本代非 bind_ranges)。

### 3. CVE-2025-21479 (KGSL GPU CP_SMMU_TABLE_UPDATE PTW)
- 引擎: A7xx 微码 bug —— `$12 & 0x3` 致用户可特权执行 `CP_SMMU_TABLE_UPDATE`(修复掩码 0x3→0x7)。
- 本机 **A6xx(Adreno 642L)**: SDS=IB3 ≠ AIB4 冲突 → **无此 bug**,PTW 假页表不激活,读回失败(`can't get GPU r/w`)。
- 判定: A6xx 上该原语族不存在(非常数问题)。曾误以 GPUVA 常数为根因,已推翻。

### 4. arm.so (CVE-2026-43499 网页载荷)
- 反汇编定论: **纯用户态 futex PI race 触发库**,无任何内核地址/符号(`run_child`/puncher/`select` 路由 + futex requeue 计时)。
- 原"写错内核地址导致重启"判定**错误**——无地址可写;重启源于竞态破坏内核 PI 等待链(几何不对→corrupt list→panic)。
- 与 1 同判: 几何限制,只崩不提权。

### 5. CVE-2026-21385 (KGSL 对齐符号扩展,2026-03 修)
- 定性更正: **非 KASLR infoleak**,而是 CWE-190 整数溢出→内存分配对齐破坏(内核写/破坏原语)。
- 补丁 2a3a06da 反向核对: 新增非 static `kgsl_get_align`,本机 kallsyms **无此符号 → 未打**。
- 实测(kgsl_align_ovl): 注入 align 指数 e=0..40(bit24/20/16/28 域),**gpuaddr 严格 4KB 递增、零重叠零错位零异常** → 普通 `GPUMEM_ALLOC_ID` 入口下 flags 高位**未映射到 `1<<align` 路径** → **经此入口不可达**。
- 边界: 未穷尽 SVM/mmap/secure/heap 路径;但作为图形面首选候选已足够判否。
- **补充实测(2026-09-15, kgsl_align_probe.c)**: 改测 `kgsl_gpumem_alloc` **独立 `align` 字段(offset 28)**, 而非 flags 高位:
  - 扫描 `align=0x1..0x20000000`(含单 bit 全 0..29 位), **所有分配均成功且 gpuaddr 全按固定步进, 无任何按 2^align 对齐/错位的响应** → align 字段被本内核忽略;
  - 溢出组合 `size=0xFFFFFFFFFF × align=大值` 返回 **EINVAL(22)** → **size 合法性在溢出前先被拒绝**, 溢出路径不可触;
  - SVM/secure 试探位(bit28/bit20)注入后仍是普通分配, 未切换 allocator。→ **"未穷尽"的 SVM/secure 分配路径在 gpumem_alloc 入口下同样不响应 align**, §B.5 结论由"入口不可达"升级为"该函数族本机不可触"。

**图形面结论: shell 唯一可达的 `/dev/kgsl-3d0` 上,5 个现代+旧代原语全部不可用。**

---

## C. mem_protect 族 (CVE-2026-0031/0032) 可达性

### C.1 决定性核实(2026-09-15): 本机无 CVE-2026-0031/0032 触发面
- **CVE-2026-0031/0032 位于 Google `common` kernel 的 `mem_protect.c`**,通过自定义系统调用 `__NR_mem_protect` 触发,arm64 handler 符号为 `__arm64_sys_mem_protect`(CWE-190 整数溢出 → OOB 写,CVSS PR:N)。
- **本机 kallsyms 全表搜不到 `__arm64_sys_mem_protect` / `sys_mem_protect`**(仅存在 `__arm64_sys_membarrier`/`memfd_create` 等其它 mem 系 handler)。
- **含义**: 本机内核**未编译该 mem_protect syscall(文件不存在/CONFIG 未开)** → **连触发入口都没有,更谈不上需不需要 system 上下文或 KASLR 前置**。
- **结论: "获得 system 上下文后走 mem_protect" 路线在本机不成立**,此前的 mem_protect 候选应整体撤销。

### C.2 澄清(避免以后误判)
- 本机符号表里的 `qcom_scm_mem_protect_{video,audio,region_id,lock_id2_flat,sd_ctrl}` 是**另一个东西** — Qualcomm SCM(secure firmware) 调用封装,经 `/dev/ion` 的 `ion_hyp_assign_*` ioctl 进入,与 CVE-2026-0031/0032 的 common-kernel `mem_protect.c` **无关**。
- 这两者常被混淆;凡涉及 CVE-2026-0031/0032 一律以 **`__arm64_sys_mem_protect` 符号存在与否**定判,不再以 qcom_scm_mem_protect_* 为准。

---

## D. /dev 可达面穷举(dev_scan, 深度递归 + 显式命中, 2026-09-15)

### D.1 实测可达清单(uid=2000 shell, SELinux enforcing)

```
W  /dev/uinput          W  /dev/uhid          W  /dev/ptmx
W  /dev/log/much/drop/common
W  /dev/ashmem*         W  /dev/null/zero/urandom/random
W  /dev/kgsl-3d0        W  /dev/binder        W  /dev/hwbinder
R  /dev/ion
R  /dev/input/event0..6
```

### D.2 ioctl 面实测(区分"open 可达"与"ioctl 攻击面可达")

| 设备 | open | ioctl 代表性命中 | 判定 |
|---|---|---|---|
| `/dev/kgsl-3d0` | W | 0x34 alloc 正常工作(前测) | **shell 唯一 ioctl 实质可达的 GPU 面** |
| `/dev/ion` | **R 仅** (O_RDWR→EACCES) | magic '{B}'+{0x11} nr0..0x40 全 ENOTTY | **ioctl 对 shell 不可达**(RO.tab+ENOTTY) |
| `/dev/binder` | W | BINDER_VERSION → EPERM | SELinux 拦 ioctl |
| `/dev/hwbinder` | W | magic 0x62/0x63/0xc0 全无 handled 命中(非EINVAL即EPERM) | ioctl 未放行/未识别 |

### D.3 更正
- **推翻此前"`/dev/kgsl-3d0 是 shell 唯一可达设备`"的判定**(probe_dev 只显式测了 5 个节点)。
- 实际上 shell 可 open 的还有 binder/hwbinder/ion(RO)/uinput/uhid/log/ashmem。但**逐一实测 ioctl 后**:
  - ion(RO) + binder/hwbinder 的 **ioctl 均被 SELinux 或驱动拒/不识别** → 无 shell 触发面。
  - 仅 kgsl ioctl 实质可用 → **D.2 表回到与 §B 一致的结论: 内核交互攻击面只有 kgsl**,但 kgsl 5 原语已全部判死。
- 因此**全局结论不受影响**: shell 侧仍无 ioctl 可达的内核写原语;mem_protect(ion)需 system 上下文。

---

## E. 本地材料与工具

- 镜像: `analysis/kernel` 44,661,248B, SHA256 D55AC8337B71, 5.4.281-qgki-gbfef。
- 符号表: `analysis/embedded-kallsyms.txt` 179,171 行(kgsl_* 597、mem_protect 29、qcom_secure 36)。
- VA-file 映射: KERNEL_CONST 已校准(dis_tl3): file = va − 0xffffffc01010f6e0。
- 关键核对: CVE-2022-22057 已打(kernel 含 `kref_get_unless_zero` 饱和感知原子 `cmn #-4`/`ldaddal`),2024-02 之前的 KGSL/timeline CVE 均在此机已修 → 窗口仅在 2024-02 之后。

---

## F. 全局结论

1. **两条线的可达性已收敛为"均不可行"**: KGSL 可达但 5 原语全死;mem_protect 族(CVE-2026-0031/0032)**本机无 `__arm64_sys_mem_protect` 触发面**(common-kernel syscall 未编译),**彻底撤销**。
2. **"从 shell 临时 root"当前无现成可达路径**,且"先获 system 上下文再走 mem_protect"这条预想路线**也不成立**(本机根本无 mem_protect syscall)。
3. 剩余可探索方向(不再含 mem_protect): 2024-02 之后的高通**内核写/破坏原语**(非 common-kernel syscall 族)。所有候选一律以**符号存在性**定判(CVE-2026-0031/0032 判例即为一课:不可仅凭"技术面匹配"预设可利用)。

4. **"换更高权限进程载体"(option 2) 实测亦不可行/低价值**(2026-09-15): 见 G。

---

## G. system 上下文载体探测(option 2 评估, 2026-09-15)

### G.1 目标
不从内核下手,而是找一个以 `system` 运行的进程当"载体",经其用户态面拿到 system-uid 原生代码执行,再解锁 shell 打不开的 `/dev/ion`/binder。满足"以 system 运行 + shell 可达其接口"两个条件的候选即"载体",再评估其是否有可落地的用户态拿码路径。

### G.2 可达性实测(shell, uid 2000, SELinux enforcing)
- 全表列出系统级 vendor daemon 后,对 `/dev/socket/*` 与 abstract socket 逐个 `connect()`:
  - `/dev/socket/vdtf`(vivo Transfer, system, pid 1273)→ **SOCK_DGRAM connect=0 CONNECTED**(send 被接受, 唯一 SELinux 放行的 system 接口)。
  - `/dev/socket/ssgqmig`、`/dev/socket/dpmd`、`/dev/socket/qesd`、`/dev/socket/ipacm_log_file`、`@mobilelogd`(mobile_log_d)→ **EACCES SELINUX-DENY**。
  - `@vdtf_pivot`、`@mobilelogd_dynamic`、`@bbsdk_identity`、`@vivo_logd_ctrl`→ REFUSED(无监听/名不符)。
- 结论: 载体候选**唯一收敛到 vdtf**,且仅"接口可达",无更多。

### G.3 为何 vdtf 载体验证不成立(投入产出判定)
1. **无现成漏洞**: 公开 CVE/PoC 无 vdtf daemon 本体的代码执行漏洞(vivo"互传"CVE-2025-15515 是局域网 app 层信息泄露,与此 socket daemon 无关)→ 只能自挖 0-day(逆向协议解析器找内存破坏)。
2. **二进制不可读**: `adb pull /vendor/lib64/hw/vendor.vivo.hardware.vdtf@1.0-impl.so` 与 `/vendor/bin/hw/vendor.vivo.hardware.vdtf@1.0-service` 对 shell **均 Permission denied** → 连逆向前置(读 vendor 二进制)都被 SELinux 挡住,shell 侧无抓手。
3. **即便拿到 system 上下文,收益兑现不了**: 它只解锁 `/dev/ion`(仅有 qcom_scm_mem_protect_* SCM 封装,非提权路径)与完整 binder(仍需再找一个 binder 服务 bug)。**mem_protect syscall 本机根本没有**,不因有 system 上下文而出现。
- 判定: option 2"换更高权限进程载体"在 2024-02 后主流内核下,**可达性与价值不可兼得**——可达的(vdtf)无现成 bug 且二进制被锁,有系统位的又全局 SELinux 挡死。**不作为下一步投入**。

---

## I. "2024-02 之后高通内核写/破坏原语" 枚举 + 符号定判(2026-09-15)

### I.1 候选集(来源: Qualcomm 2024-08 security bulletin, OSS Graphics Linux = KGSL)
- 窗口依据: 本机 vendor SPL = 2024-02-01 → 下述 CVE customer-notified 均在 2024/05/06 与 2024/07/01,晚于窗口 → **大概率未打**。
- OSS Graphics Linux(kgsl, in-tree)候选:
  - CVE-2024-23380 VBO UAF(bind_ranges 区间树) — §B2 已判死
  - CVE-2024-23381 VBO 未由 GPU SMMU unmap 致 UAF
  - CVE-2024-23382 创建 DMA fence 时 UAF
  - CVE-2024-23383 触发硬件 fence 时 UAF
  - CVE-2024-23384 shrinker 回放时 VBO 页仍 mapped → UAF
  - CVE-2024-33023 timeline fence UAF — §H2 已判死(只崩不提权 + KASLR 前置)
  - CVE-2024-33034 VBO 持过期 GPU SMMU 映射 → UAF
- OSS 中唯一的"非 UAF 竞态"类是 **CVE-2024-33027**(Improper Access Control, 用户态经 GPU 页表损坏直接改 DDR)。
- 专有(proprietary, 非 kgsl)项 CVE-2024-33021/33022(HGSL automotive GPU)对本机 SM7325 无关,剔。

### I.2 本机符号定判(embedded-kallsyms.txt)
- **VBO/稀疏/区间树系 缺失**(无 `kgsl_sharedmem_vbo`/`kgsl_memdesc_add_range`/bind_range/grow/sparse 符号)。
  → CVE-2024-23380/23381/23384/33034 的载荷体(kgsl_mem_entry + bind_ranges 区间树)**本机不存在**,同 §B2 → **判死**。
- **SMMU 系为全局/静态 ops**(`kgsl_iommu_{map,unmap,set_pt,get_ttbr0,get_gpuaddr,...}`, 非 per-ctx 动态页表存储):
  → A6xx/本代 `msm-5.4` graphics-kernel **不是**可借 SMMU 页表劫持拿 DDR 读写 的设计;
  → CVE-2024-33027(与 CVE-2025-21479 同类)**结构性缺失**(与 §B3 A6xx 无此 bug 的结论互相印证)→ **判死**。
- **timeline/DMA-fence 系存在**(`kgsl_sync_fence_create`/`kgsl_sync_timeline_signal`/`kgsl_sync_cancel`/`kgsl_drawobj_add_sync_*`):
  → CVE-2024-23382/23383 理论上符号在,但属"timeline fence UAF + 竞态"类,与 §A(2022-22057 已打饱和感知原子)+ §H2 同判 → **易崩不提权,不投入**。

### I.3 结论
- **2024-02 之后 OSS 高通 KGSL 写/破坏原语全集在本机均已判死**,且判死原因分为三类:
  1. VBO/bind_ranges 载荷体缺失(23380/23381/23384/33034);
  2. SMMU 页表劫持原始语在本代(A6xx/msm-5.4 全局 iommu)结构上不存在(33027,同 21479);
  3. timeline-fence UAF 只崩不提权且需先解 KASLR(23382/23383/33023)。
- 与 §F 全局一致: **从 shell 临时 root 无现成可达路径**。所有候选要么缺触发面、要么是"竞态即崩"的 UAF、要么缺 KASLR。
- **继续投入的唯一前置**: 解 KASLR 泄漏(perf_event_paranoid=-1 路)。KASLR 解出后可选重估 23382/23383 的堆 feng-shui 成本,但预期仍是"高崩溃率提权",不推荐为首选。

---

## H. 反汇编映射勘误 + CVE-2024-33023 定判撤回(2026-09-15)

### H.1 关键发现:本镜像**不存在全图唯一**的 VA→file 线性常量
- §E 记的 `file = va − 0xffffffc01010f6e0`(dis_tl3)对文本区是**错的**;本次实测文本段正确基址为 **`text_va 0xffffffc010080000 ↔ file 0x1000`**,即 `file = va − 0xffffffc010080000 + 0x1000`,该映射在 `kgsl_ioctl_gpumem_alloc_id`、`dma_fence_add_callback` 真实入口等多处得到**整洁 SCS 序言**(`str x30,[x18],#8`)作为佐证。两常量相差 ~0x906e0(约 590KB)。
- 含义: 本会话**此前对 CVE-2024-33023 的"未打补丁"判定(基于 linux_banner 全局 KC 反汇编)建立在垃圾反汇编上,整体撤回,不可信**。凡后续以"符号 存在性/反汇编 模式"定判,先用 H.1 的文本基址校准,且**必须核对 SC S 函数序言**而非直接信 kallsyms 条目(=本地标签,常指向冷路径/内部偏移,如 `dma_fence_add_callback` 真实入口 0xbaa058 而非符号位 0xbaa19c)。

### H.2 CVE-2024-33023 现实评估(KGSL timeline fence UAF, 2024-02 后)
- 该 CVE 属"同步 fence UAF + 竞态 → 堆损坏"类,需同时满足: 竞态窗口、堆 feng-shui 构造、**KASLR 泄漏(本机无运行时符号,泄漏前置未解)**、以及将 UAF 收敛为内核写。四条在本机均已瓶颈(§B1–B5 设备几何/竞态即崩)。
- 结论: 即便补丁态判定为未打,**端到端落地的预期仍是 panic 而非 root**;与 arm.so(GhostLock 几何不符→崩溃)同属"只崩不提权"。建议**不把 CVE-2024-33023 作下一步落地投入**,除非先解 KASLR 泄漏。

---

## J. perf_event_paranoid=-1 → KASLR 泄漏路线证伪(2026-09-15, 决定性实测)

### J.1 前提被推翻
- §I.3/H.2 曾把"解 KASLR 泄漏(perf_event_paranoid=-1 路)"列为继续投入的唯一前置。**本机实测证明该路不成立。**

### J.2 实测证据链(全部真机, uid=2000 shell)
- `perf_event_paranoid == -1`(sysctl 可读),`perf_event_open` 对 SOFTWARE 事件**成功**(无 OPENFAIL)。
- 但 **采样写出路径整体失效**: 对 SW `TASK_CLOCK`/`CPU_CLOCK`, 各种 `exclude_user`(0/1)、`sample_period`(50–2000)、`pid = 自身 / -1`、`cpu = -1 / 0 / 2` 组合, **`perf_event_mmap_page.data_head` 恒为 0**, `read(fd)` 与 mmap-ring 两条消费路均零样本。
- 对照: 同事件在**计数模式**(`sample_type=0`)下计数器正常推进(≈1e9/s) → 事件本身存活, 是 **SAMPLE 记录(内核 IP)不产出**。
- `PERF_TYPE_HARDWARE` 周期事件 `EOPNOTSUPP(95)`: 硬件 PMU 被锁。
- 旁证: `/proc/kallsyms` 读 **Permission denied**; `/proc/sys/kernel/kptr_restrict`、`dmesg_restrict` **连文件都读不了**(SELinux 拒)。

### J.3 含义
- 无 unprivileged 内核指针/KASLR 泄漏来源(perf IP、kallsyms、dmesg、sysctl 全封)。
- **本机"先破 KASLR 再落地内核写" 与 "无 KASLR 直接写" 两条均走死**; 结合 §A–I, 从 shell 临时 root: **无可行候选**。
- 若要重启此线, 需先找到"shell 可达且有指针泄漏"的驱动面(§D 已穷举 /dev 无此类), 或换设备/换内核窗口。

---

## K. §D 之外(/proc /sys)指针泄漏面排查(2026-09-15)

### K.1 实测(uid=2000 shell, adb shell)
- 扫描 `timer_list/modules/slabinfo/sched_debug/interrupts/iomem/zoneinfo/kallsyms/vmallocinfo/self:maps/self/syscall/locks/meminfo/pagetypeinfo/…/tracing/…`:**无一输出内核 VA(0xffffffc…)**。
- 大部分高价值文件被 SELinux 直接隐藏(`[ -e ]` 为假): `kallsyms/vmallocinfo/iomem/sched_debug/…both tracing…` → 连存在都不可见。
- 可读但无指针: `timer_list`(无地址泄漏), `interrupts`, `zoneinfo`, `self/maps`, `meminfo`, `self/syscall`(仅用户态地址)。
- 决定性硬证据: **`/proc/modules` 可见,但所有模块基址被掩为 `0x0000000000000000`** → 内核指针被系统性地 `%pK`-型掩码(等同 kptr_restrict 生效), 与 §J 一致。

### K.2 结论
- 除 /dev 外, /proc + /sys + 模块地址 的指针泄漏面在本机**同样封闭**; 无任何 shell 可达源能泄漏内核文本/驱动地址。
- **KASLR / 内核指针泄漏前置在本机彻底无解**(perf 采样被禁、kallsyms/dmesg/模块地址全掩、debugfs 不可见)。
- 结合 §A–K: 本设备/本内核窗口下, **从 shell 临时 root 无可行候选**, 且**无法通过补 KASLR 打破** → 建议封存该方向, 除非换设备或更换未更新内核窗口。

---

## L. 最终确认(2026-09-15, 真机复核)

### L.1 逐项复核结果
| 项 | 实测 |
|---|---|
| `perf_event_paranoid` | = **-1**(可读); perf 采样仍零 IP 记录(§J) |
| `/proc/kallsyms` | **Permission denied** |
| `/proc/modules` | 可读, 但模块基址全掩为 `0x0000000000000000`, grep `ffffffc` **0 命中** |
| `/proc/timer_list` | **Permission denied**(纠正 §K: 非"可读空", 是不可读) |
| `dmesg`/`klogctl` | **Permission denied** |
| `/proc/self/syscall` | 仅用户态地址, 无内核 VA |

### L.2 综合定论(§A–L)
- 内核写/破坏原语全集判死(§B/§C/§I); 内核指针泄漏面(perf/kallsyms/dmesg/modules/debugfs/timer_list)全封(§J/§K)。
- **本 iQOO Z6(PD2220A, SM7325, 5.4.281-qgki, SPL2024-02) 在 uid=2000 shell 下临时 root: 无可行候选, 且无可补的 KASLR 前置。**
- 处置建议: **封存该方向**; 迁移到"同样 msm-5.4/QGKI 但 vendor 或 common 内核未更新、或 debug 构建可读 debugfs"的设备时, 优先重测: §B 已判死项是否复活、/dev 能否多开温度面、tracefs/kallsyms 是否解封。

---

## M. 迁移重试清单(在"新设备/新内核窗口"上按序重测)

> 目的: 本机 §B/§C/§I/§J/§K 的"判死"多数是**结构/环境性**(几何、SMMU 代次、SELinux、掩码), 换设备后先用最快 3 类门禁判断环境是否真的变了, 再决定是否复活重测; 避免照抄本机结论。

### M.0 新设备环境快筛(≤5 分钟, 决定后续走哪条)
1. 内核版本 + QGKI: `uname -a`; 确认还是 `5.4-qgki` 还是更旧 `4.19`/`4.14`(更旧 = §B 旧代 KGSL CVE 窗口可能打开)。
2. vendor/核心 SPL: `getprop | grep -i spatch` 或 `build.prop`; **SPL 早于某 CVE 修复日** → 该 CVE 候选复活。
3. 是否 debug/可读符号:
   - `cat /proc/kallsyms | head` 是否给地址(非 denied)。
   - `ls /sys/kernel/tracing/ /sys/kernel/debug/` 是否可见/可读。
   - `dmesg | head` 是否可读。
   - `cat /proc/modules` 基址是否非 0。
   - 以上任一为真 → **KASLR 泄漏前置解除** → 优先重走 §I 的 timeline-fence UAF(23382/23383/33023) 与 §B 旧代项。
4. `getprop | grep -i blackroot` / `persist.sys.is_root` / 是否已有 init root → 决定是否还需走内核。

### M.1 内核写原语复活重测(按设备代次)
- **A7xx GPU**(新骁龙): CVE-2025-21479(`CP_SMMU_TABLE_UPDATE`, §B3) **可复活**——A6xx 的 SDS≠AIB4 限制是 A6xx 专有的。
- **A6xx 但 vendor 驱动 < 2024-02**: 重测 VBO/bind_ranges 族(23380/23381/23384/33034, §B2/§I2)——若新机稀疏/VBO 符号存在(`kgsl_sharedmem_vbo` 等)则载荷体在, 可落地。
- **非 A6xx / 更老驱动**: 重测 GhostLock 几何(§B1)——`waiter_node words_per_set` 设备相关, 换 SoC/内存控制器后可能由 "Not Feasible" 变可达。
- **common 内核较旧(带 `__arm64_sys_mem_protect`)**: 重走 §C mem_protect 族——本机判死只因"符号不存在", 换个编译了该 syscall 的 common 内核即复活。

### M.2 指针泄漏面复活重测(§J/§K 依赖)
- 依次重测: perf IP 采样(`perf_kaslr_mmap` 工具保留) → `kallsyms` → `dmesg` → `/proc/modules` → `/sys/kernel/tracing/trace`。
- 任一解封 → KASLR 前置解除, 才有资格评估 §I 高崩溃率 UAF 的 feng-shui。

### M.3 触发/工具沿用
- `/dev/kgsl-3d0` ioctl 分发表:`analysis/embedded-kallsyms.txt`(若新机也是同源码系可直接沿用; 否则重新导)。
- 反汇编映射: 换内核必重做 §H 校准(勿直接套用本机 `text_va 0xffffffc010080000`)。
- 判死文档是本机的, 不作为新机的充分条件; 每复活一项需在 §B–K 对应条目旁标注"新机 ✔/✘"。

---

## N. GhostLock 端到端重试(修正 POPOFF + 限定 KPHYS, 2026-09-15)

> 用户选定"真机端到端尝试 GhostLock(CVE-2026-43499)"。从 `C:\ghostlock_work` 源码现编译 `ghostlock` 122KB, 推送 `/data/local/tmp/ghostlock` 真机运行(log: `/data/local/tmp/gl_run.log`)。

### N.1 运行参数与现象
- env: `POPOFF=0xffffffc000000000 KPHYS=0xa8000000 PHYSOFF=0x80000000`。
- W1(SELinux enforcing)目标被正确按线性映射置为 **`0xffffffc02aa98000`**(POPOFF 生效)。
- KernelSnitch 冒泡发现 `mm_struct=0xffffff80 0002bc00`(IDENTITY 区仍在 0xffffff80, 未被 POPOFF 环境变量一并改)。
- **逐一 W1 尝试(5/5)均 `pselect returned calls=1 success=0 step=33 route_signal=false` → 写未发出, "Write 1 failed"。**

### N.2 判读
- **route 落位失败发生在 futex-PI 等待链的几何阶段(`step=33`), 与写目标基址(0xffffff80 vs 0xffffffc0)无关**: 两次基址下均不落位。
- 一致性注记: KernelSnitch 实际在 0xffffff80 找到真实 mm_struct, 暗示 direct/linear map 基址**可能本就是 0xffffff80**(VA_BITS=48 型), 而非之前误改的 0xffffffc0; 但该歧义被 route 几何失败遮蔽, 无论选哪个 `step=33` 恒成立。
- **结论: 本次"修正 POPOFF + 限定 KPHYS"端到端重试, 复现并锁定 §B.1: 该硬件上 pselect/futex-PI 路由无法落位 → GhostLock 内核写原语不可用(只崩不提权/或零写)。** §B.1 判死成立, 无新突破。

---

## O. GhostLock 适配门禁定判(2026-09-15, 对照 README + 真机复核)

> 起因: 逐条对照 GhostLock README 的适配条件, 判定本机是否具备临时 root 可能。

### O.1 真机实测(adb, uid=2000 shell)

| 项 | 实测值 |
|---|---|
| 机型 / device | **V2220A / PD2220**(iQOO Z6) |
| SoC | **SM7325**(YUPIK, soc_id 475, Snapdragon 778G, Adreno 642L/A6xx) |
| 内核 | **5.4.281-qgki-g2a88cd145def**(SMP PREEMPT, 2025-05-07) |
| Android | 14 (UP1A.231005.007, compiler05071149) |
| framework SPL / vendor SPL | 2025-04-01 / **2024-02-01** |
| BL 状态 | `vbmeta=locked`, `flash.locked=1`, `verifiedbootstate=green`, `sys.oem_unlock_allowed=0` |
| `/proc/iomem` | 不可读(§K 一致) |

### O.2 四道适配门禁(全部不通过)

1. **内核版本门槛(决定性)**: README 声明影响范围 **5.7 – 7.1**;本机 **5.4.281 < 5.7** → 落在范围外。
   → 这不是"几何/偏移"问题, 是**漏洞面本身不覆盖**, 调 PSELECT_SHIFT / KPHYS / POPOFF 均救不回。
2. **无 5.4 结构布局支持**: 仓库仅提供 `STRUCT_OFFSETS_6_12` / `_6_6` / `_6_1` / `_5_10`, 最旧 5.10; 设备表无任何 5.4 条目。
3. **SM7325 的 `kernel_phys_load` 未知**: 偏移表只收录 SM8845/SM8750/SM8650/SM8850, 且 README 明示"错值静默失败"。
4. **真机端到端**: §N 已有 5/5 `step=33 route_signal=false`, 零写落地 —— 与 1 一致。

### O.3 两处材料与真机不一致(必须记, 防止误判)

- **离线内核 ≠ 运行内核**: `analysis/kernel` 与 OTA 包均为 `gbfef221370b4`;**真机运行 `g2a88cd145def`**(同为 5.4.281-qgki, 但不同 build)。
  → §B/§H/§I 基于符号存在性的判死**全部是对 gbfef 镜像做的**, 严格说未覆盖真机 build。版本门槛(§O.2.1)不受此影响, 但若要复活 §I 的 vendor 原语, 需先重导真机 kallsyms。
- **`ro.board.platform=lahaina`(SM8350)是假值**, 真实 SoC 由 `soc0/machine=YUPIK`、`soc_id=475`、`/proc/cpuinfo` 三方确认为 **SM7325**。勿用该 prop 判定 GPU 代次。

### O.4 OTA 包警告

- `boot_extract/`(PD2220_A_14.2.13.0.W10)的 **vendor SPL = 2025-12-05**, 远新于真机 2024-02-01, 内核仍是 5.4.281-qgki-gbfef。
- **若刷入该包, 2024-02→2024-08 的 vendor CVE 窗口将被整体关闭**, 本机唯一残留的理论窗口消失 → 在找到落地路径前**不要升级**。

### O.5 定论

- **GhostLock(CVE-2026-43499)在本机不可用**, 主因是内核版本低于漏洞范围下限(5.7), 与 §B.1/§N 的实测互相印证。
- **本机临时 root: 仍无可行候选**。§B(KGSL 五原语)、§C/§F(mem_protect 无 syscall 面)、§I(2024-08 后 KGSL 全集)、§J/§K(指针泄漏全封)、§G(载体)均已判死; BL 锁且 `oem_unlock_allowed=0`, 解锁路线亦关闭。
- **建议**: 封存本机, 换设备。按 README 已验证清单优先选 6.12/6.6 机型; 若坚持 5.x 窗口, 按 `vendor-old-retry-checklist.md` 逐项重测, 且先在真机 build 上重导 kallsyms(勿沿用 gbfef)。

---

## P. 真机内核配置 + tracefs 面复测(2026-09-15, 继续 §O)

> 目标: 补上 §O.3 暴露的"离线镜像 ≠ 真机 build"缺口, 并复核 §J/§K 的"指针泄漏全封"。

### P.1 新增可用信息源(此前未被利用)

| 源 | 状态 | 产出 |
|---|---|---|
| `/proc/config.gz` | **可读**(42KB) | 已导出 `analysis/live/live-kernel-config.txt`, 5651 行, 真机 5.4.281 配置 |
| `/sys/module/` | 可读, 265 项 | 已加载模块清单 |
| `/vendor/lib/modules/*.ko` | **仅可列目录名, 文件内容不可读** | 见 Q.1(本节此行原记"可读", 已更正) |
| `/sys/kernel/tracing/` | **可见 + 部分可写** | 见 P.4(纠正 §K) |
| boot 分区 `/dev/block/sde11` | `brw------- root root`, dd → **Permission denied** | 无法取真机 boot.img |
| `/sys/module/*/sections/.text` | **Permission denied** | 无模块基址 |

### P.2 §N 的 POPOFF 用错(决定性修正)

- 真机配置 **`CONFIG_ARM64_VA_BITS=39`** → 线性映射(PAGE_OFFSET)基址 = **`0xFFFFFF8000000000`**。
- 硬证据: §N 中 KernelSnitch 实到 `mm_struct=0xffffff800002bc00`, 落在该区间。
- §N 使用 `POPOFF=0xffffffc000000000` → 算出的 W1 目标 `0xffffffc02aa98000` 落在**内核镜像区**(KIMAGE), 不是 linear map, **偏了 0x40000000**。
- 该错误当时被 route 几何失败(`step=33`)完全掩盖。**修正它也不会让 GhostLock 复活**(§O.2.1 版本门槛在前), 但**换 5.10+ 设备重试时必须用 `0xFFFFFF8000000000` 作为 linear map 基址**, 否则同样的错会再犯一次。

### P.3 真机硬化清单(决定哪些原语即使拿到也用不了)

| 配置 | 值 | 对提权的影响 |
|---|---|---|
| `CONFIG_ARM64_VA_BITS` | 39 | linear map = `0xFFFFFF8000000000` |
| `CONFIG_RANDOMIZE_BASE` | y | KASLR 开 |
| `CONFIG_RANDOMIZE_MODULE_REGION_FULL` | y | 模块区独立随机 |
| **`CONFIG_CFI_CLANG`** | **y** | **间接调用 / ops 表劫持被拦** → GhostLock Path A 的 miscdevice fops 重定向, 即便有写原语也会被 CFI 挡下 |
| `CONFIG_SHADOW_CALL_STACK` | y | 返回地址保护 |
| `CONFIG_LTO` | y | 栈帧布局受 PGO/LTO 影响(GhostLock 几何即栽在此类) |
| `CONFIG_ARM64_PAN` / `UAO` / `SW_TTBR0_PAN` | y | 内核态不直接读用户内存 |
| `CONFIG_UNMAP_KERNEL_AT_EL0`(KPTI) | y | 用户态无内核映射可读 |
| `CONFIG_HARDENED_USERCOPY` | y | usercopy 越界检查 |
| `DEBUG_LIST` / `SLUB_DEBUG` / `BUG_ON_DATA_CORRUPTION` | y | 链表/堆损坏即 panic → UAF 极难稳定利用 |
| `CONFIG_VMAP_STACK` | y | 栈溢出跨页即崩 |
| `CONFIG_KALLSYMS` / `KALLSYMS_ALL` | y | 符号全量(离线镜像分析有效) |
| `CONFIG_FUNCTION_TRACER` / `DYNAMIC_FTRACE` | **未开** | 无 `set_ftrace_filter`, 无法 function trace |
| `CONFIG_KASAN` / `KFENCE` / `INIT_ON_FREE` | **未开** | 无 sanitizer; 释放后不清零(对 UAF 略有利) |

### P.4 tracefs 实测 —— 纠正 §K, 但结论不变

- **§K 记载"tracing 不可见"是错误的**: `/sys/kernel/tracing/` 可见, 且有 **113 个全局可写**文件。
- 可**成功写入**的 `events/<subsys>/enable`: **cgroup / dma_fence / ipi / irq / sde**。
- 写入被 SELinux 拒: 全局 `events/enable`、`kgsl`、`ion`、`regulator`、`workqueue`。
- 读取被拒: `current_tracer`、`set_event`、`kprobe_events`、`available_tracers`、`saved_cmdlines`。
- **指针泄漏实测: 无。** `ipi_entry/ipi_exit/ipi_raise` 确有 `const char *reason`(8 字节裸内核指针), 但 `TP_printk` 以 `%s` 解引用, 输出的是字符串("IRQ work interrupts")而非地址。开启全部 5 个子系统采样 3 秒、**114955 条记录, grep `ffffff` 零命中**。
- **结论: KASLR 仍然封死**, §J/§K 的"无指针泄漏"判定成立; 仅"tracing 不可见"这句**作废**。
- 实测后已将 5 个子系统 enable 复位为 0, `tracing_on` 复位为 1(系统状态已还原)。

### P.5 净结论

- **KASLR 未解** → §I 的 timeline-fence UAF(23382/23383/33023) 仍无资格评估(仍卡 feng-shui 前置)。
- **GhostLock 双重判死**: ① 内核 5.4 < 漏洞下限 5.7(§O.2.1); ② 纵使有写原语, `CONFIG_CFI_CLANG=y` 会拦 fops 重定向(§P.3)。
- **本机临时 root 仍无可行候选**, 与 §O.5 一致。
- **新增两件可用工具**(不提权, 但对后续 exploit 开发有价值):
  1. `dma_fence` tracepoint 可开 → **无需 root 即可观测 KGSL timeline/fence 时序**, 可用于调试 fence 竞态。
  2. `dma_fence` tracepoint 可开 → 无需 root 即可观测 KGSL timeline/fence 时序(注: 该条成立)。
- ~~2'. vendor `.ko` 文件可 pull → 可静态审计~~ **作废, 见 Q.1**。

---

## Q. vendor .ko 静态审计 + /dev 可达面全量复核(2026-09-15)

### Q.1 vendor .ko 静态审计: 三条路全部不通

| 路径 | 结果 |
|---|---|
| 真机 `adb pull /vendor/lib/modules/*.ko` | **Permission denied**。`ls` 能列名字(readdir 放行), 但 `ls -l` 显示 `-?????????`、读内容拒。** §P.1 原记"可读"是误判(未带 `-l` 的 `ls` 只走了 readdir), 已更正。** |
| `5.4-gki/` 子目录 | 目录本身 `drwxr-xr-x root shell`, 但内含文件同样 `-?????????`, 读拒 |
| OTA 包(`boot_extract`)离线提取 | vendor 分区 16 个分片约 **1.3GB**; 偏移 1024 处命中 **EROF 超级块 magic `0xE0F5E1E2`** → 确认 EROFS; 扫 96MB 得 274 个 `\x7fELF` 命中但 **0 个合法 AArch64 ELF 头**(`vermagic=` 亦零命中) → **数据被 LZ4 压缩, 直接雕刻不可行**, 需完整 EROFS 解析 + LZ4 解压 |

- 即便做出来, 拿到的也是 **OTA 版(compiler06180932 / vendor SPL 2025-12-05)的已打补丁代码**, 而非真机在跑的 compiler05071149(SPL 2024-02)。对"找未修漏洞"价值倒挂。
- 且这些 vendor 驱动创建的设备节点 shell **均打不开**(Q.2) → 拿到代码也不可达。
- **判定: 该方向投入产出比不成立, 停止。**

### Q.2 /dev 可达面全量复核 —— 纠正 §D 枚举不全, 但结论仍成立

- §D 只记了约 10 个节点。**真机实际有数百个**(含 `/dev/qseecom`、`/dev/adsprpc-smd`、`/dev/dri/card0`、`/dev/synx_device`、`/dev/vivo_haptic`、`/dev/vivo_torch`、`/dev/wlan`、`/dev/media0`、`/dev/video*` 等 §D 完全未覆盖者)。
- 以 `dd if=X of=/dev/null bs=1 count=0` **按退出码**逐测全量字符设备(排除 block/snd/hvc/pts/input/ramdump/subsys):
  - **实际可 open 的仅 13 个**: `ashmem*`(按实例名)、`ion`、`kgsl-3d0`、`log/{common,drop,much}`、`null`、`ptmx`、`random`、`uhid`、`uinput`、`urandom`、`zero`。
  - 其余全部 **Permission denied**。
- 典型反例(文件权限宽松但被 **SELinux** 拒): `/dev/dri/card0` 与 `/dev/vivo_torch` 均为 `crw-rw-rw-`, `/dev/vivo_haptic` 为 `crw-rw-r--`, **shell 依然打不开** → 证明拦的是 SELinux 而非文件 mode。
- **结论: §D 的枚举严重不全, 但"shell 实质可达的 ioctl 面只有 kgsl"这一结论经受住了全量复核。** 注意 `/dev/ion` 仅只读可达(O_RDWR 被 SELinux 拒, §D 已记)。

### Q.3 KGSL ioctl 分发表全集(唯一真正可达的内核面)

- `CONFIG_QCOM_KGSL=y` → **KGSL 是 built-in, 不在 vendor .ko 里**, 就在已有的 `analysis/kernel` 中 → 这才是该审计的目标。
- kallsyms 提取: kgsl/adreno 符号 **2504** 个,`kgsl_ioctl_*` 条目 110 个, **去重后 44 项**(含辅助函数)。

**真实 ioctl 处理器全集(去重、剔除 compat/cfi_jt):**

```
device_getproperty / device_setproperty / device_waittimestamp_ctxtid
cmdstream_readtimestamp_ctxtid / cmdstream_freememontimestamp_ctxtid
drawctxt_create / drawctxt_destroy
gpu_command / gpu_aux_command / rb_issueibcmds / submit_commands / timestamp_event
gpumem_alloc / gpumem_alloc_id / gpumem_free_id / gpumem_get_info
gpumem_sync_cache / gpumem_sync_cache_bulk
gpuobj_alloc / gpuobj_free / gpuobj_import / gpuobj_info / gpuobj_set_info / gpuobj_sync
map_user_mem / sharedmem_flush_cache / sharedmem_free
syncsource_create / syncsource_create_fence / syncsource_destroy / syncsource_signal_fence
timeline_create / timeline_destroy / timeline_fence_get / timeline_query / timeline_signal / timeline_wait
```

- **存在性判定(复核 §B/§I)**:
  - 缺失: `kgsl_ioctl_gpumem_bind_ranges`、`kgsl_sharedmem_vbo`、`kgsl_memdesc_add_range`、`kgsl_ioctl_sparse_alloc` → **§B.2 / §I.2 的"VBO / bind_ranges 载荷体缺失"成立**, CVE-2024-23380/23381/23384/33034 判死不变。
  - 存在: 全部 `timeline_*` 与 `syncsource_*` → §I.2 判"符号在但易崩不提权", 成立。

### Q.4 本轮真正的增量: 存在一个"可达但从未实测"的面

- §B 在真机上只打过 `GPUMEM_ALLOC(0x2f)`、`GPUMEM_ALLOC_ID(0x34)`、`BIND_RANGES(0x37)` 与 align 字段 —— **44 项里只覆盖了 3~4 项**。
- 以下 handler **shell 可达(`/dev/kgsl-3d0` 为 `crw-rw-rw-`)但从未在真机上探过**:
  - `timeline_*`(6 项)、`syncsource_*`(4 项) —— 与 §I 的 fence UAF 直接相关
  - `gpuobj_*`(6 项)、`map_user_mem`、`sharedmem_*`、`drawctxt_*`、`gpu_command / submit_commands / rb_issueibcmds`
- 建议: 若还要在本机投入, 下一步应是**对这批未测 handler 做参数化的存在性/健壮性探测**(先确认能通、再看能否触发异常), 而不是继续做拿不到、且不可达的 vendor .ko 审计。
- 前置提醒: 仍未解决 KASLR(§J/§K/P.4)与 `CONFIG_CFI_CLANG=y`(§P.3), 即便撞出内存破坏, 收敛为稳定提权的预期依旧很低。

---

## R. KGSL ioctl 分发表**真机实测**(2026-09-15, 补 §Q.4)

> §B/§I 一直停留在"符号存在性"推论, 从未实测分发表。本节用自写探针在真机 `/dev/kgsl-3d0` 上直接扫。
> 工具: `kgsl_sweep.c`(nr 全扫) / `kgsl_size.c`(尺寸扫描) / `kgsl_call.c`(单次转储) / `kgsl_rep.c`(重复调用) / `kgsl_cd.c`(create-destroy)。
> 编译: NDK r27 `aarch64-linux-android35-clang -O2 -static`。

### R.1 nr 全扫结果(magic=0x09, size=0, nr 0x00–0xFF)

- **256 个 nr 中 43 个被路由**(其余 213 个 ENOTTY)。已路由清单(括号内为 errno):

| nr | errno | | nr | errno | | nr | errno |
|---|---|---|---|---|---|---|---|
| 0x02 | 19 ENODEV | | 0x38 | **0 SUCCESS** | | 0x49 | 22 EINVAL |
| 0x07 | 22 EINVAL | | 0x39 | **0 SUCCESS** | | 0x4a | 22 EINVAL |
| 0x10 | 22 EINVAL | | 0x3a | **0 SUCCESS** | | 0x4b | 95 EOPNOTSUPP |
| 0x13 | 22 EINVAL | | 0x3b | **1 EPERM** | | 0x4c | 22 EINVAL |
| 0x14 | 22 EINVAL | | 0x3c | 22 EINVAL | | 0x57 | 22 EINVAL |
| 0x15 | 95 EOPNOTSUPP | | 0x3d | 22 EINVAL | | 0x58 | **0 SUCCESS** |
| 0x16 | 22 EINVAL | | 0x40 | **0 SUCCESS** | | 0x59 | 22 EINVAL |
| 0x17 | 22 EINVAL | | 0x41 | 22 EINVAL | | 0x5a | 19 ENODEV |
| 0x20 | 95 EOPNOTSUPP | | 0x42 | 22 EINVAL | | 0x5b | 11 EAGAIN |
| 0x21 | 22 EINVAL | | 0x43 | 22 EINVAL | | 0x5c | 19 ENODEV |
| 0x24 | 22 EINVAL | | 0x45 | 22 EINVAL | | 0x5d | 19 ENODEV |
| 0x2f | 22 EINVAL(§B 的 GPUMEM_ALLOC) | | 0x46 | 22 EINVAL | | | |
| 0x32 | 19 ENODEV | | 0x47 | 22 EINVAL(BIND_RANGES) | | | |
| 0x33/0x34/0x35/0x36/0x37 | 22 EINVAL(0x34 = ALLOC_ID) | | 0x48 | **524** | | | |

### R.2 尺寸扫描(对 43 个 nr × 10 种 size = 0/8/16/24/32/48/64/96/128/256)

- **errno 对 size 完全不敏感**: 每个 nr 在全部 10 种 size 下 errno **完全相同** → **驱动不校验 `_IOC_SIZE`**(宽松点, 值得记)。
- 但**输出回写依赖 size**: size=0 时内核不回写(min(user,kernel) 语义), 仅 size≥实际结构时才看得到返回数据。

### R.3 create / destroy 实测(本轮最有价值的发现)

- **`0x40` 是 create 类**: size=256 下重复调用返回 **1, 2, 3, 4**(递增 id) → **shell 可创建内核对象并拿到句柄**。
- **`0x41` 是其 destroy**: `destroy(id=1)` → **ret=0 成功**; 二次/三次 destroy 同一 id → **EINVAL**。
  → **句柄被正确失效, 无双释放**。与 §I.4"CVE-2022-22057 已打饱和感知原子"一致, 该经典路径确已关闭。
- `0x58` 在 `u64[1]` 返回递增计数(17,18,19,20,22), 但 `0x59` 代入该值一律 EINVAL → **0x59 不是其 destroy 或字段布局不同**, 配对假设不成立。
- `0x38` 返回常量 `0x0000041B_0000041A`(=1050/1051 两个 u32), `0x3a` 返回常量 `0xE00000000` → 非 create 类, 更像读属性/全局计数。
- 全程多次探测后设备未崩溃(`uname -r` 正常返回)。

### R.4 结论

- **首次用实测替代"符号存在性"推论**, 确认真机 KGSL 分发表共 **43 个可达 handler**, 并定位到 **0x40/0x41 这一对 shell 可达的 create/destroy**。
- **未发现任何新的可利用原语**: 无双释放、无越界、无非授权访问; 固定 errno 的那些(0x3b EPERM / 0x48 524 / 0x15·0x20·0x4b EOPNOTSUPP / 0x02·0x32·0x5a·0x5c·0x5d ENODEV / 0x5b EAGAIN)均为能力未开或参数不符。
- **判定: 本机临时 root 仍无可行候选**(与 §O.5 / §P.5 / §Q.4 一致), 但攻击面已从"符号推测"收敛为"43 个实测可达 handler + 1 对 create/destroy"。
- 若继续投入, 唯一切实的方向是把 `0x40` 创建出的对象句柄与其余 handler(0x42/0x43/0x45/0x46/0x4a/0x4c 等)做**组合状态机测试**; 但 KASLR 未解 + CFI 开启(§P.3)意味着即便撞出问题也难收敛为提权。

---

## S. nr → 名称映射 + 对象语义实测(2026-09-15, 继续 §R)

> 依据公开 `msm_kgsl.h` / `kgsl_ioctl.c`(KGSL_IOC_TYPE=0x09, 分发表按 `_IOC_NR` 索引)与本机实测行为交叉比对。
> 工具: `kgsl_combo.c`(句柄差分) / `kgsl_seq.c`(序列转储) / `kgsl_var.c`(字段布局) / `kgsl_ptr.c`(用户指针)。

### S.1 映射表(置信度分级)

**高置信**(公开头文件直接给出, 且与实测行为吻合):

| nr | 名称 | 实测 errno | 说明 |
|---|---|---|---|
| 0x02 | `DEVICE_GETPROPERTY` | 19→**0** | `u64[0]`=type; type=1 时**成功** → `KGSL_PROP_DEVICE_INFO` |
| 0x07 | `DEVICE_WAITTIMESTAMP_CTXTID` | 22 | |
| 0x10 | `RINGBUFFER_ISSUEIBCMDS` | 22 | |
| 0x13 / 0x14 | `DRAWCTXT_CREATE` / `_DESTROY` | 22 / 22 | |
| 0x15 | `MAP_USER_MEM` | 95 | 能力未开 |
| 0x16 / 0x17 | `SHAREDMEM_FROM_PMEM` / `_FREE` | 22 / 22 | |
| 0x20 / 0x21 | 同上(compat 号) | 95 / 22 | |
| 0x2f | `GPUMEM_ALLOC` | 22 | `u64[1]`=len; 置 1 时**成功** |
| 0x32 | `SETPROPERTY` | 19 | |
| 0x33 | `TIMESTAMP_EVENT` | 22 | |
| 0x34 | `GPUMEM_ALLOC_ID` | 22 | §B 已用 |
| 0x35 / 0x36 / 0x37 | `GPUMEM_FREE_ID` / `GET_INFO` / `SYNC_CACHE` | 22 | |
| **0x47** | **`GPUMEM_BIND_RANGES`** | 22 | **修正 §B**: §B 记作 0x37, 实为 **0x47**(0x37 是 SYNC_CACHE)。本工作区 `kgsl_probe.c` 里的 0x47 才是对的 |

**中置信**(按分发表顺序推断, 行为吻合):

| nr | 疑似名称 | 实测行为 |
|---|---|---|
| 0x38 | `GPUMEM_SYNC_CACHE_BULK`(数组型) | 返回递增 id 对(1050/1051 → 1058/1059), 像全局 idr 计数 |
| 0x39 | `SYNCSOURCE_CREATE` | 状态依赖(有时 0, 有时 ENODEV) |
| 0x3a | `SYNCSOURCE_DESTROY` | 成功; 输出随输入变(0xE00000000 → 0x400000000) |
| 0x3b | `SYNCSOURCE_CREATE_FENCE` | **恒定 EPERM** |
| 0x3c | `SYNCSOURCE_SIGNAL_FENCE` | **见 S.2, 会解引用用户指针** |
| 0x40 / 0x41 | 对象 create / destroy 对 | 见 S.3 |
| 0x42 | 对象 info 查询 | 成功, 返回 `(id, 4)` |
| **0x43** | **`GPUOBJ_IMPORT`** | **恒定 EBADF** —— 需 dma-buf fd, 我们传了 0 |
| 0x45 | 对象 sync / info | 成功, 返回 `4096 / 786432 / 4096` |

### S.2 最值得注意的发现:0x3c 会解引用用户指针

- `u64[0]=id, u64[1]=1` → **errno 14 (EFAULT)** —— 内核把 `u64[1]` 当**用户态指针**访问了。
- 换成**合法用户指针** → 不再 EFAULT, 变为 **EINVAL**(指针被接受, 内容被拒)。
- 含义: **0x3c 是数组/指针型 ioctl**, 结构形如 `{id, __user *ptr, count}`。此类 ioctl 历来是 count / 长度校验的重灾区。
- 但元素格式猜不中(count=0..4 全 EINVAL) → 需真实结构体定义才能继续。**这是目前唯一还有"结构性"挖掘价值的点。**

### S.3 0x40/0x41 是 create/destroy 对象对

- `0x40` 重复调用返回 **1, 2, 3, 4**(递增句柄); `0x41(id)` 成功; 二次 `0x41` → EINVAL。
- 候选身份: **`GPUOBJ_ALLOC`/`GPUOBJ_FREE`** 或 **`SYNCSOURCE_CREATE`/`SYNCSOURCE_DESTROY`** —— 两者行为均符合, 现有证据不足以区分。
- 该句柄被 0x42 / 0x45 / 0x38 / 0x3a / 0x02 消费(差分扫描: errno 偏离零输入基线)。
- 无双释放(§R.3)。

### S.4 本轮结论

- **43 个可达 handler 已命名到可操作粒度**, 攻击面不再是黑盒。
- **未发现可利用原语**。0x3c 的用户指针解引用是唯一有结构价值的线索, 但需真实结构体定义。
- **阻塞项未变**: KASLR 未解(§J/§K/P.4)、CFI 开(§P.3)、PAN/UAO/KPTI 开(§P.3)。即便 0x3c 存在内存破坏, 从"写原语"到"稳定提权"仍隔着三道硬化。
- **下一步建议(按性价比)**:
  1. 拉一份 **5.4 的完整 `msm_kgsl.h`**(codelinaro / CAF 的 msm-5.4 分支), 把 0x38–0x5d 全部定名并拿到 0x3c 的真实结构体 → 成本最低、收益最直接。
  2. 用 `0x02 GETPROPERTY`(type=1 已成功)配真实输出缓冲读出 `kgsl_devinfo`(chip_id / gmem_base / min-max gpuaddr), 确认映射并拿到 GPU 地址空间布局。
  3. 若 1、2 完成且 0x3c 暴露出问题, 仍需先解 KASLR 才谈利用。

---

## T. 权威结构体定义 + GPU 对象/fence 能力实测(2026-09-15)

> 取得公开 `msm_kgsl.h` 片段(android.googlesource kernel/msm + mesa3d 版)后, 用**真实结构体**重新操作。
> 工具: `kgsl_obj.c`。**本节修正 §S.1 中置信部分的错误推断。**

### T.1 权威编号(来自头文件原文)

| nr | 名称 | 结构体 |
|---|---|---|
| 0x42 | `SYNCSOURCE_CREATE_FENCE` | `{u32 id; int fence_fd; u32 pad[4];}` |
| 0x43 | `SYNCSOURCE_SIGNAL_FENCE` | `{u32 id; int fence_fd; u32 pad[4];}` |
| 0x44 | `CFF_SYNC_GPUOBJ` | `{u64 offset, length; u32 id;}` |
| 0x45 | `GPUOBJ_ALLOC` | `{u64 size, flags, va_len, mmapsize; u32 id; u32 metadata_len; u64 metadata;}` |
| 0x46 | `GPUOBJ_FREE` | `{u64 flags; u64 __user priv; u32 id, type, len;}` |
| 0x59 | `TIMELINE_WAIT` | |
| 0x5A | `TIMELINE_QUERY` | |
| 0x5B | `TIMELINE_SIGNAL` | `{u64 timelines; u32 count; u32 timelines_size;}` ← **用户指针数组型** |
| 0x5C | `TIMELINE_FENCE_GET` | `{u64 seqno; u32 timeline; int handle;}` |
| 0x5D | `TIMELINE_DESTROY` | `__u32` |

### T.2 对 §S 的修正(**重要**)

- **§S.1 猜"timeline 系列在 0x39–0x3e"是错的** —— 实际在 **0x57–0x5D**。相应地:
  - 0x40/0x41 = **`SYNCSOURCE_CREATE` / `SYNCSOURCE_DESTROY`**(而非 GPUOBJ_ALLOC/FREE)。
  - 0x42 = `SYNCSOURCE_CREATE_FENCE`(我之前当"对象 info 查询"——错)。
  - 0x45/0x46 = `GPUOBJ_ALLOC` / `GPUOBJ_FREE`(我之前没认出来)。
- **0x43 恒定 EBADF 的成因确认**: `SYNCSOURCE_SIGNAL_FENCE` 需要一个**真实的 fence_fd**, 我们传 0 → EBADF。不是权限问题。
- 0x3c 会解引用用户指针(§S.2)这一**实测事实不变**, 但其身份待定(可能是 `GPUOBJ_SYNC` 之类), 不再断言为 SIGNAL_FENCE。
- 注: timeline 系列(0x57–0x5D)在本机 errno 分别为 22/0/22/19/11/19/19, 说明均已路由但未以零参数成功。

### T.3 新确认的可达能力(真机实测成功)

| 能力 | 调用 | 结果 |
|---|---|---|
| 分配 GPU 对象 | `GPUOBJ_ALLOC(0x45)` size=0x1000 | **成功**, id=1, mmapsize=4096 |
| 释放 GPU 对象 | `GPUOBJ_FREE(0x46)` id=1 | **成功**; 二次释放 → EINVAL(无双释放) |
| 创建 syncsource | `SYNCSOURCE_CREATE(0x40)` | **成功**, id=1 |
| 创建 sync fence | `SYNCSOURCE_CREATE_FENCE(0x42)` | **成功**, 返回 **fence_fd=4**, `fcntl(F_GETFD)` 验证**有效** |

- 全程设备未崩溃。

### T.4 评估

- **shell 现在可**: ① 任意大小分配/释放 GPU 对象; ② 创建并**持有 dma_fence 生命周期**(真实 fd)。
- 这恰是 fence UAF 类漏洞(CVE-2024-23382 / 23383 / 33023)所需的**操作面** —— 此前 §I.2 只从符号推断"存在", 现在已能实际驱动。
- **但仍缺三样, 且一个都没解决**: KASLR 未解(§J/§K/P.4)、无写原语、CFI 开启(§P.3)。
- **结论不变: 本机临时 root 无可行候选。** 但攻击面从"黑盒 43 个 nr"升级为"**命名齐全 + GPU 对象与 fence 生命周期可实际操控**"。
- **下一步(若继续)**: 用 0x40/0x42 造 fence、配合 0x45/0x46 做 GPU 对象堆喷, 观察 fence 释放与对象释放的竞态(即 23382/23383 的触发面); 但需先解决 KASLR 才能把崩溃转成利用。

---

## U. KASLR 攻破(2026-09-15)—— §J 判定被证伪

> **这是本项目最重大的反转。** §J/§L 曾"决定性"判定 perf 采样被禁、无内核指针泄漏, 并据此把本机封存。该判定**错误**。

### U.1 §J 错在哪(旧工具 `perf_kaslr.c` / `perf_kaslr2.c` 的三个 bug)

| 缺陷 | 后果 |
|---|---|
| 默认 `exclude_user=0` | 绝大多数样本是用户态 IP, 内核 IP 被淹没 |
| **从不回写 `data_tail`** | 环形缓冲满后生产者停摆, 后续样本全部丢弃 |
| 采样期间只调 `getpid` | 内核态时间占比低; 未做 `IOC_ENABLE/RESET` |

修正版 `perf_kaslr3.c`: `exclude_user=1` + 采样期持续 `read()` 触发系统调用 + 消费后回写 `data_tail` + 显式 `IOC_ENABLE`。

### U.2 实测结果(真机)

```
[A exclude_user=0] samples=10674  kernel=9465   (对照: 采样通路正常)
[B exclude_user=1] samples=10674  kernel=10674  (全内核态)
    min=0xffffffe65f281dfc  max=0xffffffe66078a794  span=0x1508998 (~21.5MB)
```

- **稳定可复现**: 两次运行 `min` 完全一致 = `0xffffffe65f281dfc`。
- 采样速率约 **1.3 万样本/秒**, 其中内核态占比 ~100%(配置 B)。
- 高频地址示例: `0xffffffe66075e430`(3865 次)、`0xffffffe65f28be4c`(1931)、`0xffffffe65f4c63fc`(1609)。

### U.3 决定性判定: 该区域确为内核 text

`perf_chain.c` 打印完整调用链:

```
sample IP=0xffffffe65f9bac58  depth=22
  [1..14] 0xffffffe65f9bac58 ... 0xffffffe65f284f08   全部 0xffffffeX
  [15]    0xfffffffffffffe00        <- PERF_CONTEXT_USER 标记
  [16..21] 0x260bdc 0x219a7c ...    <- 用户态帧
```

- **14 层连续内核帧 + 明确的 kernel→user 边界帧**, 说明 `read()` 的完整调用栈(syscall 入口 → vfs → 驱动)**整体位于 0xffffffe5–0xffffffe6**。
- span ~21.5MB 与内核镜像(text+rodata)体量吻合。
- **结论: 内核 text 基址 ≈ 0xffffffe5f2000000 量级(2MB 对齐), 最小观测值 0xffffffe65f281dfc。**

### U.4 由此改变的判断

- **KASLR 不再是阻塞项。** §J / §K / §L / §P.4 中"无内核指针泄漏源""KASLR 全封"的记载**作废**。
- §I.2 把 timeline-fence UAF(23382/23383/33023)判死的三条理由中, "**KASLR 泄漏前置未解**"这条**已解除**; 剩余"易崩 + 需堆 feng-shui"仍在, 但不再是死局。
- §O.5 / §P.5 / §Q.4 / §R.4 / §T.4 的"本机临时 root 无可行候选"结论**需要重估** —— 它建立在 KASLR 不可解之上。
- **建议撤销"封存本机"的处置建议。**

### U.5 遗留问题与下一步

1. **符号基址需重新推导**: `analysis/embedded-kallsyms.txt` 记 `_text=0xffffffc010080000`, 与实测的 0xffffffe6 区**不一致**(可能该文件来源镜像与真机 build 布局不同, 或 §H 的基址校准遗留问题)。
   → 需先用实测 `min` 与 gbfef 符号做**差分指纹比对**标定真机 `_text`, 才能把 IP 解析成符号。
2. **线性映射基址待确认**: §P.2 由 `CONFIG_ARM64_VA_BITS=39` 推得 `0xFFFFFF8000000000`, 但 text 落在 0xffffffe6 说明实际布局与推想不同, 需实测校正(关系到写原语的目标地址计算)。
3. 之后才谈得上使用 §T.3 的 GPU 对象/fence 能力做堆布局与 fence 竞态。

> **注意**: 本节只证明"能拿到内核地址", **尚未获得写原语**。CFI(§P.3)仍在。但 KASLR 这道总闸门已经打开。

---

## V. 符号基址标定完成(2026-09-15)

> 工具: `calib_base.py`。把 §U 采到的裸 IP 翻译成真实符号地址。

### V.1 方法(两步)

1. **text 区间夹逼**: 采样点必须是可执行代码, 故翻译后须落在 gbfef 的 `[_stext, _etext]` 内:
   - `B ≤ min_ip − (_stext − _text)`
   - `B ≥ max_ip − (_etext − _text)`
   - 实测 gbfef text = **21.1MB**, 样本 span = **20.9MB** → 区间仅剩 **0.09MB**(0x16668)。
2. **相位约束定唯一解**: arm64 KASLR slide 以 2MB 为粒度, 故 `_text mod 2MB` 应与 gbfef 一致(`0x80000`)。在区间内取满足该相位的唯一值。

> 注: 直接用"符号最近邻"打分是**无效**的 —— 179k 符号在 44MB 内平均间距约 250 字节, 任何偏移 4KB 内都能命中(实测全部 27/27 满分, 零区分度)。必须靠**区间 + 相位**这类结构约束。

### V.2 结果

```
真机 _text  = 0xffffffe65f280000
真机 _stext = 0xffffffe65f281000
真机 _etext = 0xffffffe6607a0000
KASLR slide = 0x264f200000
```

### V.3 校验(采样点解析完全自洽)

| 采样 IP | 解析结果 | 是否符合 workload |
|---|---|---|
| `0x...65f53310c` | `__arm64_sys_sched_yield +0x0` | ✅ **精确入口**, 我们确实在调 `sched_yield` |
| `0x...65f284f08` | `el0_svc +0x8` | ✅ 系统调用入口 |
| `0x...65f4c63fc` | `el0_svc_common +0x4c` | ✅ |
| `0x...65f28be4c/50/58/70` | `__arch_clear_user +0xc/10/18/30` | ✅ `read(/dev/zero)` 清用户缓冲 |
| `0x...65f2a87cc` | `__clear_user +0x108` | ✅ |
| `0x...65f7a7b74/bb0` | `__fdget_pos +0x1c/58` | ✅ fd 查找 |
| `0x...65fa29718` | `copy_page_from_iter_iovec +0x344` | ✅ |
| `0x...66075e430` | `_raw_spin_unlock +0x34` | ✅ |

→ **真机 text 布局与 gbfef 镜像一致**, 可直接用 gbfef 偏移推算任意符号。

### V.4 提权相关符号地址(本次标定的直接产出)

| 符号 | 真机地址 |
|---|---|
| `commit_creds` | `0xffffffe65f51f154` |
| `prepare_kernel_cred` | `0xffffffe65f51f67c` |
| `init_cred` | `0xffffffe661b3d528` |
| `selinux_state` | `0xffffffe661d18000` |
| `__arm64_sys_futex` | `0xffffffe65f5eb870` |
| `futex_wait_requeue_pi` | `0xffffffe65f5eb2d8` |
| `core_sys_select` | `0xffffffe65f799988` |
| `__arm64_sys_pselect6` | `0xffffffe65f79a52c` |
| `kgsl_ioctl` | `0xffffffe65fc865ec` |
| `kgsl_ioctl_timeline_create` | `0xffffffe65fc97760` |
| `kgsl_ioctl_gpuobj_alloc` | `0xffffffe65fc7bc60` |
| `init_task` | `0xffffffe661b2e200` |
| `swapper_pg_dir` | `0xffffffe6615bb000` |

### V.5 意义

- **KASLR 不再是不确定性来源**: 现在能给出任意内核符号的真实运行时地址。
- 关键门槛的剩余状态: **写原语仍缺**(§B/§I 的 KGSL 原语判死仍成立), **CFI 仍开**(§P.3)。
- 但 `selinux_state` / `init_cred` / `commit_creds` 地址已知, 意味着**一旦获得写原语, 提权路径是现成的**(改 `cred` 或关 SELinux), 不再需要额外的信息泄漏。
- **下一步最值钱的两件事**:
  1. 找一个写原语 —— 现在有了地址, §I 的 timeline-fence UAF(0x5B `TIMELINE_SIGNAL` 是用户指针数组型, §T.1)值得重新评估;
  2. 复核 §P.2 的线性映射基址(text 在 0xffffffe6 说明原推想有误, 需实测校正)。

---

## W. 线性映射(PAGE_OFFSET)校正尝试(2026-09-15)

> 工具: `calib_lmap.py`。**结论: 无法在"无读原语"的前提下算出 PAGE_OFFSET**, 但拿到了**一旦有读原语即可一步求出它的全部地址**。

### W.0 先厘清: 到底需不需要 PAGE_OFFSET

- **写原语按"内核 VA 直接写"(如 GhostLock 的 PI write) → 不需要。** §V 已给出全部符号的真实 VA, 直接写 `selinux_state` / `init_cred` 即可。
- **写原语按"物理地址 + 线性映射别名"(physmap 型) → 需要。** 本节服务于这种情况。

### W.1 尝试的推导路径

`CONFIG_ARM64_VA_BITS=39` + `4K_PAGES` + `SPARSEMEM_VMEMMAP`, 理论上:
`VMEMMAP_START = PAGE_OFFSET − VMEMMAP_SIZE`, 而 `VMEMMAP_SIZE = 1<<(39−12−1+6) = 4GB`。
→ 只要知道 `vmemmap` 的真机地址即可反推 PAGE_OFFSET。

**但失败**: kallsyms 里的 `vmemmap` 是 **.data 中的一个 8 字节指针变量**, 不是数组基址。它和以下变量紧挨:

```
0xffffffc01222ae68  D  module_alloc_base
0xffffffc01222ae70  D  memstart_addr
0xffffffc01222ae78  D  physvirt_offset
0xffffffc01222ae80  D  vmemmap
0xffffffc01222ae88  D  arm64_dma_phys_limit
0xffffffc01222ae90  D  kimage_voffset
```

→ **PAGE_OFFSET 的值存在 `physvirt_offset`/`memstart_addr` 里, 而非可从符号地址推导。** 解析式: `PAGE_OFFSET = physvirt_offset + memstart_addr`(依赖 `__virt_to_phys` 实现), 需**读内存**才能得到。

### W.2 实测产出: 这些变量的真机地址(§V slide 换算)

| 变量 | 真机地址 | 用途 |
|---|---|---|
| `memstart_addr` | `0xffffffe66142ae70` | 物理内存起始 |
| `physvirt_offset` | `0xffffffe66142ae78` | **VA→PA 偏移量, 直接决定 PAGE_OFFSET** |
| `vmemmap` | `0xffffffe66142ae80` | struct page 数组基址 |
| `kimage_voffset` | `0xffffffe66142ae90` | 内核镜像 slide, 可**交叉验证 §V 的 0x264f200000** |
| `module_alloc_base` | `0xffffffe66142ae68` | 模块分配基址 |

**一旦获得读原语, 第一件事就读这 5 个地址**, 其中 `kimage_voffset` 还能反过来校验 §V 标定是否正确 —— 若读到 `0x264f200000` 则说明 §V 完全正确。

### W.3 对既有结论的修正

- **§P.2 的"linear map = 0xFFFFFF8000000000"标注为未经证实**。实测 text 落在 `0xffffffe65f280000`(距 VA_START 约 27GB), 与任何 39-bit 标准布局的常见推想都对不上, 说明该机 VA 布局非典型(大 KASLR 偏移或厂商改动)。在读到 `physvirt_offset` 之前, 不要用它计算写入地址。
- §N 中"POPOFF 用错"的判断**同样存疑**: 现在有了真实符号 VA, 应直接用 §V 的地址, 不再依赖 linear map 换算。

### W.4 下一步

1. **优先: 找写原语**。若为 VA 直写型, 现有信息已够; 若为 physmap 型, 先读 `physvirt_offset`。
2. 候选重点: `0x5B TIMELINE_SIGNAL`(`{u64 timelines; u32 count; u32 timelines_size}` 用户指针数组型, §T.1) 与 §T.3 已验证可用的 GPU 对象/fence 能力。
3. 拿到任意读能力后, 第一时间读 `0xffffffe66142ae78`(physvirt_offset)与 `0xffffffe66142ae90`(kimage_voffset)。

---

## X. `0x5B TIMELINE_SIGNAL` 专项(2026-09-15)—— 假设证伪, 但 timeline API 打通

> 工具: `kgsl_tl.c` / `kgsl_tl2.c` / `kgsl_tl3.c` / `kgsl_tl4.c`。

### X.1 结构确认

- `0x58` = `TIMELINE_CREATE`(返回 timeline id; 0x57 为 EINVAL, 不是 create)。
- `struct kgsl_timeline_signal { u64 timelines; u32 count; u32 timelines_size; }`
- **元素尺寸为 12 字节**(非 8): 布局 `{ u64 seqno; u32 timeline; }`(packed)。

### X.2 `tsize` 参数面 —— 被严格约束, 无步长控制

缓冲区每个 u32 均填为有效 id(排除数据合法性干扰)后扫描:

| tsize | 结果 |
|---|---|
| 4, 8 | ENODEV(读不到 offset 8 的 timeline 字段) |
| **12** | **SUCCESS(唯一可用值)** |
| 16 | **EINVAL** |
| 20/24/32/48/64/128/256/1024/4096 | **EFAULT** |

→ **驱动确实做了尺寸校验**, `timelines_size` 不能当作可控步长/拷贝长度。**"数组型 ioctl 校验缺失"的假设不成立。**

### X.3 `count` 参数面 —— 无溢出、无崩溃

- 大缓冲(1MB)下 `count` = 1/16/256/4096/32768/87381 **全部成功**。
- `count` = 0x7fffffff / 0xffffffff → ENODEV(越界元素 timeline=0), **非 EINVAL/ENOMEM/崩溃**。
- 小缓冲(4KB) + `count*tsize` 远超缓冲(48KB/768KB/12MB) → ENODEV, 未触发大规模越界拷贝。
- 全程**未崩溃**。

### X.4 意外收获: timeline API 从 shell 全部打通

| 调用 | 结果 |
|---|---|
| `TIMELINE_CREATE(0x58)` | 成功, 返回 id |
| `TIMELINE_SIGNAL(0x5B)` seq=5 | **成功** |
| `TIMELINE_FENCE_GET(0x5C)` seq=3 | **成功, 返回真实 fence fd** |
| `TIMELINE_DESTROY(0x5D)` | 成功 |

### X.5 生命周期/引用计数 —— 干净, 无 CVE-2022-22057 类问题

- **双销毁**: 首次成功, 第二/三次 → ENODEV → 句柄正确失效, **无 double-free**。
- **fence 与 destroy 并存**: 先 `fence_get` 取 fd, 再 destroy timeline → destroy 成功且 **fence fd 仍有效** → 引用计数正确。
- 非法 id(0/0xffffffff/999999)→ 一律 ENODEV。
- 观察到 **id 复用**(销毁后新建又得同一 id), 属 idr 正常回收。

### X.6 结论

- **`0x5B` 未产出写原语, 假设证伪。** timeline 子系统的参数校验与生命周期管理**硬化良好**。
- 结合 §T.3: shell 已能完整操控 **GPU 对象** 与 **syncsource / timeline 两套 fence 生命周期**, 操作能力齐备, 缺的只是**一个真正的内存破坏点**。
- **剩余唯一理论方向**: `TIMELINE_WAIT(0x59)` / `fence_get` 与 `TIMELINE_DESTROY(0x5D)` 的**并发竞态**(CVE-2024-23382/23383/33023), 需竞态 harness(多线程+同步), 属"高崩溃率"方向。
- 与 §I.2 预判一致: 即便触发, 收敛为稳定提权仍需绕过 CFI 与 DEBUG_LIST/SLUB_DEBUG 的 panic 倾向。

---

## Y. timeline 竞态专项(2026-09-15)—— 最后一条理论路径也被排除

> 工具: `kgsl_race.c`(基础竞态) / `kgsl_race2.c`(延迟扫描 + 销毁后使用)。

### Y.1 补齐的 API 布局

- `0x5A TIMELINE_QUERY` = `{ u64 seqno; u32 timeline; }`(12 字节) → **成功**。由此确认 `struct kgsl_timeline_val = {u64 seqno; u32 timeline;}`(packed, 12B)。
- `0x59 TIMELINE_WAIT` 未定出(4–32 字节全 EINVAL, ≥36 字节转 ENOENT, 疑似字段在大尺寸才对齐), 但**竞态不需要它**。

### Y.2 竞态 v1: fence_get vs destroy(400 轮)

```
TOTAL fence_ok=6094 fence_err=19506 destroy_ok=400 unexpected_errno=0
```
- 销毁后的 fence_get 一律 ENODEV(19)/EINVAL(22), **无任何异常 errno**。

### Y.3 竞态 v2: 延迟扫描 + 销毁后继续使用 fence(10 种延迟 × 120 轮 = 1200 轮)

| destroy 延迟 | fence 成功 | destroy 成功 | 销毁后 poll 报错 | 异常 |
|---|---|---|---|---|
| 0/1/2/5/10/20/50/100/200/500 us | 960/轮(全成功) | 120/轮(全成功) | **0** | **0** |

- **关键观察**: 销毁后 960 个 fence fd **全部仍可正常 `poll`** → fence 正确持有 timeline 引用, **不存在悬垂引用**。
- 全程设备未崩溃。

### Y.4 结论

- **CVE-2024-23382 / 23383 / 33023 类(dma_fence 与 timeline 引用计数竞态)在本机不成立。** 该子系统在并发与"销毁后使用"两种场景下均表现正确。
- 加上 §X(参数校验严格、双销毁被拒、非法 id 拒绝), **timeline 子系统整体硬化良好**。
- **§I.2 中"timeline-fence UAF"这条残留理论路径已实测排除。**

### Y.5 至此: 黑盒路径已穷尽

已覆盖:
1. 全部 43 个可达 handler 的参数面与生命周期(§Q/§S/§T/§X)
2. 数组型 ioctl 的 count/stride 校验(§X)
3. fence 与对象销毁的竞态及销毁后使用(§Y)
4. KASLR 与符号地址(§U/§V)

**未发现任何可利用的内存破坏点。**

### Y.6 若仍要在本机继续 —— 唯一有实质意义的方向

黑盒枚举已无空间, 剩下的是**源码级审计**:
1. 取 **msm-5.4 的 KGSL 源码**(codelinaro / CAF 的 msm-5.4 分支)的 `kgsl.c` / `kgsl_ioctl.c` / `kgsl_timeline.c` / `kgsl_sync.c`。
2. 与本机实测结果(ioctl 编号、结构体布局、可达 handler、硬化配置)对照, 找出**黑盒探不到的分支**(需特定 flags / 特定调用序列 / 特定硬件状态才进入的路径)。
3. 针对这些分支构造触发条件。

这是"读代码找漏洞"而非"继续枚举", 工作量与不确定性都显著更高, 但也是本机唯一还没做过的路径。

---

## Z. 补全编号映射 + GPU_COMMAND 可达性(2026-09-15)

> 工具: `kgsl_cmd.c` / `kgsl_ctx.c`。本轮补齐了 §S/§T 遗留的编号缺口, 并确认命令提交面不可达。

### Z.1 编号映射补全(据公开 `msm_kgsl.h` / `kgsl_ioctl.c`)

| nr | 名称 | 本机实测 |
|---|---|---|
| 0x40 / 0x41 | `SYNCSOURCE_CREATE` / `DESTROY` | 成功(§T.3) |
| 0x42 / 0x43 | `SYNCSOURCE_CREATE_FENCE` / `SIGNAL_FENCE` | 42 成功返 fd; 43 需真实 fd |
| 0x44 | `CFF_SYNC_GPUOBJ` | 未路由 |
| 0x45 / 0x46 | `GPUOBJ_ALLOC` / `FREE` | 成功(§T.3) |
| **0x47** | **`GPUOBJ_INFO`** | **成功, 返回 gpuaddr** |
| **0x48** | **`GPUOBJ_IMPORT`** | errno 524 |
| **0x49** | **`GPUOBJ_SYNC`** | EINVAL |
| **0x4A** | **`GPU_COMMAND`**(size 64) | **EINVAL(见 Z.3)** |
| **0x4B** | **`GPUOBJ_SET_INFO`** | EOPNOTSUPP |

**修正**: **`0x47` 是 `GPUOBJ_INFO`, 不是 `GPUMEM_BIND_RANGES`**。§B 记的 0x37 与本工作区旧 `kgsl_probe.c` 记的 0x47 **两者都错**。(`GPUMEM_BIND_RANGES` 位于 SPARSE 系列之后, 与本机 0x50–0x55 的 ENOTTY 区间吻合 —— 与外部同平台实践记载的"0x50-0x55 五个 SPARSE_* handler 为 NULL"一致。)

### Z.2 GPUOBJ_INFO 实测成功

```
GPUOBJ_ALLOC(0x45) size=0x1000 -> id=1, mmapsize=4096
GPUOBJ_INFO (0x47)            -> gpuaddr=0x4000000000, size=4096, va_len=4096
```

→ 分配/查询 GPU 对象的完整闭环可用, 且能拿到 **GPU 虚拟地址**。

### Z.3 `GPU_COMMAND(0x4A)` **不可达** —— 命令提交面关闭

- 前置: `DRAWCTXT_CREATE(0x13)`。实测 **flags = 全部 32 个单 bit + 多种组合 + 0, 一律 EINVAL**。
- 说明拒绝发生在 flags 校验**之前或之外**, 属 handler 全局拒绝(shell 上下文不具备创建 context 的条件)。
- 无 context ⇒ `GPU_COMMAND` 中的 `context_id` 必然查不到 ⇒ **命令提交链整体不可达**。
- 含义: **"IB 提交越界"这一类(外部同平台实践中挖出漏洞的正是此面)在本机从 shell 不可达。**
- 备注: 0x10 `RINGBUFFER_ISSUEIBCMDS`、`SUBMIT_COMMANDS` 同属命令提交面, 同样因缺 context 而不可达。

### Z.4 本机可达面最终结论

**从 uid=2000 shell 出发, 可达且已实测的内核攻击面为:**

| 面 | 状态 |
|---|---|
| GPU 内存对象分配/释放/查询(0x45/0x46/0x47) | ✅ 可用 |
| syncsource 及 fence(0x40–0x43) | ✅ 可用, 生命周期干净 |
| timeline 及 fence(0x57–0x5D) | ✅ 可用, 生命周期干净 |
| **draw context 与命令提交(0x13/0x4A/0x10)** | ❌ **不可达** |
| 其余(GPUMEM_* 等) | 已测, 参数校验严格 |

**结论: 所有可达面均已实测, 未发现内存破坏点; 唯一形态上最像有戏的"命令提交面"因无法建 context 而不可达。**

### Z.5 关于下一步的方法论(重要参考)

外部对同代平台(SM6375)做过高度相似的实践, 其有效路径是:

1. **从内核镜像 dump 出 `kgsl_ioctl_funcs` 分发表**(每项 16 字节 `{cmd, pad, handler}`), 与 `msm_kgsl.h` 的宏逐项比对 —— 本机已完成等价工作(§Q/§S/§T/§Z)。
2. **取同 SoC 平台、其他厂商的开源内核**(如 OnePlus / 小米的 OSS 仓库, 同为 msm-5.4 基线), 与设备 vendor 驱动做**跨厂商 diff**, diff 出的差异即"缺失的修复清单"。
3. 针对 diff 出的修复点构造触发条件。
4. 该实践最终在 **kgsl IB 越界**上取得突破 —— 但**本机该面不可达**(Z.3), 故不能直接套用。

→ 对本机而言, 跨厂商 diff 仍是唯一未做的路径, 但**必须先解决 context 不可达**这一前置, 否则命令提交类的差异点都无从触发。

---

## AA. mmap 路径与 GPUOBJ_IMPORT 专项(2026-09-15)

> §A–§Z 一直在用 ioctl, **`mmap` 这条路径此前从未测过**。本节补齐。
> 工具: `kgsl_mmap.c` / `kgsl_mmap2.c` / `kgsl_mmap3.c` / `kgsl_import.c`。

### AA.1 mmap 正常工作, 且能读写对象内存

```
GPUOBJ_ALLOC(0x45) size=0x1000 -> id=1, gpuaddr=0x4000000000, mmapsize=4096
mmap(NULL, 4096, RW, MAP_SHARED, fd, 0x4000000000) -> OK, 读写自检通过
```
→ 分配 → INFO 取 gpuaddr → mmap 的完整闭环可用。

### AA.2 mmap offset 语义解码(非标准, 但无越界)

分配 3 个对象(A=0x4000000000, B=0x4000001000, C=0x4000002000)后探测:

| offset | 结果 |
|---|---|
| 0x1000 | → 对象 A |
| 0x2000 | → 对象 B |
| 0x3000 | → 对象 C |
| 0x4000 及以上 | **EINVAL** |
| 0x100000 / 0x200000 / ... | **EINVAL** |
| 0x3ffffff000 (= A−0x1000) | **EINVAL** |
| 0x4000001000 (= A+0x1000) | **EINVAL** |
| 非页对齐(0x1234 / A+0x10) | **EINVAL** |
| size > 对象大小(64KB/1MB/256MB) | **EOVERFLOW** |

- **规律**: `offset = gpuaddr − 0x3FFFFFF000`, 即一套额外的"低地址"访问约定。
- **别名已证**: 用 offset=0x1000 写入 `0xEE`, 正规映射(offset=gpuaddr)同步变为 `0xEE` → **同一物理页**。
- **无越界**: 超出已分配对象的 offset 一律 EINVAL; **释放对象后其 offset 立即 EINVAL**(无残留 → 无 UAF 面)。
- **结论: 只能映射本进程自己的对象, 不构成原语。**

### AA.3 `GPUOBJ_IMPORT(0x48)` —— 地址校验正常, 未发现泄漏

`struct kgsl_gpuobj_import { u64 priv; u64 priv_len; u64 flags; u32 type; u32 id; }`,type=ADDR(2) 时 `priv` 指向 `{ u64 virtaddr; }`。

| 测试 | 结果 |
|---|---|
| type=0/1/4/5/6 + 用户地址 | **ENOTSUPP(524)** —— 本 build 未支持这些导入类型 |
| type=3(ION) | EBADF(需真实 ion fd; 而 `ion` 对 shell 仅只读可达) |
| type=2(ADDR) + **用户地址** | EINVAL |
| type=2(ADDR) + **内核地址**(`_text`/`physvirt_offset`/`selinux_state`/`init_cred`/rodata) | **EINVAL —— 与用户地址完全一致** |
| `priv` 指针本身指向内核地址 | **EFAULT** —— `copy_from_user` 检查正常 |

- **关键判读**: 内核地址与用户地址返回**同一个 EINVAL**, 说明失败发生在地址校验之前(ADDR 导入路径在本 build 不可用), **内核地址未被特殊接受** → **无内核内存导入/泄漏**。
- `priv` 指向内核地址得到 EFAULT, 说明 hunk 边界检查(`access_ok`/`copy_from_user`)是有效的。

### AA.4 本节结论

- **`mmap` 路径已覆盖**: 功能正常、offset 语义已解码、无越界、无残留。
- **两种经典"导入型"原语均被否**: GPUOBJ_IMPORT 的 ADDR 路径不可用且地址校验有效; ion 对 shell 只读。
- **未新增任何原语**。与 §Z.4 结论一致。

---

## AB. CVE-2026-21385 专项 + 跨厂商 diff 尝试(2026-09-15)

> 工具: `kgsl_align2.c` ~ `kgsl_align5.c`。**本节找到了全场最接近"真实漏洞行为"的一处异常, 但无法武器化。**

### AB.1 为什么锁定这个 CVE

- **CVE-2026-21385**: KGSL 内存对齐处理的整数溢出/回绕, 2026-03 Android 公告中**正在被实际利用的零日**。
- **受影响芯片清单明确包含 Snapdragon 778G —— 即本机 SM7325。**
- 修复: `2a3a06da63495bf6483d9d9969b4420f4f981c50`(msm-5.4), 把 `kgsl_memdesc_get_align()` 返回类型由 `int` 改为 `u32`, 消除移位时的符号扩展。
- OSV 记录其修复目标文件为 **`drivers/gpu/msm/kgsl_iommu.c`** → 即 **GPU 虚拟地址分配路径**。
- §B.5 曾判此 CVE 不可达, 但**只测了 `GPUMEM_ALLOC(0x2f)` 与 `GPUMEM_ALLOC_ID(0x34)` 两个入口**; §T 刚打通的 **`GPUOBJ_ALLOC(0x45)`**(带 `size/flags/va_len`)从未测过 —— 而它正是走 GPU VA 分配的现代入口。

### AB.2 实测: `GPUOBJ_ALLOC(0x45)` 注入 align 位

`flags` 高位为 align 域(bit24 起)。重复分配结果:

| flags | 连续分配得到的 gpuaddr |
|---|---|
| `0` (基线) | `0x4000000000`, `…1000`, `…2000`, `…3000`… **正常 4KB 步进** |
| `1<<24` (align=1) | `0x4000000000`, `…1000`, `…2000`, `…3000` **正常** |
| **`16<<24`** | **全部 `0x0`**(连续 6 个对象都是 0, 却都报成功, `va_len`/`mmapsize` 均为 4096) |
| **`31<<24`** | **全部 `0x0`**(连续 4 个) |
| `1<<3` (`USE_CPU_MAP`) | `0xec9f1000/2000/3000…` —— **另一合法 VA 区, 干净 4KB 步进, 零重叠** |

- **关键异常: `align ≥ 16` 时所有对象 gpuaddr 变成 `0x0`, 但 ioctl 返回成功。** 在缺少修复的驱动里, 这正符合"对齐值参与地址计算后被破坏"的形态。
- `1<<3` 的表现说明 bit3 是 `KGSL_MEMFLAGS_USE_CPU_MAP`, 属正常的另一套 VA 区, **不是 bug**(已排除误判)。

### AB.3 该异常无法武器化(实测逐个排除)

| 尝试 | 结果 |
|---|---|
| `mmap(offset=0)` / `mmap(offset=0xec9f0000)` | **EINVAL** —— GPU VA 0 与 CPU_MAP 区都无法映射 |
| 多对象是否重叠同一 gpuaddr | 是(都为 0), 但 **无任何可观察副作用** |
| 逐一释放这些对象 | 全部 OK, 无异常 |
| 释放后再分配 | 正常对象仍得正常地址; align≥16 仍得 0 |
| `SHAREDMEM_FREE(0x17)` 按 gpuaddr 释放(传 0 / 0x4000000000 / ~0) | **一律 EINVAL** —— 该路径不按 gpuaddr 生效 |
| 设备健康度(事后复测 timeline 创建) | **正常** |

→ **异常可稳定复现, 但没有任何 shell 可达的路径能观察到它、更无法转成写原语。** 要利用它, 前提是能用 GPU 去访问那个被破坏的 VA —— 而**命令提交面不可达(§Z.3)**。

### AB.4 跨厂商 diff 的可行性结论

- **同平台开源内核存在**: Nothing Phone(1) / POCO X5 Pro / 小米 11 Lite 5G NE **均为 SM7325**, 有多个 msm-5.4 OSS 仓库(`ExTV/android_kernel_msm-5.4_nothing_sm7325`、`MiCode/Xiaomi_Kernel_OpenSource` 等)。
- **但 vivo 不公开源码** → 无法取得**本机自身**的驱动源码, 只能拿同平台他厂源码做代理; 而本机驱动为 2024-02 冻结版, 与他厂版本差异无法精确定位。
- **补丁原文取不到**: `git.codelinaro.org` 对本环境返回 **429**(与外部同平台实践记录的限流现象一致), 无法直接读取修复 diff。
- **可用的替代路径(已验证有效)**: 用高通安全公告的 CVE 清单做"修复基准", 逐条在真机上判定可达性 —— 本节即此法的实践(CVE-2026-21385 就是通过它锁定的, 而 §I 当初只覆盖到 2024-08 公告)。

### AB.5 本节结论

- **锁定并实测了一个"疑似未修复"的目标**(CVE-2026-21385, 受影响芯片含本机 SoC, 且本机 kallsyms 确无修复引入的 `kgsl_get_align` 符号)。
- **复现出与其实质相符的可观察异常**(crafted align → GPU VA 被算成 0)。
- **但无法武器化**: 缺少 "让 GPU 访问该 VA" 的能力, 而该能力被 context 不可达挡住。
- **这是本机最接近真实漏洞的一处结果, 也再次把瓶颈归结到同一个点: 命令提交面不可达。**

---

## AC. `DRAWCTXT_CREATE` 为何全部 EINVAL —— 前置条件排查(2026-09-15)

> 工具: `kgsl_ctx2.c` / `kgsl_shadow.c` + 镜像内分发表解码。**结论: 该 handler 的 EINVAL 与参数无关, 属前置条件/资源级失败, 且标准初始化序列被 EPERM 挡住。**

### AC.1 先确认编号无误(镜像内分发表解码)

直接从镜像读出 `kgsl_ioctl_funcs`(gbfef VA `0xffffffc01218eb70`, file `0x210fb70`):

- 该表是**线性列表**(不是按 nr 索引), nr 由条目 `cmd` 字段决定。
- 解出的 `cmd` 完全正确, **确证 `0x13` 就是 `DRAWCTXT_CREATE`(size=8)**, 并顺带确证:
  `0x10`=RB_ISSUEIBCMDS(size 20)、`0x45`=GPUOBJ_ALLOC(**size 48**)、`0x47`=GPUOBJ_INFO(size 48)、`0x4A`=GPU_COMMAND(**size 64**)。
- 但条目的 **handler 指针列在文件中全为 0** → 该镜像是**重定位前**的产物(绝对指针由 boot 时 `__relocate_kernel` 填入), 因此**无法用镜像解析出 handler 地址**。

### AC.2 EINVAL 的特征: 与参数完全无关

| 变量 | 扫描范围 | 结果 |
|---|---|---|
| `flags` | 全部 32 个单 bit + 10 余种组合 + 0 | **一律 EINVAL** |
| `_IOC_SIZE` | 0/8/16/24/32/48/64/96/128/256(§R) | **一律 EINVAL** |
| 调用时机 | 裸调 / GETPROPERTY 之后 / SETPROPERTY 之后 | **一律 EINVAL** |
| open flags | O_RDWR / O_RDWR\|O_NONBLOCK / +O_ASYNC | 无差别 |

→ **失败发生在 flags 校验之外**, 属前置条件或资源级失败(不是"参数没填对")。

### AC.3 顺带扩展了 GETPROPERTY 的可用面

`GETPROPERTY(0x02)` type 扫描(§R 只测过 type=1):

| type | 名称 | 结果 |
|---|---|---|
| 1 | DEVICE_INFO | **OK** — chip_id=0x06030500(Adreno 642L) |
| 2 | DEVICE_SHADOW | **OK** — `gpuaddr=0xfff00000`, size=0x8000 |
| 6 / 7 | MMU_ENABLE / INTERRUPT_WAITS | OK(=1, MMU 已启用) |
| 19 / 21 / 23 / 24 / 25 / 26 / 27 / 32 | 其余属性 | OK, 返回各类计数值 |
| 8 / 9 | (VERSION / GPU_RESET_STAT) | EINVAL |

### AC.4 memstore 映射被 EPERM 挡住(关键)

- `DEVICE_SHADOW` 给出 memstore 的 GPU 地址 `0xfff00000`(size 0x8000)。
- **`mmap(fd, offset=0xfff00000)` → `EPERM`(Operation not permitted)**, 各种 size 均如此。
- 注意是 **EPERM 而非 EINVAL** → 说明存在**归属/权限检查**, 该内核分配的共享缓冲区不允许本进程映射(隔离正确)。
- 但这也意味着 **kgsl 的标准初始化序列(mmap memstore)在 shell 下无法完成**, 而这很可能正是 context 创建被拒的上游原因。

### AC.5 结论

- **`0x13` 确实是 `DRAWCTXT_CREATE`**, 我们一直在调对的东西。
- 它的 EINVAL **与 flags、size、调用时机、open flags 全部无关** → 是前置条件/资源级失败。
- 标准初始化前置(memstore mmap)被 **EPERM** 拦住, shell 无法推进。
- **这就是挡住所有剩余方向的单一闸门**:
  - 命令提交(`GPU_COMMAND` 0x4A / `ISSUEIBCMDS` 0x10)需要 context
  - §AB 复现出的 CVE-2026-21385 异常(VA 被算成 0)**需要让 GPU 去访问那个 VA**, 同样需要 context
- **从 uid=2000 shell 出发, 无法创建 GPU context —— 这一条已由多角度证据确认。** 本机在"提权"这一目标上已无剩余可推进的方向。

---

## AD. **重大反转: 命令提交面打通**(2026-09-15)

> **§Z.3 / §Z.4 的"命令提交面不可达"判定是错的。** 本节用校准后的反汇编定位了真实原因, 并在真机上打通。

### AD.0 先修好反汇编通路(这一步是前提)

- 从 arm64 Image 自带的 **PE/COFF 段表**取得权威映射:
  `.text` VA(镜像内偏移)=0x1000 → 对应 `_stext`(VA `0xffffffc010081000`)。
- **正确映射: `file = VA − 0xffffffc010080000`**。
- **§H 记录的常量(`0xffffffc01007f000`)偏了 0x1000(整整 4KB)**, 这正是此前反汇编抽错位置、得出垃圾结论的根因。
- 用 5 个函数交叉验证, 全部呈现干净 SCS 序言(`str x30, [x18], #0x8`): `do_undefinstr` / `__arm64_sys_futex` / `kgsl_ioctl_drawctxt_create` / `_destroy` / `kgsl_ioctl_gpuobj_alloc`。
- 工具: `dis_calib.py`(校准抽取) / `dis_symbol.py`(带符号解析的反汇编器, 自动把 bl/b 与 adrp+add 目标翻译成 kallsyms 符号名)。

### AD.1 定位真实原因:`adreno_drawctxt_create` 的 flags 掩码

`kgsl_ioctl_drawctxt_create` 反汇编(带符号):

```
000020  ldr  x23, [x0]                 ; device
000030  ldr  x20, [x8, #0xa0]          ; ftbl->drawctxt_create
000038  add  x8, x8, #0x19c            ; -> adreno_drawctxt_create.cfi_jt
00003c  cmp  x20, x8                   ; CFI 检查
00004c  blr  x20                       ; 调用 adreno_drawctxt_create
```
→ **该 handler 本身完全没有 flags 校验**, EINVAL 来自被调方。

`adreno_drawctxt_create` 开头:

```
000020  ldr  w24, [x1]                 ; w24 = flags
000038  mov  w11, #0x12                ; 掩码 0x12 = bit1(0x02) | bit4(0x10)
00004c  bics wzr, w11, w24             ; (0x12 & ~flags)
000050  b.ne 0x8c                      ; flags 未同时含这两位 -> 跳转
...
000098  mov  x20, #-0x16               ; -22 = -EINVAL
```

**结论: flags 必须同时包含 `0x02` 与 `0x10`(即 `flags & 0x12 == 0x12`)。**

### AD.2 为什么之前判定失败(教训)

- §R 扫了 `_IOC_SIZE`;§AC 扫了**全部 32 个单 bit** + `0x100010`(只有 0x10) / `0x100002`(只有 0x02) / 若干组合 —— **从未测试两位同时置位**。
- 单 bit 扫描看似"穷尽", 实际对**多 bit 组合要求**存在盲区。这是本次方法论上的重要教训。

### AD.3 真机验证(全部成功)

| flags | 结果 |
|---|---|
| **`0x12`** | **OK, drawctxt_id=28** |
| `0x100012` (0x12+TYPE_GL) | OK, id=70 |
| `0x200012` | OK, id=71 |
| `0x100412` (+SYNC) | OK, id=74 |
| `0x13` / `0x16` / `0x1a` | OK |
| `0x02` / `0x10` / `0x100002` / `0x100010` | EINVAL(单 bit 不满足) |

**并且 `GPU_COMMAND(0x4A)` 用该 context 提交返回 `ret=0`(成功)。**

### AD.4 由此重开的攻击面(**推翻 §Z.4**)

- **`DRAWCTXT_CREATE(0x13)` 可达** → **`GPU_COMMAND(0x4A)` 可达** → `RINGBUFFER_ISSUEIBCMDS(0x10)` / `SUBMIT_COMMANDS` 同类面随之重开。
- **"IB 提交越界"这一类**(外部同平台实践挖到漏洞的正是此面) **在本机重新变为可达**。
- **§AB 的 CVE-2026-21385 异常(GPU VA 被算成 0)现在有条件武器化** —— 因为终于可以让 GPU 去访问那个 VA 了。
- 前置条件已齐: KASLR(§U) + 符号地址(§V) + GPU 对象分配(§T.3) + 内存映射(§AA) + **context 与命令提交(本节)**。

### AD.5 状态更新

- **"本机无剩余方向"的结论作废。** 项目重新进入可推进状态。
- 下一步优先级(全新):
  1. **构造真实 IB 提交**(`GPU_COMMAND` 带 cmdlist/objlist/synclist), 验证命令真正被执行。
  2. 针对 `cmdlist`/`cmdsize`/`numcmds` 的**越界与校验**做参数面扫描(该面历史上出过多个 CVE)。
  3. 回到 §AB 的 CVE-2026-21385: 用 GPU 访问被算成 0 的 VA, 观察是否转化为实际的内存破坏。

---

## AE. IB 提交面实测: **边界校验缺失 + 提交被处理**(2026-09-15)

> 工具: `kgsl_ib.c` / `kgsl_ib2.c` / `kgsl_ib3.c` / `kgsl_gpuwrite.c` / `kgsl_exec.c`。
> §AD 打通 context 后, 本节把命令提交面实测到底。

### AE.1 有效提交格式(实测得出)

`GPU_COMMAND(0x4A)` 需要:
- 全局 `flags = 0x2`(为 0 时 EINVAL)
- 条目 `{offset, gpuaddr, size, flags, id}` 中 **`flags != 0`**(1/2/4 均可)
- `cmdsize = 32`(= sizeof(kgsl_command_object)), `numcmds ≥ 1`
- `context_id` = §AD 创建的 context

**注**: `kgsl_ib.c` 首轮扫描用了 `flags=0`, 导致**全部** EINVAL —— 那批"边界校验严格"的结论**作废**。

### AE.2 关键发现: **IB 边界完全不校验**

用有效格式重跑(`kgsl_ib3.c`), 对象范围 `[0x4000030000, 0x4000031000)`:

| 提交内容 | 结果 |
|---|---|
| `gpuaddr=对象首, size=0x1004 / 0x2000 / 0x10000 / 0x100000 / 0x10000000 / 0xffffffff` | **全部 ret=0 被接受** |
| `gpuaddr=0x4000031000`(对象之外) | **ret=0 被接受** |
| `gpuaddr=0x4000130000`(远越界) | **ret=0 被接受** |
| `gpuaddr=0x0` | **ret=0 被接受** |
| `gpuaddr=0x1000` | **ret=0 被接受** |
| 用**对象1 的 id** 提交**对象2 的 gpuaddr** | **ret=0 被接受**(id 与 gpuaddr 不一致) |
| `numcmds` 1→6 | 全部接受 |

→ **内核在 ioctl 接收阶段对 `gpuaddr` / `size` / `id` 三者均无一致性或越界校验**。这正是外部同平台实践中"**kgsl IB 越界**"类漏洞的形态。

### AE.3 提交确实被处理(非空转)

- 三次提交内核分别回填 `timestamp = 1 / 2 / 3`。
- `WAITTIMESTAMP_CTXTID(0x07)` 对每个 timestamp **均立即返回 0(耗时 0ms)**。
- → **提交进入了调度并被推进**, 不是被静默丢弃。

### AE.4 尚未观察到 GPU 侧内存写入

`kgsl_gpuwrite.c` / `kgsl_exec.c` 试验: IB 内放 `CP_MEM_WRITE(0x3D)`(3 payload 与 4 payload 两种编码), 目标设为**本对象内**地址(便于读回验证):

- 提交成功、timestamp 推进、等待返回成功;
- **但目标处数值未被改写**(始终为预置的 0x11111111)。

可能原因(待查):
1. `CP_MEM_WRITE` 在**非安全上下文**被忽略(A6xx 上常见限制);
2. 报文编码/opcode 与本代不符;
3. IB 前需要特定前言(preamble)命令序列。

### AE.5 本节结论

- **§Z.3 / §Z.4 的"命令提交面不可达"已彻底推翻。** 现在具备: **创建 context → 分配对象 → mmap 读写 → 构造任意 IB → 提交并被调度处理** 的完整能力链。
- **`gpuaddr` / `size` 无校验**这一发现, 把"IB 越界"从"不可达"变成"**可达且已确认校验缺失**"。
- 距离实际内存破坏还差一步: **让 GPU 真正按其执行一条能产生可观察副作用的 PM4 命令**(AE.4 未成功, 三种编码均无效)。
- 下一步优先级:
  1. 找到本代(A6xx)可用的、能产生可观察效果的 PM4 命令(如 `CP_MEM_WRITE` 的正确形参、或 `CP_EVENT_WRITE`/`CP_WAIT_MEM_WRITE`);
  2. 用 `gpuaddr=0x0` / 越界 gpuaddr 结合该命令, 观察是否读取到对象之外的内存(**越界读 = 信息泄漏源头**);
  3. 回到 §AB: 用 `align≥16` 造出 gpuaddr=0 的对象, 再用 GPU 访问, 验证 CVE-2026-21385 是否可转化为实际破坏。

> **状态**: 本机从"已穷尽"重新变为**可推进**, 且当前卡点已从"不可达"变成"需要一个可观察的 PM4 原语"。

---

## AF. PM4 写内存原语穷举 —— 零命中(2026-09-15)

> 工具: `kgsl_pm4.c`。目标: 找到一条 GPU 会真正执行且能在内存上留痕的 PM4 命令。

### AF.1 扫描范围

以**自己对象内**的地址为写入目标(便于 mmap 读回验证), 哨兵值 `0x11111111`:

| opcode | 名称 | 载荷 | 扫描量 |
|---|---|---|---|
| `0x3D` | `CP_MEM_WRITE` | addr_lo, addr_hi, data | 1 |
| `0x3E` | `CP_REG_TO_MEM` | reg, addr_lo, addr_hi, cnt | 8 个 reg |
| `0x46` | `CP_EVENT_WRITE` | event, addr_lo, addr_hi, 0 | **23 个 event** |
| `0x58` | `CP_EVENT_WRITE_SHD` | 同上 | 23 个 event |
| `0x59` | `CP_EVENT_WRITE_CFL` | 同上 | 23 个 event |

- 每次提交后都等待其 timestamp(`0x07`), 并 `usleep(20ms)` 后用 mmap 读回目标。
- **结果: 命中数 = 0**, 目标始终为哨兵值; 全程设备未崩溃。

### AF.2 与"提交确被处理"的矛盾

- 提交返回 0, 内核回填递增 `timestamp`, `WAITTIMESTAMP_CTXTID(0x07)` **立即返回 0**(§AE.3)。
- 若命令从未被 GPU 退役, 该等待应按 timeout(已给 2000~3000ms)阻塞 —— 它没有。
- **即: 命令被退役了, 但任何一种内存写命令都没有留下痕迹。**

### AF.3 两种可能(尚未区分)

1. **命令确实执行, 但被 CP 侧限制过滤** —— 例如 A6xx 的 `CP_PROTECT` 只放行特定地址/寄存器范围, 或非安全上下文禁止 `CP_MEM_WRITE`。
2. **命令未被 GPU 真正执行** —— `WAITTIMESTAMP` 立即返回也可能来自内核侧短路径(例如等待的是 CONSUMED/QUEUED 而非 RETIRED, 或该 context 的 timestamp 由内核直接推进)。

### AF.4 下一步(按性价比)

1. **用已修好的反汇编通路直接读驱动代码**(不再靠猜):
   - `kgsl_ioctl_gpu_command` → 看 `cmdlist` 条目到底如何被使用(是否用 `id` 反查对象并忽略用户 `gpuaddr`);
   - `adreno_ringbuffer` 的 `CP_PROTECT` 编程 → 直接得到**哪些 PM4 命令被允许**;
   - `kgsl_readtimestamp` / `waittimestamp_ctxtid` → 确认等待的到底是哪个 timestamp 类型。
   - 工具已就绪: `dis_symbol.py <符号名>`。
2. **决定性执行测试(有风险)**: 在 IB 内放 `CP_WAIT_REG_MEM` 轮询一个永不满足的条件(无超时) —— 若 GPU 真执行, 会挂住直至被 kgsl 复位; 可据此确证/否证"是否执行"。**可能触发 GPU reset, 需评估后再做。**
3. 若确认执行被过滤, 转向 **`CP_INDIRECT_BUFFER(0x3F)`** 一类的"取指"路径(配合 §AE.2 的无边界校验), 而非写命令。

### AF.5 状态

- **能力链已就绪**: context → 对象 → mmap → 任意 IB → 提交并退役。
- **缺口明确且收窄为一点**: 需要一个能在 GPU 侧产生可观察副作用的 PM4 原语; 这已不再是"面不可达", 而是**具体的命令/过滤问题**, 且可用手中的反汇编工具直接读代码求解。

### AF.6 代码级确认(反汇编 READ, 用 §AD.0 修好的通路)

**`kgsl_ioctl_gpu_command`**(VA `0xffffffc010a78054`):

```
000040 ldr w8,[x2,#0x14]   ; numcmds
000044 cmp w8,w9           ; w9 = 0x186a0 = 100000
000048 b.hi 0x2d0          ; > 100000 -> EINVAL
00004c ldr w10,[x2,#0x24]  ; numobjs
000058 b.hi 0x2d0          ; > 100000 -> EINVAL
00005c ldr w9,[x22,#0x34]  ; numsyncs
000060 cmp w9,#0x20        ; 上限 32
0000a4 ldr w1,[x22,#0x38]  ; context_id
0000ac bl  kgsl_context_get
0000bc cmp x8,x21          ; 校验 context 归属本 dev_priv
```
→ **只校验计数上限与 context 归属; 对 `cmdlist` 条目的地址/大小零校验。**

**`kgsl_drawobj_cmd_add_cmdlist`**(VA `0xffffffc010a8388c`):

```
0000c8 add  x21,x21,#0x20      ; 条目步长硬编码 32
0000b4 csel w24,w3,w8,lo       ; 拷贝长度 = min(cmdsize, 32)
0000fc bl   _copy_from_user    ; 把条目拷进栈上缓冲
000104 ldr  w3,[sp,#0x20]      ; entry.flags
000108 tst  w3,#0x7
00010c b.eq 0x164              ; (flags & 7)==0 -> dev_err + EINVAL
000120 ldp  x10,x8,[sp,#0x10]  ; gpuaddr / size
000124 ldp  w12,w9,[sp,#0x20]  ; flags / id
000138 stp  x11,x10,[x0,#0x18] ; 内核对象: offset, gpuaddr   <- 原样拷入
00013c stp  x8,w12,[x0,#0x28]  ;            size,   flags
```
→ **`offset` / `gpuaddr` / `size` / `id` 被原样拷入内核命令对象, 全程无边界或一致性校验。**
→ 唯一附加约束: **条目 `flags & 0x7 != 0`**(否则 `dev_err` + EINVAL) —— 与 §AE.1 的实测完全对应。

**结论: §AE.2 的"IB 边界不校验"由行为观测升级为源码级确认。** 这条"CVE 级"缺失真实存在, 只差一个能在 GPU 侧留痕的 PM4 原语来兑现。

### AF.7 本轮收尾状态

| 环节 | 状态 |
|---|---|
| KASLR | ✅ 已破(§U) |
| 符号地址 | ✅ 已标定(§V) |
| 反汇编通路 | ✅ 已修好并交叉验证(§AD.0) |
| 创建 context | ✅ `flags=0x12`(§AD.3) |
| 分配/映射 GPU 对象 | ✅(§T.3 / §AA) |
| 构造任意 IB 并提交 | ✅ 被调度退役(§AE.3) |
| **IB 边界校验** | ❌ **不存在(行为 + 代码双重确认)** |
| **GPU 侧可观察的 PM4 写原语** | ⏳ **未获得 —— 当前唯一缺口** |

**下一步(最高性价比)**: 继续用 `dis_symbol.py` 读 `adreno_ringbuffer` 的 `CP_PROTECT` 编程与 IB 提交序列, **直接查出哪些 PM4 命令被放行**, 而不是继续盲扫 opcode。

---

## AG. 双路径确认: 边界校验缺失是系统性的; PM4 写命令被拦(2026-09-15)

> 工具: `kgsl_ib4.c`。目的: 换一条**完全不同的提交路径**交叉验证 §AE.2 的结论。

### AG.1 legacy 路径同构

`RINGBUFFER_ISSUEIBCMDS(0x10)` (`struct kgsl_ringbuffer_issueibcmds` + `kgsl_ibdesc{gpuaddr, hostptr, sizedwords, ctrl}`) —— 与 `GPU_COMMAND(0x4A)` 是两套独立代码:

| 测试 | 结果 |
|---|---|
| 合法 IB 提交 | ret=0, timestamp=1 ✓ |
| `WAITTIMESTAMP` | 立即返回 0 |
| **`gpuaddr` = 对象之外** | **ret=0 被接受** |
| **`sizedwords` = 0x1000000(16M dwords)** | **ret=0 被接受** |

→ **两条独立路径均无边界校验, 属系统性缺失, 而非单点疏漏。**

### AG.2 PM4 写命令在此平台上被拦(系统性否定)

两次提交路径 + 5 个 opcode + 3 套事件编码, 累计约 100 次提交:

| 命令族 | 尝试量 | 结果 |
|---|---|---|
| `CP_MEM_WRITE (0x3D)` | 3/4 payload 两种 | 无效果 |
| `CP_REG_TO_MEM (0x3E)` | 8 个源寄存器 | 无效果 |
| `CP_EVENT_WRITE (0x46)` | 23 种 event | 无效果 |
| `CP_EVENT_WRITE_SHD (0x58)` | 23 种 event | 无效果 |
| `CP_EVENT_WRITE_CFL (0x59)` | 23 种 event | 无效果 |

- 提交均被接受并退役(timestamp 推进, WAITTIME 立即返回), **但目标内存始终未变**。
- **与 §AF.3 的可能 ① 吻合: 命令被 CP 侧过滤。** A6xx 的 kgsl 会通过 **`CP_PROTECT`** 寄存器把 CP 可访问的地址/寄存器限定在允许范围内, 用户 IB 的写内存命令大概率不在白名单内。

### AG.3 阶段结论(诚实评估)

- **已确证**: 存在一条**代码级确认的边界校验缺失**(§AF.6), 且在**两条独立提交路径**上都可达(§AG.1)。这本身是一个真实的、可陈述的缺陷。
- **但无法直接武器化**: 用户 IB 里的**内存写命令全部被挡**, 因此"越界 IB"目前只能带来被接受的提交, 不能读也不能写。
- **与外部同平台先例的差异**: 该先例的成功面是 **SM6375**; 本机 **SM7325/A6xx** 的 `CP_PROTECT` 配置不同(与 §B.3/§I.2 "A6xx 结构性受限"的多次结论方向一致)。
- **要突破需先做一件事**: **读出 `CP_PROTECT` 的实际编程值**, 枚举出白名单内的命令, 再在其中寻找可产生可观察副作用的原语(例如可读回内存的路径 → 信息泄漏, 或可写的寄存器 → 间接写)。

### AG.4 明确的下一步(单一定向任务)

用已修好的 `dis_symbol.py` 读:
1. `adreno_ringbuffer_addcmds.llvm.*`(`0xffffffc010af7d38`)—— 报文构造, 找出提交时写入的 PM4 包头常量;
2. `adreno_ringbuffer_init`(`0xffffffc010af7940`)与 a6xx 相关初始化 —— 定位 `CP_PROTECT`(寄存器 `0x880`–`0x8A0` 区间)的编程点;
3. 由此列出**用户 IB 中被允许的 PM4 命令集合**。

> 这是**读代码**的任务, 不是继续盲试。工具与映射均已就绪。

---

## AH. 关键澄清: 提交被接收但 **GPU 未真正执行 IB**(2026-09-15)

> 工具: `kgsl_sync.c` / `kgsl_fault.c`。本节把 §AF/§AG 遗留的"为什么写命令无效果"追到根上, 并**修正了对提交能力的乐观解读**。

### AH.1 先排除"缓存一致性"假设

假设: GPU 写了内存, 但 CPU 经 mmap 读到的是旧缓存。
- `GPUMEM_SYNC_CACHE(0x37)`: op 0–5 **全部 EINVAL**(该 ioctl 对本代对象不可用)。
- `GPUOBJ_SYNC(0x49)`: op 1/2/3/5 **返回成功**, 但**目标值始终未变**。
→ **缓存维护不是原因, 假设排除。**

### AH.2 `CP_PROTECT` 假设也被削弱

- 在整个内核镜像中检索 `CP_PROTECT` / `cp_protect` / `CP_PROTECT_CNTL` / `CP_ME_INIT` / `CP_ROQ`:
  **全部 0 命中**。
- 说明该驱动**很可能根本没有编程 CP_PROTECT**(至少不以这些名字出现), 因此"写命令被白名单过滤"这一解释**缺乏依据**。

### AH.3 决定性测试: 非法 PM4 未触发任何错误

- 把对象填充为 `0x11111111`(PM4 type 字段 = 0), 然后**声明整个对象(0x1000 字节)为 IB 提交**:
  - 提交返回 0, 等待返回 0;
  - **上下文保持健康**: 随后的合法提交仍返回 0, 还能新建 context(id=70)、还能 `GPUOBJ_ALLOC`;
  - 设备未重启、无异常。
- 若 GPU 真的在逐包解析该 IB, 应至少有一次报错或上下文被标记 faulted。**没有。**

### AH.4 结论: **"能提交"≠"GPU 在执行"**

综合 §AE–§AH:

| 事实 | 状态 |
|---|---|
| 能创建 context、能提交 IB、内核回填 timestamp、WAITTIME 立即返回 | ✅ 确证 |
| 提交无边界校验(代码级 + 双路径确证) | ✅ 确证 |
| **IB 内容是否被 GPU 真正执行** | ❌ **证据指向"未执行"** |

- 最可能的原因: **命令被内核接收并按时间戳"退役", 但 GPU 侧并未真正执行** —— 例如 GPU 处于未实际运行/未调度的状态, 或该 context 的最小配置(`flags=0x12`)不足以让它被真正派发到 GPU。
- **对前几节结论的修正**: §AD.4 "命令提交面打通" 应降级表述为**"提交接口可达且校验缺失, 但命令执行链路未验证通过"**。§AE.4/§AF/§AG 中"既然退役了就说明执行了"的推论**不成立**。

### AH.5 现在的准确位置

- **已确证的缺陷**: `GPU_COMMAND(0x4A)` 与 `RINGBUFFER_ISSUEIBCMDS(0x10)` 两条路径均**无 IB 边界/一致性校验**(代码级 + 行为级双重证据)。这是一个真实、可陈述的输入校验缺失。
- **未能兑现**: 因为命令未被真正执行, 该缺陷目前**无法转化为任何读/写原语**。
- **下一步若要继续**(均为研究型任务, 不再是快速验证):
  1. **验证执行链路**: 用 `synclist` 挂一个 timeline fence 到提交上, 观察 GPU 完成时 fence 是否真的信号 —— 这是判定"是否执行"最干净的方法;
  2. 读 `adreno_ringbuffer_submitcmd` / `adreno_dispatch` 判断本代派发的前置条件(是否需要更完整的 context flags / 是否需要设备处于特定电源状态);
  3. 若确认执行链路需要真实 GPU 上下文, 则应转向"从正常图形栈进程借上下文"的方向, 而非从 shell 直接构造。

### AH.6 诚实总结

本次会话已把本机从"完全封死"推进到"**具备完整侦察能力 + 发现一处真实的校验缺失**", 这是实质性成果; 但**临时 root 仍未达成**, 且当前的卡点("命令是否真被执行")属于需要专门投入的研究问题, 不再是靠一轮实验能跨过的。

---

## AI. 定论: IB 内容**未到达 GPU**(2026-09-15)

> 工具: `kgsl_exec2.c`。本节修正 §AH.3 的推理漏洞, 并用**必然越界**的报文给出决定性判定。

### AI.1 先修正 §AH.3 的漏洞

§AH.3 用 `0x11111111` 当"非法 PM4"是不严谨的: 它的 **PM4 type 字段 = 0**, 而 type-0 包无长度字段、未知名**可能被 CP 静默消费**, 因此"无 fault"不能证明未执行。必须换用**行为必然确定**的报文。

### AI.2 决定性测试(保证越界 / 保证非法)

| IB 首 dword | 含义 | 预期(若执行) | 实测 |
|---|---|---|---|
| `0x707f3fff` = `P7(0x7F, 0x3FFF)` | 非法 opcode + **16383 dword 载荷** | CP 必须取 64KB 载荷 → 越过我们 0x1000 的对象进入**无映射区** → **必然 fault** | 提交/等待返回 0,**无 fault**, 后续提交正常 |
| `0x703d3fff` = `P7(0x3D, 0x3FFF)` | `CP_MEM_WRITE` 超大计数 | 同上 | 同 上 |
| `0x40000000` | PM4 type=4(保留) | 非法类型 | 同 上 |

- 每次之后都做一次合法提交复测, **全部正常**; 最终可新建 context(id=70)、`GPUOBJ_ALLOC` 正常; 设备未重启。

### AI.3 定论

- **IB 的内容根本没有到达 GPU。** 既没有被执行, 也没有被任何 CP 解析器看过 —— 否则一个 16383 dword 载荷的非法包必然留下痕迹。
- 因此前几节的"timestamp 推进 / WAITTIME 立即返回"**只是内核侧记账**, 不代表 GPU 完成。**§AE.3、§AD.3 中"提交被处理 = GPU 执行"的推论一律作废。**
- 最可能的机理: **shell 创建的 context 并未被真正派发到 GPU**(设备未进入 ACTIVE / GPU 侧从未运行该命令流), 内核按记账路径直接"退役"了它。旁证: `mmap` memstore 被 `EPERM` 拒绝(§AC.4) —— 说明该 fd 走不完 kgsl 的正常设备初始化/激活序列。

### AI.4 对全部相关结论的最终修正

| 结论 | 状态 |
|---|---|
| 能创建 context(`flags=0x12`)、能走通两套提交接口 | ✅ 成立 |
| `GPU_COMMAND(0x4A)` 与 `RINGBUFFER_ISSUEIBCMDS(0x10)` **均无 IB 边界/一致性校验** | ✅ 成立(代码级 + 行为级双证据) |
| **"命令提交面打通"** | ❌ **作废** —— 接口可达, 但命令不执行 |
| **该校验缺失可转化为读/写原语** | ❌ **不成立** —— 命令未到达 GPU |
| §AB 的 CVE-2026-21385 异常可用 GPU 兑现 | ❌ 同样受阻于本节结论 |

### AI.5 本机最终结论(2026-09-15 收束)

- **已确证的真成果**:
  1. **KASLR 攻破**(§U) + **全部符号地址标定**(§V);
  2. **反汇编通路修正**(§AD.0) —— `file = VA − 0xffffffc010080000`, 纠正了 §H 的 0x1000 偏差, 并用 5 个函数交叉验证;
  3. **43 个 KGSL handler 实测命名** + 两套 fence 生命周期实操(§Q–§T);
  4. **一处代码级确证的输入校验缺失**(§AF.6): 两条独立提交路径均不校验 IB 的 `gpuaddr`/`size`/`id`。
- **未能达成**: 临时 root。根本原因是 **shell 无法让 GPU 真正执行任何命令**。
- **剩余方向(均为研究级, 非快速验证)**:
  1. 查明"为何 context 不被真正派发"(读 `adreno_dispatch` / `kgsl_active_count_get` / GMU 初始化路径), 判断是否有可从 shell 满足的前置;
  2. 或改换载体: 不自行构造 context, 而从**正在运行的真实图形栈进程**借上下文(需要该进程的接口或一个可注入点);
  3. 或更换设备 —— 用本会话已就绪的完整流水线(KASLR/符号/反汇编/ handler 测绘)在新机上快速重跑。

> **诚实评价**: 本会话在"信息层"做到了很高的完成度, 并确证了一处真实缺陷; 但在"执行层"撞上了同一堵墙——**shell 上下文无法驱动 GPU**。这堵墙同时阻断了 §AB、§AE–§AG 的全部线索。

---

## AJ. 定论之定论: **GPU 从未取过我们的 IB**(2026-09-15)

> 工具: `kgsl_exec3.c` + 反汇编 `adreno_dispatcher_queue_cmds`。本节回答"context 为何不被派发"。

### AJ.1 先修正 §AI 的第二个推理漏洞

§AI 认为 `P7(0x7F,0x3FFF)`(16383 dword 载荷)**必然越界 fault**。此假设**不严谨**: 我们此前分配了数十个对象, 其 GPU VA 是**连续**的(`0x4000030000`, `…1000`, `…2000`…), 因此"多读 64KB"很可能落在**相邻对象**上, 属已映射区域 → 不会 fault。

### AJ.2 决定性测试: 把 IB 取指地址指向**无映射 VA**

| 提交时 `cmdlist[0].gpuaddr` | 若 GPU 真去取指 | 实测 |
|---|---|---|
| `0x0` | 传输故障 → context faulted | 提交 OK / 等待 0ms / **上下文与后续提交全部正常** |
| `0x1000` | 同上 | 同上 |
| `0xDEAD0000` | 同上 | 同上 |
| `0x8000000000000000` | 同上 | 同上 |
| `0xFFFFFFFFFFFFF000` | 同上 | 同上 |
| `gaddr − 0x100000000` | 同上 | 同上 |

- 每次之后都做正常提交复测, **全部正常**; 最终可新建 context(id=70)、`GPUOBJ_ALLOC` 正常; 设备未重启。

**结论: 若 GPU 曾尝试从这些地址取指, 必然留下传输故障痕迹。没有 —— 因此 GPU 根本没有取过我们的 IB。**

### AJ.3 派发入口读到的内容

`adreno_dispatcher_queue_cmds`(VA `0xffffffc010aeb520`, size 0x858):

```
000030  cbz  w3, 0x4c              ; numcmds == 0 -> EINVAL
000038  ldr  w8, [x8, #0xec]       ; dispatcher 上限
000044  cmp  w8, w3 ; b.hs 0x54    ; numcmds 超限 -> EINVAL
000058  cbz  x1, 0x90              ; cmdlist == NULL -> 错误(-35)
000064  ldr  x8, [x27, #0x20]!     ; drawobj->flags
000068  tbnz w8, #0x2, 0x90        ; 特定 flag -> 错误
...                                ; 之后进入 drawobj 数组遍历(按 type 分派)
```
→ 入口只做**计数/指针/flag 校验**; 未发现"直接拒发"的分支。即: **命令确实被接收进队列, 只是后续没有真正走到 GPU。**

### AJ.4 context 为何不被派发 —— 证据链与主假设

**证据链**:

1. `DRAWCTXT_CREATE(0x13)` 成功(`flags=0x12`), 返回合法 context id;
2. 两套提交接口(`0x4A` / `0x10`)均接受提交, 内核回填递增 timestamp;
3. `WAITTIMESTAMP_CTXTID(0x07)` **0ms 返回**(若是真实 GPU 完成, 也应返回, 故此点无区分力);
4. 任何 PM4 写命令**无内存效果**;
5. 非法/超大载荷包**无 fault**;
6. **无映射 IB 地址 也无 fault** ← 决定性;
7. **`mmap` memstore 被 `EPERM` 拒绝**(§AC.4) —— 该 fd 走不进 kgsl 的标准设备激活/共享内存序列。

**主假设**: shell 进程创建的 context **未被真正纳入 GPU 调度**。最可能与 **memstore 不可访问(EPERM)** 相关 —— kgsl 的正常用户态需要映射 memstore 并使用其中的时间戳槽位; 缺少这一步时, 提交虽被内核接受并记账, 但**永远不会被真正泵到 GPU**。

**待验证的下一步(具体、可做)**:
1. **查明 memstore mmap 为何 EPERM** —— 这是目前最可疑的单点。**注**: `kgsl_mmap` **不在 kallsyms 中**(大概被 inline 或改名), 需先解析 `kgsl_fops`(file_operations 结构)取出 `.mmap` 函数指针再反汇编; 若无符合条件, 则整条链可能就此封死。
2. 读 `adreno_dispatcher_queue_context` / `adreno_dispatcher_schedule` 与 `adreno_dispatcher_start`, 确认派发线程是否因缺少某前置而从未处理该 context。
3. 若两者均指向"需要图形栈进程的上下文", 则回到 §AI.5 的方向 ②(从真实图形栈进程借上下文)。

### AJ.5 最终状态

- **本机临时 root 未达成**, 且已把卡点收敛到一个**具体、可继续追查的单点: `mmap` memstore 的 `EPERM`**。
- 本节所有结论均基于实测, 前几节中"提交即执行"的乐观推论已全部作废并标注。

---

## AK. 追查 `kgsl_mmap` 的 EPERM —— 新工具有效, 但定位受阻(2026-09-15)

### AK.1 镜像中绝对指针被清零, 需改用 PC 相对交叉引用

- `kgsl_fops` 已定位(`0xffffffc01218e660`, 数据符号), 但**其函数指针列在镜像文件中是 0**(与 §AD.0 分发表同理), 无法直接读出 `.mmap` 字段。
- 因此新建工具 **`xref.py`**: 扫描 `.text` 中所有 `adrp + add` 同寄存器对, 解出目标 VA 并与给定符号比对 —— 这些引用是 **PC 相对**的, 在镜像中得以保留。
- 有效性已验证: 全图识别出 **91148** 组 `adrp+add`。

### AK.2 结果: 定位受阻

- 扫描 `kgsl_memstore_vm_ops`(`0xffffffc01218e868`): **0 处引用**。
- 放宽为"adrp 到该页(`0xffffffc01218e000`) + 后续任意指令": 找到 35 处, 但**偏移全部落在该页其他符号上**(0x150 / 0x238 / 0x3a8 …), **无一命中 0x868**。
- 说明 `kgsl_memstore_vm_ops` **并非由 .text 经 `adrp` 直接寻址**, 更可能是**从其它数据结构(memdesc ops 表)间接引用**; 因此无法用此方法直接定位 `kgsl_mmap`。
- → **memstore EPERM 的具体条件本轮未能查出。**

### AK.3 本轮产出与状态

- **产出**: `xref.py` —— 一个可复用的"符号→引用点"定位工具(在绝对指针被清零的 arm64 Image 上依然可用), 配合 `dis_symbol.py` 组成完整的离线分析链。
- **状态**: "context 为何不被派发"已收敛为**一个具体的待查点**(memstore 路径 / 派发前置), 但本轮未能突破。
- **剩余可做**: ① 从 `kgsl_memdesc_ops` 类数据表(如 `kgsl_system_ops` / `kgsl_contiguous_ops`)反查 `vm_ops` 归属, 再回溯调用方; ② 换用 `adrp + ldr` 组合路径再扫; ③ 或跳过代码定位, 直接用行为实验穷举 memstore mmap 的可行参数组合(protection / flags / 时机)。

---

## AL. 设备级计数差分 —— 50 次提交后**零变化**(2026-09-15)

> 工具: `kgsl_prop.c`。思路: 用 `GETPROPERTY(0x02)` 的多个可读 type 当"设备状态探针", 提交前后做差分。

### AL.1 读数

```
[before]        t1=433195486715838465 t2=4293918720 t6=1 t7=1 t19=0
                t21=23969940 t23=15 t24=48 t25=0 t26=32 t27=3 t32=0
[after20 NOP]   完全同上
[after 10 写命令] 完全同上   (目标处仍为 0x70100000, 未被改写)
[after 10 非法包] 完全同上
[after 10 无映射] 完全同上
```

- 累计 50 次提交(合法 / 写命令 / 非法包 / 无映射地址四种), **全部探针数值一字未变**。
- 其中 `t19 = 0`(疑似 fault/reset 统计)在投递非法包后仍为 0。
- 附注: `t2 = 0xFFF00000`, 即 memstore 的 GPU 地址; `t6/t7 = 1`(MMU 已启用)。

### AL.2 判读(含本测试的局限)

- **结论方向一致**: 没有任何设备级计数因我们的提交而变化, 与"提交未产生任何 GPU 侧活动"相符。
- **局限(必须说明)**: 这些计数器是**设备级**的, 即使提交被正常执行也未必变化(例如合法的 NOP 不该改变 fault 计数)。因此本测试**不能单独证明未执行**, 只是没有给出任何"被执行过"的正面证据。
- `t19=0` 在投递 10 次非法包后仍为 0 —— 这一条相对有说服力(非法包若被执行, fault 统计理应变化)。

### AL.3 至此的证据全貌

| 判据 | 指向 |
|---|---|
| 任何 PM4 写命令无内存效果 | 未执行 |
| 非法/超大载荷包无 fault | 未执行 |
| **无映射 IB 地址无 fault**(决定性) | 未执行 |
| 销毁后 fence 行为正常、无异常 errno | — |
| 设备级计数 50 次提交后零变化 | (弱)未执行 |
| `mmap` memstore 被 EPERM | 该 fd 走不进正常序列 |

**没有任何一项证据支持"命令被 GPU 执行"。**

---

## AM. 穷举收束: 两条最后的合理假设均被排除(2026-09-15)

### AM.1 缓存一致性 —— 这次是真正排除(此前排除方式不可靠)

此前用"猜 `GPUOBJ_SYNC` 的 op 值"来排除缓存假设, 不严谨。本轮改用三条正交手段(`kgsl_coherent.c`):

| 手段 | 结果 |
|---|---|
| 用 `KGSL_MEMFLAGS_IOCOHERENT(0x10)` 分配对象(GPU/CPU 共缓存) | 目标**未变** |
| 提交后 `msync(MS_INVALIDATE)` | ret=0, 目标**未变** |
| 提交后 `madvise(MADV_DONTNEED)` 丢页重取 | ret=0, 目标**未变** |
| `USE_CPU_MAP(0x8)` 对象 | **mmap 直接 EINVAL**(该类型不可 mmap) |

→ **缓存一致性不是原因, 假设彻底排除。**

### AM.2 objlist 假设 —— 排除

假设: kgsl 要求 `cmdlist` 引用的对象同时出现在 `objlist` 中做生命周期跟踪, 否则静默丢弃该 IB。
(此前所有测试都是 `numobjs=0`, 确实从未验证过。)

`kgsl_objlist.c` 试了 9 种组合(含 `numobjs=1` 的 objlist、四种 objflags、三种 cmdflags、以及只给 objlist 的 marker 路径):

**全部 ret=0, 目标一律未变, 命中 0。**

→ **objlist 不是原因。**

### AM.3 "让 GPU 动起来"的完整穷举清单

| # | 尝试 | 结果 |
|---|---|---|
| 1 | 5 个 PM4 写内存 opcode(`0x3D/0x3E/0x46/0x58/0x59`) × 多套载荷 | 无写入 |
| 2 | `CP_EVENT_WRITE` 三变体 × 各 23 种 event | 无写入 |
| 3 | 缓存: 直读 / `msync(MS_INVALIDATE)` / `madvise(DONTNEED)` / IOCOHERENT 对象 | 无写入 |
| 4 | `GPUOBJ_SYNC(0x49)` op 1/2/3/5 | 无写入 |
| 5 | 非法 / 超大载荷包(含 16383 dword) | 无 fault |
| 6 | **无映射 IB 取指地址**(6 个) | **无 fault(决定性)** |
| 7 | 设备级计数, 50 次提交前后差分 | 零变化 |
| 8 | objlist 9 种组合 | 无写入 |
| 9 | legacy 路径 `RINGBUFFER_ISSUEIBCMDS(0x10)` | 与上同 |
| 10 | `mmap` memstore | EPERM |
| 11 | 定位 `kgsl_mmap`(`xref.py`) | 受阻(非 adrp 直接寻址) |

**累计约 150 次真机提交, 覆盖 PM4 / 缓存 / 对象生命周期 / 提交路径 / 地址校验 / 设备计数六个维度 —— 没有任何一次产生 GPU 侧可见效果。**

### AM.4 诚实结论

- **判断: 从 uid=2000 shell 创建的 context 在这台设备上无法驱动 GPU。** 这是**结构性**的, 不是参数没调对。
- 支撑: 上述 11 项穷举 + `mmap` memstore 的 `EPERM`(该 fd 走不完 kgsl 正常激活序列)构成一致的证据链。
- **"只要有一丝希望"的诚实回答**: 在**黑盒实验层面已无剩余假设**。剩下的只有两类**项目级**工作:
  1. **真正逆向 kgsl_mmap / 派发链**: 需绕过"镜像绝对指针被清零", 从数据表反查 `vm_ops` 归属再回溯调用方 —— 这是数小时到数天的逆向工程, 不是再跑几轮实验;
  2. **换载体**: 从**正在运行的真实图形栈进程**取得 context —— 但这本身就需要另一个能力(注入点), 属另一个问题。
- **建议**: 换设备。本会话产出的完整流水线(KASLR 攻破 / 符号标定 / `dis_symbol.py` + `xref.py` 反汇编链 / 43 个 handler 测绘 / 全套探测源码)可直接迁移, 在新机上重跑成本很低。

---

## AN. "从图形栈进程借 context" —— 架构上不可行(2026-09-15)

> 工具: `kgsl_ctx4.c`。本节回答"借 context"路线, 并补上 context 标志面的最后一轮扫描。

### AN.1 借 context 在 kgsl 设计上不成立(**代码已确认**)

- kgsl 把 context 绑定到**文件描述符**对应的 `kgsl_device_private`:
  `kgsl_ioctl_gpu_command` 中显式校验 `context->dev_priv == 本 fd 的 dev_priv`(§AF.6 反汇编中的 `cmp x8,x21`)。
- 因此**拿到别的进程的 context id 也没用** —— ioctl 会被这条归属校验挡下。
- 要真正"借", 只能**在图形栈进程内执行代码**, 即需要一个**注入原语** —— 而这正是我们本来就想获得的东西。**该路线不是捷径, 它预设了要解决问题的答案。**

### AN.2 于是改为扫描 context 标志 —— 找"能驱动 GPU 的配置"

`kgsl_ctx4.c` 试了 **15 种 context 标志组合**(重点覆盖直接改变时间戳记账方式的 `PER_CONTEXT_TS(0x40)` 与 `USER_GENERATED_TS(0x80)`, 因为"时间戳记了账却没执行"正是最可疑处):

| 标志 | 建 context | 提交 | 目标是否被写 |
|---|---|---|---|
| `0x12`(基线) / `+0x40` / `+0x100000` / `+GL+PCTS` / `+0x800` / `+0x8` / `+0x10+0x20` / `+0x200` / `+0x400` / `+0x1` / `+0x100` / `+0x4000000` / `+0x2000000` | 全部成功 | 全部 ret=0 | **全部未写** |
| `+0x80`(UGTS) / `+0xC0` | 成功 | **ret=-1**(UGTS 要求用户提供 timestamp, 我们传 0 → 被拒) | — |

**13 次成功提交, 命中 0。**

→ **context 标志不是差异所在。**

### AN.3 结论

- "借 context"路线: **架构上不可行**(需注入原语)。
- "换 context 配置": **15 种组合全部无效**。
- 结合 §AM 的 11 项穷举, **黑盒方向已无剩余假设**。

> **对"是否还有一丝希望"的最终回答**:
> **在本机黑盒层面: 没有。** 唯一剩下的实质路径是**逆向 kgsl 的 mmap / 派发链**(需绕过镜像绝对指针被清零的障碍), 属数小时到数天的逆向工程项目, 而不是再跑几轮探测。
> **理性选择是换设备**: 本会话把"侦察阶段"做成了可复用流水线, 在新机上重跑成本极低。

---

# 逆向项目: kgsl mmap / 派发链

## AO. 项目启动即有突破: 反汇编 `kgsl_mmap` → **发现 memstore 可只读映射**

### AO.1 工程障碍与突破手段

**障碍**: 镜像中 `.data`/`.rodata` 的**绝对指针全被清零**(重定位前的产物), 函数指针表读不出。
- 实测确认: `kgsl_fops`、`kgsl_memstore_vm_ops` 等全为 0 字节; 而 `cmd` 这类非指针数据保留。
- `.data` VirtSize 0xd3e000 > RawSize 0x60ca00, 差额为 BSS; PE 段头 **无重定位表**(PtrReloc=0, NReloc=0)。

**突破手段**: 改用 **PC 相对交叉引用**(`adrp+add` 在镜像中保留), 工具 `xref.py`。

**并且修掉了两个工具 bug**(这是本轮能出结果的前提):
1. `xref.py` 的 `FILE_BASE` 误用 0x1000 → **所有 adrp 目标整体偏移 0x1000**, 导致全部查询返回 0 处引用(**假阴性**)。修正为 0。
2. 映射基准确认: **`file = VA − 0xffffffc010080000`**。双锚点验证: ① PE 段表 `.text` 偏移 0x1000 ↔ `_stext`; ② `kgsl_ioctl_funcs` 是按 nr 索引的稀疏数组, 仅在此映射下 `entry[nr]` 的 cmd 才与 nr 精确对应(`[2]`=GETPROPERTY、`[7]`=WAITTIMESTAMP_CTXTID)。
3. `kdump.py` 同期修正(此前多加了 +0x1000, 读到错位区域)。

**工具自检(修正后)**:
```
kgsl_ioctl_funcs      <- kgsl_ioctl+0x58                     ✓ 分派器
kgsl_property_funcs   <- kgsl_ioctl_device_getproperty+0x80  ✓ 属性分派
```

### AO.2 定位 `kgsl_mmap`(**它一直在 kallsyms 里, 只是带哈希后缀**)

```
kgsl_memstore_vm_ops  <- kgsl_mmap$c4b75b2e95fcbe08742d4d7cdee51d5a+0xa4
kgsl_gpumem_vm_ops    <- kgsl_mmap$c4b75b2e95fcbe08742d4d7cdee51d5a+0x11c
```
→ `kgsl_mmap` VA = **`0xffffffc010a7ee68`**(此前精确匹配 `kgsl_mmap` 找不到, 因为它被克隆/outline 成了带 `$hash` 后缀的符号)。

### AO.3 反汇编 `kgsl_mmap` 得到关键条件

```asm
000038  ldr  x8, [x0, #0xd8]              ; x8 = file->private_data (dev_priv)
00003c  ldr  x2, [x1, #0x98]              ; x2 = vma->vm_pgoff
000044  and  x9, x2, #0xfffffffffffff     ; 掩码
000048  cmp  x9, x10                      ; x10 = 0xfff00
00004c  b.ne 0xc8                         ; 不等 -> 普通对象路径 get_mmap_entry
000054  ldr  x11, [x20, #0x50]            ; vma->vm_flags
000058  tbnz w11, #0x1, 0x190             ; ★ VM_WRITE 置位 -> 走 EPERM 分支
000060  and  x8, x11, #0xffffffffffffffdf ; 清 VM_MAYWRITE
0000a8  add  x10, x10, #0x868             ; &kgsl_memstore_vm_ops
0000ac  mov  w0, wzr                      ; return 0 (成功)
```

**关键结论**: `0xfff00 << 12 = 0xfff00000` = **memstore 的 GPU 地址**。memstore 路径**只在 `VM_WRITE` 置位时才拒绝** —— 也就是说 **memstore 是"只读可映射"的**。

**此前所有 memstore 测试都用了 `PROT_READ|PROT_WRITE`**, 因此全部 EPERM, 并导致"memstore 不可映射"的错误结论(§AC.4 已作废)。

### AO.4 真机验证: **memstore 只读映射成功**

```
mmap(offset=0xfff00000, PROT_READ)          -> OK      ← 新能力!
mmap(offset=0xfff00000, PROT_READ|WRITE)    -> EPERM
mmap(offset=0xfff00000, PROT_WRITE)         -> EPERM
```

- 得到**内核分配的 GPU 共享缓冲区只读视图**(0x8000 字节), 内含 per-context 时间戳槽、各类计数。
- 读取示例: offset 0x20 = 28(我们建的 context id); 0x78/0x80 = 51602; 0xc8/0xd0 = 46076。
- **这是本会话获得的第一条"内核内存只读通道"。**

### AO.5 用新通道做决定性判别 —— GPU **确实未参与**

`kgsl_disc.c`: 每提交一次就观察该 context 的时间戳槽(`ctx*40`, sopt@+0 / eopt@+8)。

| 提交时 `cmdlist[0].gpuaddr` | sopt | eopt | eopt 是否推进 |
|---|---|---|---|
| 合法对象地址 | 0→1 | 0→1 | 推进 |
| 合法对象地址(复测) | 1→2 | 1→2 | 推进 |
| **无映射 `0xDEAD0000`** | 2→3 | 2→3 | **推进** |
| **无映射 `0x0`** | 3→4 | 3→4 | **推进** |
| **无映射 `0x8000000000000000`** | 4→5 | 4→5 | **推进** |
| 合法(再复测) | 5→6 | 5→6 | 推进 |
| **无映射 `0x1000`** | 6→7 | 6→7 | **推进** |
| 合法(第三次) | 7→8 | 7→8 | 推进 |

**判读**: 若 GPU 需要取我们的 IB, 则"取不到的地址"必然导致取指故障 → 批次尾部的写时间戳包不会执行 → **eopt 应停滞**。
**实测: 不管地址是否可映射, eopt 每次都推进, 且始终等于 sopt。**

→ **`eoptimestamp` 是内核写的, GPU 未参与。§AJ 的"GPU 从未取过 IB"由此从推断升级为证明。**

### AO.6 项目成果小结

| 项 | 结果 |
|---|---|
| 工具链修复 | `xref.py` FILE_BASE bug(假阴性根因) + `kdump.py` 偏移 + 映射双锚点确认 |
| `kgsl_mmap` 定位 | ✅ 找到(带 `$hash` 后缀的克隆符号 `0xffffffc010a7ee68`) |
| `kgsl_mmap` 逻辑 | ✅ 读出 memstore 分支的完整条件 |
| **新获能力** | ✅ **memstore 只读映射**(内核分配的 GPU 共享缓冲区, 0x8000 字节) |
| 中心问题 | ✅ **判定完成**: GPU 不执行我们的命令流(现为**证明**) |
| 待查 | "为何不参与" → 需继续读派发链(`adreno_dispatcher_queue_context` / `adreno_active_count_get` / GMU 初始化) |

### AO.7 下一步(项目排期)

1. **读派发链**: `adreno_dispatcher_queue_context`(`0xffffffc010aec7fc`)、`dispatcher_queue_context`(`0xffffffc010aec838`)、`adreno_dispatcher_start`(`0xffffffc010aeca88`)、`adreno_active_count_get`(`0xffffffc010aac6a8`) —— 找"命令进队但 GPU 不参与"的分界点。
2. **利用新通道**: memstore 只读映射已可读 GPU 状态; 继续分析其布局(per-context 槽位、fault 计数、GPU 型号相关字段), 可能找到更多可用于判定/信息收集的字段。
3. **工具方法沉淀**: "绝对指针被清零 → 用 `adrp+add` 交叉引用反查函数" 已跑通, 可作为后续所有定位任务的标准手段。

---

## S. 反向补丁审计(2026-09-22, 主线=hid零写→root 的后续转向)

> 方向: 审计文档§23.4 推荐的路线A"反向补丁审计"。本轮从 v5.4.302 修复集 + 2026 热门 LPE 家族过滤。

### S.1 决定性门禁(实测, 一次过滤一整类候选)
| 门禁 | 实测 | 含义 |
|---|---|---|
| user namespace | `unshare -U` → **EINVAL**; `/proc/sys/user/max_user_namespaces` → **Permission denied** | **userns 被禁 → 无法在 sandbox 里拿 CAP_NET_ADMIN** |
| CapEff | **全 0** | shell 无任何 capability |
| SYSV IPC | ENOSYS(§8.1 已记) | msg_msg 喷射不可用 |
| af_alg / CRYPTO_USER_API | 全部 `# CONFIG_CRYPTO_USER_API_* is not set` | af_alg socket 族不可达 |
| RDS | `# CONFIG_RDS is not set` | PinTheft 不可用 |
| nft | `/system/bin/nft` 不存在; userns 禁 | nf_tables 状态改动不可达 |
| sctp | sockstat 无 SCTP; protocols 无 | 一批 sctp CVE 关闭 |
| 活跃协议 | UNIX(898) / TCP / UDP / NETLINK(56) / PACKET(7) | 真正活的 socket 面 |

⇒ **"需 userns 拿 CAP" 是决定性过滤**: 2026 最强 LPE 家族全部依赖它, 对本机全不适用。

### S.2 热门候选逐条判定(2026)
| CVE | 子系统 | 本机适用? |
|---|---|---|
| CVE-2025-40271 | proc_readdir_de rbtree UAF(3.14–6.18) | ✗ 真 UAF 且 5.4.281 缺, 但需 CAP_NET_ADMIN(veth) + SYSV msg_msg + modprobe_path 终点 → 三道门禁都不满足 |
| CVE-2024-1086 | nf_tables double-free | ✗ userns 禁 |
| CVE-2026-23231 | nf_tables RCU UAF | ✗ userns + msg_msg + modprobe_path |
| CVE-2026-43503 (DirtyClone) | page cache | ✗ userns 禁 |
| CVE-2026-46300 (Fragnesia) | XFRM ESP-in-TCP | ✗ userns + 需 CONFIG_INET_ESPINTCP |
| CVE-2026-43284/-43500 (DirtyFrag) | xfrm/rxrpc | ✗ userns |
| CVE-2026-31431 (Copy Fail) | algif_aead | ✗ CRYPTO_USER_API 关 |
| CVE-2026-43494 (PinTheft) | RDS zerocopy | ✗ RDS 未编译 |
| CVE-2026-53362 | ipv6 frag OOB | ✗ userns + 6.12+x86 |
| CVE-2026-31419 | bonding UAF | ✗ 需 CAP/组网 |
| CVE-2025-38256 | io_uring rsrc folio | ✗ 本机 io_uring 511 无 rsrc (已 §19.0 证伪 opcode>11) |
| CVE-2025-68814 | io_uring filename leak | ✗ 仅泄漏且 OPENAT 未实现 |

### S.3 剩余可深挖(未定)
- **af_alg 关闭**已排除 page-cache 家族, 但注意 DirtyPipe(CVE-2022-0847) 终点也是 page cache —— **不依赖 userns**。需确认本机 pipe 是否可写只读文件页面(pipe_buffer flag 未初始化 → CAN_MERGE)。这是 page-cache 家族里**唯一不依赖 userns/CAP** 的, 值得单独验证(虽然 Linux 本机可能已含当初修复, 需反汇编确认)。
- NETLINK(56 socket) 面未针对"无 CAP 可操作"的协议族专项审计。
- 结论: **1728 未修复 CVE 中, 无 userns/无 CAP/无 SYSV 的 Android shell 可用候选极少**, 大量高价值候选被 userns 门禁一刀切死。**S 节与 §F/§J/§K/§O/§P 的"本机无可行候选"全局结论互相印证**。

### S.4 DirtyPipe (CVE-2022-0847) 反汇编定论 —— 已修复(2026-09-22)
- **动机**: page-cache 家族里唯一不依赖 userns/CAP 的候选; 若不适用则 page-cache 全部关闭。
- **反汇编** `pipe_write$baf80d164bcf9e90eecb51e862ccc554` @ VA `0xffffffc0105896e8` (file `0x5096e8`):
  - merge 判定区(offset 0x509750–0x50978c): 取 pipe 尾部 buffer 的 ops 指针 `[buf+0x10]`, 与 **`anon_pipe_buf_ops`** (0x20aa000+0xdb8) 比较, `cmp x11,x12; b.ne → 走新 buffer 分支`。⇒ **仅当尾部 buffer 属于 anon_pipe_buf_ops 时才允许 merge**。
  - 新建 buffer(offset 0x509914–0x509924): `str x25,[x9]` = page; `str x11,[x10,#0x10]` = ops; **`str wzr,[x9,#0x18]` = flags 写 0**(无 CAN_MERGE); `ldrb [file+0x42]; tbz bit0 → 不设 flags`。
- **结论**: 本机 `pipe_write` 对新 buffer flags=0、且 merge 只对 anon_pipe_buf_ops 有效 ⇒ **splice 的只读文件页走 page_cache_pipe_buf_ops, 不满足 merge 条件 ⇒ CVE-2022-0847 修复在位**。(与实测: 多次写成功但文件页未被 'Z' 覆盖一致。)
- **page-cache 家族全部关闭**(Copy Fail/DirtyFrag/DirtyClone/Fragnesia 靠 userns, DirtyPipe 已修)。