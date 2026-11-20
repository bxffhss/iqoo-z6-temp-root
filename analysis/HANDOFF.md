# 交接文档 — iQOO Z6 KGSL 内核提权研究(截至 2026-09-17 晚)

> 新对话直接用本文件 + `.workbuddy/memory/MEMORY.md` 即可接续, 无需重跑已完成的逆向。
>
> **索引修订 (2026-09-17 22:30)**: 修正 `kgsl_dis.asm` 实际路径(在仓库根, 非 `analysis/`)、
> 澄清 §CM/§CN 归属(总账止于 §CA, 审计在 `kgsl_audit_01/02.md`)、
> 补入此前漏索引的 `CURRENT-STATUS.md` / `kernel-lpe-conclusions.md`, 并补 §三C 的**真机运行地址(KASLR)**。

---

## 一、目标与现状
- **目标**: BL 锁定 + uid=2000 shell 的 iQOO Z6 上取得临时 root(内核提权)
- **现状**: 情报与工具链已完备(**符号化内核审计 + 权威 ioctl 表 + GPUOBJ 原语 + dlopen 能力**),
  已审 6 条核心内核路径**未发现漏洞**; GPU 微码路线**实测判死**
- **未达成**: 尚未找到可利用的漏洞 → 未获得 root

## 二、设备/环境(固定事实)
| 项 | 值 |
|---|---|
| 机型 | iQOO Z6 / V2220A / PD2220, SM7325 (Adreno 642L / A6xx) |
| 内核 | 5.4.281-qgki-g2a88cd145def (2025-05-07 编译) |
| 构建 | PD2220_A_14.2.9.1.W10.V000L1, 指纹 `vivo/PD2220/PD2220:11/RP1A.200720.012/compiler0507114814:user/release-keys` |
| SPL | **Android 2025-04-01 / vendor 2024-02-01** |
| 账号 | uid=2000 shell, SELinux enforcing, BL locked |
| config | 无 USER_NS, 无 NF_TABLES; 有 NETFILTER/BPF/KPROBES/MODULES/ION |
| shell 可开设备 | binder, hwbinder, **kgsl-3d0**, uhid, uinput, ptmx, ashmem, null/zero/random |
| adb | `/c/adb/platform-tools/adb -s <DEVICE_SERIAL>` (push 后必须 chmod 755) |
| 编译 | NDK r27 `J:/Users/Administrator/AppData/Local/Android/Sdk/ndk/27.3.13750724/.../clang.exe --target=aarch64-linux-android35 -O2 [-static]` |
| bash 前缀 | `export PATH=/usr/bin:/bin:$PATH` |

## 三、三条主线的结论

### A) GPU 微码路线 —— 实测判死(不要再投入)
- `CP_SMMU_TABLE_UPDATE(0x53)` 处理器入口 = 跳转表 index **0xa62**: `brne $12,0x0,#0x143e`; **$12 = @IB_LEVEL**
  → level 0(RB/内核级)才直写 TTBR0; level≥1(我们的 IB1)走记录路径
- 错误路径 `0x2eb3` = `jump #0x2eb3` **死循环**
- **决定性实验**: 传正确 64 位 VA 记录 + 故意填错魔数 → 仍静默、canary 落地、GPU 存活 ⇒ **0x53 在 IB1 被丢弃**
- 旁路全灭: 0x54/0x55 同样检查; TYPE4/CP_REG_RMW 寄存器写被保护; RB/memstore **不在 TTBR0 可见空间**(页级测绘 0 命中);
  preamble/CTX_SWITCH gflags = MARKER; 0x10(ISSUEIBCMDS) 结构正确但恒 hard fault; CP_MEM_TO_MEM **恒定只拷 1 dword**
- 保留资产: `sqe/`(Adreno QRisc 微码反汇编工具链) + `cheese/kgsl_*.c` 探针 —— **换 A7xx 设备可直接复用(CVE-2025-21479 那条路是通的)**

### B) ioctl 权威表 + GPUOBJ 原语(已完成, 可直接用)
- **权威来源 = `/vendor/lib64/libgsl.so`**(已拉到 `vendor_libs/`): 内含官方表(file 0x208aa0, 24B 条目 `{cmd, pad, name_ptr, flags}`)
  → `analysis/gsl_ioctl_names.txt`; 内核侧表在 vaddr 0x1210eb70(native)/0x1210fae0(compat), `entry[nr]=base+nr*16`
- **⚠️ 按 kgsl.h 猜的 nr→名字全错**, 正确关键项:
  0x15 MAP_USER_MEM(48) | 0x2f GPUMEM_ALLOC(24) | 0x34 GPUMEM_ALLOC_ID(48) | 0x36 GPUMEM_GET_INFO(72) |
  0x3c GPUMEM_SYNC_CACHE_BULK(24) | 0x3d SUBMIT_COMMANDS(56) | 0x40 SYNCSOURCE_CREATE(16) | 0x42/0x43 SYNCSOURCE_*_FENCE |
  0x44 CFF_SYNC_GPUOBJ | **0x45 GPUOBJ_ALLOC(48)** | 0x46 GPUOBJ_FREE(32) | **0x47 GPUOBJ_INFO(48)** | 0x48 GPUOBJ_IMPORT(32) |
  0x49 GPUOBJ_SYNC | **0x4a GPU_COMMAND(64)** | 0x4c GPUOBJ_SET_INFO(32) | 0x57 GPU_AUX_COMMAND(48) | 0x58 TIMELINE_CREATE(16) |
  0x59 TIMELINE_WAIT | 0x5a TIMELINE_QUERY | 0x5b TIMELINE_SIGNAL | 0x5d TIMELINE_DESTROY |
  **0x50-0x55 SPARSE_*(PHYS/VIRT_ALLOC, BIND, GPU_SPARSE_COMMAND) 内核未实现 → ENOTTY**; 0x38-0x3b PERFCOUNTER 实测 ENOTTY
- **实测确证的结构体**:
  - ALLOC(0x45, 48B) `{u64 size@0; u64 flags@8(回填 |=0xc0000); u64 va_len@16; u64 mmapsize@24(出); u32 id@32(出); u32 metadata_len@36; u64 metadata@40}`
  - INFO(0x47, 48B) `{u64 gpuaddr@0出; u64 flags@8; u64 size@16; u64 va_len@24; u64 va_addr@32; u64 id@40**入**}` ← id 只认 @40
  - SET_INFO(0x4c, 32B) `{u64 id@0; u64 flags@8; u32 type@16(必须=1); u32 metadata_len@20; u64 metadata@24}`
    (metadata_len 可大于分配值 → 内核会 realloc, **非漏洞**)
  - IMPORT(0x48, 32B) `{u64 priv_ptr@0; u64 priv_len@8; u64 flags@16; u64 type@24}`; **priv 是"指向值的指针"**(传数值→EFAULT);
    type∈{2,3}(其它 ENOTSUPP); type=3 = fd 导入 dma-buf, type=2 = 用户地址
  - GPU_COMMAND(0x4a, 64B) 与 `cheese/adrenaline.h` 完全一致: `flags@0, cmdlist@8, cmdsize@0x10, numcmds@0x14, objlist@0x18, objsize@0x20, numobjs@0x24, synclist@0x28, syncsize@0x30, numsyncs@0x34, context_id@0x38`
  - GPU_AUX_COMMAND(0x57, 48B): `numcmds@0x14(必须=1), numobjs@0x24(≤0x20), context_id@0x28`
