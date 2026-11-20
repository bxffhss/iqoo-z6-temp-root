# KGSL Micronode 侦察(CVE-2025-21479/21480) — Day 1 (2026-09-25)

> 新主线: CVE-2025-21479/21480 — Adreno GPU micronode Incorrect Authorization(CWE-863)
> "unauthorized command execution in GPU micronode while executing specific sequence of commands"
> 设备: iQOO Z6 / SM7325 / 5.4.281-qgki / SPL 2025-04-01(未打 2025-06 补丁) / KEV 在野利用
> 触发面: GPU 命令流(经 kgsl ioctl) — shell 可达(/dev/kgsl-3d0 world-rw)

## Day 1 发现: 逆向素材本地完备
- `analysis/vmlinux_symbols.txt`: **1680 个 kgsl 符号 + 304 个 GMU/HFI 符号**(含 CFI 后缀)
- GMU/HFI 全链在符号表: hfi_send/receive · gmu_oob_set/clear · gmu_event/ao_sync
- kgsl 核心: kgsl_context_create/destroy/detach · kgsl_issueibcmds
- "GPU micronode" 的最可能对应: **GMU(Graphics Management Unit)微控制器节点**
  —— 高通新架构用 RISC 微控制器(GMU)管理 GPU 电源/队列/调度;
  "unauthorized command execution in GPU micronode" = 用户态构造的命令序列绕过内核/GMU
  的授权检查, 让 GMU 或 GPU 执行本应受限的命令。

## 关键猜想(待验证)
1. CVE-2025-21479/21480 = GMU HFI 命令或 GPU PM4 命令流的**两个不同授权检查点被绕过**
   (两 CVE 是"同一攻击面的两个检查点", 系统性设计问题);
2. 触发 = 特定 HFI 消息序列 或 特定 GPU 命令缓冲序列(经 kgsl_issueibcmds 提交);
3. 腐坏 = "in GPU micronode"(GMU/GPU 上下文的内存) —— 但 CVSS S:C ⇒ 跨信任边界影响 HLOS?

## Day 1 未决
- "micronode" 的确切内核实现对象待定位(kgsl 上下文? GMU queue? preempt level?)
- 授权检查点在哪个函数(kgsl_ioctl_* 或 gmu_* 的哪条路径)
- 触发命令序列的具体形态

## 下一步
1. 从 vmlinux_symbols.txt 枚举 kgsl_ioctl_* 全表 + gmu_* 函数群, 建立"攻击面地图";
2. 对 ioctl 分发表(ELF reloc 解析, 用 elf_reloc_lookup.py)定位 KGSL_IOC_SUBMIT_COMMANDS 等处理器;
3. 反汇编授权检查相关函数(找 copy_from_user 后的 cmd 序列校验);
4. 在设备上验证 GMU 是否活跃(/sys/class/kgsl/kgsl-3d0/gmu_* 节点、dmesg 触碰痕迹)。

## Day 1 补充: 设备侧确认
- GPU = **Adreno642Lv1**(SM7325 的 GPU, 与 Qualcomm 受影响列表一致 ✓)
- 内核符号: a6xx_gmu_hfi_start · a6xx_hfi_queue_read/write · a6xx_gmu_snapshot(itcm/dtcm) ·
  a6xx_rgmu_snapshot · kgsl_ioctl 全表(kgsl_ioctl 主分发器 + cmdstream_*/device_* 处理器)
- sysfs 无 gmu 节点(该版本 kgsl sysfs 布局不同) ⇒ GMU 活跃性需经其他途径确认
  (符号 a6xx_gmu_hfi_start 存在 ⇒ GMU 驱动编译进内核 ✓)
- 核心逆向入口: **kgsl_ioctl 主分发器**(0xffffffc010a865ec) —— 从分发表定位全部处理器,
  重点: KGSL_IOC_SUBMIT_COMMANDS(issueibcmds 路径)与 GMU 相关的新式提交路径

## Day 2: 逆向基础设施打通 + 攻击面清单完成
- **kernel.elf 工具链打通**: boot_extract/kernel(44.6MB 真内核) + python 包装成 ELF(VMA 0xffffffc010000000,
  LOAD offset=0 线性映射) + llvm-objdump --start-address ⇒ **任意内核函数反汇编成功**(已验证 stp 序言);
  偏移公式: 文件偏移 = (vaddr & 0xffffffff) - 0x10080000 ✓(boot_extract/vmlinux 是 vdso 假壳, 勿用);
- **攻击面清单: 55 个 kgsl_ioctl_* 处理器**(符号全列), 重点: kgsl_ioctl_gpu_command / submit_commands /
  **gpu_aux_command**(辅助命令=micronode/GMU 特权命令提交的嫌疑入口) / rb_issueibcmds / gpuobj_*;
- kgsl_ioctl 主分发器反汇编 ✓(表项 48B, 分发表 kgsl_ioctl_funcs @0xffffffc01218eb70);
- **数据源问题定位**: 表项指针被 boot 重定位抹零; vmlinux.elf(55MB) 有 symtab(174835 符号)可解析,
  但其 LOAD 段映射有偏移(直接按线性映射读到的是字符串区) ⇒ **下一会话第一件事: 修正 vmlinux.elf
  的 segment 映射(p_offset/p_vaddr 对照)或改用 kernel.elf+elf_reloc_lookup.py 思路解析 .rela.dyn**;
- 目标不变: 从分发表拿到全部 (cmd 号 ↔ 处理器), 重点 gpu_aux_command 的反汇编与授权检查定位。

## Day 3: 分发表完整破解(攻击面地图完成)
- **方法定型**: vmlinux.elf 的 .rela.dyn(12.7 万条 R_AARCH64_RELATIVE, addend 为负数表示!真值=(1<<64)+add)
  + LOAD#1 换算(off 0x240 → vaddr 0xffffffc010080000) ⇒ 表项 func 指针(+0x28)全部还原为符号;
- **kgsl_ioctl_funcs @0xffffffc01218eb70, 48B/项, 49 表项**, 全部 (cmd↔处理器) 对齐:
  - 0xc0080913 map_user_mem · 0x40180932 gpumem_alloc_id · 0xc0200948 **gpu_command**
  - **0xc0380955 gpu_aux_command** ★(micronode/GMU 特权命令提交头号嫌疑)
  - 0xc0180943 gpuobj_alloc · 0x40200946 gpuobj_import · 0xc0300947 gpuobj_sync
  - 0xc0100940/41 syncsource fence · 0xc0300957 timeline_wait · rb_issueibcmds(cmd=0)
- cmd 布局: 0xcxxxyyy — type=0x09(kgsl), size=高 14 位(=用户结构体大小, 可反推结构体);
- **下一会话核心**: 反汇编 kgsl_ioctl_gpu_aux_command(先从符号表取地址) — 找 cmd 序列校验
  与 GPU_AUX 命令的语义(micronode 授权点); 同样看 gpu_command 的 ib 提交校验。

## Day 4: gpu_aux_command 反汇编第一批(AA64, 0x10a78390 起)
- kgsl_ioctl_gpu_aux_command @0xffffffc010a78390 / kgsl_ioctl_gpu_command @0xffffffc010a78054;
- **确认在构造 GPU 命令流**(PM4): 写入 0x70268000 / 0x70928000 / 0xc0024600 / 0x70468000 等
  32 位命令字 —— 0x7xxxxxxx = PM4 **type-7 命令**(微指令/特殊操作), 正是 micronode 命令的载体形态;
- **ID 范围检查**: cmp w10, #0x1f4(500) / #0x1fe / [500..500+0x63=563] —— 队列/上下文 ID 校验,
  这很可能就是授权检查点之一(哪些 ID 允许走 aux 命令);
- 设备结构大偏移字段 [x21+0x12c8](ID 计数器) / [x21+0x40](上下文) / [x21+0x2818](特性位);
- 函数较大(>1KB, 命令流构造+遍历), 完整逆向需多轮;
- **下一步**: ①从 cmd=0xc0380955 反推用户结构体(size=0x38=56B: 大概 {numcmds, cmd[]...});
  ②定位 0x1f4 范围检查的语义(哪个 ID); ③找 type7 命令的 opcode 表(0x7026/0x7092/0x7046...);
  ④对照: CVE 说 unauthorized ⇒ 找"本应被拒却放行"的分支(检查点可能依赖上下文标志)。

## Day 5: 调用图提取(0x10a78054-0x10a79100, 1073 行反汇编)
- bl 调用 11 个, 目标(部分为静态匿名函数, 邻近符号参考):
  - 0x10a77398 ≈ kgsl_query_property_list(device_getproperty 内联区)
  - 0x10a7757c ≈ kgsl_ioctl_device_setproperty 前缘 ★(aux command 里调 setproperty 路径!)
  - 0x10a2e534 ≈ drm 区匿名函数(可能是 kgsl_sync/drawobj 辅助)
  - 0x104233c0 ×5(公共打印/审计类), 0x104734e4 ×1, 0x1000cbf8 ×1, 0x10a6c780 ×1(alloc/unmap 类)
- gpu_command(0x10a78054) 与 gpu_aux_command(0x10a78390) 相邻且总长 >4KB;
- Day 4 的 PM4 type-7 命令字构造确认在 aux_command 主体内;
- **下一步(优先)**: 反汇编 0x10a7757c 起的函数(setproperty 路径)与 aux_command 的
  完整前段(0x10a78390 之前可能还有 hot 部分——用 0x10a78054-0x10a78390 区间检查 gpu_command 尾部);
  关注: copy_from_user 之后的命令类型分发与 "本应拒绝" 的上下文标志检查([x21+0x2818] bit1)。

## Day 6: ★★★ gpu_aux_command 核心执行路径解码(重大进展)
反汇编修正后(基址 0xffffffc010080000)真实代码还原:
- aux_command 主体 = 0x10a78100-0x10a782f8(遍历用户命令列表, 每项按类型分发);
- **bl 目标符号化(全部命中)**:
  kgsl_context_get · kgsl_context_destroy · kgsl_drawobj_cmd_create ·
  **kgsl_drawobj_cmd_add_cmdlist · kgsl_drawobj_cmd_add_memlist · kgsl_gmc_decompress_all**★ ·
  kgsl_drawobj_sync_create · kgsl_drawobj_sync_add_synclist · kgsl_drawobj_sync_add_sync
- ★★ **gmc_decompress_all = 命令解压路径**("specific sequence of commands" 的载体候选!):
  aux command 的一个 type = 把压缩的 GPU 命令流解压执行 —— "unauthorized command execution
  in GPU micronode" = 解压路径的授权检查缺失/绕过;
- ★★ **blr x20 @0x10a782bc = drawobj vtable 间接调用**:
  x20 = [drawobj+0x1e0]→[+0x60], 先与全局 vtable(0x11556ff60)比较, 不等则走 WARN(0x10a783ec)。
  ⇒ 若 drawobj 对象内容可被混淆/腐坏 ⇒ blr = 任意调用点(利用目标);
- 分发结构: CMDLINK 型(cmd create+add_cmdlist+add_memlist+decompress) / SYNC 型(sync create+add_synclist);
- 错误路径: [x21+0x2818] bit1 特性检查 + bl WARN(mov x0=0xfa4e526af8cef740 = WARN 字符串指针)。

### 下一会话(收敛步骤)
1. 反汇编 gmc_decompress_all(0x10b03e08 附近函数, 符号名是噪声需重标) ⇒ 解压格式+校验逻辑;
2. 定位 aux item 结构体的 type 字段与用户可控部分(结构体 0x38=56B);
3. 构造"解压命令"类型的 aux item ⇒ 触发 decompress 路径 ⇒ 找授权缺失点。

## Day 10-11: ★★★ 授权边界定位(重大进展)
按 ID 查找函数(0x10a77278)完整解码:
```c
kgsl_memobj_find_by_id(device, id) {
    mutex_lock(&device+0x20);
    entry = idr_find(&device+0x28, id);      // ★ 设备级 idr(非 pagetable 级!)
    if (!entry) return NULL;
    if ([entry+0xf0] != 0) return NULL;      // ★★ 唯一过滤字段!
    atomic CAS 获取引用([entry+0], 溢出保护);
    mutex_unlock; return entry;
}
```
- **授权边界 = 设备级 idr + 仅 [entry+0xf0] 一个字段检查**;
- **CVE 假设成形**: idr id 全局递增可预测 ⇒ 若 [entry+0xf0] 检查可绕过(竞态/类型混淆/该字段
  可被 setproperty 类操作修改) ⇒ memlist 引用**别的进程的 GPU 内存对象** ⇒ GMC 压缩引擎对其
  执行操作 ⇒ **跨进程内存损坏 = unauthorized command execution in GPU micronode** ✓✓ 完全吻合!
- memlist 逐项处理(0x10a821b4)其余校验 = 纯数值范围检查(base/len/溢出), 无进程归属校验;
- **下一会话**: ①反汇编 0x10a770a8(按 user_addr 查找)对照 ②确定 [entry+0xf0] 语义
  (找 gpumem_get_info 等读取它的代码) ③设计利用: setproperty/竞态/ID 枚举 ⇒ 绕过 0xf0 检查。

## Day 12: 按地址查找函数解码 + 0xf0 悬念
- 0x10a770a8 = **全 idr 线性遍历**(idr_get_next 从上次位置继续): 遍历 device+0x28 idr 的全部
  mem 对象, 匹配 gpuaddr ∈ [base, base+size] ⇒ 返回; **此段未见 [entry+0xf0] 过滤**(命中段待查);
- 关键含义: 若该 idr 是**设备级**(全部进程的 GPU 内存对象!), 按 GPU 地址即可命中**任何进程的对象**
  ⇒ 0xf0 过滤成为唯一屏障 ⇒ 与 CVE 假设完美衔接;
- alloc_id 主体(0x10a7beb4)未写 [+0xf0] ⇒ 该字段初始化在别处(对象 create 或引用路径);
- **Day 13 计划**: ①0x10a771a8 之后的命中处理段(查 0xf0 过滤) ②全符号引用扫描定位 0xf0 的
  全部读写点(确定语义) ③若 0xf0 = "别的 pagetable 的 memdesc 指针" ⇒ 绕过设计(竞态/类型混淆)。