- **dma-buf 来源未解决**: 无 `/dev/dma_heap`; `/dev/ion` 仅 O_RDONLY 可开, `ION_IOC_ALLOC` → EINVAL ⇒ type=3 导入走不通

### C) 内核符号化审计工作台(已完成, 这是当前最有价值的资产)
- **`vmlinux-to-elf` 已跑通**(工具在 `vmlinux-to-elf-master/`; 用**系统 Python `K:/Python3/python.exe`**, 已装 peewee):
  ```
  cd vmlinux-to-elf-master
  /k/Python3/python.exe -m vmlinux_to_elf.scripts.vmlinux_to_elf ../kernel_image.img ../vmlinux.elf
  ```
  → `vmlinux.elf`(55MB, **179170 个符号**); 符号表 `analysis/vmlinux_symbols.txt`
- **地址映射(已由符号确证)**: `_text = 0xffffffc010080000`; **文件偏移 = (vaddr & 0xffffffff) - 0x10080000**
- **反汇编**:
  ```
  OD=.../ndk/27.3.13750724/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-objdump.exe
  "$OD" -d --start-address=0xffffffc010a78054 --stop-address=0xffffffc010a780a0 vmlinux.elf
  ```
- **提权符号(已定位)**: commit_creds=0xffffffc01031f154 / prepare_kernel_cred=0xffffffc01031f67c /
  init_cred=0xffffffc01293d528 / selinux_state=0xffffffc012b18000 / __do_sys_capset=0xffffffc0102ef8c8 /
  call_usermodehelper=0xffffffc0103051fc
- **⚠ 以上是「静态/未滑动」地址**(基址 `_text=0xffffffc010080000`)。**真机运行地址 = 静态 + KASLR slide**。
  该信息**只**记录在 `analysis/CURRENT-STATUS.md` §3.1-3.2(本文件此前遗漏, 已补):
  - 真机 `_text = 0xffffffe65f280000` / `_stext = 0xffffffe65f281000` / `_etext = 0xffffffe6607a0000`
  - **KASLR slide = `0x264f200000`**(跨运行稳定, 至少两次完全一致)
  - 获取方式: `perf_event_open` 软件事件 + `exclude_user=1` + 采样期持续触发系统调用;
    约 1.3 万样本/秒, 14 层连续内核帧 + 明确 kernel→user 边界帧判定
    (工具 `perf_kaslr3.c` / `perf_chain.c`, 旧工具失败原因是漏了 `IOC_ENABLE` 且从不回写 `data_tail`)
  - 真机真值(静态地址 + slide): commit_creds=`0xffffffe65f51f154` | prepare_kernel_cred=`0xffffffe65f51f67c` |
    init_cred=`0xffffffe661b3d528` | selinux_state=`0xffffffe661d18000` | init_task=`0xffffffe661b2e200` |
    kgsl_ioctl=`0xffffffe65fc865ec` | kgsl_ioctl_gpuobj_alloc=`0xffffffe65fc7bc60` |
    kgsl_ioctl_timeline_create=`0xffffffe65fc97760`
  - ⚠ **离线镜像 ≠ 真机内核**: `kernel_image.img` 为 `5.4.281-qgki-gbfef221370b4`, 真机运行
    `5.4.281-qgki-g2a88cd145def` —— 版本号不同, **仅 text 布局一致**, 可照偏移推符号, 勿当成同一镜像
  - 待办遗留: `physvirt_offset` / `memstart_addr` / `vmemmap` / `kimage_voffset` 是 .data 中的 8 字节变量,
    算出 PAGE_OFFSET 需要读原语; 真机地址见 `CURRENT-STATUS.md` §6(若写原语是内核 VA 直写型则**不需要** PAGE_OFFSET)
- **kgsl handler 全部可读**(0x10a7xxxx-0x10aaxxxx); 镜像里 0x11514000-0x11582000 的 440KB 零区是**数据区**, 与 kgsl 代码无关
- **dlopen libgsl 已打通**: `dlopen("/vendor/lib64/libgsl.so")` 可解析 **65 个 `ioctl_kgsl_*` 包装函数**(`analysis/gsl_ioctl_wrappers.txt`)
  + 全套 GSL API(gsl_device_open/context_create/memory_alloc_pure/command_issueib_sync...)
  **编译要点: 必须动态链接**(`clang --target=aarch64-linux-android35 -O2`, **不要 -static/-ldl**, 否则链到 libdl.a 桩而失败)

## 四、审计进度与结论(§CM-§CP)
工具: `kgsl_dis.asm`(**在仓库根目录 `G:\项目\Windows管理\usb\临时root\kgsl_dis.asm`, 不在 `analysis/` 下**;
kgsl 段完整反汇编 67226 行) + `analysis/kgsl_triage.txt`(敏感调用点自动分级)
已审 6 条核心路径, **"计数/长度→分配/拷贝"全部自洽, 未发现经典越界**:
- `kgsl_ioctl_gpu_command` @0x10a78054: numcmds≤100000 / numobjs≤100000 / numsyncs≤32 / context 校验 + 栈保护
- `kgsl_ioctl_gpumem_sync_cache_bulk` @0x10a7af04: 1≤count≤0x400, kcalloc/copy 长度一致
- `kgsl_ioctl_gpuobj_alloc` @0x10a7bc60 → gpumem_alloc_entry → kgsl_allocate_user → kgsl_alloc_pages:
  metadata clamp≤0x40; size≠0; `PAGE_ALIGN(size)` 回绕为 0→EINVAL; memdesc->size 与分配参数一致
- `kgsl_ioctl_gpuobj_import` @0x10a79ce0 → kgsl_setup_useraddr → memdesc_sg_virt:
  len 仅校验"非零+页对齐"(无上界), 但 npages/kvmalloc/get_user_pages 数量一致 + `end=size+addr` 防回绕
- `kgsl_ioctl_gpu_aux_command` @0x10a78390: numcmds==1, numobjs≤0x20
- `kgsl_drawobj_sync_add_synclist` @0x10a840b4: kcalloc(count,0x80) 与循环次数/用户指针步距(0x18)/拷贝上限(≤0x18) 三者一致

### 第 3 批(§CP, 详见 `analysis/kgsl_audit_03.md`)—— 合计 **10 条路径, 仍零发现**
- `drawobj_sync_add_syncpoints` @0x10a8372c: 按 `TIF_32BIT` 分双路径, 64 位用 24B 缓冲/步距 0x18,
  compat 用 12B 缓冲/步距 0xc + 拓宽成 native —— **缓冲=memset=拷贝=步距 四者一致** ✓
- `drawobj_cmd_add_cmdlist` @0x10a8388c: `min(cmdsize,0x20)` 拷入 32B 栈缓冲, 步距 **0x20** ✓
  条目确认为标准 `{offset@0,gpuaddr@8,size@0x10,flags@0x18,id@0x1c}`;flags 要求 `&7 != 0`
- `drawobj_cmd_add_memlist` @0x10a83a30: 同构, 步距 0x20 ✓;flags **bit3 必须置位**, bit4 → `add_profiling_buffer`
- `drawobj_add_timeline` @0x10a824e4: 16B 栈缓冲 + `check_zeroed_user` 尾部校验 + `kvmalloc(count*16)`(64 位无溢出) ✓
  (用户可控步距 `step`, 但拷贝恒被 `min(剩余,16)` 封顶, 且只读用户自身地址 → **非内核原语**)
- **CVE-2026-21385 对齐路径逐处核对**: `kgsl_iommu_get_gpuaddr`(align = `(flags>>16)&0xffff`,
  `lsl w11,w12,w11` 为 **32 位**取模 32 → **无 64 位符号扩展**)、`find_svm_region`/`set_svm_region`(ALIGN 全 64 位, 有防回绕)
  → 本机在 **IOMMU/VA 分配族无符号扩展**;§BN 判定(src-level 确证)**维持**
- `kgsl_ioctl_map_user_mem` @0x10a7a6cc 初步: 48B 结构确认
  `{fd@0,gpuaddr@8,len@0x10,offset@0x18,hostptr@0x20,memtype@0x28,flags@0x2c}`;
  flags bit3(SECURE) 需安全 mmu 否则 -EOPNOTSUPP;memtype 仅 {2,3};内部 bit32 = `TIF_32BIT` 标记
- **ioctl 分发表全部解出**(套 `.rela.dyn` + 解 `.cfi_jt`)→ `analysis/kgsl_ioctl_handlers_v2.txt`
- **`submit_commands` 链(0x3d)审完** —— 第二条提交路径, 3 个函数全部自洽:
  - `kgsl_ioctl_submit_commands`@0x10a77d3c: `numcmds ≤ 100000` / `numsyncs ≤ 32` / context 归属校验;
    栈上 drawobj 指针数组 **2 槽**, `stp xzr,xzr` 清零恰好 2 槽, 实测写入下标 ≤1;
    清理循环由"已成功存入"计数驱动(递增在 `add_*` 之前)→ **无越界、无泄漏** ✓
  - `kgsl_drawobj_cmd_add_ibdesc_list`@0x10a835d8: 又是 **TIF_32BIT 双路径**
    (64 位 32B 栈缓冲/步距 0x20;compat 16B/步距 0x10 + 拼 native)—— 四长度一致 ✓
  - `kgsl_drawobj_cmd_add_ibdesc`@0x10a81ff4: `size = sizedwords << 2`(**64 位, 无溢出**);
    ⚠ `sizedwords` 无上界, 但属 §AF.6 已知的"IB 边界不校验"同一类语义问题, §CA 已判死
    ⚠ 附带(功能 bug 非安全问题): compat 拼 native 时 `desc+4` 4 字节被丢弃
### UAF / 生命周期面 —— 第 1 轮(§CR, 详见 `analysis/kgsl_audit_03.md` §10)
**mem_entry 释放路径 = 设计上防 UAF, 四重机制互相独立**:
- **`pending_free` 闸门**: `gpumem_free_entry`@0x10a78ec0 在 `process->mem_lock`(`priv+0x20`)内
  检查并置位 `entry+0xf0` ⇒ 二次释放必然 `-EBUSY(-16)`
- ★ **`kgsl_sharedmem_find`@0x10a77030 跳过已释放对象**: 持 mem_lock 遍历 idr, 做
  `gpuaddr ∈ [entry->gpuaddr, +size)` 范围匹配, 而 **`[entry+0xf0] != 0` 的 entry 直接跳过**
  ⇒ 已释放对象**查不到** ⇒ 二次释放时 find 返回 NULL ⇒ ioctl 返回 **-EINVAL**
  —— **与黑盒实测"二次释放→EINVAL"完全吻合, 首次给出源码级解释**
- **引用计数配平**: find 用 `refcount_inc_not_zero` + 饱和检查(**返回值即持有引用 +1**);
  `gpumem_free_entry` 内一次 `refcount_dec_and_test`(**-1**)与之配平
  ⇒ 该函数里那个 `kgsl_mem_entry_destroy` 分支在本路径上**实际不可达**(防御性), 真实释放在进程拆除时
- **销毁异步化**: `kgsl_mem_entry_put_deferred`@0x10a75ac4 在引用归零时**不立即 kfree**,
  而是 `queue_work_on(8, wq, entry+0x138)` 交给 workqueue ⇒ 避免持锁/GPU 在飞时销毁
  (CVE-2022-22057 那类问题的经典缓解)
- 其余: `kgsl_mem_entry_destroy`@0x10a75bb4 = `memtype=(flags>>5)&7` → 统计 → `detach_process`
  → `kgsl_sharedmem_free` → `kfree`, 顺序正确(先脱链再释放)
- 另: `gpumem_free_entry` 会写一个 **free 日志环形缓冲**(0x200 项 × 40B, `0xffffffc01317e0f90`)

**⇒ 该子面未发现漏洞;下一轮转 context 销毁 vs 提交竞态 与 fence 回调**
- **合计 13 条路径, 仍零内存安全发现**

## 五、下一步(§CQ 路线更新: **Route A 已闭合**, 主线转 UAF)

**★ 已选主线: CVE-2026-21385 定位与定向实测**(理由: 唯一挂钩「确认存在 + 在野利用 + 明确含 SM7325 +
vendor SPL 2024-02 必然未修」的漏洞;其余路线要么同维度已 13/13 零发现, 要么黑盒已行为覆盖)
- 已做 A1 第 1 轮: 全段搜索对齐提取点 → `ubfx #16,#16` **全段只有 1 处**(0x10aa7b8c), 且是 32 位位移 + 零扩展
- 已做 **A1 第 2 轮**(§CQ, 详见 `kgsl_audit_03.md` §7)—— 结论比第 1 轮硬得多:
  - **`gpumem_alloc_entry` 对 align 有显式上界**: `(flags & 0xFF0000) > 0x180000` → `_dev_err` + **sanitize**
    (`flags & 0x9D00FF08` 抹掉该域再 `| 0x190000`)⇒ 对齐指数被封在 **≤24**
    ⇒ **CVE-2026-21385 在 GPUOBJ_ALLOC / GPUMEM_ALLOC 入口上"源码级"判死**(强于 §BN 的经验判定)
  - ⚠ **`kgsl_ioctl_map_user_mem`(0x15/0x20) 的 flags 掩码是 `0x91FFFF08`, 没有这个上界**
    ⇒ 它能用 `flags = 0x001F0000` 把对齐指数推到 **31** ⇒ **唯一开口**
  - 但消费点 `kgsl_iommu_get_gpuaddr` 仍是 `lsl w` + `csel w22`(零扩展)⇒ **该处不会因 2GiB 对齐越界**
  - 对齐提取点已按三种编码穷举(`>>16` / `&0xffff` / `&0xff0000`), 确认**全段唯一**