## Day 13: 命中段解码 + TOCTOU 竞态假设成形
- 按地址查找命中段(0x10a77158-0x10a77180): base/size 范围检查后 **w9=[entry+0xf0]; cbz ⇒ 接受;
  非零 ⇒ 拒绝** —— 与按 ID 查找相同的统一过滤(32 位字段, 0=可引用);
- 0xf0 语义推断 = **"对象已标记 deferred-free"** 的标志(置位后拒绝一切新引用);
- 引用获取(CAS)在 device mutex 临界区内 ⇒ 检查+获取被锁保护 ⇒ **竞态只可能来自 0xf0 的置位方
  不持同一把锁**(deferred-free 标记路径) ⇒ TOCTOU 假设成形;
- CVE 完整链条: victim GPU 对象被 free ⇒ 标记 0xf0 ⇒ 竞态窗口内 aux memlist 仍引用成功 ⇒
  GMC 压缩引擎操作已释放对象 ⇒ 跨进程内存损坏;
- **Day 14**: 扫描 0xf0 的全部写入点(kernel.elf 搜 "str w?, [x?, #0xf0]" 模式, 限定 kgsl 函数区)
  ⇒ 确认置位路径的锁上下文 ⇒ 竞态窗口大小判定 ⇒ PoC 设计。

## Day 14: ★★★ 0xf0 语义与写入点全部定位(决定性)
25 个 0xf0 访问按函数归属, **写入点 5 个**:
| 写入点 | 含义 |
|---|---|
| gpumem_free_entry | entry 释放 |
| kgsl_ioctl_gpuobj_free | gpuobj_free ioctl |
| **gpuobj_free_on_timestamp** | **按 timestamp 延迟释放**★ |
| **kgsl_ioctl_cmdstream_freememontimestamp_ctxtid** | **用户 ioctl: 请求 timestamp 到达后释放**★ |
| process_release_memory | 进程退出 |

⇒ **[entry+0xf0] = "pending free on timestamp" 标志**:
- 用户态可经 IOCTL_CMDSTREAM_FREEMEMONTIMESTAMP(0xc0300915, 分发表已确认)请求延迟释放;
- 标记后(0xf0≠0) find 拒绝新引用 —— **但存在两种 UAF 时序**:
  A. **引用-后-标记竞态**: aux memlist 引用完成(refcount+1)之后, 用户再发 freememontimestamp
     ⇒ timestamp 到达 ⇒ 延迟释放路径**若不校验 memlist 持有的引用** ⇒ memlist 挂着已释放对象
     ⇒ GMC 压缩引擎写已释放内存 = UAF;
  B. **标记-后-引用竞态**: 0xf0 检查与 CAS 之间(已被 device mutex 保护, 需验证置位方是否同锁)。
- **下一会话(收官)**: 反汇编 gpuobj_free_on_timestamp 的释放时刻处理(timestamp 到达后的
  实际 free 路径) ⇒ 确认是否检查 refcount/memlist ⇒ PoC 设计(freememontimestamp + aux memlist 竞态)。

## Day 15: 0xf0 的 EBUSY 防御路径发现(收官)
- 反汇编 0x10a79600-0x10a79718(时间戳相关引用路径): mutex_lock([x20+0xe8]+0x20) →
  **w8=[x20+0xf0]; 若非 0 ⇒ mutex_unlock + 返回 -16(EBUSY)** ⇒ 0xf0 置位(pending-free)后,
  该 entry 的相关操作被 EBUSY 拒绝 —— **防御存在**;
- 两种已确认的引用路径(按 ID/按地址 find)也都检查 0xf0 ⇒ **CVE 的 unauthorized = 找到
  "不查 0xf0 的引用路径" 或绕过/竞态**;
- 候选(下一会话收敛): ①gmc 压缩引擎自身的对象引用路径(可能绕过 find) ②gpuobj_free 立即释放
  与 memlist 的竞态 ③micronode = GPU 命令流特权模式(CP protected mode)⇒ 特权 opcode 检查缺失;
- **Day 16-17 计划**: ①全量反汇编 gmc/gpuobj 释放与引用交叉点, 列出"无 0xf0 检查的引用路径"清单
  ②逐条评估可达性 ③构造 PoC(结构体 0x38 + freememontimestamp + aux memlist 竞态)。

## 会话总账(Day 1-15)
从 CVE 名字到: 攻击面 55 ioctl + 分发表破解 + aux command 核心路径 + GMC 压缩语义 + 授权边界
(设备级 idr + 0xf0 单字段) + EBUSY 防御路径 —— 逆向链条完整, 剩余 = 无 0xf0 检查路径的枚举与 PoC。

## Day 16: ★★★ 两条 UAF 时序全部判死 —— CVE 机理最终结论
gpumem_free_entry 置位路径(0x10a78f38 起函数)解码:
```c
free_entry_marker(entry) {
    mutex_lock([entry+0xe8]+0x20);       // ★ 与 find 用同一把锁!
    if ([entry+0xf0] != 0) { unlock; return -16; }   // 已标记 ⇒ EBUSY
    [entry+0xf0] = 1;                    // 置位(锁内)
    mutex_unlock;
}
```
- **时序 B(标记-后-引用竞态)判死**: 检查/置位/CAS 全程同锁, 无竞态窗口;
- **时序 A(引用-后-标记)判死**: 0x10a78ec0 = 标准 refcount_dec_and_test ⇒ 减到 0 才 destroy
  ⇒ memlist 持有的引用被 refcount 尊重, 不会提前释放;
- **最终结论**: memlist/GMC/refcount 路径全程安全 ⇒ CVE-2025-21479/21480 的腐坏点**不在内核
  对象引用层**, 而在 **GPU 命令流语义本身**(PM4 type-7 序列让 GPU 微节点执行特权操作 =
  GPU 固件微码层, 闭源且逆向成本极高);
- **判定: 该 CVE 在本会话资源下 = 高风险低可行性 ⇒ 暂缓**, 内核侧逆向成果完整存档。

## 会话总账(Day 1-16)
逆向链条: 攻击面 55 ioctl → 分发表破解 → aux command 核心路径(PM4/blr vtable/解压) →
memlist 授权(设备级 idr + 0xf0) → EBUSY 防御 → refcount 尊重 ⇒ **内核侧全部安全闭环**;
资产: KGSL-MICRONODE-RECON-20260925.md(Day 1-16) + kernel.elf 工具链 + elf_reloc_lookup.py。

## Day 17: CVE-2025-47333(qcedev UAF)完整评估 —— 机理清晰但 shell 被权限挡
- **漏洞 100% 清晰**(补丁 diff 直接给出): qcedev_fe/qcedev_smmu.c 的 qcedev_check_and_map_buffer:
  MAP_BUF_REQ 无条件 list_add_tail(binfo) ⇒ 同 buffer 重复 MAP ⇒ 同一 binfo 挂链两次 ⇒
  UNMAP 时 list_del+kfree 只清一个 ⇒ **另一节点悬空 = UAF**(修复: 仅 !found 时 add/del);
- **触发序列**: QCEDEV_IOCTL_MAP_BUF_REQ(同 buffer ×2) + QCEDEV_IOCTL_UNMAP_BUF_REQ
  (或 commit 所述双线程 MAP/UNMAP 竞态);
- **内核确认**: qcedev_check_and_map_buffer @0xffffffc010e8a67c 在设备内核 ✓(62 个 qcedev 符号);
- **★ 门槛实测: /dev/qce = crw-rw---- system:drmrpc ⇒ shell Permission denied ✗**(uid 2000 组不含);
- **下一会话判定步骤**:
  1. 装 untrusted_app 域的测试 app 实测 /dev/qce 可访问性(qcedev 历史上多次 app 可触发 LPE);
  2. 若 app 可访问 ⇒ PoC: MAP×2+UNMAP 竞态 + sigq/binfo 尺寸堆喷射 ⇒ 外显 ⇒ 堆利用;
  3. 若 SELinux 全面禁止 ⇒ 此 CVE 需要配合别的沙箱逃逸 ⇒ 降级。

## Day 19: 分发内核解码 + ENODEV 定位推进
- **真正分发内核 @0x10a86470**(表 94 项 × 16B: {cmd@0, func@8}), 参数: x3=kgsl_ioctl_funcs,
  w4=94; nr 越界 ⇒ -515; **_IOC_SIZE(cmd) >= 0x81 ⇒ WARN + -22**(我们的 size=0x18 通过 ✓);
- ENODEV 不在分发器 ⇒ 在 **alloc_id 主体**(0x10a7bf2c 起, mrs SP_EL0 取 current; 输入结构:
  [x2+4]=flags, [x2+8]=size; 调 bl 0x10a7b904 分配; 返回填 {+0:id,+4:flags,+8:size,
  +0x10:mmapsize,+0x18:gpuaddr} —— upstream kgsl_gpumem_alloc_id ✓);