- 已做 **A1 第 3 轮**(§CQ, `kgsl_audit_03.md` §8):
  - ★ **解出 `kgsl_ioctl_helper`@0x10a863f8 的 IO 地基**: 固定 **128B 预清零栈缓冲**(sp+0x8) +
    **`min(表size, 用户size)`** 双向拷贝 + **表 size ≥ 0x81 直接 EINVAL** + 表项/用户 cmd 的 dir 位双重检查
    ⇒ **排除"共用 handler / 尺寸不一致"一整类怀疑**(如 `nr 0x20` size=24 与 `0x15` size=48 共用 handler),
    并解释清了 CURRENT-STATUS §3.3 的"不校验 _IOC_SIZE / 回写依赖 size"
  - ★ **`map_user_mem` 对齐开口确认成立**: 0x10a7a8e4 汇合点按 size 反写对齐指数
    (≥2MB→21 / ≥1MB→20 / ≥64KB→6 / **<64KB→用户值原样保留且无上界**)
    ⇒ `MAP_USER_MEM(len<64KB, flags=0x001F0000)` 可把指数灌成 31
  - 但消费点仅影响 VA 摆放(零扩展 + 全 64 位 ALIGN + `-ENOMEM` 兜底) ⇒ **武器化未成立**
- 已做 **A2 在线实测**(`cheese/kgsl_a2.c` + `cheese/kgsl_a2b.c`;原始输出 `analysis/a2-align-test.log`):
  - 开口 **可达 ✓**: `MAP_USER_MEM(len<64KB, flags=0x001F0000)` 接受 exp=31(GPUOBJ_ALLOC 同位置会被拦)
  - 对齐 **被采纳 ✓**: 同参连分两次的 gpuaddr **间距 = `max(2^exp,0x1000)` 精确吻合**
    (exp8→0x1000, 13→0x2000, 16→0x10000, 20→0x100000, 24→0x1000000, **31→0x80000000 = 2GiB**)
  - **可转为原语 ✗**: mmap 四种 offset(正确 / −4K / 截断32位 / 0)**全 EINVAL**(反算校验健全);
    16 次 2GiB 步进分配全成功、**严格递增 0x80000000、无 `gpuaddr==0` 假成功、无别名**;
    全程零 oops, canary 全绿
- ⛔ **结论: Route A 闭合** —— CVE-2026-21385 在本机通过 kgsl align 字段**不可武器化**;
  该路径属**按设计工作**(用户请求超大对齐是合法但无意义的请求)。**不要再投入此路线。**
- 已作废: §BN 的位段扫描(`flags = N<<24` 只动了 bits 24-31, 实际只命中 bit28 USE_CPU_MAP)

### ★ 新主线: UAF / 生命周期面(KGSL 历史 CVE 最密集区)

至今**只做过黑盒行为覆盖**(双销毁 / 销毁后用 fence fd / 1600 轮竞态全干净, CURRENT-STATUS §3.4),
**完全没做静态审计**。建议顺序:
1. `kgsl_mem_entry` 引用计数: `gpumem_free_entry` / `kgsl_mem_entry_put` / `kgsl_mem_entry_attach_process`
   与 GPU 使用期的交叉;`put_gpuaddr` 与 `_insert_gpuaddr` 的时序
2. context 销毁 vs 提交竞态: `kgsl_context_destroy` / `kgsl_context_get-put` 与 `gpu_command` 的窗口
3. `timeline` / `syncobj` fence 回调: `drawobj_sync_*_callback`、`kgsl_syncsource_process_release_syncsources`
4. 方法: 沿用 `kgsl_dis.asm` + `vmlinux.elf` 符号化工作流, 重点看「**引用计数递减之后的第二次使用**」

**⚠ 第 1 轮已完成(§10)**: **mem_entry 释放路径是设计上防 UAF 的**(四重机制, 见 §四 UAF 小节),
该子面未发现漏洞。下一轮从第 2/3 项入手, **不必再查 mem_entry 释放**。
关键符号地址: `kgsl_context_destroy`=0x10a768b4 / `kgsl_context_get`=0x10a7d338(+7 份内联副本) /
`kgsl_mmu_put_gpuaddr`=0x10a87318 / `_insert_gpuaddr`=0xffffffc010aa80c4 /
`kgsl_iommu_put_gpuaddr`=0x10aa7cf0 / `kgsl_mem_entry_attach_process`=0x10a7a2f8

**⚠ 第 2 轮已完成(§11, context 生命周期)**: **双闸门, 无窗口**
- `kgsl_context_get`@0x10a7d338: **读锁 `device+0x758`** → `idr_find(device+0x740, id)` →
  拒绝 `ctx->flags([+0x20]) bit1` → `refcount_inc_not_zero([ctx])` → 解锁
  ⇒ **查表 + 取引用在同一临界区**
- `kgsl_context_destroy`@0x10a768b4: timeline_put → **写锁 `device+0x758`** →
  清 memstore 槽(`ctx->id*40`, `+8`) → **`idr_remove(device+0x740)` + `ctx->id=-1`** → 解锁 →
  递减 priv 引用 → `ftbl->drawctxt_destroy(ctx)`
- ⇒ `get` 要么在 destroy 前(引用 +1, 递减不归零)、要么在 destroy 后(`idr_find` 找不到)
  ⇒ **不存在"拿到正在被释放的 ctx"的窗口**;与黑盒 1600 轮竞态全干净互为印证
- 第一道闸门: `destroy` 开头 `tbz flags,#1 -> brk`(断言), `get` 见到该位即拒绝

**→ 第 3 轮候选**:
1. `adreno_drawctxt_destroy`@**0xffffffc010af3368** —— **不在 kgsl 段(在 adreno 段)**,
   需直接 `llvm-objdump -d` 反汇编 `vmlinux.elf`;这里才是"销毁时是否等 GPU flush 完"的落点
2. ~~fence 回调 / syncobj 回收~~ → **已完成(见下)**
3. `kgsl_mmu_put_gpuaddr`@0x10a87318 / `_insert_gpuaddr`@0xffffffc010aa80c4 时序

**⚠ 第 3 轮已完成(§12)—— UAF 面收口**:
- **`adreno_drawctxt_destroy`@0xffffffc010af3368**(跨段反汇编): 整个函数就是 **`kfree(ctx)`**
  ⇒ 销毁路径**不等 GPU**
- **`kgsl_active_count_wait`@0x10a8cb78 全内核仅 4 个调用点**: `kgsl_pwrctrl_change_state` +
  **`adreno_last_close`(×3)** ⇒ 「等 GPU 做完」**推迟到 last-close / 电源切换**, 不在 per-context 销毁里
  —— **设计选择, 非缺陷**
- ★ **无 per-context 定时器**: 符号区搜 `kgsl_context*timer` **零命中**(仅全局 `kgsl_idle_check`@0x10a8b370)。
  老 KGSL 的 `context->timer` 已被 per-context **timeline** 取代(销毁里的 `kgsl_sync_timeline_put` 即它)
  ⇒ **"timer 回调踩已释放 context"这一类在本机不适用**(一个完整的攻击面被排除)
- **`kgsl_syncsource_process_release_syncsources`@0x10aaa0f0 有序**: 持 `priv+0x1c0` → `idr_remove`+`id=0`
  → 持 `syncs+0x40` → 逐个 `dma_fence_signal_locked` + `__list_del_entry_valid` + `list_del`
  → `kgsl_process_private_put` → **最后 `kfree(syncs)`** ⇒ signal 在前、kfree 在后, 无 UAF

**⛔ UAF 面整体收口**: mem_entry 释放 / context 生命周期 / fence·syncobj 回收 **三个子面全部干净**,
且每个都与既有黑盒测试互为印证。**不再投入。**

### 副轨(遗留, 优先级低于已收口的面)
- `add_profiling_buffer`@0x10a8213c —— 唯一**两条**用户路径可达(仍未读)
- `timeline_*` 五个 handler@0x10a97xxx-0x10a98xxx
- `kgsl_mmu_put_gpuaddr` / `_insert_gpuaddr` 时序(VA 回收 vs 对象释放)

### (背景留档) uhid/uinput 是怎么被发现的 —— 详细内容与 CVE 情报见上方 §CV 块

**背景**: 做"换子系统"的可达性枚举时发现 —— **vendor 侧全被 SELinux 关死**(见下表),
可开的只剩 `kgsl-3d0` / **`uhid`** / **`uinput`** / `ptmx`(+ binder/hwbinder)。
其中 `uhid` 与 `uinput` **可达、从未审计、且在 SPL 窗口内**(vendor SPL 2024-02)。

- **符号确认**(在 **0x10eb/0x10ee 段**, hid/input 区, **不在 kgsl 段**;`kgsl_dis.asm` 不覆盖,
  需 `llvm-objdump -d --start-address=... vmlinux.elf` 跨段反汇编):
  - `__initcall_145_1128_uinput_misc_init6` / `__initcall_168_815_uhid_misc_init6`(两者均编入内核)
  - `__uhid_report_queue_and_wait` @**0x10eb0d50** / `uhid_hid_driver`(导出)
  - (`ashmem_ioctl`@0x10eee780 同段但不可达)
- **`uinput` 面**: `UI_DEV_CREATE` / `UI_DEV_SETUP` / `UI_ABS_SETUP` / `UI_DEV_DESTROY` /
  **`UI_BEGIN_FF_UPLOAD` / `UI_END_FF_UPLOAD` / `UI_BEGIN_FF_ERASE` / `UI_END_FF_ERASE`**
  (力反馈上传/擦除 —— 历史上 `copy_from_user` + 尺寸处理的高危区)
- **`uhid` 面**: `UHID_CREATE` / **`UHID_CREATE2`(report descriptor 长度)** / `UHID_DESTROY` /
  `UHID_INPUT2` / `UHID_GET_REPORT` / `UHID_OUTPUT`(`__uhid_report_queue_and_wait` 等待队列)
- **时效性**: 内核 5.4.281 + vendor SPL **2024-02** ⇒ 2024-03 之后 hid/uinput 的修复**必然缺失**
- **步骤**: ① 检索 2024-02 之后的 hid/uinput CVE;② 跨段反汇编 uhid/uinput 的 ioctl 面,
  核对"长度/计数 → 分配/拷贝";③ 必要时真机探测(两者均可 open, 风险低)

### ★★ 新主线: `uhid` → `hid-multitouch` / `hid-core`(§CV, 真正的矿脉)

**可达性**: `/dev/uhid`、`/dev/uinput` 实测 `open()` 成功(§13 枚举, **唯一剩下的可达面**)。
**uhid 让用户态凭空造 HID 设备(完全控制 report descriptor + bus/vendor/product)**
⇒ `hid_add_device` → `hid_scan_report`(定 group)→ 驱动 probe → `hidinput_connect` 全链可达。

**内核里确认编入**(符号级):

| 组件 | 符号与地址 |
|---|---|
| uhid | `uhid_misc_init` 的 initcall / `__uhid_report_queue_and_wait`@**0x10eb0d50** / `uhid_hid_driver` |
| uinput | `uinput_misc_init` 的 initcall |
| hid core | `hid_add_device`@0x10ea24f0 / `hid_open_report`@0x10e9f7d8 / `hid_parse_report`@0x10e9f3fc / `hid_report_raw_event`@0x10ea0fe4 / `hid_connect`@0x10ea1694 |
| hid-input | `hidinput_*` 整族 0x10ea3xxx-0x10ea5xxx |
| ★ **hid-multitouch** | **`mt_devices`@0x120fea80 / `mt_classes`@0x120ff3e0 / `mt_probe`@0x101ba53c**;`mt_report_fixup` **符号缺失**(待确认) |

**窗口内 CVE(vendor SPL 2024-02 ⇒ 全部必然未修)**:

*hid-multitouch(内存破坏型, 最肥)*
- **CVE-2025-39806** —— `mt_report_fixup()` **无边界检查**访问 descriptor **偏移 607**
  (先读 `[607]==0x15` 再写 `[607]=0x25`);descriptor **< 607 字节**即触发 ⇒
  **slab 越界读 + 条件越界写(固定偏移)**。修复方式就是加 `*size >= 608`
- **CVE-2026-43047** —— 设备对 feature report 请求返回**不匹配的 report ID** → HID core 混淆 → **OOB write**(7.8)
- **CVE-2026-64364** —— **contact count 过大** → 破坏 `struct mt_device` 相邻成员 → 定时器上下文 panic
- (CVE-2026-80780 `hid_pidff` 需 `hid-universal-pidff`, **5.4 无此驱动, 不适用**)

*hid-core*
- **CVE-2026-80918** —— `fetch_item()` 对 **long item** 存指针而 `item_udata()/item_sdata()` 按短格式读
  ⇒ 返回**内核指针低 32 位**当数值(dmesg 打印);触发: 用 long 编码的 `REPORT_SIZE`
- **CVE-2026-31624** —— `s32ton()` 位移越界, `report_size` 只被限制到 **≤256**;经 output report 触发

*uinput*
- **CVE-2026-31667** —— 力反馈锁序反转(`ff->mutex → udev->mutex → input_mutex → dev->mutex → ff->mutex`),
  修复是把 `uinput_request_send()` 的 `udev->mutex` 换成 `state_lock` 自旋锁 ⇒ **死锁/DoS**(非内存破坏)