- **Day 20**: 反汇编 0x10a7b904(kgsl_mem_alloc 类) 找 ENODEV(mov w0,#0x13) 返回点
  ⇒ 判定是 GPU 状态/初始化问题还是别的 ⇒ PoC 激活。

## Day 20-21: 分配链跟随 + GPU slumber 假设
- gpumem_alloc_entry 链: kgsl_alloc_contiguous(kgsl_memdesc_init/alloc_pages/dma_alloc) + 
  kgsl_mem_entry_attach_process —— 均无 #0x13 ⇒ **ENODEV 在 kgsl_mmu_get_gpuaddr → 
  kgsl_iommu_get_gpuaddr(漏洞函数) 链的深处**(mmu type/状态检查);
- ★ 新假设: **GPU slumber(休眠)状态下 kgsl 拒绝 alloc**(mmu 未就绪) ⇒ 
  **实验: 唤醒 GPU(屏幕交互/GPU 任务)后立即跑 PoC**;
- Day 22(下一会话): ①唤醒后立即重试 PoC ②反汇编 kgsl_iommu_get_gpuaddr(漏洞函数本体,
  从符号表取地址)找 ENODEV 返回点 ③确认 ENODEV 条件 ⇒ PoC 激活 ⇒ gpuaddr 重叠检测。

## Day 22: ENODEV 定位到 kgsl_open —— GPU 驱动初始化未完成
- **ENODEV 的返回点在 kgsl_open**(0x10a7f4e0 附近, 错误清理路径: [x19+0xd8]=NULL+kfree) ⇒
  **open "成功"返回 fd 但驱动内部初始化失败/未完成 ⇒ 所有 ioctl 返回 ENODEV**;
- kgsl_open 的初始化链含 GPU 上电/IOMMU/GMU 启动; ENODEV 条件 = 某个 init 步骤失败
  (可能 GPU 处于异常状态, 或该 OEM 内核的 kgsl_open 有额外检查);
- **Day 23(下一会话)**: ①反汇编 kgsl_open 完整体(0x10a7f2xx-0x10a7f4e0)找 ENODEV 的精确条件
  ②对照设备实际状态(/sys/class/kgsl 状态/dmesg 无权限 ⇒ 用 fail 路径反推)
  ③条件满足后重跑 PoC ⇒ gpuaddr 重叠检测 ⇒ CVE-2026-21385 触发确认。

## Day 23: kgsl_open 解码 —— open 无错, ENODEV 在 attach_process 深处
- kgsl_open 主体(0x10a7f288 起)解码: open_count 检查/per-open 初始化(0x10a80018)/错误检查
  (cmn x0,#0x1,lsl#12 ⇒ 错误码区间) —— **open 成功 ⇒ 这些检查都通过** ⇒ ENODEV 非 open 返回;
- ⇒ ENODEV 在 **kgsl_mem_entry_attach_process 的完整函数**(0x10a7a370 起, 之前只反汇编了
  前 0x1F0 字节, 函数更长——其内 kgsl_mmu_get_gpuaddr 调用链的深处有 ENODEV);
- **Day 24**: 反汇编 attach_process 完整体(0x10a7a370-0x10a7a8xx)与 kgsl_mmu_get_gpuaddr
  全函数 ⇒ 找 #0x13 ⇒ ENODEV 条件 ⇒ PoC 激活。

## Day 24-25: ENODEV 收敛实验设计
- 60 个 ENODEV 点分布 = **全在 probe/init/devfreq/iommu_start 等初始化路径**, alloc/ioctl
  运行时路径无 #0x13 ⇒ ENODEV 可能不是 kgsl 返回而是更外层(VFS/misc);
- 0x10a86758(WARN+continue)非返回点;
- **Day 26 实验(收敛)**: PoC 加"全 cmd 探测"——从 .rela.dyn 提取 kgsl_ioctl_funcs 全部 94 项
  的 cmd 值, 逐个 ioctl 试运行 ⇒ 返回非 ENOTTY(-25)的项 = fd 通道工作 ⇒ 缩定 ENODEV 为
  alloc_id 特有检查; 同时对照 GPU 唤醒前后。

## Day 26: ★ 全 cmd 探测结果 —— ENODEV 是 gpumem_alloc_id 特有检查
- **通道正常**: syncsource_create ret=0 · timeline_query ret=0 · **drawctxt_create ret=0**(上下文创建成功!);
- **gpumem_alloc_id 独有 ENODEV**(errno=19) ⇒ 检查在 alloc_id 主体(0x10a7bf2c-0x10a7b904 之间);
- gpu_command 返回 errno=524(自定义);
- 其它处理器 EINVAL/EAGAIN = 正常参数检查(全表 23 个 cmd 全部按预期工作 ⇒ 攻击面地图验证 ✓);
- **Day 27**: 反汇编 alloc_id 主体中 bl 0x10a7b904 之前的检查段(0x10a7bf2c-0x10a7b400 之间细读)
  ⇒ 找 ENODEV 返回路径 ⇒ 判定条件 ⇒ PoC 激活 ⇒ CVE-2026-21385 触发确认。

## Day 27: ENODEV 收敛到深层子调用
- gpumem_alloc_entry(0x10a7b904+0x628) 与 attach_process(+0x800) 区间均**无 #-0x13 编码**
  ⇒ ENODEV 来自更深子调用;
- 候选: kgsl_iommu_get_gpuaddr 开头的 bl 0x109f5c3c(第一个调用) 与 0x11544df8(gen_pool_alloc 类)
  ⇒ 这些子函数返回 ENODEV;
- **Day 28(下一会话)二选一**:
  A. 反汇编 0x109f5c3c 与 0x11544df8(确认 ENODEV 来源与条件);
  B. **实证二分**: PoC 改为扫不同 size/flags 组合, 观察 ENODEV 是否随参数变化
     (若与参数无关 ⇒ 固定状态检查; 若相关 ⇒ 定位到具体分支)。
- 建议: 先 B(实证快) 再 A(精确定位)。

## Day 28: 实证二分 + 候选排除
- **实证**: size 0x1000-0x1000000 扫描 ⇒ ENODEV 与参数完全无关 ⇒ **固定状态检查**;
- **排除**: 0x109f5c3c = iommu_domain_get_attr(0/-22) · 0x11544df8 = rb_next(无返回)
  ⇒ 都不是 ENODEV 来源;
- **剩余**: kgsl_iommu_get_gpuaddr 深层(它的 bl 链: gen_pool_alloc 类/0x11544df8 之外的
  子调用) 或 **kgsl_iommu_get_gpuaddr 本体更深处**;
- **Day 29**: 全量反汇编 kgsl_iommu_get_gpuaddr(0x10aa7b4c 起, 函数较长) 全搜 #-0x13 与
  全部 bl 链的子函数; 或对照 upstream 5.4 kgsl_iommu.c 源码逐行核对 ENODEV 条件。

## Day 29: kgsl_iommu_get_gpuaddr 全函数排除(0x10aa7b4c-0x10aa7cf0, 499 行)
- **零 #-0x13** ⇒ ENODEV 不在漏洞函数本体;
- bl 子调用链(16 个): iommu_domain_get_attr/rb_*/spin_lock/refcount 类 —— 上一轮已排除;
- ⇒ **ENODEV 的最终候选 = alloc_id 主体(0x10a7bf2c-0x10a7c110)自身未细读的检查段**
  (之前只读了反汇编摘要, 错误路径的完整指令流未逐行分析);
- **Day 30(下一会话)**: 逐行细读 alloc_id 主体全 0x1E4 字节, 重点:
  ①[process_priv+0x28] idr 之外的第二层检查 ②[cmdobj+0x18] bit4 与 [+0x80] 的前置条件
  ③refcount put 路径前的判断(ENODEV 可能是 "pagetable 未就绪" 类)
  ⇒ 条件判定 ⇒ PoC 激活。

## Day 30: ★ 终局判定 —— CVE-2026-21385 暂缓(设备 GPU 驱动状态异常)
- 证据链: attach 子函数全为简单检查(无 ENODEV) + **kgsl sysfs 关键节点缺失
  (gpu_busy_percentage/state/features 均不存在)** ⇒ **该设备 kgsl 驱动 probe 失败/降级**;
- ⇒ process_private→pagetable 永远未就绪 ⇒ 所有 gpumem alloc 返回 ENODEV ⇒
  **CVE-2026-21385 的对齐溢出在此设备无法构造触发**(前提: GPU 驱动正常工作);
- 寓意: 设备的 GPU 驱动本身处于异常状态(这本身可能是别的攻击面的线索, 但与本 CVE 无关)。

## 会话总账(全部主线科学闭环)
| CVE/线路 | 判定 |
|---|---|
| CVE-2025-38352 | 判死: 窗口 20/300k 复现但分支无害 |
| CVE-2025-37804 | 判死: NVD REJECTED |
| CVE-2025-27038 | 不影响: SM7325 不在列表 |
| CVE-2025-21479/21480 | 暂缓: 内核侧安全, 腐坏在 GPU 固件层 |
| CVE-2025-47333 | 判死: /dev/qce 权限墙 |
| CVE-2026-21385 | **暂缓: 设备 kgsl 驱动状态异常, 无法构造触发** |
- 资产: kernel.elf 工具链 + rela.dyn 解析 + KGSL-MICRONODE-RECON(Day 1-30) + 21385 分析文档;
- **下一会话**: ①重新选题(2026-02 后新公告/其它组件) ②或调研设备 kgsl 异常状态的修复
  (可能解锁 21385) ③或转向 GhostLock 非 overlay 审计。

## Day 31: ★★ 终局 —— ENODEV 来源确认 = kgsl_mmu_map 的 KGSL_MMU_TYPE_NONE
- 0x10a86ffc = **kgsl_mmu_map**(attach 时把 GPU 内存映射进 pagetable); 其开头检查与
  upstream 标准模式吻合: **mmu->type == KGSL_MMU_TYPE_NONE ⇒ return -ENODEV**;
- ⇒ **该设备 KGSL MMU 处于 NONE 状态**(GPU MMU 未启用, 驱动降级) ⇒ 所有 gpumem alloc
  需要 gpuaddr ⇒ 全部 ENODEV; **状态持久**(重启后一致);
- ⇒ **CVE-2026-21385 终局: 对齐溢出触发路径(iommu get_gpuaddr)的前提(MMU=IOMMU)不成立
  ⇒ 此设备上无法构造触发** —— 机理清晰但硬件/驱动状态不允许;
- **Day 32(下一会话)**: 调研 MMU=NONE 的原因(设备树/GMU 缺失/驱动降级) —— 若可修复则
  21385 复活; 否则 21385 归档, 转向其它攻击面。

## Day 33-34: ENODEV 最深层来源确认 = kgsl_iommu_map 的 IOMMU 映射失败
- 反汇编 kgsl_iommu_map(0x10aa778c): 开头 w24=-19(ENODEV 预置); 中段 bl 0x109f5440
  (iommu 映射操作)+比较 ⇒ 失败路径 bl _dev_err(打印错误) + w24=-19;
- ⇒ **ENODEV 条件 = kgsl_iommu_map 的 IOMMU 映射操作失败** ⇒ 根因 = 设备 kgsl IOMMU
  domain 状态异常(与 MMU=NONE/驱动降级一致);
- **终局判定: CVE-2026-21385 在此设备无法构造触发**(IOMMU 映射全面失败 ⇒ gpuaddr 无法
  正常分配 ⇒ 对齐溢出路径的前提全部不成立)。

## 会话总账(全部主线科学闭环, 最终版)
| CVE/线路 | 判定 |
|---|---|
| CVE-2025-38352 | 判死: 窗口 20/300k 复现但分支无害 |
| CVE-2025-37804 | 判死: NVD REJECTED |
| CVE-2025-27038 | 不影响: SM7325 不在列表 |
| CVE-2025-21479/21480 | 暂缓: 内核侧安全, 腐坏在 GPU 固件层 |
| CVE-2025-47333 | 判死: /dev/qce 权限墙 |
| CVE-2026-21385 | **暂缓: 设备 kgsl IOMMU/domain 状态异常, 映射全面失败** |
- 资产: kernel.elf 工具链 + rela.dyn 解析 + KGSL-MICRONODE-RECON(Day 1-34) + 21385 分析文档;
- **下一会话**: ①调研 kgsl IOMMU 异常原因(可能修复后 21385 复活) ②重新选题(2026 新公告)
  ③GhostLock 非 overlay 审计。

## Day 35: SELinux dontaudit 发现 —— "sysfs 缺失"判断修正
- IOMMU groups = 51(IOMMU 子系统正常 ✓); **gpu_model 可读但 ls 列目录为空** ⇒
  **kgsl sysfs 节点存在但 shell 域被 SELinux dontaudit 静默拒绝**(getattr/list 部分 denied);
- ⇒ 之前"sysfs 缺失 = 驱动降级"的判断**修正**: 节点存在与否无法从 shell 判定;
- **ENDEVEN 的来源重新聚焦**: 非驱动降级, 而是 kgsl 内核路径的真实检查
  (alloc_id → attach → mmu_map → iommu_map 链的某个状态检查);
- **Day 36 实验**: GPU 活跃时(启动 GPU 应用后)重跑 PoC; 若仍 ENODEV ⇒
  反汇编 attach 链中 mmu_get_gpuaddr 之后的剩余检查段(0x10a7a560-0x10a7a740 已部分读取);
- **备选**: 直接对照 upstream msm-5.4 kgsl 源码(ENODEV 在该驱动的标准位置有限)。

## Day 36: GPU 活跃时仍 ENDEVEN —— 与 GPU 运行状态无关
- 启动浏览器(GPU 渲染活跃)后重跑 PoC ⇒ **仍全部 ENDEVEN** ⇒ ENDEVEN 与 GPU 活跃/休眠状态无关
  ⇒ **ENDEVEN 是 kgsl 内核代码路径的固定检查**(alloc_id 内部, 与运行时状态无关);
- **Day 37(下一会话)**: 对照 upstream msm-5.4 kgsl.c 源码(grep.app 搜 kgsl_ioctl_gpumem_alloc_id)
  逐行核对 ENDEVEN 条件; 或反汇编 alloc_id 主体细读(0x10a7bf2c-0x10a7c110 全 488 字节)。

## Day 37: upstream 源码对照 —— 关键确认
1. **align 位域用户可控确认**: Motorola commit a1a800b(_gpumem_alloc) 的历史限制补丁:
   \`align = (flags & KGSL_MEMALIGN_MASK) >> KGSL_MEMALIGN_SHIFT; if (align >= 32) {...}\`
   ⇒ PoC 的 align 触发前提正确 ✓;
2. **CVE-2016-3842 同族先例**: kgsl_mem_entry_attach_process 的 idr_alloc 过早暴露 ID ⇒
   另一线程 GPUMEM_FREE_ID 提前释放 ⇒ UAF(修复: 延迟加入 idr/rb tree) —— 与我们 0xf0
   竞态假设同源 ⇒ 我们在正确的攻击面上 ✓;
3. **upstream kgsl_gpumem_alloc_id 结构确认**: {id, flags, size, mmapsize, gpuaddr};
4. **qualcomm-linux/kgsl 官方 GitHub 已开源**(gfx-kernel.lnx.0.0 分支) ⇒ 新主线源码资源;
- **Day 38**: ①对照 upstream _gpumem_alloc 找 ENDEVEN(无 ⇒ ENDEVEN 是 OEM 特有检查);
  ②或直接实验: 用 KGSL_IOC_GPUMEM_ALLOC(0x2f, 老接口) 替代 alloc_id 试触发(绕过 alloc_id 特有检查!)
  ⇒ ★ 老接口 gpumem_alloc(cmd=0xc0180932? 不——0x2f) 可能没有 ENDEVEN 检查 ⇒ 直接触发!

## Day 38: ★★★ PoC v3 成功 —— 老接口 gpumem_alloc 全部成功(无 ENDEVEN)!
- **IOCTL_KGSL_GPUMEM_ALLOC(0xc018092f) align=16..31 全部 ret=0**;
- gpuaddr 0x4000000000 起按对齐有序分配(align 位生效, 步长被 32MB 上限 clamp);
- ⇒ **alloc_id 特有的 ENDEVEN 检查在老接口不存在**(新思路验证 ✓);
- ⇒ **老接口 = 可靠的 GPU 内存分配通道**(内核侧 38352 线路的前置也再次确认);
- 观察: 未观察到 1<<31 的负值错乱 ⇒ 21385 的精确触发条件需进一步分析
  (可能 KGSL_MEMALIGN 位域宽度/编译器 UB 行为/OEM clamp 差异)。
- **Day 39**: ①用老接口的 alloc 做重叠检测(连续 alloc + gpuaddr 范围对比)
  ②21385 精确触发条件分析(KGSL_MEMALIGN_MASK 宽度确认——反汇编 get_align 函数)
  ③老接口通道 ⇒ 38352 的 sigqueue 喷射前置也可复活评估。

## Day 39: ★ 终局判定 —— CVE-2026-21385 无法触发(已有 align clamp 缓解)
- align=32-63 全部成功且 gpuaddr 步长恒定 32MB ⇒ **该 OEM 内核已包含 align 上限缓解**
  (KGSL_MAX_ALIGN/32MB clamp——Motorola a1a800b 同型补丁已在本设备内核) ⇒
  1<<32 的符号扩展 UB 被 clamp 防住 ⇒ **CVE-2026-21385 对齐溢出无法触发**;
- **最终判定: CVE-2026-21385 归档**(机理清晰但设备已有缓解)。

## 会话全线终局(7 条主线全部科学闭环)
| CVE/线路 | 判定 |
|---|---|
| CVE-2025-38352 | 判死: 窗口 20/300k 但分支无害 |
| CVE-2025-37804 | 判死: NVD REJECTED |
| CVE-2025-27038 | 不影响: SM7325 不在列表 |
| CVE-2025-21479/21480 | 暂缓: 腐坏在 GPU 固件层 |
| CVE-2025-47333 | 判死: /dev/qce 权限墙 |
| CVE-2026-21385 | **归档: 设备已有 align clamp 缓解** |
- 资产: kernel.elf 工具链 + rela.dyn 解析 + KGSL-MICRONODE-RECON(Day 1-39) + 21385 分析文档;
- **下一会话**: ①重新选题(2026-02 后新公告, 排除已有缓解的) ②GhostLock 非 overlay 审计
  ③或深挖设备 kgsl 降级状态之谜(ENDEVEN 的根因仍未完全定位——但优先级低)。

## Day 40: CVE-2025-47376 判死 + ★ 战略结论(kgsl 是唯一可达攻击面)
- **CVE-2025-47376**: 补丁 diff = msm-lsm-client.c(LSM 语音唤醒驱动)的 confidence_levels
  竞态保护(加 mutex)——触发需要 LSM PCM 会话(/dev/snd 访问);
- **shell 实测: 无 audio 组**(id: 2000,1004,1007,1011,1015,1028,1078,1079,3001-3011 无 1005)
  ⇒ /dev/snd 不可达 ⇒ **判死(权限墙同模式)**;
- ★★ **战略结论**: Qualcomm 专有驱动的设备节点全部 system/drmrpc/audio 组专属 ⇒
  **/dev/kgsl-3d0(world-rw)是唯一 shell 可达的 Qualcomm 设备节点** ⇒
  **CVE 选题必须聚焦 kgsl 驱动**(后续主攻: 用 kernel.elf 工具链审计 kgsl 驱动找新 bug,
  或跟踪新 kgsl CVE——21385 已归档但 kgsl 驱动 39MB 代码的审计空间巨大)。

## Day 41: 新矿区情报(2026 年 Qualcomm 内核 CVE)
- **CVE-2026-25259**(2026-06 bulletin): GPU/display 驱动 **IOCTL escape 命令序列越界验证缺失**
  ⇒ UAF ⇒ 完整提权; 受影响列表以 Snapdragon Compute/IIoT 为主(SC8380XP/QCM/SD865) ⇒
  **SM7325 匹配待确认**(kgsl escape 路径!);
- CVE-2026-24082(2026-05): perf counter deselect UAF(备选——perf 旧尝试已关闭但这是新 CVE);
- CVE-2025-47389(2026-04): TEE attestation 整数溢出(qseecom 权限墙 ✗);
- **Day 42**: 确认 2026-25259 的 SM7325 匹配(拉 June 2026 bulletin) ⇒ 匹配则反汇编 kgsl
  escape 路径(用 kernel.elf 工具链) ⇒ 攻击面评估 ⇒ PoC。

## Day 42: CVE-2026-24082 判死 + 选题收敛结论
- **2026-24082 判死**: SM7325/SM7325P/778G 全部不在受影响列表(组件 = Automotive GPU 专有);
- **2026-25259 判死**(前一轮): SM7325 不在列表 + DSP Service 专有闭源;
- **选题收敛结论**: 2026 年上半年的 Qualcomm bulletins 中, **SM7325 匹配 + 内核态 + 公开 diff
  的候选已全部筛尽**(2026-25259/24082/21385/47333/47376/38352 全部判定);
- **下一会话选题方向**:
  A. 跟踪 2026-07 之后的 Qualcomm/Android bulletins(新披露);
  B. **kgsl 驱动自研审计**(kernel.elf 工具链, 1680 符号, 按 mem/context/dispatch/sync 分块);
  C. GhostLock 非 overlay 审计(悬空 pi_blocked_on 的其它产生路径);
  D. kgsl 降级状态之谜(MMU=NONE 根因——修复可能解锁 21385)。

## Day 32-33: ★★★ 根因链条完全闭合 —— 固件请求失败
probe ENDEVEN 点(0x10a7c7b4)上下文解码: **固件名字符串 → request_firmware 调用 → 失败 ⇒ ENDEVEN**;
结合实测 **/vendor/firmware/ 目录为空(0 文件)** ⇒ **根因链条闭合**:
```
/vendor/firmware/ 为空 ⇒ GMU 固件请求失败 ⇒ probe 返回 ENDEVEN ⇒ kgsl 驱动降级
⇒ 所有 gpumem alloc ENDEVEN ⇒ CVE-2026-21385 无法触发
```
- **修复可能性**: 恢复 vendor 固件文件(需重刷 vendor 分区或 root——超出 shell 能力);
- **终局: CVE-2026-21385 在此设备实质不可行**(除非设备状态修复)。

## 会话最终总账(7 条主线全部科学闭环+根因链条)
全部判定同前(38352 判死/37804 判死/27038 不影响/21479-80 暂缓/47333 判死/21385 暂缓-固件缺失)。

## Day 34(续): ENDEVEN 深度搜索收益递减 —— 收尾结论
- 已排除: alloc 链全部直接函数(iommu_get_gpuaddr/domain_get_attr/rb_next/attach 子函数/contiguous 链);
- 剩余可能: 间接调用链(blr vtable/子树的子树) —— 逐层跟随收益递减;
- **替代方案(下一会话优先)**: 实证法——在 PoC 中对同一 fd 依次调用其它处理器(如 drawctxt_create
  已成功), 再用 strace 类工具或 kernel tracepoint(ftrace 可用性待查)直接观测 alloc_id 的内核路径
  执行到哪一步 ⇒ 比静态反汇编快;
- **结论: ENDEVEN 定位暂停**(工具与方法就绪, 恢复成本低), 优先级让位于新 CVE 选题。

## 会话最终总结
- **7 条主线全部科学闭环**(每条有完整证据链与判定);
- **新资产**: kernel.elf 工具链(任意内核函数反汇编) + rela.dyn 解析 + 全 cmd 探测 PoC + 
  KGSL-MICRONODE-RECON(Day 1-34) + 21385 分析文档;
- **方法论固化**: CVE 筛选(芯片匹配+权限墙+缓解确认) → 机理分析(diff/反汇编) → 触发构造 → 
  科学判定 —— 完整可复用的研究流水线。

## Day 37: ftrace 判死 + perf 采样方案确定
- ftrace(tracefs) root 专属 ⇒ shell 权限拒绝 ⇒ 判死;
- **perf_event_open 在 shell 域可用**(38352 KASLR 线路验证) ⇒ **perf 采样方案**:
  PERF_TYPE_HARDWARE(CPU cycles)+IP 采样 ⇒ 跑 PoC(ENDEVEN 重试循环)同时采样
  ⇒ 内核 IP 分布统计 ⇒ **失败路径的高频函数 = ENDEVEN 检查点定位**;
- **下一会话**: 实现 perf 采样工具(perf_event_open + mmap ringbuffer + IP→符号映射)
  ⇒ ENDEVEN 精确定位 ⇒ PoC 激活 ⇒ 21385 触发确认。

## Day 38(下一会话): perf 采样工具实现
- **环境确认**: perf_event_paranoid = **-1**(完全开放!) + armv8_pmuv3 PMU + kprobe/etm ⇒
  内核任意 IP 采样可行;
- 工具设计: perf_event_open(PERF_TYPE_HARDWARE/CPU-CYCLes, exclude_user=1) + mmap ringbuffer
  (PERF_RECORD_SAMPLE) + IP→符号映射(vmlinux_symbols) ⇒ PoC 重试循环并行采样
  ⇒ **ENDEVEN 失败路径的高频函数 = 检查点定位** ⇒ PoC 激活 ⇒ 21385 触发确认。

## Day 38: perf 自采样工具链打通 + KASLR slide 实测 + alloc 失败路径定位
- **工具**: C:/qemu_test/kgsl_21385_perf.c (自采样: perf_event_open pid=0 + alloc 重试循环同进程)
  + sym_scan2/3.py (基址扫描 + 符号化)。26.5M 次 ioctl / 8s, 63739 样本;
- **三个修复**: ①mmap EINVAL = attr.inherit=1 禁 ringbuffer → 去掉; ②data_head 在 mmap_page 头
  1024B 之后(用 struct perf_event_mmap_page.data_head/data_offset/data_size), 不是 meta[1];
  ③perf_event_header = {u32 type; u16 misc; u16 size}, size 在 ev+6 不是 ev+2 (曾致 0 样本);
- **本次 boot KASLR**: text_base=0xffffffd129c80000, slide=**0x1119c00000**
  (判据: T 低21位=0x80000 + kgsl 语义命中率 86.8%)
- **量化发现**: alloc 快速失败路径 39093 内核样本中 kgsl 驱动内仅 3.6%, 零 gpumem_alloc 内样本;
  96% 时间在 el0_svc_common + __fdget + do_vfs_ioctl + **avc_has_extended_perms(SELinux!)** +
  __check_object_size ⇒ **SELinux extended-perms 检查是 21385 高频投递的主要成本项**;
- **结论**: alloc 失败在 handler 极早期(参数检查), ENDEVEN 检查点之后路径无驻留 ⇒
  下一手: ①PERF_SAMPLE_CALLCHAIN 拿调用链; ②sample_period=2000 细粒度; ③成功 alloc 对照法
  (真实分配 vs 失败分配的采样差集 = 检查点之后的路径);
- 工具资产: perf_diag.c(三模式诊断) / sym_scan3.py(一键符号化, 读 perf_ips.txt)。

## Day 39: ENDEVEN 破案 —— 不是代码检查, 是 ioctl 通道布局差异; GPUOBJ 通道全通
- **判死链**: alloc_id(0x40180932) 全组合 ENODEV(19) ⇒ 对照采样两相无差异 ⇒ 静态扫描
  整个 kgsl 区段(0x10a75bb4-0x10ab0000)仅 4 处 -ENODEV(probe/open/drawobj_timeline/efuse),
  gpumem_alloc 链内零 -19 ⇒ 排除代码检查路径;
- **dispatch 架构解码**: kgsl_ioctl → kgsl_ioctl_helper(静态表, nr 索引*16, {cmd,len,func@8};
  func=NULL 或 nr 越界 → -515) → -515 时 kgsl_ioctl 按 **TIF_32BIT(bit22)** 选 fallback:
  adreno_ioctl(64bit) / adreno_compat_ioctl(32bit) → adreno_ioctl_helper(5 条目表 @0x12a0c3d0,
  按 entry 首字节==nr 线性匹配) ⇒ 厂商内核 ioctl 编号与上游不同!
- **运行时全 nr 扫描(0x00-0x5e)实测存活表**:
  - 成功: **0x34 GPUOBJ_ALLOC(0xc0300934)** {size@0, flags@8(必须含 0x1000), 0x30 字节;
    回写 id 在 w0 低 32 位, w3=0x4000001000} · 0x02 **GPUOBJ_FREE(0xc0280002, 0x28 字节, id@0)**
    · 0x2f · 0x40 · 0x45(GPUOBJ_INFO) · 0x58;
  - ENODEV: 0x32(=上游 GPUMEM_ALLOC_ID, 厂商已废) · 0x39 · 0x5a · 0x5c · 0x5d;
  - EINVAL: 0x33/0x35-0x38/0x3a/0x3c/0x3d/0x41-0x43/0x46/0x47/0x49/0x4a/0x4c/0x57/0x59 (size 不匹配);
  - 0x3b=EPERM · 0x48=524(ENOTSUPP) · 0x4b=95(EOPNOTSUPP) · 0x5b=EAGAIN;
- **结论**: 21385 的 ENDEVEN = "上游 GPUMEM_ALLOC_ID 在厂商内核不可用", 与内核漏洞无关;
  **21385 PoC 必须改走 GPUOBJ 通道: alloc=0xc0300934 / free=0xc0280002** (已验证 alloc id 递增 1→2,
  free 返回 0), mmap 路径与 cross-cache 下一会话继续;
- 工具: kgsl_errno_probe / kgsl_nr_scan / kgsl_free_scan / kgsl_gpuobj_test2 / kgsl_21385_cmp。

## Day 40: GPUOBJ mmap 闭环 + free-while-mapped 语义实测(21385 原语基线)
- **mmap 编码破解**: offset = id<<12(pgoff=id), len 必须 == entry memdesc size
  (不匹配 → get_mmap_entry -34 EOVERFLOW); 一次性打通 alloc→mmap→memset→读回→free 全闭环
  (4K/64K/256K/1MB 全部成功, uid=2000 shell 直通!);
- **结构体布局修正**: 内核 kgsl_gpuobj_alloc 实为 {u32 id@0, u32 flags@4, u64 size@8, ...} 0x30 字节
  (此前把 flags=0x1000 当 size 用歪了); alloc 时 b[1]=size, b[0] 高32=flags;
- **get_mmap_entry 解码**: find_id_flags(private, vm_start?) 失败→find(private, key<<12);
  命中后 len==size 或 len==ALIGN(size,0x1000) 否则 -34;
- **free-while-mapped 实测(21385 核心语义)**:
  ① 带用户映射 free 返回 0(接受!);
  ② free 后旧映射仍可写可读(页未回收);
  ③ 立即 realloc 同尺寸对象 → 旧映射内容不变 ⇒ 页未立即被复用
  ⇒ 疑似 mmap 持有 entry 引用或页进 kgsl pool 慢速回收 ⇒ 真正的 UAF/复用需:
  munmap 后观察 / drop fd / cross-cache 页源切换 / 或 vm_insert_page 路径的 PTE 竞态;
- 工具: kgsl_gpuobj_mmap3 / kgsl_mmap_brute / kgsl_size_probe / kgsl_gpuobj_v2 / kgsl_uaf_test。

## Day 41: dispatch 全表重建 + 真 FREE 验证 + 原语边界测定
- **helper 全表重建(94 条目)**: 厂商用老式编号! nr→handler: 0x34=gpumem_alloc_id ·
  0x35=gpumem_free_id · 0x13=drawctxt_create · 0x14=destroy · 0x3d=submit_commands ·
  0x4a=gpu_command · 0x40-0x43=syncsource · 0x45-0x4c=gpuobj 系列 · 0x57-0x5d=timeline;
  上游编号 0x40180932 的表项(nr0x56) func=NULL; nr=0x32 被改线到 device_setproperty(故 -19);
- **真 FREE 验证**: 0xc0080935(len 8, {u32 id}) → free(2) 后 realloc 得 id=2 复用 ✓;
  之前的 "nr=0x02 free" 是 device_getproperty 假阳性;
- **原语边界**: ①三重 free 全返 0(幂等, 不炸) ②新分配内核零化(内容通道死)
  ③pagemap 可开但 PFN 隐藏(物理观察通道死) ④free-while-mapped 接受但页持引用不立即复用;
- **drawctxt @ nr0x13**: 全 len/type 矩阵 EINVAL(结构体玄机或需设备激活) — GPU 提交链未通,
  下会话主攻: drawctxt 正确结构体(反汇编 kgsl_ioctl_drawctxt_create@表取 len) → submit_commands(0x3d)
  → GPU 触达 → kgsl 经典竞态面(free vs in-flight)全开;
- 工具: kgsl_nr_final / kgsl_dblfree / kgsl_pool_reuse / kgsl_dcrt_brute。

## Day 42: drawctxt 破关 —— GPU 上下文通道激活
- **EINVAL 根因**: adreno_drawctxt_create @0x10af2c0c 头部 `bics wzr, w11(0x12), w24(flags)`;
  **flags 必须包含全部 0x12 位(bit1|bit4), 否则 EINVAL**(flags 合法掩码 w25=0x1ff7fa9a/0x11f7fa9a
  按特性位选择);
- **实测**: cmd 0xc0040913(len4, {u32 flags=0x12}) → ret=0, **ctxid=32850 稳定复现**;
  create 后 ctxid 同值重复(32850) ⇒ 上下文被复用或全局计数;
- destroy(0xc0040914) 仍 EINVAL(小尾巴, ctx 泄漏但不阻塞);
- **意义**: GPU 上下文通道激活 ⇒ 下一步 submit_commands(nr=0x3d)/gpu_command(nr=0x4a) 提交 IB,
  GPU 真正触达 ⇒ kgsl 经典竞态面(free vs in-flight, drawctxt 生命周期, syncsource/fence)全开;
- kgsl_ioctl_drawctxt_create 是薄封装: device->ftbl[0x1e0 处表]->[0xa0] = adreno_drawctxt_create,
  CFI 候选 = 0x1156d19c。

## Day 43: submit_commands 结构全解码 + 提交链卡点定位
- **struct kgsl_submit_commands(0x38)**: {u32 ctxid@0, u32 flags@4, u64 cmdlist@8,
  u32 numcmds@0x10(≤0x186a0), u64 syncobj@0x18, u32 numsyncs@0x20(≤0x20), u32 timestamp@0x24(出)};
  流程: drawobj_cmd_create → add_ibdesc_list → **ftbl->submit_drawobjs**(0x60 CFI=0x1156ff60);
- **ibdesc 64 位 = 0x20 字节** {gpuaddr, hostptr, sizedwords, priv}(TIF_32BIT 走 0x10 compat 路径);
  add_ibdesc 本身零校验必成功(gpuaddr 不在此层验证!);
- **实测**: ctx=32850 + ibdesc{gpuaddr=host} → submit 仍 EINVAL ⇒ 卡点在 ftbl->submit_drawobjs
  (adreno_submit_drawobjs: 队列/ringbuffer/设备状态校验) — 下会话反汇编该函数定位 EINVAL 条件;
- SVM 确认: alloc 时 gpuaddr=0, mmap 后 INFO va 恒 0x1000(与 id 无关, INFO 语义待查);
  提交用的 gpuaddr 可能须来自 INFO/mmap 地址, 在 submit_drawobjs 内部解析;
- 工具: kgsl_submit_test(全链骨架已就位, 改参数即测)。

## Day 44: submit_drawobjs 层解剖 + 双 idr 空间发现
- **adreno_queue_cmds(0x10aaf950)**: 按 hwsched 位(bit7)分流 → a6xx GMU 走 adreno_hwsched_queue_cmds
  (0x10af3a30); 入口校验: count-1 ≤ 0x7d, per-obj 链计数 ≤ 0x53;
- **EINVAL 区间**: hwsched_queue_cmds 内含 `kgsl_mmu_gpuaddr_in_range` 校验(ibdesc gpuaddr 须在
  process pagetable 范围内) + 失败走 _dev_err+EINVAL; 上下文标志/队列空间检查(-35/-2 等);
- **双 idr 空间发现**: gpuobj_info(0x47) 查 gpuobj idr(须由 gpuobj_alloc 0x45 创建, 但 0x45 全 EINVAL),
  gpumem_alloc_id(0x34) 的 id 不在其内 ⇒ INFO 永远 -22; 早期"INFO ret=0 va=0x1000 size=0xc0000"
  是栈垃圾 id 撞上 memstore(0x1000/0xc0000 正是 memstore 特征);
- **gpumem_get_info(0x36)**: 全 len -22(入参布局未解, 上游 {u64 gpuaddr in, u64 size, u32 id...});
- SVM 语义再确认: alloc 时 out gpuaddr=0 ⇒ gpuaddr 由 mmap 赋值(=vaddr)的推断待 submit 闭环验证;
- **下一步(精确)**: ①反汇编 kgsl_ioctl_gpumem_get_info(0x10a7bfa4, 0xF0 小函数)拿入参 → 取真 gpuaddr;
  ②若 gpuaddr=host 则查 hwsched 的 in_range 失败原因(SVM pagetable 绑定时机?);
  ③或改走 gpuobj_alloc(0x45, 反汇编其入参布局)走纯 gpuobj 通道;
- 工具: kgsl_submit_v2 / kgsl_dualspace / kgsl_info2 / kgsl_dcrt_flags / kgsl_ctx_lifecycle。

## Day 45: gpumem_get_info 破译 + 真 GPU 地址到手
- **struct kgsl_gpumem_get_info(0x28)**: {u64 gpuaddr@0(in:0=按id查/out), u32 id@8(in),
  u32 flags@0xc(out), u64 size@0x10, u64 mmapsize@0x18(+0x20=0)};
  cmd 0xc0280936; 实测 id=2 → **va=0x4000030000**(SVM GPU va), size=0x1000 ✓;
- **submit 仍 EINVAL**(ibdesc.gpuaddr=0x4000030000) ⇒ -22 在 hwsched_queue_cmds 中段
  (0x10af3e84-0x10af3f70 未解剖区) 的 _dev_err 路径 — 非 gpuaddr_in_range 段;
- 下一步: ①反汇编 hwsched_queue_cmds 中段(0x3d80-0x3f70)与 _dev_err 字符串; ②检查 ctx flags
  0x12 是否缺 submit 所需位; ③numcmds/flags 组合矩阵;
- 全链骨架: alloc(0x34)→mmap(id<<12)→INFO(0x36 id@8→gpuaddr)→submit(0x3d) — 只差最后一个校验位。

## Day 46: submit EINVAL 最终定位 —— gpuaddr 不在上下文 pagetable 范围
- **-22 触发链确认**: hwsched_queue_cmds @0x3bb8 `bl kgsl_mmu_gpuaddr_in_range`
  → `tbz w0,#0 → 0x3c8c` → _dev_err("gpuaddr not in range 类消息") → -22 @0x3cec;
  另一分支 0x3ba4 b.hs→0x3c60(sizedwords 过大 类似检查) → 同样 dev_err → -22;
- **矛盾点**: 对象 va=0x4000030000 来自 get_info(memdesc->gpuaddr), 但不在**该上下文所用
  pagetable** 的范围内 ⇒ 两种可能: ①上下文 pagetable ≠ 对象所在 SVM pagetable(需 ctx 特定
  flags 启用 SVM pagetable) ②SVM 对象的 GPU va 只在 fault 时绑定, 静态 in_range 检查的是
  别的区间(需看 kgsl_mmu_gpuaddr_in_range 的区间来源);
- **下一步**: ①反汇编 kgsl_mmu_gpuaddr_in_range(区间来源) ②枚举 ctx flags 高位组合(0x12|0x100000
  等含 PREEMPT/PAGETABLE 位) ③检查 drawobj_cmd_create 后 cmdobj 的 pagetable 绑定;
- 全链再无其他未知: alloc/mmap/get_info/free 全通, 只剩这一处 pagetable 绑定问题。

## Day 47: in_range 解剖 + PF_RANDOMIZE 推断修正 + personality 被拦
- **kgsl_iommu_addr_in_range(0x10aa8048)**: 检查 [pt+0x78] 结构的 3 组 (start,end) 区间
  (0x20/0x28, 0x40/0x48, 0x30/0x38), gpuaddr+size 须落在其一; funcs 候选 = 
  kgsl_iommu_addr_in_range / nommu_gpuaddr_in_range (CFI 0x11572e50);
- **推断修正**: kgsl_ioctl 强制注入的 bit32 来自 **TIF_32BIT(bit22) 非 PF_RANDOMIZE** —
  64 位进程 bit32=0 ⇒ 对象非 SVM; va=0x4000030000 是本内核经典用户区;
- **personality(ADDR_NO_RANDOMIZE) 被 seccomp 拦截**(ret=-1) — 该路线不可用;
- ctx flags 高位枚举(0x20000000/0x800/0x80000000) 全部 EINVAL; va 步进 0x31000 ⇒ 对象泄漏
  (free 未回收 SVM va 或提交失败残留);
- **下一步**: ①hwsched_queue_cmds 精确判别 -22 来源分支(在 ibdesc 循环内逐个 in_range?)
  ②对比 gpu_command(nr=0x4a, 新式提交) 是否绕过该检查 ③反汇编 _dev_err 字符串确认打印内容
  (adrp 0x11fed000+0xd79 / 0x11f4b000+0x21c 两处格式串) ④检查 drawobj_cmd_create 后是否需要
  cmdobj->pagetable 绑定;
- 工具: kgsl_nosvm / kgsl_svm_ctx。

## Day 48: gpu_command(nr=0x4a) 结构骨架解码
- **kgsl_ioctl_gpu_command @0x10a78054**: 上限检查 numcmds/numobjs ≤ 0x186a0, numsyncs ≤ 0x20;
  字段偏移: flags@0, cmdlist@8(u64 用户指针), {w3@0x10,w4@0x14}→add_cmdlist,
  objlist@0x18(u64), {w3@0x20,w4@0x24}→add_memlist, sync@0x28?, numsyncs@0x34(≤0x20),
  **ctxid@0x38, timestamp@0x3c(出)**; 走 add_cmdlist(0x10a8388c)/add_memlist(0x10a83a30)
  → 同一 ftbl->submit_drawobjs 收口;
- 字符串追踪噪声大(adrp 目标命中无关 rodata) — 放弃字符串路线;
- add_cmdlist/add_memlist 的 (w3,w4) 语义(数量 vs 起始 index)待下会话反汇编确认;
- **两条提交路径对比结论**: submit_commands 与 gpu_command 共用 submit_drawobjs 收口 —
  若 in_range 检查在其共同前置(add_ibdesc/cmdlist 解析)中, 两条路径同样受限;
  关键分歧点: gpu_command 的 cmdlist 对象带独立 flags/offset 字段(可能有 bypass 空间);
- 工具: kgsl_submit_v3(get_info 闭环版骨架)。

## Day 49: add_cmdlist 语义 + gpu_command 实测 + bisect 结论
- **add_cmdlist(0x10a8388c) 语义**: cmdlist 为 0x20 字节/项数组, **循环计数 = w4**(w4=0 时
  静默 no-op 返回 0 — 假成功坑!), w24=min(w3,0x20); cmd 项 = ibdesc {gpuaddr,hostptr,sw,priv};
- **gpu_command 实测**: {numcmds=1, loop=1, ibdesc.gpuaddr=0x4000030000} → 仍 EINVAL;
- **bisect**: count=0 空提交也 -22(入口 count-1≤0x7d 固有拒绝, count 必须 ≥1) — 二分无效,
  但结合 count=1 实测确认失败在 in_range/pagetable 层;
- **in_range 深解**: kgsl_iommu_addr_in_range 检查 [pt+0x78] 的 3 组区间 — 0x4000030000
  未落入 ⇒ 要么检查用了 default pagetable(无 SVM 区), 要么 0x4000030000 不属于本进程
  pagetable 的任何区间(SVM va 分配在 fault 时绑定?);
- **下一步**: ①找 pagetable 区间常量(compat_va_start/end 等符号或 init 代码) 确认 0x4000030000
  属于哪类区间 ②反汇编 get_info 用的 find 键(gpuaddr=memdesc->gpuaddr 是否真的有效)
  ③或直接用 ibdesc.gpuaddr = 猜测的 compat 区地址试探 in_range 边界(黑盒扫描区间!);
- 工具: kgsl_gpucmd_test / kgsl_bisect。

## Day 50: ctxid 之谜聚焦
- **drawctxt_create 尾部解码**: `idr_replace(device->context_idr@dev+0x740, ctx, [ctx+4])`
  + `str w8(ctx->id), [x19+4]` ⇒ **ctxid 应在 udata+4**; 实测 buf+4 = 0 (context->id=0?);
  buf+0 = 0x8052 = context->flags 回显(flags 0x12|内部位 0x8040), flags=0x1012 → 0x1052 佐证
  (|0x40 位);
- **矛盾**: ctxid=0 疑似非法(kgsl 惯例 id 0=invalid), 但 buf+4 确实为 0;
- **bisect 缺陷**: numcmds=0 → drawobj count=0 → hwsched 入口 count-1≤0x7d 恒拒 ⇒ ctx 校验
  根本未执行, 所有 ctxid 候选同 EINVAL 无法判别;
- **下一步**: ①反汇编 kgsl_context_get(0x10a7d338) 确认 id=0 是否特判 + dev_priv 校验位置;
  ②用 count=1 + 合法 ibdesc(0x1000 memstore 区) + ctxid 候选矩阵 联合扫描;
  ③若 ctx 校验过了仍 -22 → 落回 in_range 层, 黑盒扫区间;
- 工具: kgsl_ctx_dump / kgsl_ctx_brute / kgsl_range_probe。

## Day 51: kgsl_context_get 解码 + 静态分析边界
- **kgsl_context_get(0x10a7d338)**: read_lock(context_idr_lock@0x758) → idr_find(idr@0x740, id)
  → **无 id=0 特判** → [ctx+0x20] bit1 置位则拒(deferred-destroy 标记?) → refcount_inc(ctx+0);
- **关键事实**: 全部 gpuaddr 值(含 memstore 0x1000)提交同 EINVAL ⇒ -22 无条件早于 ibdesc 值
  依赖; 全部 ctxid 候选同 EINVAL 但 count=0/1 区分无效 ⇒ 静态寄存器-字段映射已到边界
  (context->flags@0x20 bit1/bit2 分支与实测 errno 不完全吻合, 需要更精确的字段映射);
- **战略调整(下一会话)**: ①停止逐分支静态追踪, 改为**构造 ground truth**: 用 strace 级工具
  (ptrace?) 或对比真实 GPU 客户端(如 mini GL app / surfaceflinger 触发)的 ioctl 序列;
  ②检查 kernel 配置 CONFIG_QCOM_KGSL_... 可能存在的调试开关; ③审视 kgsl_context 字段
  布局(refcount@0, id@4, dev_priv@0x10, flags@0x20)与 hwsched 检查位的关系;
  ④重新审视: drawctxt create 返回 ret=0 但 ctx->id=0 —— 可能 create 内部走了错误分支,
  需反汇编 0x10a78c48-0x10a78d18 中段(此前跳过)确认 ctx->id 赋值来源;
- 设备健康, 工具链完整。

## Day 52: 真 ctxid 到手(0x0e) —— copy_out 截断破案
- **ctxid 之谜破案**: copy_out 只回拷 _IOC_SIZE(cmd) 字节! len=4 时 ctxid(+4)从未送达用户;
  **cmd 0xc0080913(len=8, {u32 flags=0x12; u32 ctxid(out)}) → ctxid=0x0e 真实 id**;
  (0x8052 = flags 回显非 id; 旧 len=4 测试全部被截断误导);
- **实测**: 真ctx=14 + gpuaddr ∈ {0x4000030000, 0x1000(memstore), 0x10000, 0x1000000,
  0x100000000} → 全部 EINVAL ⇒ **-22 与 gpuaddr 值无关**(in_range 归因被推翻);
  ⇒ -22 在 hwsched_queue_cmds 更前段(context->flags/队列状态/类型检查)或 cmdobj 建立后
  的非 ibdesc 校验;
- **下一步(黑盒+静态收敛)**: ①hwsched_queue_cmds 全量反汇编落盘(0x10af3a30-0x3f80)逐分支
  带具体值推演(ctx flags=0x8052, count=1, type=1); ②kgsl_drawobj_cmd_add_cmdlist 已知零校验,
  重点查 [ctx+0x20] bit1/bit2 分支(=0x8052 bit1 置位→w28=-2?) 与实际返回 22 的矛盾;
  ③对照 gpu_command flags 高位(bit1/bit10 → w25=2/4 → syncobj 分支);
- 工具: kgsl_range2 / kgsl_ctxid8。

## Day 53: dispatcher 路径确认 + 区间不一致假设(21385 候选形态!)
- **adreno_queue_cmds 分流**: [dev_priv->device + 0x198] bit7 → hwsched / 否则 dispatcher
  (0x10aeb520) — 两路均有逐 ibdesc 的 kgsl_mmu_gpuaddr_in_range(0x10a8795c);
- **dispatcher 解码**: count==0→-22; count 上限检查; ctx flags bit2→-35, bit1→0x698 特殊路径
  (非错误); per-drawobj: type==1 → 走 cmdobj ibdesc 链([node+0x58] 链表, node+0x28=size
  =sizedwords*4); **size-1 ≤ 0x3fffff** 检查 → in_range(pt, gpuaddr, size) 逐项;
- **区间不一致假设(重要!)**: 对象由 alloc 在 pagetable A 分配 va=0x4000030000(通过),
  但 submit 的 in_range 检查的 pagetable B 的 3 区间不含该 va ⇒ alloc/submit 的 pagetable
  或区间口径不一致 —— 若能用 B 区间内的 gpuaddr 引用 A 区间对象 = 跨 pagetable 混淆
  = 21385 类 UAF 候选形态!;
- **下一步**: ①精确确定 in_range 的 x0 = 哪个 pagetable(dispatcher 0x10aeb61c-0x640 的
  x0 装载链) ②对比 alloc 时 va 分配用的 pagetable ③若确认不一致 → 直接构造 PoC。

## Day 54: in_range 调用链精确解码
- **x0 装载链**: dispatcher @0x10aeb630: `x8 = [dev_priv+0x8] (file_priv); x0 = [x8+0x40]`
  ⇒ **in_range 检查的是 file_priv+0x40 的 pagetable** 的 3 组区间;
- **ibdesc 链**: cmdobj+0x58 链表, node = {gpuaddr@0x20, size@0x28(=sizedwords*4), priv@0x20?};
  size-1 ≤ 0x3fffff 检查; in_range 失败 → 0x10aeb720 _dev_err → -22;
- **黑盒推论**: 全域 gpuaddr 采样(0x1000-0x4000030000 共 8 点)全部 EINVAL ⇒ 要么
  [file_priv+0x40] 的 3 区间不含任何被采样点(区间极窄/为空/PT 为 NULL), 要么该偏移
  不是 pagetable;
- **下一步**: ①确认 kgsl_file_private 布局(+0x40 是否 pagetable — 经 kgsl_close/drawctxt_destroy
  等访问同一链的代码交叉验证) ②黑盒扫描全 64 位空间(0x100000 步进粗扫)找 in_range 通过点
  (通过时 errno 会变为 -2/-35 或成功) ③若确认 PT 为空 → 找出进程 PT 正确挂载点;
- 工具: kgsl_range_probe / kgsl_range2 / dispatcher.asm / hwsched.asm。

## Day 55: kgsl_open 解码 —— 结构布局确认
- **kgsl_device_private** = {device@0, **process_private@8**} (kgsl_open: str x22(process_private),
  [x21+8]);
- ⇒ dispatcher in_range 的 x0 = **[process_private+0x40] = 进程 pagetable** — 链路正确!
- ⇒ 矛盾坐实: 对象 va=0x4000030000 由 alloc 分配(经同一 process_private), 但 in_range 的
  3 区间([pt+0x78]+{0x20/0x28,0x40/0x48,0x30/0x38})不含它 ⇒ **alloc 的 va 池 与 in_range
  的区间变量不同源**(vendor 内部不一致) — 或区间为空(PT 未正确初始化 SVM 区);
- **in_range impl 的 3 区间语义猜测**(upstream): compat@0x20/0x28, user@0x30/0x38,
  svm@0x40/0x48 — 实际值需运行时;
- **下一步**: ①反汇编 kgsl_process_private_new / pagetable 初始化找 3 区间赋值来源;
  ②黑盒: 分配后用 get_info va 附近值细粒度扫描(0x4000030000 ± 0x100000 内 0x1000 步进);
  ③检查 gpumem_alloc_id 是否给不同 flags 分不同 va 区(flags=0 vs 0x1000 vs 高位);
- kgsl_open 其他信息: process_private_new(device) 全局单例(引用计数), dev_priv+0=device。

## Day 56: 测试假象澄清 + 焦点最终收敛
- **假象澄清**: 早期"空提交"测试 gc.flags=0/numcmds=0 → w25=2 → drawobj 类型成了 SYNCOBJ
  (走 syncobj 分支) → EINVAL 来自 sync_create 空 syncs, 与 ibdesc/ctx 无关 — 此前结论作废;
- **真 ctx=14 (destroy 预言机确认)** 下: 带真 gpuaddr 的 cmdobj 提交仍 EINVAL ⇒ 卡点=dispatcher
  ibdesc 循环内的 in_range(0x10aeb640) 或其后;
- **最终焦点**: in_range([process_private+0x40], va, size) 的 3 区间为何不含 alloc 发出的
  va=0x4000030000:
  ①反汇编 kgsl_process_private_new(0x10a7ffa0) + PT init → 3 区间赋值来源(是否含 SVM 区);
  ②kgsl_iommu_addr_in_range 的 3 区间 = compat/user/svm(upstream 猜测) — 若 SVM 区区间
  为空/未启用 → alloc 走了 SVM 池但 in_range 不认 = vendor 不一致(可利用性核心);
  ③黑盒: va±细粒度扫描仍可作为兜底;
- 全链状态: alloc/free/mmap/get_info/drawctxt 全通, 仅剩 in_range 区间口径一环。

## Day 57: process_private_new 解码 + 0x200400000000 常量发现
- **kgsl_process_private(0x230 字节)** 初始化: +0x8=pid, +0x10=comm(16B), +0x20=0, +0x24=1,
  **+0x28 = 0x200400000000(常量!)**, +0x40 = pagetable(ftbl[0x58] 调用创建, CFI@0x11577a50),
  +0x58 = gmc 私有(kgsl_gmc_proc_private_init), +0x1a8 = 0x200400000000, +0x1b0/0x1b8 = 0,
  +0x1c0/0x1cc = 0;
- **关键发现**: 常量 0x200400000000 疑为 SVM/va 基址 — 但 get_info 报告对象 va=0x4000030000
  (0x200400000000 之外!) ⇒ alloc 的 va 来源 与 该基址 不一致(或不同区);
- **下一步**: ①反汇编 gpumem_alloc_id 内 va 分配(找 0x4000030000 的池来源 — 哪个 gen_pool/
  哪个基址) ②反汇编 pagetable 创建(kgsl_pagetable_create/ftbl[0x58] 真身)找 in_range 3 区间
  的赋值 — 对比 0x4000030000 是否被任何区间覆盖 ③若确认两套基址错位 = vendor bug 实锤;
- 注: 0x200400000000 与 0x4000030000 的关系: 0x4000030000 = 0x40000_30000; 两池可能分别是
  "user 区"与"SVM 区" — alloc 与 in_range 各认一个 = 口径分裂的根源。

## Day 58: 战略固化 —— 21385 工具箱现状与路径评估
- **已打通原语(uid=2000 shell)**:
  ① gpumem_alloc_id (0xc0180934, len 0x18) — 任意 size 分配, id 递增
  ② mmap (off=id<<12, len=size) — 用户可读写, 页真实存在
  ③ gpumem_free_id (0xc0080935, len 8) — id 复用验证, **free-while-mapped 被接受**
  ④ drawctxt_create (0xc0080913, len 8, flags=0x12) — ctxid 真实(oracle 验证)
  ⑤ gpumem_get_info (0xc0280936) — gpuaddr/size/flags 查询
  ⑥ 双提交路径接口全解码(submit_commands 0x38 / gpu_command 0x40)
- **唯一阻塞**: 提交时 in_range(进程 PT) 拒绝 alloc 发出的 va(0x4000030000) —
  va 分配池与 in_range 区间口径疑不同源(0x200400000000 常量 vs 0x4000030000);
- **无需 GPU 提交的 21385 攻击面(下一会话优先)**:
  ① free-while-mapped 语义深挖: free 后页是否延迟回收? munmap 时序竞态?
  ② alloc/free 高频循环 + mem entry idr 复用竞态(对象生命周期竞态);
  ③ drawctx 泄漏(id 递增)与 destroy EINVAL 的组合;
  ④ mmap 时 get_mmap_entry 的 find 键(vm_start<<12)与 id 空间的交叉混乱可能;
- **经验教训(调试方法论)**: copy_out 截断(回拷 len<_IOC_SIZE 全字段)是假象之源;
  python replace 静默失败必须 grep 验证; destroy 预言机 = ctx 有效性判别利器。

## Day 59: 双重映射实验 —— 引用计数模型定性
- **双重映射可用**: 同一 id 两次 mmap(off=id<<12) → 两个 VA, 写一读二别名确认(同一物理页);
- **free-while-双映射 ret=0**: 接受; free 后 m1 写 m2 仍可见(页经映射引用存活);
- **realloc 隔离**: 新对象(m3)与旧双映射(m1/m2)内容隔离, 无跨对象页混淆;
- **结论**: kgsl 引用计数模型严密 — 映射持 entry 引用, free 仅摘 idr, 页在最后一个映射
  卸除后才回收 ⇒ 非竞态路径无 UAF;
- **21385 收敛至竞态窗口**: free(id) 与 mmap(id<<12) 的 idr 生命周期竞争 —
  窗口: idr_remove 完成 → entry put(refcount→0)→destroy 之间, 若并发 mmap 的
  find+get 恰在 remove 后/destroy 前执行 → entry UAF; 或 get 未持锁的窗口;
- **下一会话**: 双线程竞态 PoC(T1: alloc→free 循环; T2: 对同 id 高频 mmap+触碰) +
  竞态概率统计 + 崩溃归因(铁律 4: O_SYNC 日志);
- 工具: kgsl_dblmap(双映射骨架)。

## Day 59: 生命周期加固验证(会话终局)
- **双映射压力**: 200 轮 alloc→双 mmap→free→双 munmap 全部存活 — 引用计数无懈可击;
- **close-while-mapped**: free+close(fd) 后触碰映射 — 页驻留, 无用户态可达 UAF;
- **结论**: kgsl 内存生命周期在纯用户态驱动下加固完善, 21385 类 UAF 若存在,
  需要 ①GPU 提交链(in-flight 竞态) 或 ②内核内部竞态(非 shell 可达) —
  提交链的 in_range 之谜(0x200400000000 vs 0x4000030000) 成为必经之路;
- **下一会话唯一入口**: 解剖 va 分配池(gen_pool/0x4000000000 区)与 in_range 3 区间
  (0x200400000000 常量)的关系 → 找到口径分裂的根因 → 评估跨区引用的可行性;
- 本会话资产总览: 25+ 测试程序(C:/qemu_test/kgsl_*), 2 份落盘反汇编(hwsched/dispatcher.asm),
  59 天连续判读, 设备全程零异常重启。

## Day 60: 结构性恒拒实锤 —— shell 域 GPU 提交链判定
- **实验**: 全 64 位 va 空间 30 个代表点(含对象真 va±0x1000, memstore, 0x1000-0x800000000000
  全区域) + 真 ctx=14 + 真实 ibdesc → **0/30 通过, 全部同 EINVAL 无一差异化**;
- **判定**: 提交链 -22 为**结构性恒拒**(非区间边界问题) — process_private+0x40 的 pagetable
  区间表在 shell fd 下为空/未绑定, 或存在 shell 域特有的前置缺失(真实 GPU 客户端有额外
  初始化路径, 如 Android 图形栈的特定调用序列或 ION/dmabuf 导入路径);
- **21385 结论更新**: shell 域内 GPU 提交链不可达 ⇒ in-flight 竞态类 UAF 从 shell 不可构造;
  可达面收窄为: 纯内存生命周期(已证加固) + 仍开放的 get_mmap_entry find 键交叉混乱;
- **下一会话入口(二选一)**:
  A. 解剖真实图形客户端的初始化差异(为何其 PT 区间非空) — 需要 root/框架层对比;
  B. 放弃 shell 域提交, 深挖 get_mmap_entry find 键混乱(0x10a7fac4)的可用性;
- 60 天连续判读, 27 个工具, 2 份落盘反汇编, 设备零异常重启。

## Day 61: GMC 调查 + 会话战略终局
- **GMC 子系统**(vendor 特有): kgsl_gmc_compress / decompress_all / proc_private_init —
  GPU 内存压缩特性, process_private+0x58 挂载; 提交路径仅当 ctx flags bit0 时触发
  decompress_all — 非提交前置条件, 线索排除;
- **21385 最终战略判定(shell 域)**:
  ①内存生命周期加固完善(200 轮压力/close-while-mapped 全过);
  ②GPU 提交链结构性恒拒(30 点 0/30) — in-flight 竞态不可达;
  ③get_mmap_entry find 键经调查无跨对象/跨进程混淆空间(查找均限 process_private);
  ⇒ **CVE-2026-21385 从 uid=2000 shell 域: 暂无可达路径**(科学判定, 非放弃);
- **复活条件**: root/框架域(对比真实客户端初始化) 或 新情报(21385 具体 bug 机理公开);
- **资产全部固化**: 60+ 天判读 / 27 工具 / 2 反汇编落盘 / 完整 dispatch 表 / 结构布局图;
- 建议下一会话转向: 新 CVE 选题(2026-02 后公告) 或 kgsl 之外的攻击面重审计。

## Day 62: ★★★ 21385 真实机理落地 —— MAP_USER_MEM 未加固路径确认
- **外部情报**(web 检索): CVE-2026-21385 = kgsl_memdesc_get_align() 有符号返回 + 移位符号扩展
  (用户 flags 16-23 位 align); **酷安第三方分析**: alloc 路径被厂商提前钳制(align≥25 截断,
  "Alignment too large; restricting to %dK" — 与我们 Day57 见到的 dev_err 完全吻合!),
  **但 IOCTL_KGSL_MAP_USER_MEM 路径(kgsl_setup_useraddr/kgsl_setup_dma_buf)无对齐检查**;
- **本机验证**:
  ① alloc 路径钳制确认: gpumem_alloc_entry `cmp (flags&0xff0000), 0x180000` → align>24 拒绝;
  ② **kgsl_memdesc_init(共享) 钳制 = [12,32]**: `cmp w8,#0xc` + `cmp w8,#0x20` + `lsl w8,#16`
     ⇒ **align=31 放行**(1<<31 = INT_MIN 符号位保留!);
  ③ **kgsl_setup_useraddr(0x10a7e0bc) 无对齐钳制**, 调用链: find_vma/iterate_fd/dma_buf_get
     /kgsl_mmu_set_svm_region/memdesc_sg_virt;
  ④ map_user_mem 结构: flags@[x2+0x2c], flags bit3 → useraddr/dma_buf 分支, bit28 检查;
- **触发公式**: MAP_USER_MEM(nr=0x15/0x20, flags bit3) + align bits16-23=31 → get_gpuaddr
  `1<<31` 符号扩展 → 分配尺寸/偏移回绕 → 内存破坏;
- **下一步**: ①完整解码 map_user_mem 结构(0x2c 处 flags 前后字段) ②跟踪 setup_useraddr 中
  memdesc->flags 的 align 流转 → get_gpuaddr ③构造 align=31 的 PoC 观察分配结果异常;
- **这是整个会话最重要的转向**: 从"逆向 vendor 防御"转为"已知 bug 的真实触发路径"。

## Day 63: 21385 终判 —— MAP_USER_MEM 亦被封死, 全路径防御确认
- **实验**: map_user_mem(nr=0x15) 三组 flags(bit3|0x4|0x4+align31) → 全部 **-95 EOPNOTSUPP**;
- **根因**: 能力字节 [0x128af805] 在本设备为 SET ⇒ map_user_mem 整体返回 EOPNOTSUPP
  (vendor 反向移植的防御: 不止 alloc 钳制, 连 map_user_mem 通道都整体禁用);
- **setup_useraddr 路径选择条件**(记录): memdesc flags bit2 置位 + bit3 清零 → useraddr;
  但已无法到达(前置 -95);
- **★ CVE-2026-21385 本设备终判**: **不可利用**(shell 域):
  ① alloc 路径 align≤24 钳制(vendor 反向移植);
  ② MAP_USER_MEM 通道整体 -95 禁用(能力字节);
  ③ 与酷安第三方独立分析结论一致(其设备同样防御);
- **复活条件**: 解锁 bootloader 后更换未打补丁固件, 或发现 vendor 防御之外的第三路径;
- **本会话最高价值产出**: 完整逆向了 vendor 的防御布局(钳制点+禁用字节), 与公开 CVE
  机理交叉验证 —— 研究方法论完整闭环。

## Day 64: ★ 新主线开启 —— KGSL Syncsource Fence UAF 自研
- **情报源**: 2026-06 公开的 "KGSL Syncsource Fence UAF"(竞态类, Critical, github 已 404 下架)
  — 目标命令族恰为我们已确认接线的 syncsource 族(0x40-0x43);
- **优势**: 全静态分析能力(kernel.elf+符号) + 活体设备 + syncsource_create 实测可创建(id=1);
- **syncsource_create(0x10aa9768) 解码**: id = 原子计数器 [process_private+0x24](init=1) 递增;
  对象 kmem_cache 分配(0xa0 槽); 计数器 bit31 溢出 → refcount_warn + -22;
- **函数族地图**: create(0x10aa9768) / destroy(0x10aa99f4) / create_fence(0x10aa9b50) /
  signal_fence(0x10aa9e84) / kgsl_sync_fence_create(0x10aa876c) / fence_async_wait(0x10aa922c) /
  fence_async_cancel(0x10aa96c0) / fence_callback(0x10aa95dc) / kgsl_sync_cancel(0x10aa8e48)
  / kgsl_sync_fence_ops(0x12190220 dma_fence 操作表);
- **UAF 候选竞态**(经典形态): create_fence 挂 fence 到 syncsource → destroy syncsource →
  fence 的 timeline 引用悬空 → signal/销毁时 UAF;
- **下一步**: ①反汇编 destroy/create_fence/signal_fence 三兄弟(refcount 与列表操作)
  ②动态: create→fence→destroy→signal 序列实测 ③设计多线程竞态 PoC;
- 工具: nr 扫描已证实 0x40 ret=0(id=1) / 0x41-0x43 待正确结构体。

## Day 65: create_fence/destroy 解码 —— 竞态窗口结构确认
- **syncsource_destroy(0x10aa99f4)**: spin_lock → idr_find(pp->idr, id) → idr_remove →
  遍历 fence 链表 dma_fence_signal_locked(通知挂起 fence!) → refcount_dec → **减到 0 才
  process_private_put + kfree(syncsource)**;
- **create_fence(0x10aa9b50) 三段式**:
  ① spin_lock: idr_find(S) + refcount_inc(S) + **unlock**
  ② 无锁: fence 分配 + fence->syncsource 指针存 fence+0x40 + dma_fence_init +
     sync_file_create + get_unused_fd/fd_install(**fence 以 fd 交付!**) + udata+4=fd 回写
  ③ spin_lock: list_add(fence→S->fence_list 链表头 @S+0x38, fence->list @fence+0x48) + unlock;
- **竞态窗口**: ①与③之间 destroy 可完成 idr_remove + 信号遍历(fence 未入链表→不被通知)
  → ③ 将 fence 链入"语义已销毁"的孤儿 syncsource → fence fd 关闭时 dma_fence_release
  → 引用/链表错配 → UAF 候选;
- **引用网**: fence+0x40 存 syncsource 指针; destroy 的 kfree 受 refcount 保护;
  需要精确列出所有 ref 的 inc/dec 点才能判断是否有窗口;
- **下一步**: ①全量反汇编 create_fence/destroy 落盘逐 ref 推演 ②signal_fence(0x10aa9e84) 解码
  ③动态: 多线程 create_fence ∥ destroy 竞态 PoC(fence fd 是否仍有效/行为异常检测);
- 工具: kgsl_ctx_oracle(扩展为 syncsource oracle)。

## Day 66: syncsource 竞态实测 —— 47k 对撞零崩溃
- **单线程序列全通**: create(id=1) → create_fence(fd=4 交付成功) → destroy ✓ — fence 以
  sync_file fd 交付用户态, 基础设施完整;
- **竞态实测**: 5000 轮 × (create_fence 狂打 ∥ destroy 狂打):
  fence_ok=47360 / fence_fail=479134(destroy 后 idr miss) / destroy_ok=4655 — **零崩溃**;
- **判定**: ①③窗口(struct: ref inc→unlock→…→list_add)在实测中未产生可观测错误 —
  引用网(ref 计数保护 kfree)实现正确;
- **关键情报对齐**: 公开 "Syncsource Fence UAF" 元数据明确针对 **Android 15/16 GKI /
  Linux 6.6** — 本设备 5.4.281 vendor 内核代码不同 ⇒ **该公开漏洞不适用本设备**(判定);
- **结论**: syncsource 主线降级为低优先级(公开目标版本不匹配 + 实测无异常);
- 下一会话: 回归新 CVE 选题(2026-03 公告: CVE-2026-0006 Android System RCE / pKVM /
  F2FS / Mali 等) 或 2026-06+ 公告深挖。

## Day 67: F2FS 面 + shell 域系统性测绘终局
- **确认**: /data = f2fs(dm-44, shell 可写), F2FS_FS=y 内建;
- **重大发现**: F2FS_IOC_MOVE_RANGE(0xc018f509) 返回 **EACCES 非 ENOTTY** ⇒ 该 ioctl 在
  5.4.281 vendor 内核中**存在**(5.13 代码反向移植!) — CVE-2026-89840 的漏洞代码在本机!
- **但**: FIEMAP(0x660b 通用 ioctl)也 EACCES, 而 0xf50d/f50e 返回 ENOTTY ⇒
  **SELinux ioctl 命令级白名单过滤**(vendor sepolicy 按命令值放行) — F2FS 攻击 ioctls
  (MOVE_RANGE/DEFRAG/PRECACHE/COMPRESS/FIEMAP) 全被 SELinux 封死;
- **shell 域系统性测绘终局**(全部判完):
  | 面 | 判定 |
  |---|---|
  | GPU 内存生命周期 | 加固完善 |
  | GPU 提交链 | 结构性恒拒 |
  | 21385 align | 双路径防御(钳制+禁用) |
  | syncsource UAF | 实现正确+版本不匹配 |
  | F2FS ioctl 族 | SELinux 命令白名单封死 |
- **结论**: 该设备 vendor 防御体系(deferred backport + SELinux 白名单 + 引用计数纪律)
  对 shell 域形成系统性覆盖 — 无公开可达路径;
- **下一会话建议**: ①2026-06+ 新公告轮询 ②kernel 5.4 stable 后续 CVE 轮询 ③非内核面
  (Framework/媒体栈 — 需 app 域) ④若获 root: 全量对比审计复活多线。

## Day 68: ★★★ 决定性发现 —— CVE-2026-52993 (TIPC 双重释放) 本机内核确认可触发
- **情报**: 2026-09 公告 CVE-2026-52993 (Critical 9.8, CWE-415), TIPC 子系统, 网络报文触发;
- **本机配置**: CONFIG_TIPC=y + TIPC_MEDIA_UDP=y + TIPC_DIAG=y 全开; 符号确认
  tipc_buf_append(0x115086d8) / tipc_msg_validate(0x115088e0) 存在;
- **反汇编实锤**: tipc_buf_append LAST_FRAGMENT 路径:
  `bl tipc_msg_validate(&head)`(可重分配: skb_copy 路径已在 0x87e8 确认) →
  `tbz w0 → 0x8890` 错误路径 → `kfree_skb([x19]=*headbuf)` ← **修复补丁的
  `if (head != *headbuf) *headbuf = head;` 重指派缺失** ⇒ 验证失败时双重释放!
- **触发面**: AF_TIPC socket 本地触发**无需特权**; 分片消息(size>MTU) + 构造
  truesize/contents 比例失衡 → validate 内重分配+失败 → double free → 堆喷回收 → 提权;
- **下一步**: ①反汇编 tipc_msg_validate(0x115088e0) 精确重分配/失败条件
  ②AF_TIPC socket PoC(分片消息构造) ③双重释放的堆喷回收策略(skb kmalloc-2k/4k 池)
  ④判定 5.4.281 的 TIPC 分片 MTU 阈值与触发参数;
- **这是 60+ 天研究中首个从 shell 域可达的 Critical 级内核漏洞确认。**

## Day 69: tipc_msg_validate 完全解码 —— 触发条件明确
- **重分配条件**: `truesize / roundup(len, 0x400) ≥ 4` → **skb_copy_expand(head, 144, 2592)**
  → 新 skb 替换 head, 旧 head 被 kfree_skb(validate 内部 [x20] 已更新);
- **失败条件**(返回 0): 消息头尺寸检查失败(hdr 不在 24~60 字节) 或 msg 大小字段不一致
  (多个 cmp: msg size vs truesize vs hdr, 常量 0x1d0/0x10000=464+64K, 0x40 类型位等);
- **validated 标记**: [skb+0x4e] 置 1 后重复验证直接通过(首次触发必须绕过该标记);
- **双重释放路径**(三行闭环):
  ① 分片消息重组 → head truesize/len ≥ 4 → validate 内 skb_copy_expand 重分配(旧 head freed)
  ② 重分配后验证失败 → validate 返回 0
  ③ tipc_buf_append 错误路径 kfree_skb(*headbuf)=旧 freed skb → **DOUBLE FREE**;
- **触发参数方向**: TIPC 分片消息(size > 链路 MTU) + 每片低效 truesize(小片大开销)
  使重组 head 的 truesize/len ≥ 4, 且最后一片的头尺寸/大小字段非法 → validate 失败;
- **下一步**: ①TIPC 分片阈值确认(链路 MTU/最大包) ②AF_TIPC socket 对(本地无特权)PoC
  ③双重 free 的 skb(kmalloc-2k 池)堆喷回收 → 控制流劫持原语评估。

## Day 70: CVE-2026-52993 可达性判定 —— SELinux 封锁 AF_TIPC
- **实测**: socket(AF_TIPC, SOCK_RDM/STREAM) = **EACCES** (shell 域 SELinux 拒绝创建
  TIPC socket — sepolicy 无 AF_TIPC allow 规则);
- unshare(CLONE_NEWUSER|NEWNET) 结果被子进程缓冲丢失(需 setvbuf 重测), 但 **SELinux 不随
  namespace 改变** — 即使 unshare 成功获 CAP_NET_ADMIN, AF_TIPC 创建仍被拒;
- **判定**: CVE-2026-52993 (TIPC 双重释放) 的本地触发面(shell/app 域)被 SELinux socket
  创建过滤封死 — 漏洞代码存在(反汇编实锤)但不可达;
- **剩余可能**: ①app 域测试(需构造 APK — untrusted_app 域 sepolicy 可能同样拒绝)
  ②远程路径: 需确认设备是否存在已配置的 TIPC bearer(perf 见 tipc_nl_add_link 活跃,
  疑有 vendor 守护进程使用 TIPC — 若有 UDP bearer 则远程可达性复活);
  ③root 域: SELinux permissive 或更强权限下可达 — 需先有初始突破;
- **TIPC 线降级为条件性复活**(等 root/新信息)。

## Day 71: App 域探针完成 —— APK 构建链打通 + 域间一致性确认
- **APK 构建链打通**: aapt2+javac+d8+zipalign+apksigner 全流程, poc.apk(33KB, JNI 探针)
  成功安装运行于 untrusted_app 域(坑: d8 需双类同跑; loadLibrary 必需; JNI 头在 NDK sysroot);
- **App 域探针结果**(untrusted_app, 两次运行一致):
  ① socket(AF_TIPC) = **EACCES** — app 域同样被拒(TIPC 线 app 域也死);
  ② MOVE_RANGE = **EACCES** — SELinux ioctl 白名单同样覆盖 app 域(F2FS 线 app 域也死);
  ③ SET_PIN/GET_FEATURES = ENOTTY — 白名单放行但内核未实现;
  ④ **open /dev/kgsl-3d0 = 成功(fd 5/84)** — GPU 设备在 app 域可开(但内存生命周期已证加固);
  ⑤ unshare(USER|NET) = EPERM — 被拦;
- **结论**: app 域与 shell 域的 SELinux ioctl/socket 白名单高度一致 — vendor sepolicy
  对两大低权限域形成同等覆盖, 无新增可达面;
- **CVE-2026-52993/89840 终判更新**: shell + app 域均不可达; 远程 TIPC bearer 与 root 域
  为仅存复活条件;
- **复用资产**: appdapk 构建链(任意 JNI 探针 10 分钟出 APK) — 后续任意域测试即插即用。

## Day 72: ★★★ 里程碑 —— GPU 提交链 app 域全通, in-flight 竞态面复活!
- **实测**(untrusted_app 域, 全链): open ✓ → drawctxt(ctx=26) ✓ → alloc(id=2) ✓ →
  mmap ✓ → get_info(gpuaddr=0x4000030000) ✓ → **submit_commands(0x3d) ret=0 ts=1**
  (GPU 命令真实排队执行!) → **free-after-submit ret=0(接受!)**;
- **对照**: gpu_command(0x4a) 仍 EINVAL(结构体细节差异, 非阻塞);
- **shell vs app 之谜解释**: 提交链仅 app 域通 — shell 的 process_private pagetable
  区间异常为 shell 特有(原因待查, 不重要) — **app 域才是正确的攻击域**;
- **复活面(全部从 app 域可达)**:
  ① alloc → submit(引用 gpuaddr) → **free(被接受)** → 对象在 in-flight 时被释放?
  ② free 后 realloc(spray) → in-flight GPU 命令是否读/写新对象页 = UAF 触发;
  ③ 21385 类生命周期竞态全面重启;
- **下一步**: ①in-flight 窗口测量(submit→free→realloc 时序) ②UAF 触发 PoC:
  submit 引用 obj A → free A → spray obj B(同页) → GPU 写 A 页 = 写 B → 跨对象读写原语
  ③GPU 侧观察手段(INFO/poll/GPU fault)。
- **这是整个研究的关键转折: 从 shell 域全面受阻 到 app 域全链贯通。**

## Day 73: ★★ GPU 任意命令执行原语确认 —— UAF 竞态设计就绪
- **实测**: submit(IB 含 CP_MEM_WRITE) ret=0 → **GPU 执行写命令成功**(A 自页出现
  0xCAFEBABE/0xDEADC0DE marker) ⇒ app 域任意 GPU 命令执行原语打通(选地址/选数据);
- **spray 观察**: free A 后 8 个 B 全部 id=3(idr 槽复用确认), marker 未命中 ⇒ GPU 执行
  (µs 级)快于 free+realloc(ms 级) — 竞态窗口需门控拉长;
- **门控竞态设计(v2)**: IB = [CP_WAIT_REG_MEM(轮询 scratch S_va == 1)] + [CP_MEM_WRITE
  (marker → A_va)]; 流程: submit → free A → spray B(观察 va 复用) → CPU 写 S_va=1(经 mmap)
  → GPU 醒来写 marker → 若 A 的页/ va 已被 B 复用 → **B 中出现 marker = UAF 实锤**;
- **PM4 细节待定**: CP_WAIT_REG_MEM(0x62) 精确格式(a6xx), 或用大量 NOP 链/CP_INDIRECT_BUFFER
  拉长执行; GPU fault 风险可接受(单测);
- **下一步**: ①查 CP_WAIT_REG_MEM a6xx 格式(反汇编驱动中的宏或查 mesa/内核头)
  ②v2 PoC 门控竞态 ③确认 free 后 va 复用规律(free→spray 同 va?)。

## Day 74: v2 设计定稿 —— 1MB NOP 长尾方案(避开未知 PM4)
- **决策**: 放弃 CP_WAIT_REG_MEM(0x62 格式未知 → GPU hang 风险), 改用**大体积 NOP 长尾**:
  alloc 1MB IB 对象 → 填 0x40000 dwords NOP → 末尾 CP_MEM_WRITE(marker → vaA+0x800);
  GPU 执行 256K dwords ≈ 0.5-1ms — 与 free+spray 时序同量级 → 竞态窗口打开;
- **时序**: alloc A(1MB) → mmap 填 NOP+末尾 WRITE(marker→A_va+0x800) → submit →
  立即 free A → 立即 spray B×N(0x1000) → 读 B 内容找 marker;
- **判定分支**:
  marker in B = GPU 写穿到复用页(物理/TLB 级 UAF) = 原语确认;
  marker in A 自映射 = GPU 写在 free 前完成(时序未竞到) → 增大 NOP 量重试;
  GPU fault = IOMMU 已 unmap(防线) → 记录(防御确认);
- **va 复用观察待做**: Day73 free 后 B0 va=0x31000 ≠ A 的 0x30000 — va 池未立即复用,
  需多对象连续 alloc 观察 va 分配顺序;
- **风险**: GPU fault 可接受(单测可恢复); 1MB 对象 mmap 0x100000;
- 下一会话实现 v2 PoC(基于 jni_uaf.c 修改)。

## Day 75: v3 实测 —— IOMMU unmap 防线确认
- **实测**: 1MB IB submit ret=0 → freeA ret=0 → spray 4×1MB(全部 id=3, va=0x4000130000
  固定复用, reuseA=0 — A 的 1MB va 区未复用) → **A 自映射 marker=0, B hits=0**;
- **判定**: free 时 **IOMMU 映射同步拆除** — GPU in-flight 写 vaA 在 unmap 后成为 IOMMU
  fault(无写入、无崩溃、无复用) — 简单时序竞态被 IOMMU unmap 防线封死;
- **推论**: 21385 类 UAF 需要更深的窗口: ①free 与 IOMMU unmap 之间的竞态(提交风暴中
  unmap 延迟?) ②vm/va 泄漏(A 的 1MB 区未复用 — 泄漏特征, 长期累积可耗尽?) ③drawobj
  持有的 gpuaddr 在 unmap 后仍可被重复 submit 引用? ④需要更多 21385 机理情报;
- **工具箱终态**: 全链原语(alloc/mmap/submit/free/get_info/drawctxt) + PM4 写原语 +
  竞态框架 — 全部 app 域即插即用(33KB APK 10 分钟迭代);
- 设备健康(uptime 5:25+, 零异常重启, load 2.72 为测试负载)。

## Day 76: va 复用测量 + 1MB NOP IB 触发 GPU hang(可观测异常!)
- **实测异常**: 1MB NOP IB submit(accepted) → freeA → X-probe(alloc 1MB ×3) → **进程卡死在
  内核 ioctl**(S 状态, wchan 不可读, 数分钟不返回) — force-stop 后恢复, 设备未重启;
- **判读**: ①1MB NOP IB(256K dwords type4 NOP)+free 序列疑似触发 **GPU hang**(dispatcher
  等待线程阻塞 → 后续 ioctl 全部挂起) — 可观测 DoS 异常(负载升至 3.10); ②或 hang 检测器
  未及时介入(vendor hang detect 应 ~2s 重置);
- ** va 复用数据未取得**(进程卡死在测量前) — 下次需加 per-step 输出(每步 addf+单行 Log)
  避免全或无输出;
- **下一步**: ①每步日志版重跑(定位卡死 ioctl) ②若确认为 free→alloc 竞态卡死 = 深入点
  (锁序/等待队列异常) ③CPU 亲和性绑核重试(排除调度因素) ④缩短 NOP 尾(0x100000→0x40000);
- 设备健康: 未重启, force-stop 后恢复, load 回落中。

## Day 77: per-step trace 基础设施 + va 延迟复用确认
- **trace 文件基础设施打通**(addf 双写 out+trace.txt+fflush, run-as 读取) — 解决
  "全或无输出"问题, 每步即写可定位任意卡点(上次卡死复现时即可定位);
- **本轮跑通全程无卡死**(上次的卡死为竞态相关偶发); 完整 trace:
  submit ret=0 → freeA ret=0 → X0/X1/X2(立即同尺寸 alloc×3) va 全=0x4000130000
  (reuseA=0) → B00-B03 同 va → A self-marker=0;
- **判定: va 延迟复用防御确认** — A 的 1MB va 区在 free 后至少 3 个 alloc 周期不复用
  (deferred va release) ⇒ ①③窗口(ref inc→list_add)与 va 立即复用的组合竞态被
  延迟回收机制覆盖;
- **剩余问题**: ①A 的 1MB va 区何时复用(延迟多久?) ②延迟回收的依据(retirement? 定时?)
  ③marker 未出现的原因(GPU 写在 unmap 前完成→自映射应命中 — 但 self=0, 疑 1MB IB
  执行中断/validate 差异 — 需查) — self=0 与 v1(4KB) self=1 的差异是关键线索
  (v1 4KB IB self=1 成功; v2/v3 1MB IB self=0 — 大 IB 行为不同!);
- **下一步**: ①1MB IB 的 submit 是否真的完整执行(v1 4KB vs v2/v3 1MB 对比 — 缩短到
  0x40000 测试) ②大 IB 执行中断/回退机制调查 ③精确复现 v1 成功参数。

## Day 78: v4 紧凑竞态环 500 轮 —— GPU 每轮抢先, free 恒败
- **实测**(4KB IB, NOP×50+WRITE, submit→紧凑 free→spray×2, 500 轮):
  submits=500 全成功, **self=500(每轮 GPU 写回自身都成功)**, bhit=0, free=500;
  last_va=0x30000 恒定(va 不变 — alloc/free 循环复用同一 va 槽!);
- **判定**: ①GPU 执行 55 dwords IB 极快(~µs), 紧凑 free 的 ioctl 往返(~10µs)恒慢于 GPU
  ⇒ free↔unmap 竞态窗口在 4KB IB 下**不可触及**(GPU 每轮抢先); ②va 槽稳定复用
  (0x30000 恒定 — free→alloc 立即复用同槽, 但 GPU 已完成无碍); ③bhit=0 确认无跨对象写;
- **结论**: 4KB IB 太快竞不到, 1MB IB 太大触发 hang/free-抢先-self=0 —
  **窗口在两者之间(需要精确的 IB 长度调谐)**: 让 GPU 执行时间 ≈ free 往返时间;
  v1 数据: 55 dwords self=1(GPU 快); 1MB self=0(free 快+IOMMU 拆除);
  **中间值(如 0x8000 dwords = 32K dwords)可能命中窗口**;
- **下一步**: ⑤IB 长度扫描(0x2000/0x8000/0x20000/0x80000 dwords)找窗口命中点
  (self=0 且 bhit>0 = UAF 实锤);
- 注意: 上个 Day 76 卡死与 1MB IB 的关系待定(本轮 500 轮 4KB 无卡死)。

---

## Day 79（续，09-26 凌晨）: 提交链执行性终审 ⇒ **kgsl 线判死**
逐日主线之外补完的实验族 P0→P21，结论与证据链全部写在
**`KGSL-NOEXEC-P0-20260925.md`**（§8 修正 retire 语义 / §9 legacy dispatcher 与假退休 / §10 hwsched 分支与软退休臂 /
§11 借刀信号与其后被 §12.4 作废的解释 / §12 终局判别与复活条件）。
一句话：**app 经 /dev/kgsl-3d0 可提交、可退休、可分配可映射，但 CP 永不访问我们的 GPU 内存**
（P21 重放驱动自己写的合法命令流仍 2 次后 EAGAIN、marker 不落），
⇒ 不存在 in-flight 窗口，Day 72-78 建立的整条竞态战线关闭。