**不适用**: CVE-2026-50265 / 50292(libinput udev 属性注入 → 任意 root 代码执行)——
**需 udev + libinput, Android 上不存在**。

**为什么这条线比 KGSL 有希望**: ① 可达性明确 ② **uhid = 完全控制 report descriptor**,
是"输入面"而非"提交面" ③ hid-multitouch 14 个月内 3 个内存破坏 CVE, 密度高
④ SPL 窗口内全部未修 ⑤ 成本低(一个描述符 + 一次 `UHID_CREATE2`)

**下一步(待执行)**:

**⚠ 已执行第一步(§15, 见下)—— 结果: CVE-2026-43047 确认存在, CVE-2025-39806 不存在**

### ★★★ §15 确认结果(本项目最好的一次)

**手法(可复用)**: `.rela.dyn` 里 addend == `mt_devices`(0x120fea80) 的重定位 ⇒ 就是 `hid_driver.id_table`
字段地址 `0xffffffc0128bb660`;读 struct−8 得到 `.name` = **"hid-multitouch"** ✓;
再把该 struct ±0x300 内所有重定位按偏移列出, 每个值先**按 `.cfi_jt` 桩解码**(单条 `b`)得到真函数。
恢复出的回调表: +0x28 `mt_probe` / +0x30 `mt_remove` / +0x50 `mt_event` / +0x58 `mt_report` /
+0x68..+0x80 `mt_input_mapping`/`mt_input_mapped`/`mt_input_configured`/`mt_feature_mapping` / +0x90/+0x98 `mt_resume`/`mt_reset_resume`

**✗ CVE-2025-39806 不存在**(双重验证):
- 其他驱动的 fixup **全都有符号**(`sony_`/`lg_`/`ms_`/`uclogic_`/`apple_`/`elecom_`/`hidpp_`/`pk_report_fixup`),
  **独缺 `mt_report_fixup`**;且回调表里**没有 report_fixup 槽位**
- 全内核搜 `LDRB/STRB #607`(138/11 处)**无一处属于 hid 代码**;`cmp #608` 仅 1 处(ALSA)

**★★★ CVE-2026-43047 确认存在** —— `mt_get_feature`@0x101bcb1c 尾部:
```
0x101bcbac: blr x8                    ; hid_hw_raw_request(hdev, report->id, buf, size, FEATURE, GET)
0x101bcbc0: tbnz w0,#0x1f -> warn+kfree+return     ; ret<0 只发警告, 无 ID 检查
0x101bcbc4: mov w1,#2                 ; HID_INPUT_REPORT
0x101bcbd8: bl hid_report_raw_event   ; ★★ 直接把设备响应喂进 HID 输入解析器
0x101bcbe0: kfree(buf); return
```
**`hid_hw_raw_request` 与 `hid_report_raw_event` 之间没有任何 report ID 校验** ——
而修复描述正是"check that the report ID in the response matches the one requested;
if not, **omit reporting the raw event**"。**该插检查的位置就是这两行之间, 本机没有。**
⇒ **OOB write(CVSS 7.8), 可达, 未修复。**

**可达性链完整**: ① `/dev/uhid` 可 open ② `hid-multitouch` 已编入
③ **uhid 的 feature 响应字节由用户态提供**(内核发 GET_REPORT 时, uhid 经读路径把 `UHID_GET_REPORT`
事件交给用户态, 用户态回 `UHID_GET_REPORT_REPLY`)⇒ **报告 ID 由我们填写, 可故意制造不匹配**

**★★★ 越界写的确切机制已定位(§16, 指令级)** —— 本项目最核心的成果

**请求侧 `mt_get_feature`@0x101bcb1c(完整)**:
```
w22 = hid_report_len(被请求的特征报告)          ; (report->size+7)/8 + (report->id!=0)
x20 = hid_alloc_report_buf(report, GFP_KERNEL)  ; ★ 缓冲按"被请求的报告"分配
if ((w22-1)>>13 != 0) -> warn + kfree + return  ; 上限 8192
hid_hw_raw_request(hdev, report->id, buf, w22, HID_FEATURE_REPORT=2, HID_REQ_GET_REPORT=1)
tbnz w0,#0x1f -> warn + kfree + return          ; ★ 只看 ret<0; **实际返回字节数被丢弃**
hid_report_raw_event(hdev, HID_INPUT_REPORT=2, buf, w22, 0)   ; ★★ size 用"被请求报告"的长度
kfree(buf)
```
⇒ **缓冲长度(来自被请求的报告)与待解析报告(由 `buf[0]` = 设备返回的 ID 决定)彻底解耦**

**消费侧 `hid_report_raw_event`@0x10ea0fe4 —— 越界写的确切指令**:
```
w11 = [report]                                   ; ★ report->id(= buf[0], 攻击者可控)
w8  = min(上限 8192/4096, (report->size-1)>>3)   ; 报告期望的数据字节数
w8  = (report->id != 0)
w25 = w22 - w8                                   ; csize − 编号字节
w24 = w4 - w25                                   ; ★ 报告期望长度 − 已供长度
x0  = (data + 编号字节) + (csize − 编号字节) = data + csize
bl  memset                                       ; ★★★ memset(data + csize, 0, w24)
```
**基点正好是「已供数据的末尾」, 长度 = 报告期望长度 − 已供长度**

**攻击者构造**:
| 控制项 | 选成 | 后果 |
|---|---|---|
| 被请求特征报告的 `report->size` | **小**(如 8 bit ⇒ csize=1) | `csize` 小、`buf` 小 |
| 返回的 `buf[0]` | 指向一个**大**输入报告(ID 由 uhid 用户态填) | 查出 report 期望长度大 ⇒ `w4` 大 |
| → | | `w24 ≈ w4 − 1`, **最大 8191** |

⇒ **`memset(data+1, 0, ~8191)` 而 `buf` 仅 1 字节** ⇒
**堆越界零填充写, 长度攻击者可控(上限 4096/8192)** —— 与 CVE 描述 "OOB writes" 完全吻合。
**在 kmalloc 小对象上做零填充是经典可利用形态**(可改相邻对象的指针低位/长度/标志)。

**★★ 触发路径已定位(§17)** —— `mt_get_feature` 全内核只有 **3 个调用点, 全部来自
`mt_feature_mapping`@0x101bc578**(`.feature_mapping` 回调, 由 hid-core 在 `hidinput_connect`
期间对 **FEATURE 报告**的字段逐个调用):

| 调用点 | 触发 usage |
|---|---|
| 0x101bc5d0 | **`0x000D0055` = `HID_DG_CONTACTMAX`** ★ 之后读响应首字节存 `td+0x69`(接触点上限, 有 ≤250 钳位) |
| 0x101bc610 | `0xFF0000C5`(vendor page 0xFF00 / usage 0xC5) |
| 0x101bc62c | `0x000D0059`(**该路径已有上界检查** `if (idx >= max) { _dev_err; return; }` —— 疑含 CVE-2026-64364 的修复) |

**★ 完整触发方案**(描述符须同时含):
- (a) 足以让 `hid_scan_report()` 判为 **MULTITOUCH** 的用法(Digitizer / Touch Screen)
- (b) ★ 一个 **FEATURE 报告**, 含 `usage = Digitizer(0x0D)/ContactMax(0x55)` 字段,
  且该报告要**小**(如 report_size=8, report_count=1 ⇒ `hid_report_len` = 1~2)
  ⇒ 它就是 `mt_get_feature` 的"被请求报告" ⇒ `csize` 小、`buf` 小
- (c) ★ 一个 **INPUT 报告**, ID 非 0, `report->size` **很大**(如 8192 bit)
- 然后: `hidinput_connect` → `mt_feature_mapping(ContactMax)` → `mt_get_feature` → `GET_REPORT`
  → **uhid 把 `UHID_GET_REPORT` 交用户态, 我们回 `buf[0]` = 大 INPUT 报告的 ID**
  → `hid_report_raw_event` 按 `buf[0]` 查出大报告 → `memset(buf + csize, 0, w24)` **越界写**

**剩余待做**:
1. 确认 `0x10ea10c0` 旁路(`[hdev+0xc30]`)是否影响 memset 主路径
2. 确认 `hid_alloc_report_buf` 的分配尺寸与 `w22` 的关系(决定越界起点/幅度)
3. **写 uhid 探针**: 按 (a)(b)(c) 构描述符 → `UHID_CREATE2` → 读路径处理 `UHID_GET_REPORT`
   并回**不匹配的大报告 ID**; **先只验"设备绑定成功", 再逼近越界**
4. 与上游 diff `mt_feature_mapping` 的 `0x000D0059` 分支
5. 次目标: **CVE-2026-64364** → `mt_touch_report`@0x101bcedc / `mt_process_slot`@0x101bd1cc;
   **CVE-2026-31624** → hid-core `s32ton()` output report 路径

hid-multitouch 完整函数集见 `analysis/kgsl_audit_03.md` §15.4

### ⛔ 换 vendor 子系统 = 已被 SELinux 关死(§13, 证据已补全, 该方向划掉)

全 `/dev` 枚举(补全此前"枚举严重不全"的缺口), 只测带 other 位的节点:

| 节点 | mode | O_RDWR | O_RDONLY |
|---|---|---|---|
| /dev/dri/card0 · renderD128 | `crw-rw-rw-` | **EACCES** | **EACCES** |
| /dev/adsprpc-smd (fastrpc) | `crw-rw-r--` | EACCES | EACCES |
| /dev/goodix_fp · chipone_fp | `crw-r--r--` | EACCES | EACCES |
| /dev/ion | `crw-rw-r--` | EACCES | **OK** |
| /dev/membuf · iio:device0 · kmsg | — | EACCES | EACCES |
| `/dev/ashmem` | `crw-rw-rw-` | **EACCES** | **EACCES** ⚠ |
| /dev/kgsl-3d0 · uhid · uinput · ptmx | — | **OK** | **OK** |

**⇒ mode 位无关紧要, SELinux(shell 域)才是守门人** —— msm DRM ioctl 面、fastrpc、指纹、IIO 全不可达。
⚠ **修正既有记忆**: `/dev/ashmem` 在 shell 域下 **EACCES**(尽管 mode 0666),
项目记忆里"shell 可开 ashmem"需复核。

### 原待办清单(保留)

1. **drawobj 列表族剩余 4 个**逐条核对"循环次数 vs 数组容量 vs 用户指针步距":
   `kgsl_drawobj_cmd_add_cmdlist`@0x10a8388c / `_add_memlist`@0x10a83a30 / `kgsl_drawobj_sync_add_syncpoints`@0x10a8372c / `kgsl_drawobj_add_timeline`
2. **UAF/生命周期面(最有机会)**: kgsl_mem_entry 引用计数(free vs GPU 使用)、context 销毁与提交竞争、
   timeline/syncobj 的 fence 回调(`drawobj_sync_*_callback`)、`kgsl_syncsource_process_release_syncsources`
3. ~~未命名 ioctl 排查~~ → **已完成(§CP), 原猜测作废**: `0x24` = `kgsl_ioctl_sharedmem_flush_cache`,
   `0x5c` = `kgsl_ioctl_timeline_fence_get` —— **不存在"外部 fd 映射进 GPU"这条路**。
   权威归属见 `analysis/kgsl_ioctl_handlers_v2.txt`(全表已解出, 7 项自校验通过)
4. **从未静态审计的路径(§CP 新暴露, 已更新)**:
   - ~~`kgsl_ioctl_submit_commands`~~ → **已审完, 自洽(§CP 第 5 节)**
   - `add_profiling_buffer`@0x10a8213c —— **下一批第一优先**;有**两条**用户可达路径:
     `add_memlist` 的 flags bit4 / `add_ibdesc` 的 `flags&3==3` + cmdobj bit0(两处参数含义不同, 先定签名)
   - `kgsl_ioctl_map_user_mem`@0x10a7a6cc (0x15/0x20) —— 后半段(FD 路径 0x7a870 起、gpuaddr 回写、SVM 分支)未读完
   - `timeline_*` 五个 handler@0x10a97xxx-0x10a98xxx
   - 另: `kgsl_memdesc_get_align()` 在 **size/映射长度**侧的消费点未查(CVE-2026-21385 残留面)
5. 备选: dlopen(libgsl) 做 API 级结构化 fuzz(会重启设备, 需逐项隔离 + 存活 canary + tracefs)
6. 若需完整内核(当前镜像有 440KB 零区, 但**不影响 kgsl**): 下载官方 OTA 包 PD2220_A_14.2.9.1.W10.V000L1 取 boot.img

## 六、坑清单(务必避免重复踩)
1. **Bionic `_IOWR(t,nr,X)` 编码的是 `sizeof(X)`** — 传**整数变量**会被编成 sizeof(int)=4;
   手写 ioctl 尺寸扫描必须自己拼 `((3<<30)|(t<<8)|nr|(size<<16))`
2. `-static` 会链到 **libdl.a 桩**, dlopen 运行时报 "use libdl.so instead" → 必须动态链接
3. **原始 `kallsyms.txt` 是字符串偏移表**(头部写明), **不是符号地址** → 符号要靠 vmlinux-to-elf
   (**例外**: `analysis/embedded-kallsyms.txt`(9.7MB, 9-8 生成) 已是**解码后的 `addr type name` 表**,
   含真实静态地址, 早于 vmlinux.elf, 可用来交叉校验符号)
4. 镜像 440KB 零区(0x11514000-0x11582000)是**数据区**, 不要误判为"kgsl 代码缺失"
5. 地址算术: bash 的 `$((0xffffffc010a840b4 + 0x180))` **会溢出** → 用显式十六进制地址
6. Windows 保留名: 输出文件别叫 `aux.asm`(会 Permission denied)
7. kgsl IB 上限 4KB → 每批 ≤160 个 6-dword 包, 否则段错误
8. GPU 侧验证值**绝不能与指令立即数/静态填充值相同**(曾导致 §BT 假阳性整轮作废)
9. 内核 oops 会**重启设备** → 动态 fuzz 必须逐 ioctl 隔离 + canary + tracefs
10. `MEMORY.md` 有 3000-4000 字符上限, 追加过多会被截断 → 定期压缩

## 七、关键文件索引
```
── 交接 / 总账 ─────────────────────────────────────────────────────────────
analysis/HANDOFF.md                ← 本文件(权威交接入口)
analysis/REVERSE-PROJECT-kgsl.md   ← 总账 §A–§CA(第三十五节, 1729 行); **§CM/§CN 不在此文件**
analysis/CURRENT-STATUS.md         ← 9-15/16 快照; **唯一记录真机 KASLR slide + 真机符号地址**;
                                     其"IB 边界不校验 / 命令提交面已打通"等结论已被 §AI/§CA 证否, 引用须标版本
analysis/kernel-lpe-conclusions.md ← 早期详细证据链 §A–§AV(1841 行); 部分结论已被 §CA 推翻
── 内核符号化工作台 ───────────────────────────────────────────────────────
vmlinux.elf                        ← 内核 ELF(55MB, 179170 符号) ← 当前权威符号源
kernel_image.img                   ← 原始镜像 44MB(**gbfef221370b4, ≠ 真机 g2a88cd145def**)
vmlinux-to-elf-master/             ← 符号恢复工具(**目录名是连字符 `vmlinux-to-elf`, 不是下划线**)
analysis/vmlinux_workflow.md       ← 符号化审计工作流(命令级)
analysis/vmlinux_symbols.txt       ← 179170 个符号(llvm-nm 导出)
analysis/embedded-kallsyms.txt     ← 镜像内嵌 kallsyms 解码表(9.7MB, `addr type name`);
                                     早于 vmlinux.elf 的独立符号源, **可做交叉校验**
kgsl_dis.asm                       ← ⚠ **在仓库根目录**(不在 analysis/); kgsl 段完整反汇编 67226 行
analysis/kgsl_triage.txt           ← 敏感调用点自动分级清单
analysis/kgsl_patterns.txt         ← 危险模式扫描(每个 copy/alloc 调用点前 6 条指令, 47KB)
analysis/kgsl_audit_01.md          ← handler 审计 §CM(第 1 批, 4 路径)
analysis/kgsl_audit_02.md          ← handler 审计 §CN(第 2 批, 2 路径 + triage 方法)
analysis/kgsl_audit_03.md          ← handler 审计 §CP(第 3 批: drawobj 4 个 + CVE 对齐路径 + map_user_mem 初步)
kgsl_ioctl_handlers_v2.txt         ← ★权威 ioctl nr→handler 全表(套 .rela.dyn + 解 .cfi_jt, 7 项自校验)
resolve_handlers3.py               ← 分发表还原脚本(依赖 vmlinux.elf; 另见 find_ioctl_table.py / read_ioctl_table.py)
analysis/kernel.elf / kernel2.elf  ← ⚠ **0 字节空文件**(9-15 的失败残留), 无内容, 可删
── ioctl 权威表 / GPU 原语 ────────────────────────────────────────────────
analysis/gsl_ioctl_names.txt       ← 官方 ioctl 名表(来自 libgsl.so)
analysis/kgsl_ioctl_table.txt      ← 内核 ioctl 全表(含状态)
analysis/kgsl_ioctl_handlers.txt   ← ⛔ **已作废**(基址错+未套重定位), 仅历史留档
analysis/kgsl_ioctl_handlers_v2.txt ← ★**权威** nr→handler 全表
analysis/kgsl_ioctl_probe.txt      ← handler 探测结果
analysis/gsl_ioctl_wrappers.txt    ← 65 个 ioctl_kgsl_* 包装函数
analysis/kgsl_gpuobj.txt           ← GPUOBJ 结构体实测结果
analysis/gsl_dlopen.txt            ← dlopen 用法与 import 实测
vendor_libs/                       ← libgsl / libGLESv2_adreno / vulkan.adreno / libadreno_utils
cheese/                            ← 真机探针(kgsl_*.c, adrenaline.h)
cheese/kgsl_a2.c / kgsl_a2b.c      ← ★ A2 对齐实测探针(Route A 闭合证据)
analysis/a2-align-test.log         ← ★ A2 原始输出 + 解读(Route A 闭合证据)
── GPU 微码路线(已判死, 留档备查) ─────────────────────────────────────────
sqe/                               ← Adreno QRisc 微码反汇编工具链
analysis/ttbr*-sweep*.log          ← GPU VA 页级测绘原始日志(判死证据)
analysis/recscan-1024.log / reg-sweep-a642.txt ← 记录扫描 / 寄存器扫描原始日志
```

## 八、一句话现状
> **KGSL 已彻底穷尽**; **vendor 其他子系统被 SELinux 关死**; GPU 微码判死。
>
> **★★★ 唯一可推进面 = `/dev/uhid` → `hid-multitouch`, 且已定位到指令级的堆越界写**(§14–§16):
> - `uhid` 可 open, **能让用户态凭空造 HID 设备, feature 响应字节完全由用户态提供**
> - 内核里 `hid-multitouch` 已编入(`mt_devices`@0x120fea80)
> - ✗ **CVE-2025-39806 不存在**(`mt_report_fixup` 未编入, 双重验证)
> - **★★★ CVE-2026-43047 确认存在且机制已定位**: `mt_get_feature`@0x101bcb1c 在
>   `hid_hw_raw_request` → `hid_report_raw_event` 之间**无 report ID 校验**;
>   `hid_report_raw_event`@0x10ea0fe4 的 0x10ea10d8 处
>   **`memset(data + csize, 0, 报告期望长度 − 已供长度)`**
>   ⇒ 请求小特征报告 + 返回大输入报告的 ID ⇒ **堆越界零填充写, 长度可控(≤4096/8192)**
>   —— CVE 描述 "OOB writes" 完全吻合, **本项目首个"指令级确认机制 + 可达 + 未修"的内存破坏漏洞**
>
> **当前任务**: ① 确认旁路 `[hdev+0xc30]` ② 确认 `hid_alloc_report_buf` 尺寸
> ③ **选定能走到 `mt_get_feature` 的设备类型** ④ 构造"小特征报告+大输入报告"描述符 ⑤ 真机先验绑定
> (**不要先真机乱试, 先把触发路径搞清楚**)
>
> **⛔ 不要再投入**: KGSL 全部 / vendor 其他子系统(DRM·fastrpc·指纹·IIO) / GPU 微码 /
> CVE-2025-39806 / CVE-2026-80780 / CVE-2026-50265·50292
