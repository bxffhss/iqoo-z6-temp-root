# 逆向项目: kgsl mmap / 派发链

- 启动: 2026-09-16 00:0x
- 目标: 查明"命令进队成功但 GPU 不参与执行"的分界点, 为后续利用铺路
- 前置结论: §AM(黑盒穷举已尽) / §AJ(GPU 从未取过 IB)

---

## 一、工程障碍与已建立的手段

### 1.1 核心障碍: 镜像中绝对指针被清零

| 观察 | 说明 |
|---|---|
| `kgsl_fops` / `kgsl_memstore_vm_ops` 等数据表 | **全为 0 字节**(指针列) |
| `kgsl_ioctl_funcs` 的 `cmd` 列 | **保留**(非指针数据) |
| PE 段头 `.data` | VirtSize 0xd3e000 > RawSize 0x60ca00(差额为 BSS) |
| PE 重定位表 | **不存在**(PtrReloc=0, NReloc=0) |

→ **无法从镜像直接读函数指针表。**

### 1.2 手段: PC 相对交叉引用

`adrp + add` 在镜像中**保留偏移**, 可反查"谁引用了某个符号"。
工具: **`xref.py`**(扫全 `.text`, 解 `adrp+add` 同寄存器对的目标 VA)。

**双锚点确立映射基准**: **`file = VA − 0xffffffc010080000`**(无 +0x1000)
1. PE 段表: `.text` 镜像内偏移 0x1000 ↔ `_stext`(VA 0xffffffc010081000)
2. `kgsl_ioctl_funcs` 是按 nr 索引的稀疏数组 —— 仅在此映射下 `entry[nr]` 的 cmd 与 nr 精确对应(`[2]`=GETPROPERTY, `[7]`=WAITTIMESTAMP_CTXTID)

### 1.3 工具自检(必须做)

```
kgsl_ioctl_funcs     <- kgsl_ioctl+0x58                      ✓
kgsl_property_funcs  <- kgsl_ioctl_device_getproperty+0x80   ✓
```

⚠️ **踩过的坑(两个假阴性根因, 均已修正)**:
- `xref.py` 早期 `FILE_BASE = 0x1000` → 所有 adrp 目标偏 0x1000 → **全部查询返回 0 处引用**(看起来像"目标不存在", 实为工具错)
- `kdump.py` 同类错误(多加 +0x1000, 读到错位区域)

---

## 二、已完成

### 2.1 `kgsl_mmap` 定位 ✅

- **它一直在 kallsyms 里, 只是带哈希后缀**(克隆/outlined 符号):
  `kgsl_mmap$c4b75b2e95fcbe08742d4d7cdee51d5a`, VA **`0xffffffc010a7ee68`**
- 定位方式: `xref.py kgsl_memstore_vm_ops` / `kgsl_gpumem_vm_ops` → 均指向它
- **教训**: 精确匹配符号名会漏掉 `$hash` 后缀的克隆符号

### 2.2 `kgsl_mmap` 关键逻辑 ✅

```asm
00003c  ldr  x2, [x1, #0x98]              ; vma->vm_pgoff
000044  and  x9, x2, #0xfffffffffffff
000048  cmp  x9, 0xfff00                  ; = 0xfff00000 >> 12 (memstore GPU VA)
00004c  b.ne 0xc8                         ; 否 -> 普通对象路径
000054  ldr  x11, [x20, #0x50]            ; vma->vm_flags
000058  tbnz w11, #0x1, 0x190             ; VM_WRITE 置位 -> EPERM 分支
000060  and  x8, x11, #0xffffffffffffffdf ; 清 VM_MAYWRITE
0000a8  add  x10, x10, #0x868             ; vma->vm_ops = &kgsl_memstore_vm_ops
0000ac  mov  w0, wzr                      ; return 0
```

**→ memstore 是"只读可映射"的。**

### 2.3 🎯 新能力: memstore 只读映射 ✅

```
mmap(fd, 0x8000, PROT_READ, MAP_SHARED, offset=0xfff00000)  -> OK
(带 VM_WRITE 的映射 -> EPERM)
```

- **内核分配的 GPU 共享缓冲区只读视图**(0x8000 字节)
- per-context 时间戳槽: 偏移 `ctx * 40`; `soptimestamp`@+0, `eoptimestamp`@+8
- 这推翻了此前"memstore 不可映射"的结论(§AC.4 作废)—— **根因是所有测试都用了读写**

### 2.4 🎯 中心问题判定完成(证明) ✅

用新通道做判别(`kgsl_disc.c`, 每提交后读 `eopt`):

| IB 地址 | sopt | eopt | eopt 推进? |
|---|---|---|---|
| 合法 | 0→1 | 0→1 | 是 |
| **无映射 0xDEAD0000** | 2→3 | 2→3 | **是** |
| **无映射 0x0** | 3→4 | 3→4 | **是** |
| **无映射 0x8000000000000000** | 4→5 | 4→5 | **是** |
| **无映射 0x1000** | 6→7 | 6→7 | **是** |

- 若 GPU 需取 IB, 取不到的地址必然取指故障 → 批次尾部的时间戳包不会执行 → `eopt` 应停滞
- **实测从不停滞, 且恒等于 `sopt`**
- **→ `eoptimestamp` 由内核写, GPU 未参与。§AJ 的推断升级为证明。**

---

## 三、待做(排期)

1. **读派发链** —— 找"命令进队但 GPU 不参与"的分界点:
   - `adreno_dispatcher_queue_context`  `0xffffffc010aec7fc`
   - `dispatcher_queue_context`          `0xffffffc010aec838`
   - `adreno_dispatcher_start`           `0xffffffc010aeca88`
   - `adreno_active_count_get`           `0xffffffc010aac6a8`
2. **继续挖 memstore 布局**: 已可读 GPU 状态, 分析 per-context 槽位 / fault 计数 / 各字段语义
3. **方法沉淀**: "绝对指针被清零 → 用 adrp+add 交叉引用反查函数" 已跑通, 作为后续定位任务的标准手段

---

## 四、工具清单

| 工具 | 用途 |
|---|---|
| `xref.py` | 符号 → 引用点(adrp+add 交叉引用), 已修正 FILE_BASE |
| `dis_symbol.py` | 带符号解析的反汇编(b/l 与 adrp+add 目标自动翻译成符号名) |
| `kdump.py` | 按 VA 转储镜像数据(已修正偏移), 自动把 8 字节解成"符号+偏移" |
| `dis_calib.py` | 映射校准 + 抽取(5 函数 SCS 序言验证) |
| `calib_base.py` / `calib_lmap.py` | 符号基址标定 / 线性映射反推 |
| `perf_kaslr3.c` / `perf_chain.c` | KASLR 采样 / 调用链判定 |
| `kgsl_*.c` (30+ 个) | KGSL ioctl / 提交 / 内存 / 观测 探测组件 |

---

## 五、第二轮: 派发链读取 + memstore 槽位观测

### 5.1 派发链已基本走通(反汇编)

| 函数 | VA | 读到的内容 |
|---|---|---|
| `adreno_dispatcher_queue_context` | `0xffffffc010aec7fc` | 调 `dispatcher_queue_context` 后**立即 `kthread_queue_work`** 唤醒调度线程(`kgsl_driver+0x548`) → **调度确实被触发** |
| `adreno_dispatcher_work$7d27...` | `0xffffffc010aed284` | 主循环: `kgsl_check_timestamp` → **`retire_cmdobj`** → `_adreno_dispatch_check_timeout` → `dispatcher_do_fault` → **`dispatcher_handle_jobs_list`** → `_dispatcher_power_down` |
| `dispatcher_handle_jobs_list` | `0xffffffc010aee5d0` | 取下一个 drawobj 后调用 **`sendcmd`** ← 真正提交到 GPU 的入口 |
| **`sendcmd`** | `0xffffffc010aeec48` | `mutex_lock` 后检查 **`device->0x2b58 != 0 → 返回 -EBUSY`**(门禁; 通常为 0, 不拦); 其余为正常提交流程 |
| `retire_cmdobj` | `0xffffffc010af0484` | **调用 `adreno_get_rptr`** —— 退役判定依赖**环缓冲读指针** |

→ **命令从 ioctl 到 `sendcmd` 的路径是通的; 未发现"直接拒发"分支。**

### 5.2 memstore 槽位观测(新证据)

```
=== 提交前 ===
  全局槽 +0x000: 0 0 0 0 0 0 0 0 28 0     ← 仅 current_context=28
  ctx 槽 +0x460: 0 0 0 0 0 0 0 0 0 0
=== 提交 3 次后 ===
  全局槽 +0x000: 0 0 0 0 0 0 0 0 28 0     ← 全局 sopt/eopt 恒为 0
  ctx 槽 +0x460: 3 0 3 0 0 0 0 0 0 0     ← 只有本 context 槽更新为 3
```

- **全局槽 sopt/eopt 始终为 0**; 只有 per-context 槽被更新。
- **memstore 中存在大量其他 context 的成对非零槽**: `+0x78/+0x80`=51602、`+0xc8/+0xd0`=46076、`+0x118/+0x120`=49923 …(间隔 0x50)—— **系统图形栈进程的 context, 时间戳为大数值**。
- → **系统 GPU 活跃。**

### 5.3 由此产生的张力(必须记录)

- `retire_cmdobj` 依赖 **`adreno_get_rptr`**(环缓冲读指针)—— 若 GPU 完全不消费环缓冲, 退役不应发生; 但我们的提交**每次都退役**。
- 我们的 ctx 槽与系统 ctx 槽**以相同形态更新**(sopt==eopt)。
- 但用 IB 写 memstore 的任何目标(全局 eopt `+0x8`、未用区 `+0x7000`)**全部未被改写**(`kgsl_wr.c`, CP_MEM_WRITE 与 CP_EVENT_WRITE 各编码均试)。

→ **结论从"GPU 完全不参与"细化为: 命令可能进入了环缓冲并被消费, 但 IB 内容未产生任何内存效果。**
→ 矛头重新指向 **CP 侧过滤(CP_PROTECT / 非安全上下文限制)**。
→ ⚠️ 此前"镜像中无 `CP_PROTECT` 字符串 → 该假设不成立"的排除**无效**(宏名不留字符串)。

### 5.4 下一轮具体任务

1. **读 `adreno_ringbuffer_submitcmd`(`0xffffffc010af881c`)** —— kgsl 到底构造了哪些包:
   - 我们的 IB 是否被 `CP_INDIRECT_BUFFER` 引用?
   - 前后插入 preamble / timestamp 包 / 寄存器写?
   - 在 `adreno_ringbuffer_addcmds` / a6xx init 中搜 **0x880–0x8A0 区间的立即数**(CP_PROTECT 寄存器)
2. **判据**: 确认 CP_PROTECT 白名单 → 列出用户 IB 中被允许的命令 → 找可产生可观测副作用的原语
3. **辅助**: memstore 已可作为"可读的写入靶场" —— 任何成功的 GPU 写都会立刻被观测到

---

## 六、第三轮: CP_PROTECT 配置 + 提交包常量(重要判据)

### 6.1 新工具

| 工具 | 用途 |
|---|---|
| `imm_scan.py` | 在 `.text` 中搜"立即数 = 指定寄存器地址"的 MOVZ/MOVN 指令 |
| `dis_range.py` | **任意 VA 区段**反汇编(带符号解析) —— 用于读函数内部深层代码 |

### 6.2 🎯 CP_PROTECT 配置已完整读出

**发现路径**: `imm_scan.py 0x880 0x8A0` → 命中 **`a5xx_start$93afe6...`(12 处)** → `dis_range.py` 读该处代码:

```asm
+00048  mov  w1, #0x8a0            ; CP_PROTECT_CNTL
+0004c  mov  w2, #0x7              ; ★ 值 0x7 → CP_PROTECT 已启用
+00094  adrp x26, ...+0xe18        ; -> a5xx_protected_blocks  ← 白名单数据表
+000c8  add  x8, x26, x25
+000cc  ldp  w21, w9, [x8]         ; 表项 {reg, f1, f2}
+000dc  orr  w8, w9, w8, lsl #24
+000e4  orr  w22, w8, #0x60000000  ; 构造寄存器值
+00100  mov  w1, w21 / mov w2, w22 / blr x8   ; 写寄存器
+000bc  add  x25, x25, #0xc        ; 步长 12 字节
+000c0  cmp  x25, #0xcc            ; 共 17 项
```

**`a5xx_protected_blocks`(`0xffffffc012195e18`)全部 17 项**:

| # | reg | 起始地址(f1<<2) | 控制字节 |
|---|---|---|---|
| 0 | 0x880 | 0x10 | 0x2 |
| 1 | 0x881 | 0x20 | 0x3 |
| 2 | 0x882 | 0x40 | 0x4 |
| 3 | 0x883 | 0x80 | 0x5 |
| 4 | 0x884 | 0x100 | 0x6 |
| 5 | 0x885 | 0x200 | 0x6 |
| 6 | 0x886 | 0x3E000 | 0x4 |
| 7 | 0x887 | 0x3D000 | 0x1 |
| 8 | 0x888 | 0x2000 | 0x6 |
| 9 | 0x889 | 0x2100 | 0x3 |
| 10 | 0x88a | 0x2200 | 0x5 |
| 11 | 0x88b | 0x2A80 | 0x0 |
| 12 | 0x88c | 0x3300 | 0x0 |
| 13 | 0x88d | 0x33C0 | 0x1 |
| 14 | 0x88e | 0x39A0 | 0x3 |
| 15 | 0x88f | 0x39C0 | 0x4 |
| 16 | 0x890 | 0x3A00 | 0x4 |

### 6.3 ⚠️ 但 CP_PROTECT **解释不了**现象

- 表内地址全是**小数值**(0x10 … 0x3E000), 是 **GPU 寄存器偏移**的形态, **不是内存地址**。
- Adreno `CP_PROTECT` 的语义是**限制 `CP_REG_WRITE` 类寄存器写入**的白名单 —— **保护寄存器, 不是内存**。
- → **CP_PROTECT 不是 `CP_MEM_WRITE` 失效的原因。**

### 6.4 🎯 提交包常量: kgsl 自己就在用 CP_MEM_WRITE / CP_EVENT_WRITE

`adreno_ringbuffer_addcmds.llvm.*` 中的 PM4 包常量(`movk` 高位):

| 常量 | 包 |
|---|---|
| `0x7010` | CP_NOP |
| **`0x703d`** | **CP_MEM_WRITE** |
| **`0x7046`** | **CP_EVENT_WRITE** |
| `0x7026` / `0x7092` / `0x70bf` / `0x70df` | 其他 A6xx 包 |
| — | **无 `0x703f`(CP_INDIRECT_BUFFER)** |

**两个重要推论**:
1. **kgsl 自身就使用 `CP_MEM_WRITE` 与 `CP_EVENT_WRITE`** → 这些命令**未被 CP 拦截**。结合 6.3, **"CP 侧过滤"这一假设被排除**。
2. **两段提交代码中都不存在 `CP_INDIRECT_BUFFER`** → kgsl **不使用间接缓冲**, 而是把命令数据**内联**进环缓冲。
   - 这同时解释了 §AJ 的现象: **用户传入的 `cmdlist[i].gpuaddr` 可能根本没被用来取指**, 所以"无映射 gpuaddr 不故障"是**必然的**, 与"GPU 是否执行"无关(该测试的判别力需重新评估)。

### 6.5 下一轮的收敛点

现在问题收敛成一句话: **kgsl 内联进环缓冲的 IB 数据是从哪里取的?**
- 若按 `id` 查 memdesc 取数据 → 我们的内容就是被执行的 → 那 CP_MEM_WRITE 必然生效(矛盾, 需再查)
- 若按用户 `gpuaddr` 取数据 → 无映射地址时应取到垃圾/失败 → 与观测一致

**做法**: 在 `adreno_ringbuffer_submitcmd` 里读"内联拷贝"那一段 —— 看它从哪个结构体字段读源地址、以及拷贝长度如何确定(对应 §AF.6 已读到的 `{offset, gpuaddr, size, flags, id}` 五元组中的哪几个)。`dis_range.py` 已可读该函数任意深度。

---

## 七、第四轮: `adreno_ringbuffer_submitcmd` 内部结构

### 7.1 命令流缓冲区的构造(已读出)

```asm
+00038  bl   kvmalloc_node                     ; 分配命令流缓冲区
+00048  mov  w11, #0x1000
+00050  movk w11, #0xc000, lsl #16             ; w11 = 0xC0001000
+00058  movk w16, #0x7010, lsl #16             ; w16 = 0x70100001 = CP_NOP(count=1)
+00060  movk w10, #0x2ead, lsl #16             ; w10 = 0x2EADEABE  ← 魔数
+00068  csel w9, w11, w16, lo                   ; 按 GPU 型号二选一
+00070  stp  w9, w10, [x0]                      ; ★ 缓冲区前 8 字节 = {前言包, 0x2EADEABE}
+00088  movk w1, #0x703e, lsl #16               ; CP_REG_TO_MEM(opcode 0x3E)
+000b0  str  w9, [x0, #0x8]                     ; 第二个包
```

→ kgsl 先写一段**前言**(`0xC0001000` 或 `CP_NOP` + 魔数 `0x2EADEABE` + `CP_REG_TO_MEM` …), 再拼用户命令。
→ 其中 `CP_REG_TO_MEM(0x3E)` 说明 kgsl 会把**某个寄存器读回内存** —— 与时间戳/指针回读有关。

### 7.2 ⚠️ 关键障碍: 该函数的调用几乎全是**间接调用**

列出 `adreno_ringbuffer_submitcmd` 的**全部直接调用目标**:

```
memset                        ×1
kvmalloc_node                 ×1
adreno_fault_skipcmd_detached ×1
__cfi_slowpath                ×1
```

**仅此四个。** 也就是说:
- **包的发射、用户命令数据的拷贝/引用、环缓冲写入** —— 全部通过 **`blr`(间接调用)** 完成(经结构体函数指针, 并受 CFI 保护)。
- 因此**无法再从 `bl` 直接读出调用图**。

### 7.3 下一步的门槛(诚实评估)

要继续读下去, 必须先**重建相关结构体的字段偏移**, 才能知道每个 `blr` 调的是谁。这需要:
1. 定位 `kgsl_drawobj_cmd` / `kgsl_ringbuffer` / `kgsl_device` 的布局(可从已知字段反推, 如 §AF.6 已得到 cmdobj 的 `{id@0x10, offset@0x18, gpuaddr@0x20, size@0x28, flags@0x30}`);
2. 逐个 `blr` 点解出函数指针来源 → 命名目标函数;
3. 据此找到"用户命令数据从哪里取"。

**这是一项结构体逆向工程**, 每步比前面几轮更慢。

### 7.4 项目累计成果(截至本轮)

| 能力/结论 | 状态 |
|---|---|
| 工具链: 校准映射 / `xref` / `dump` / `dis_symbol` / `dis_range` / `imm_scan` | ✅ 全部可用并互相验证 |
| `kgsl_mmap` 定位 + 逻辑 | ✅ 并据此获得 **memstore 只读映射** |
| 派发链(ioctl→`sendcmd`) | ✅ 读通, 无拒发分支 |
| CP_PROTECT 全部 17 项配置 | ✅ 读出(**但已排除它是原因**) |
| 提交路径 PM4 包常量 | ✅ 确认 kgsl 自身使用 `CP_MEM_WRITE`/`CP_EVENT_WRITE`; **无 CP_INDIRECT_BUFFER** |
| **"IB 内容为何不生效"** | ❌ **未定位** —— 卡在 submitcmd 的间接调用上 |
| 纠正的错误判据 | ✅ §AJ 的"无映射 gpuaddr 不故障"因"无 indirect buffer"而失去判别力 |

---

## 八、第五轮: 命令流里确实写了用户 gpuaddr, 但容错假设也被排除

### 8.1 🔧 新技巧: 用 CFI 桩反查间接调用目标(有效!)

`adreno_ringbuffer_submitcmd` 的 `bl` 只有 4 个, 但存在 `blr`。**CFI 检查会 `adrp+add` 指向目标函数的 `.cfi_jt` 桩**, 因此把 `blr` 的目标暴露出来:

```
$ dis_symbol.py adreno_ringbuffer_submitcmd | grep cfi_jt
  -> a6xx_preemption_post_ibsubmit.cfi_jt     ← 抢占钩子
  -> a6xx_set_marker.cfi_jt                   ← 抢占标记
```

→ **该函数的间接调用只有抢占钩子** → **包的发射与用户数据引用都是内联的, 可以读。**
→ **这是本次会话最有复用价值的新技巧: `grep cfi_jt` 即可列出任意函数的间接调用目标。**

### 8.2 🎯 命令流里确实写入了用户提供的 gpuaddr 与 size

```asm
+00038  ldr  x11 , [x9, #0x20]      ; ★ cmdobj->gpuaddr
+00044  str  w11 , [x10, #0x4]!     ; 写低 32 位
+00074  lsr  x12 , x11, #32
+0007c  str  w12 , [x26, #0x8]      ; 写高 32 位
+00080  ldr  w12 , [x9, #0x28]      ; ★ cmdobj->size
+00090  ubfx w10 , w12, #2, #20     ; size>>2 取 20 位 → 正是 PM4 包头 count 域
+00094  str  w10 , [x26], #0x4      ; 写包头
```

**→ 用户指定的 IB 地址确实被写入命令流, 用于 GPU 取指。**

### 8.3 但"容错掩盖故障"的假设被实测**排除**

若 GPU 真去取指, 无映射地址必然故障; 之前未见故障, 可能被容错机制静默容忍。用 `KGSL_CONTEXT_NO_FAULT_TOLERANCE(0x200)` 重测(`kgsl_faultdet.c`):

| 组 | 步骤 | 结果 |
|---|---|---|
| **关闭容错**(`flags=0x108252`) | 合法提交 / 再提交 | 成功 / 成功 |
| | **无映射 `0xDEAD0000` 提交** | **成功** |
| | 故障后再提交合法地址 | **成功 —— 上下文完好, 未触发故障** |
| 对照(容错开启) | 无映射提交 / 再提交 | 成功 / 成功 |
| 健康检查 | 新建 context / `GPUOBJ_ALLOC` | 正常 |

→ **即便关闭容错, 无映射 IB 也不故障。容错不是解释。**

### 8.4 结论与新的首要嫌疑

- 管线**全段都已被执行**: ioctl → dispatcher 唤醒 → `dispatcher_handle_jobs_list` → `sendcmd` → **命令流里确实写入了我们的 gpuaddr/size**。
- 但 **GPU 侧毫无反应**(无 fault、无内存效果)。
- **新的首要嫌疑: `sendcmd` 的门禁**
  ```asm
  sendcmd:
    0000b8  ldr  w8, [x19, #0x2b58]     ; device 的某个状态标志
    0000bc  cbz  w8, 0x12c             ; 为 0 才继续提交
    0000ec  mov  w22, #-0x10           ; 否则 return -EBUSY (不提交!)
  ```
  → 若 `device+0x2b58 != 0`, `sendcmd` **直接返回 -EBUSY 且不提交**; 而 **ioctl 早已返回 0**(入队成功), 用户侧看不到任何错误。**这与"提交全部成功但 GPU 无反应"的现象完全吻合。**

### 8.5 下一轮任务(明确)

1. **查明 `device+0x2b58` 是什么、由谁置位** —— 这是当前第一嫌疑:
   - 用 `xref`/`dis_range` 找**写 `[x?, #0x2b58]`** 的代码点(需要扫 `str w?, [x?, #0x2b58]`);
   - 判断其语义(电源状态? GMU 状态? 上下文调度器状态?);
   - 判断 shell 能否影响它。
2. 若确认该门禁是关键, 则"能否驱动 GPU"就归结为"能否把该标志清零", 这可能是一个可从 shell 满足的条件 —— **若成立, 整条链将复活**。
3. 备用: 继续用 `grep cfi_jt` 扫 `a6xx_ringbuffer_submit*` 的其余间接调用。

---

## 九、第六轮: `halt_count` 语义确认 + 穷尽式最后一击(零命中)

### 9.1 🎯 新工具: `off_scan.py` —— 按结构体偏移反查读写者

```bash
python off_scan.py 0x2b58 both      # 扫全 .text 中访问该偏移的 LDR/STR
```

命中 11 处, 其中 KGSL 相关 7 处:

| 函数 | 类型 |
|---|---|
| `adreno_dispatcher_unhalt+0xc` | LDR |
| `dispatcher_handle_jobs_list+0xd8` | LDR |
| **`sendcmd+0xb8`** | **LDR(门禁)** |
| `dispatcher_do_fault+0x698 / +0x69c` | LDR / **STR w31(清零)** |
| `adreno_hwsched_complete_replay+0x134` | **STR w31(清零)** |
| `hwsched_sendcmd+0x54` | LDR |

### 9.2 语义确认: 它是**调度器 halt 计数器**

```asm
adreno_dispatcher_halt:
    mov  w8, #0x2b58 ; add x8, x0, x8
    ... stadd w9, [x8]            ; ★ 原子自增
adreno_dispatcher_unhalt:
    ldr  w9, [x0, #0x2b58]
    subs w10, w9, #0x1
    ... casal / stlxr             ; ★ 原子自减
sendcmd:
    ldr  w8, [x19, #0x2b58]
    cbz  w8, 0x12c                ; == 0 才提交
    mov  w22, #-0x10              ; 否则 return -EBUSY(不提交, 但 ioctl 早已返回 0)
```

**→ `device+0x2b58` = 原子 halt 计数; 非 0 时 `sendcmd` 静默不提交。**
**→ 清零点**: `dispatcher_do_fault`(故障处理)与 `adreno_hwsched_complete_replay`(硬件调度重放)。

### 9.3 关于"系统 GPU 是否被 stall"的观察与判断

`kgsl_stall.c`:

```
静默 3 秒 -> memstore 变化槽数 = 0
再静默 3 秒 -> 变化槽数 = 0
自建 20 个 context 并提交 -> 大量槽位 0 -> 1(全部是本次自建 context 的槽)
```

- 静默期确实完全冻结。
- 但 memstore 中那些**大数值槽**(51602 / 46076 / 49923 …, 对应 ctx id 数百至一千多)**在多次运行之间保持完全相同** → 它们是**已销毁 context 的残留**, 不代表当前活跃。
- **故"静默期冻结"不能证明 halt_count > 0**; 若 halt_count 真的 >0, 系统图形栈也会停摆, 与设备可正常使用不符。**该假设未能证实。**

### 9.4 穷尽式最后一击(`kgsl_final.c`)—— 零命中

| 手段 | 覆盖量 | 结果 |
|---|---|---|
| `CP_MEM_WRITE (0x3D)` | 4 个目标(含 memstore 未用槽 / 全局 eopt / 自己对象) | 无 |
| **`CP_REG_TO_MEM (0x3E)`** | **32 个寄存器**(0x0–0x20000 覆盖 CP/GRAS/RBBM 等) | 无 |
| **`CP_EVENT_WRITE (0x46)`** | **40 个事件类型**(0x00–0x4F) | 无 |

- 累计 **76 次提交**, 全部被接受并退役(`sopt == eopt == 76`), **可观测效果为 0**。
- 上下文用 `NO_FAULT_TOLERANCE`; 设备未重启。
- **每个目标都是"可读回"的**(memstore 只读映射), 因此**不存在"写了但看不见"的可能**。

### 9.5 项目的最终结论(本轮)

- **已穷尽所有可从 shell 尝试的"让 IB 生效"手段**, 覆盖 PM4 命令族 / 寄存器读回 / 事件写入 / 目标地址 / context 标志 / 容错设置 / 两条提交路径 —— **零效果**。
- 管线**每一环都已被证实执行**: ioctl → dispatcher 唤醒 → `dispatcher_handle_jobs_list` → `sendcmd` → **命令流里写入了我们的 gpuaddr/size**。
- 但**命令流始终不产生任何 GPU 侧效果**, 且**不是** CP_PROTECT、不是容错、不是缓存、不是 objlist、不是 context 标志、不是 **memstore 可读性**(现已可读)。
- **剩余未验证的唯一环节**: `sendcmd` 之后到"环缓冲写入 GPU"之间的最后一步, 以及 `hwsched` 与 `ringbuffer` 两条路径的实际选择。这需要继续做**结构体与间接调用的逆向**(工作量: 数小时~数天)。

> **诚实评估**: 本项目已把"黑盒可试"的部分做到尽头。剩下的每一环都需要结构体级逆向, 而**不保证最终能通** ——
> 因为可能根本不存在可用的路径(shell 上下文的命令流在这个平台上确实不产生 GPU 效果)。
> **建议**: 保留本项目全部工具与结论; 若要继续, 应视为长期 RE 任务; 若要见效, 换设备(本流水线可低成本迁移)。

---

## 十、第七轮: 路径判定 + 门铃链闭合(回答"最后一步"与"走哪条路")

### 10.1 🎯 路径判定: **走 ringbuffer, 不走 hwsched**

两套并列实现都存在:

| 路径 | 调用链 |
|---|---|
| **ringbuffer** | `dispatcher_handle_jobs_list` **直接 `bl`** `sendcmd` → `adreno_ringbuffer_submitcmd` |
| hwsched | `hwsched_handle_jobs_list` → `hwsched_sendcmd` |

**判定依据**: `dispatcher_handle_jobs_list` 对 `sendcmd` 是**直接 `bl`(无 CFI 桩)**; 而 `dispatcher_handle_jobs_list` 正是已读过的 `adreno_dispatcher_work` 主循环所调用者。`hwsched_sendcmd` 只被 `hwsched_handle_jobs_list` 调用, **不在本链路**。

### 10.2 🎯 门铃链完整闭合(反查调用者得出)

```
adreno_ringbuffer_submitcmd+0xa88 ──→ adreno_ringbuffer_addcmds
adreno_ringbuffer_addcmds+0xa40   ──→ adreno_ringbuffer_wptr      ★ 门铃
```

**完整链路(每一环均已被反汇编证实):**

```
ioctl(GPU_COMMAND)
 → kthread_queue_work 唤醒调度线程
 → adreno_dispatcher_work
 → dispatcher_handle_jobs_list
 → sendcmd
 → adreno_ringbuffer_submitcmd      (命令流写入我们的 gpuaddr/size)
 → adreno_ringbuffer_addcmds
 → adreno_ringbuffer_wptr           ★
 → adreno_gmu_fenced_write(dev, 6, wptr, 1)
 → adreno_regwrite(dev, addr, wptr)   ★★ 真正写入硬件寄存器 CP_RB_WPTR
```

### 10.3 门铃确实按下(最后一环是真写)

```asm
adreno_ringbuffer_wptr:
  00008c  ldr  w2, [x22, #0x10]          ; wptr 值
  000090  mov  w1, #0x6                  ; 寄存器索引 6
  0000a0  bl   adreno_gmu_fenced_write
adreno_gmu_fenced_write:
  000050  ldr  w19, [x8, w1, uxtw #2]    ; 索引 → 实际寄存器地址(查表)
  000054  cmn  w19, #0x3 ; b.hi 0xc4     ; 地址合法性检查
  000094  blr  x24                       ; ★ adreno_regwrite —— 真正执行写
  00009c  tbnz w8, #0x4, 0xcc            ; device->[0x198] bit4 → 栅栏等待分支
```

→ **不是"没写", 而是"写了"。软件侧从 ioctl 到硬件寄存器写, 每一步都有代码级证据。**

### 10.4 最终结论

| 问题 | 答案 |
|---|---|
| 走哪条路径? | **ringbuffer**(hwsched 存在但未用) |
| 最后一步是什么? | `submitcmd → addcmds → **wptr** → gmu_fenced_write → **adreno_regwrite**(写 `CP_RB_WPTR`)` |
| 门铃按了吗? | **按了, 且是真实硬件寄存器写** |
| GPU 响应吗? | **不响应** |
| 断点 | **只可能在硬件/GMU 侧** —— 软件侧已无缺口 |

> **这说明: 从 uid=2000 shell 创建的设备上下文, 其命令流可以走完全部软件链路并把门铃写到硬件, 但 GPU/GMU 侧不产生任何效果。**
> **这是一个平台级隔离, 不是缺失的检查项。** 用户态(无论 uid)没有接口能影响 GMU 对任务的接受。

### 10.5 方法论教训(重要)

- 我在 §8 曾说"`adreno_ringbuffer_submitcmd` 只调用 4 个函数" —— **错的**。原因是 `dis_symbol.py` 的输出被 `sed/head` 截断在 600 条指令(≈0x960 字节), 而调用 `addcmds` 在 **+0xa88**, 被截掉了。
- **教训**: 用"列出全部调用"做结论前, **必须先确认函数的真实长度**(kallsyms 相邻符号可算出), 不要用固定条数截断。

### 10.6 🏁 项目终态

- **能力**: 完整的离线反汇编/交叉引用工具链(`xref` / `dis_symbol` / `dis_range` / `dump` / `imm_scan` / `off_scan` / **`grep cfi_jt`**), 均可用且互相验证。
- **已确证的真成果**: KASLR 攻破; 符号标定; 映射基准修正(纠正 §H 的 0x1000 偏差); 43 个 KGSL handler 实测命名; **memstore 只读映射**(新能力); **IB 边界校验缺失**(代码级 + 双路径); **完整软件链路地图**。
- **未达成**: 临时 root。**断点已定位到硬件/GMU 侧**, 软件侧无缺口。
- **下一步若继续**: 只可能是"从真实图形栈进程借上下文"(需要另一个注入原语)或更换设备。

---

## 十一、第八轮: 门铃的条件分支 + 优先级穷举(§AY)

### 11.1 🎯 `adreno_ringbuffer_wptr` 里有**条件分支**, 存在"不按门铃"的路径

重读该函数开头(此前只看了一半):

```asm
+00002c  ldr  w9, [x19, #0x2b98]      ; device->[0x2b98]
+000030  ldr  x8, [x19, #0x27e8]      ; device->[0x27e8]
+000038  cmp  x8, x22                 ; == 本次提交用的 rb ?
+00003c  cbz  w9, 0x54
+000040  b.ne 0x58
+000044  ldr  w8, [x22, #0x10]
+000048  mov  w9, #0x1
+00004c  strb w9, [x22, #0x518]       ; 只设 rb->[0x518]=1(延迟 kick)
+000050  b    0x5c
+000054  b.eq 0x84                    ; ★ 仅当 (w9==0 且 rb==当前rb) 才走门铃
+000058  ... str w8,[x22,#0x14] ; unlock ; ret   ← 否则**不写门铃**, 直接返回
```

**门铃(`adreno_gmu_fenced_write`)只在 `device->[0x2b98] == 0` 且 `rb == device->[0x27e8]` 时才会写。**

### 11.2 🎯 字段语义(用 `off_scan.py` 反查读写者)

**`device+0x2b98` 只被抢占(preemption)函数读写**:

| 函数 | 操作 |
|---|---|
| `a5xx_preemption_trigger` | STR(置位) ×2 |
| `a5xx_preempt_callback` | STR ×2 |
| `a5xx_preemption_schedule` | LDR |
| `_a5xx_preemption_done` | **STR w31(清零)** |
| `a5xx_preemption_start` | **STR w31(清零)** |
| `_a5xx_preemption_fault` | STR |
| `a6xx_preemption_trigger` | STR ×3(含清零) |

→ **`device+0x2b98` = 抢占状态标志。**
**`device+0x27e8` = "当前 ringbuffer" 指针**(被 `_update_wptr` / `a3xx_rb_start` / `a5xx_rb_start` 等使用)。

→ **假设**: kgsl 按 context 优先级把上下文映射到不同 ringbuffer; 若我们的 context 落在一个**不是"当前"的 ringbuffer** 上, 门铃永不写。

### 11.3 直接验证: 扫 context 优先级 —— **无效**

`kgsl_prio.c`: 扫 `KGSL_CONTEXT_PRIORITY_MASK(bits12-15)` 全部 16 个值, 每个都建 context、提交 `CP_MEM_WRITE` 到 memstore 可读回槽:

```
prio=0..15  flags=0x100012..0x10f012   提交全部 ret=0
→ memstore[0x7000] 始终 0x00000000   **命中 0**
```

→ **优先级不是决定因素; 门铃分支假设未能通过实验证实(也无法从 shell 观测 `device+0x2b98` 的实际值)。**

### 11.4 🏁 本轮为终点(软件侧已无剩余可查点)

- 软件链路**每一环均已反汇编确认**, 包含**最后一步的真实寄存器写**。
- 门铃存在**条件分支**, 其两个依赖字段(`0x2b98` 抢占状态 / `0x27e8` 当前 rb)**均无法从 shell 读写或观测**。
- 所有可通过用户态参数影响的变量(context flags 全字段、优先级全 16 值、IB 地址/大小、容错、路径选择)**已全部穷举**, 无一致效。

**结论**: **临时 root 在本机未达成; 软件侧的调查已到终点。**
剩余只可能是:
1. **从真实图形栈进程借上下文** —— 需要另一个注入原语(即先要有任意代码执行);
2. **更换设备** —— 本项目全部工具与结论可直接迁移。

---

## 十四、第十一轮: 老式分配路径(GPUMEM_ALLOC_ID)—— 亦无效(§BC)

### 14.1 老式分配可用(需要特定 flags)

```
IOCTL_KGSL_GPUMEM_ALLOC_ID (0x34), struct 28B {u64 size; u32 flags; u32 mmapsize; u32 id; u32 pad[2]}
  flags=0x1 → 成功, id=4096(mmapsize=0)
```
注意 **id 段与 GPUOBJ_ALLOC 完全不同**(4096 vs 2/3/4…) → 是另一张对象表。

### 14.2 用分配序列推断 legacy 对象的 gpuaddr(成功)

```
gpuobj(0x45)  → 0x4000030000
legacy(0x34)  → id=4096
gpuobj(0x45)  → 0x4000032000      ← 跳过了一个槽!
=> legacy 对象 gpuaddr = 0x4000031000 (中间槽)
```
**推断与实测吻合, 说明分配序列法有效。**

### 14.3 但提交仍无效果

用该地址 + kgsl 原生包头(`0x703D8003`)+ objlist/无 objlist + 双目标(memstore/对象自身)提交:

```
全部 ret=0, 双通道读回无变化, 命中 0(含对照组)
```

→ **"分配路径差异"也排除。** 老式/新式分配的对象行为一致。

### 14.4 🏁 最终收束(十一轮)

**软件链路每一环都有代码级证据, 且已穷举所有用户态可影响的变量。**

| 已排除(实测) | |
|---|---|
| CP_PROTECT 白名单 | 已读出全 17 项, 语义为寄存器保护 |
| CP 侧过滤 | kgsl 自身就用 CP_MEM_WRITE/CP_EVENT_WRITE |
| 缓存一致性 | IOCOHERENT + msync + madvise |
| objlist / 页表映射 | 20 组矩阵 |
| context flags / 优先级 | 15 组 / 16 值 |
| 容错开关 | NO_FAULT_TOLERANCE |
| **进程域(shell vs app)** | run-as com.termux 对照 |
| 分配路径(gpuobj vs legacy) | 两者对照 |
| PM4 编码 | 含 kgsl 原生 bit15 包头, 7 种形态 |
| IB 地址/大小 | 全越界也无效 |

**最终判定**: 用户态创建的 KGSL 上下文, 命令流走完整个软件链路并完成硬件寄存器写, 但 **GPU/GMU 侧无任何效果**。断点在硬件/GMU 侧, 用户态无接口可触及。

**临时 root 未达成。** 本项目遗留: 完整工具链、13 节文档、30+ 探测源码、KGSL 全地图 —— **换设备可直接复用。**

---

## 十二、第九轮: "从图形栈进程借上下文"实测 —— **路线证伪**(§BA)

### 12.1 入口发现: 设备上装有 **Termux**, 且为 debuggable

```
run-as com.termux id
  → uid=10667(u0_a667)  context=u:r:runas_app:s0:c512,c768
```

**即: 无需注入原语, 就能获得一个 app 域(uid 10xxx)的真实进程** —— 正是"真实图形栈进程"的等价环境(普通 app 的 GPU 使用路径就是这个域)。

且 Termux 自带 `aarch64-linux-android-clang` 工具链, 其 `files/usr/bin` 二进制**可直接执行**(app 数据目录 exec 在该 targetSdk 下可用)。

### 12.2 对照实验: 同一段代码, 两个域各跑一遍(`kgsl_app.c`)

| 步骤 | shell 域 (u:r:shell) | **app 域 (u:r:runas_app, uid 10667)** |
|---|---|---|
| `open("/dev/kgsl-3d0")` | ✓ | ✓ |
| memstore 只读映射 | ✓ | ✓ |
| `DRAWCTXT_CREATE(0x12\|TYPE_GL)` | ✓ | ✓ (ctx=22) |
| `GPUOBJ_ALLOC` + mmap | ✓ | ✓ (gpuaddr=0x4000030000) |
| `GPU_COMMAND` | ret=0 | **ret=0, timestamp=1** |
| `CP_MEM_WRITE` → memstore 槽 | 无效果 | **无效果** |
| ctx 槽 sopt/eopt | 记账推进 | **记账推进(sopt=eopt=1)** |

### 12.3 结论: **路线证伪**

- **app 域的 context 行为与 shell 域完全一致** → 问题**不在"谁提交"**(进程域/uid), 而在**提交本身**。
- "从真实图形栈进程借上下文"在该方向不成立: 借来的上下文和自己的没区别。
- 顺带**排除了一整类"权限/域"假设**: SELinux 域、uid、app 与 shell 的差异都与本现象无关。

### 12.4 🔧 附带修正: `0x70BF8003` 其实是 **CP_INDIRECT_BUFFER**

此前按原始 movk 常量 `0x70bf` 判定"无 CP_INDIRECT_BUFFER" —— **误判**。
正确解码: PM4 type-7 的 opcode 在 **bits[22:16]**(且需 `& 0x7F`):
`(0x70BF8003 >> 16) & 0x7F = 0x3F` = **CP_INDIRECT_BUFFER**, count=3(bit15 为标志位)。

→ **kgsl 确实用 `CP_INDIRECT_BUFFER` 引用用户的 IB, GPU 会真的去取指。**

### 12.5 由此产生的**新的首要假设**(待验证)

**提交时 `numobjs=0`(objlist 为空) → 对象可能未映射进本次提交的 GPU 页表 → GPU 取指必然 fault → 故障被静默丢弃。**

可统一解释: 无映射 gpuaddr 与"自己的对象"表现相同(都 fault/丢弃); 提交全部"成功"且退役(内核记账), 但无任何 GPU 效果。

**验证方法(下一轮)**: 在现有 memstore 观测手段下, 重做"对象入 objlist + `CP_MEM_WRITE` 写该对象自身"的实验(§AM 的 objlist 测试是在 memstore 通道出现**之前**做的, 判读手段不足, 需重做)。

---

## 十三、第十轮: 页表映射假设验证 —— **亦被排除**(§BB)

`kgsl_pagetab.c` —— 在 **memstore 观测通道可用**的前提下, 系统性重做 objlist 实验:

| 矩阵 | 取值 |
|---|---|
| objlist | 无 / 有 |
| objflags | 1 / 2 / 4 / 0x10 / 0x20 / 7 |
| cmdflags | 1 / 2 / 4 / 7 |
| 写入目标 | 自己对象(+0x100) / memstore 槽(+0x7000) |
| IB 长度 | 4 dword / 8 dword |

**共 20 组, 全部 ret=0, 双通道(对象 mmap + memstore)读回均无变化, 命中 0。**

→ **"对象未映射进 GPU 页表"的假设(至少经 objlist 途径)** **被排除。**

---

## 🏁 项目最终收束(全部十轮)

### 软件侧: 完整、闭合、无缺口
```
ioctl → dispatcher 唤醒 → handle_jobs_list → sendcmd
      → adreno_ringbuffer_submitcmd(命令流写入用户 gpuaddr/size)
      → adreno_ringbuffer_addcmds → adreno_ringbuffer_wptr
      → adreno_gmu_fenced_write → adreno_regwrite   ★ 真实硬件寄存器写
```

### 已穷举排除的假设(全部有实测依据)
CP_PROTECT 白名单 · CP 侧过滤 · 缓存一致性(4 种手段) · objlist/页表映射(20 组) ·
context flags(15 组) · context 优先级(16 值) · 容错开关 · **进程域(shell vs app)** ·
两条提交路径 · IB 地址/大小越界 · PM4 全命令族(0x3D/0x3E/0x46/0x58/0x59 × 全参数) ·
设备级计数 · memstore 可读性

### 最终判定
**从用户态(无论 shell 还是 app 域)创建的 KGSL 上下文, 其命令流能走完整个软件链路并完成硬件寄存器写,
但 GPU/GMU 侧不产生任何效果。断点在硬件/GMU 侧, 用户态没有任何接口可以触及。**

### 真实成果(可迁移)
- **工具链**: `xref` / `dis_symbol` / `dis_range` / `kdump` / `imm_scan` / `off_scan` / `grep cfi_jt` 技巧
- **方法**: "绝对指针被清零 → PC 相对交叉引用"; "CFI 桩反查间接调用"; "memstore 只读通道"
- **地图**: KGSL 全部 ioctl handler、派发链、提交链、CP_PROTECT 配置、PM4 包常量
- **文档**: `REVERSE-PROJECT-kgsl.md`(13 节完整记录) + `kernel-lpe-conclusions.md`(证据链) + 30+ 探测源码


---

## 十五、第十二轮: 🔍 tracefs 突破 —— 中央问题精确答案(§BD)

### 15.1 关键入口: **readtracefs 组(3012)使 tracefs 可写**

进程组含 `3009(readproc), 3012(readtracefs)` → `/sys/kernel/tracing/events/kgsl/*` 的 enable **可写**!
可用事件: `adreno_cmdbatch_{queued,submitted,retired,fault,sync}` / `adreno_gpu_fault` / `adreno_drawctxt_*` / `adreno_hw_preempt_*`

### 15.2 🎯 GPU_COMMAND 提交的真相: `submitted_to_rb=0`, flags=MARKER

```
adreno_cmdbatch_retired: ctx=30 ctx_prio=8 ts=1 ... flags=MARKER
    rb_id=2, r/w=130/130, q_inflight=0, dq_id=0,
    submitted_to_rb=0, retired_on_gmu=0     ← 从未提交进环缓冲
```

- `gc.flags=0x2`(我们一直用的值) = **MARKER** → kgsl 当作"标记", 直接走 work queue 退役, **根本不进环缓冲**
- 这解释了此前"retired 但无效果"的全部现象
- 有效 gflags: 0x2 / 0x6 / 0x7 / 0xe(bit1 必须置位); 0x4(CMD)单独 → EINVAL
- 全部变体 trace 均 `submitted_to_rb=0, r/w=130/130`

### 15.3 🎯 0x10(legacy) 路径真的提交了, 而且 GPU 硬故障

```
adreno_cmdbatch_queued:    ctx=30 ts=1 queued=1 flags=none
adreno_cmdbatch_submitted: ctx=30 ts=1 rb_id=2 r/w=38/dd      ← wptr 真的移动!
adreno_cmdbatch_fault:     ctx=30 ts=1 type=hard              ← ★ 硬故障!
adreno_cmdbatch_submitted: ... r/w=38/d6                       ← 恢复后重新提交
adreno_cmdbatch_retired:   ... r/w=d6/d6
```

**→ GPU 确实取指了我们的 IB, 但发生 type=hard 硬故障!**
**→ 结论: 我们的 GPU 对象不在 GPU 的 IOMMU 页表里, 取指即 fault; 故障被恢复流程吞掉并重放/退役。**

### 15.4 差分定位(配合 trace)

- **纯 CP_NOP×4 的 IB 也 hard fault** → fault 在"取指"本身, 不是 CP_MEM_WRITE 的问题
- 第一次 fault 后, 同 context 的后续提交返回 EINVAL(上下文被故障流程置为不可用)

### 15.5 根因与"缺的那块拼图"

**问题不是"GPU 不执行我们的命令", 而是"我们的内存在 GPU 侧不可访问"。**

需要一个 GPU 可映射的缓冲区, 但所有用户态路径均受阻:

| 路径 | 结果 |
|---|---|
| `GPUOBJ_ALLOC(0x45)` 对象 | 不在 GPU 页表(hard fault) |
| `MAP_USER_MEM(0x15) type=ADDR/PMEM` | **EOPNOTSUPP**(已废弃) |
| `MAP_USER_MEM type=ION/DMA_BUF` | 需要 dma-buf fd |
| `/dev/ion` ION_ALLOC | **所有 heap mask(0–31)全部 EINVAL**(含不同 magic/nr/尺寸) |
| `/dev/dma_heap/` | 不存在(5.4 内核) |

### 15.6 结论

- **中央问题已精确定位**: 用户态可以构造并提交命令(legacy 0x10 路径), 但**没有任何办法从 shell/app 域获得一个 GPU 可访问的缓冲区**(ION 被 EINVAL 挡死, ADDR 映射被 EOPNOTSUPP 移除)。
- 这不是"权限不够"这么简单: 即使拿到 app 域, ION 依然 EINVAL —— 这台 vivo 设备的 ion 访问被进一步收紧(或 heap id 编号超出位图范围)。
- **若能解决"GPU 可映射缓冲"这一个问题, 整条链立即复活。**
- 后续: 逆向 /dev/ion 的 heap id 表(从内核镜像数据段反查), 或从已持有 dma-buf 的进程借 fd(需要 SCM_RIGHTS, shell 无)。


---

## 十六、第十三轮: 完整观测下的最终判定

### 16.1 ION 链路打通到最后一米

```
/dev/ion ION_IOC_ALLOC(cmd=0xC0184900, 24B, heap bit0)  -> dma-buf fd
mmap(dma-buf)                                            -> 用户内存
kgsl MAP_USER_MEM(0x15, type=3/DMA_BUF, hostptr=0)       -> gpuaddr=0x4000030000
```

- MAP_USER_MEM 真实布局(反汇编+回填 dump): **gpuaddr 在偏移 8**(不是 32), **type 在偏移 40**(2=ADDR, 3=DMA_BUF, 其他 -> EOPNOTSUPP); type=3 还要求 hostptr==0。

### 16.2 hard fault 依旧 —— 且纯 NOP 的 IB 也 fault

trace 时间线(每次提交):
```
queued -> submitted(r/w=38/dd, wptr 已移动) -> fault(type=hard)
       -> 恢复: resubmit(r/w=38/d6) -> retired(r/w=d6/d6)
```

- **纯 4xCP_NOP 的 IB 也 hard fault** -> fault 发生在**取指阶段**, 与命令内容无关
- MAP_USER_MEM 的 dma-buf 与 GPUOBJ 对象表现相同 -> **GPU 页表里没有我们的任何映射**
- 故障后恢复流程重放并"退役", 但后续提交继续 fault —— 页表始终没有我们的映射

### 16.3 最终判定(基于完整 ftrace 证据链)

**从用户态创建的 KGSL 上下文, 其命令流能走完全部软件链路、真正提交进环缓冲(wptr 移动)、GPU 也开始执行 —— 但在取指阶段因页表缺映射而硬故障, 随后被 kgsl 恢复流程静默吞掉。**

-> 缺的一环: 让 GPU 的页表(或上下文切换序列)包含我们的映射。
-> 这在真实图形栈中由 libGLESv2/Vulkan 驱动的完整初始化序列完成(含 CP_SMMU_TABLE_UPDATE/上下文切换 preamble), 不是单个 ioctl 能补上的。

### 16.4 全部已排除项(13+ 轮实测)

进程域(shell/app) / SELinux / uid / 分配路径(gpuobj/legacy/ION+MAP_USER_MEM) /
PM4 编码(kgsl 原生 bit15 包头, 7 形态) / IB 地址与大小 / objlist(20 组) / context flags(15) /
优先级(16) / 容错 / 缓存(4 手段) / CP_PROTECT / hwsched与ringbuffer / 提交 flags 全变体

### 16.5 项目最终结论

**临时 root 未达成。** 但已把问题从"完全无观测"推进到"逐条提交级别的完整内核侧可视化":
- 能看到每一条提交的 queued/submitted/fault/retired 全过程
- 能看到 ringbuffer 的 r/w 指针移动
- 能看到 fault 类型与恢复流程

**剩余缺口唯一且明确**: 用户态无法让 GPU 的页表包含自己的映射(该映射由图形栈驱动的完整初始化建立)。
若要继续, 需逆向 kgsl 的上下文切换/页表激活序列, 寻找可从用户态触发的激活路径 —— 属长期逆向工作。


---

## 十七、第十四轮: 全事件时间线 —— 确认上下文切换正常, fault 在 GPU 侧执行(§BF)

启用**全部可写的 kgsl 事件**后, 单次提交的完整时间线:

```
adreno_cmdbatch_queued:    ctx=30 ctx_prio=8 ts=1 queued=1
adreno_drawctxt_switch:    rb level=2 oldctx=0 newctx=30    ← ★ GPU 上下文切换正常发生
adreno_cmdbatch_submitted: rb_id=2 r/w=38/dd                ← 已写入环缓冲
adreno_cmdbatch_fault:     ctx=30 ts=1 type=hard            ← GPU 执行阶段硬故障
adreno_drawctxt_switch:    oldctx=0 newctx=30               ← 恢复重放(同样切换)
adreno_cmdbatch_submitted: r/w=38/d6
adreno_cmdbatch_retired:   submitted_to_rb=0                ← 恢复批次退役
(之后设备进入 SLUMBER)
```

- **GPU 上下文切换(newctx=30)正常发生** → 我们的 context 已被 GPU 接受
- 提交进入 ringbuffer(rb_id=2, wptr 移动)
- **fault 发生在 GPU 执行阶段**(取指或更早), type=hard
- 恢复流程重放 → 继续故障 → 最终设备 SLUMBER
- IOMMU/arm_smmu 的 io_page_fault 事件被 vivo 白名单**禁用**(仅 kgsl/adreno 子集可写), 无法看到具体故障地址

### 最终判定(终稿)

**用户态构造的 KGSL 提交, 从 ioctl 到 GPU 上下文切换到环缓冲写入, 全部正常; GPU 开始执行后在取指阶段因页表缺映射而硬故障。**

该页表映射由图形栈驱动的完整初始化(libGLESv2/Vulkan 的 per-context 状态建立)完成, 无法通过单个 ioctl 补上; IOMMU fault 的具体地址也被 tracefs 白名单隐藏。

**临时 root 未达成。** 剩余路径: ① 逆向 kgsl 上下文激活/页表序列(长期); ② 借真实图形栈进程的页表(需要注入); ③ 换设备。


---

## 十八、第十五轮: context 标志全扫 —— 全部同样 fault(§BJ, 终局)

10 种 context 标志(经 0x10 真实提交 4xCP_NOP, ftrace 逐个对号):

| 变体 | 结果 |
|---|---|
| 基线 / +PER_CONTEXT_TS / +NO_FAULT_TOL / +PREEMPT_RB / +PREEMPT_FINE / +INVALIDATE_ON_FAULT / +CTX_SWITCH / +SYNC / +END_OF_FRAME / +0x2000 | **全部: switch(newctx) → submitted(RB2) → fault(type=hard) → 恢复重放** |

**无一变体避免 fault。**

---

# 🏁 项目终局报告

## 最终事实链(全部有代码级/trace 级证据)

1. 用户态(shell 或 app 域)可完成: 打开设备 → 建 context → 分配/映射内存 → 构造 IB → 提交
2. 内核侧全链路执行: ioctl → dispatcher 唤醒 → handle_jobs_list → sendcmd → submitcmd(写环缓冲) → addcmds → wptr(硬件门铃)
3. GPU 侧: 上下文切换到我们的 context(newctx=N) → 开始执行 → **取指阶段硬故障(type=hard)**
4. 恢复流程重放并退役, 但每次提交继续 fault
5. GPU 本身活跃(系统 context 时间戳持续推进)

## 穷举排除清单(全部实测)

进程域(shell/app) · SELinux · uid · 分配路径(gpuobj/legacy 0x34/ION+MAP_USER_MEM type=3) ·
MAP_USER_MEM 全 type(1/2/3) · PM4 编码(kgsl 原生 bit15 包头, 7 形态) · IB 地址/大小 ·
objlist(20 组) · context flags(15 组) · context 优先级(16 值) · context PREEMPT_STYLE ·
容错(INVALIDATE/NO_FAULT_TOL) · 缓存(4 手段) · CP_PROTECT(全 17 项读出) ·
hwsched/ringbuffer 路径 · GPU_COMMAND 全 gflags · syncpoint 全 type/size · 设备计数

## 结论

**这台设备(iQOO Z6 / SM7325 / kernel 5.4.281-qgki / vivo)的 KGSL, 用户态创建的提交在 GPU 执行阶段必然硬故障, 根因位于 GPU/GMU/页表激活的硬件侧机制 —— 用户态没有任何接口可以触及。**

**临时 root 未达成。**

## 可复用资产

- 工具链: `xref.py` / `dis_symbol.py` / `dis_range.py` / `kdump.py` / `imm_scan.py` / `off_scan.py` / cfi_jt 技巧
- 观测: memstore 只读映射 / tracefs KGSL 事件全时间线
- 地图: KGSL 全部 handler、派发链、提交链、CP_PROTECT 17 项配置、PM4 包常量、syncpoint 类型
- 文档: `REVERSE-PROJECT-kgsl.md`(18 节) + `kernel-lpe-conclusions.md` + 40+ 探测源码
- 方法论: 绝对指针清零→PC 相对交叉引用 / CFI 桩反查 / 函数长度必须用 kallsyms 确认


---

## 十九、长期任务第 2 步: 页表切换链完整闭合(§CA)

### 19.1 调用链(反查调用者得出)

```
adreno_drawctxt_switch+0x2a0
  -> adreno_iommu_set_pt_ctx(ctxt, new_pagetable, ...)
      |- [跳过检查] pagetable->[0x18]->[0x40] == 目标页表 ? -> 0x100(跳过)
      |- adreno_iommu_set_pt_generate_cmds(ctxt, cmdbuf, new_pt)
      |     |- pagetable->ops->get_ttbr0(pt)       <- 读新页表的 TTBR0
      |     |- pagetable->ops->get_contextidr(pt)  <- 读 CONTEXTIDR
      |     `- 生成命令流:
      |          { 0x0000000140050e01,                    <- CP_SET_MARKER 类
      |            0x70D3xxxx + TTBR0(lo,hi) + ...,      <- CP_SMMU_TABLE_UPDATE (opcode 0xD3)
      |            0x7013xxxx + 寄存器写(0x4808/0x130...), <- 寄存器编程
      |            0x2EADEABE }                             <- 结束魔数
      `- adreno_ringbuffer_addcmds(ringbuffer, cmdbuf, flags=3)  <- 加入环缓冲
```

### 19.2 关键解码

- **0x70D3 = CP_SMMU_TABLE_UPDATE(opcode 0xD3)** —— 页表切换的核心命令, 载荷含 TTBR0(lo/hi) 与 CONTEXTIDR
- TTBR0/CONTEXTIDR 由 kgsl_iommu_get_ttbr0 / kgsl_iommu_get_contextidr 从新页表读出(经 CFI 间接调用)
- 0x2EADEABE 魔数出现在 set_pt_ctx 的命令流尾部(与 submitcmd 的前言魔数相同)
- 跳过机制: 每个 rb/bank 维护一份"当前页表记录"(ctxt[0x1c] 索引 -> -0x530 步长的关联结构 -> -0x12b8 偏移), 匹配则跳过

### 19.3 与 fault 的关系(逻辑推演)

- 我们的 trace 显示 drawctxt_switch 事件发生 -> switch 路径被走到
- 若未走"跳过"分支 -> 命令流(含 SMMU_TABLE_UPDATE)会生成并提交 -> GPU 应正确切页表
- 但 IB 取指仍 fault -> 两种可能:
  1. CP_SMMU_TABLE_UPDATE 命令在此 GPU 代的编码有偏差(与 PM4 编码问题同类, 但 real app 同代码正常 -> 存疑)
  2. 走过了"跳过"分支 —— kgsl 认为当前页表已是我们的(记录被污染), 实际 GPU 页表不同
- 区分二者需要读 ctxt[0x1c] 索引的关联结构(软件记录), 需内核读能力

### 19.4 页表/上下文激活机制 —— 已建地图

| 组件 | 符号 | 状态 |
|---|---|---|
| 上下文切换入口 | adreno_drawctxt_switch | 已定位(+0x2a0 调 set_pt_ctx) |
| 页表切换构造 | adreno_iommu_set_pt_ctx | 已反汇编(跳过机制/CFI/调用链) |
| 命令流生成 | adreno_iommu_set_pt_generate_cmds | 已反汇编(SMMU_TABLE_UPDATE/TTBR0/CONTEXTIDR/魔数) |
| TTBR0 读取 | kgsl_iommu_get_ttbr0 | 已定位(cfi_jt 确认) |
| CONTEXTIDR 读取 | kgsl_iommu_get_contextidr | 已定位 |
| 页表对象 | kgsl_mmu_createpagetableobject / kgsl_iommu_getpagetable | 已定位 |
| 页表销毁 | kgsl_iommu_destroy_pagetable / kgsl_destroy_pagetable | 已定位 |
| TTBR0 直写 | kgsl_iommu_set_pt | 已定位 |
| ringbuffer 选择 | ctxt[0x1c] 索引 -> -0x530 步长关联结构 -> -0x12b8 偏移 | 已确认存在 |

### 19.5 长期任务的下一步(按优先级)

1. 反汇编 drawobj_add_sync_timestamp 全函数 + kgsl_drawobj_sync_add_sync 的 EINVAL 精确来源 —— 解决"GPU_COMMAND 只能 MARKER"的问题, 让 CMD 类提交可用
2. 重建 struct kgsl_pagetable / struct kgsl_context 布局(从已知字段反推), 从而能在静态反汇编中准确解读所有 ctxt/pt 访问
3. 确认 CP_SMMU_TABLE_UPDATE(0x70D3) 的载荷格式(对照 mesa/freedreno 的 a6xx 定义), 排除编码偏差
4. 若 1-3 完成, 重新审视"页表切换被跳过"假说并设计可观测实验


---

## 二十、联网搜索突破: cheese 框架的正确 KGSL 参数(§BL, 待下一会话验证)

### 20.1 来源

GitHub: [zhuowei/cheese](https://github.com/zhuowei/cheese) — CVE-2025-21479 PoC
基于 Project Zero/Ben Hawkes 的 [Adrenaline](https://googleprojectzero.blogspot.com/2020/09/attacking-qualcomm-adreno-gpu.html)
基于 GitHub Security/Man Yue Mo 的 [adreno_user](https://github.blog/security/vulnerability-research/the-code-that-wasnt-there-reading-memory-on-an-android-device-by-accident/)

### 20.2 与我们的关键差异

| 参数 | cheese(正确) | 我们(之前的) | 影响 |
|---|---|---|---|
| context flags | **0x1812** | 0x108052 | cheese 不设 TYPE_GL; priority=1 |
| MAP_USER_MEM type | **2 = ADDR** | 3 = DMABUF | ADDR 映射 malloc 内存 |
| MAP_USER_MEM fd | **不设(0)** | 设 dma-buf fd | ADDR 类型不需要 fd |
| cmdlist flags | **0x1 (CMDLIST_IB)** | 2 | 正确的 IB 标志 |
| PM4 包头 | **含奇偶校验位** | 无校验 | GPU 可能拒绝无校验包 |
| USE_CPU_MAP | **0x10000000** | 0x8 | GPUOBJ_ALLOC flags |

### 20.3 PM4 包头构造(含奇偶校验)

```c
static inline uint pm4_calc_odd_parity_bit(uint val) {
    return (0x9669 >> (0xf & ((val) ^ ((val)>>4) ^ ((val)>>8) ^ ((val)>>12) ^
        ((val)>>16) ^ ((val)>>20) ^ ((val)>>24) ^ ((val)>>28)))) & 1;
}
static inline uint cp_type7_packet(uint opcode, uint cnt) {
    return CP_TYPE7_PKT | ((cnt) << 0) |
           (pm4_calc_odd_parity_bit(cnt) << 15) |
           (((opcode) & 0x7F) << 16) |
           ((pm4_calc_odd_parity_bit(opcode) << 23));
}
```

### 20.4 MAP_USER_MEM 正确结构(aarch64)

```c
struct kgsl_map_user_mem {
    int fd;                    /* offset 0, size 4 — ADDR 类型时不设 */
    unsigned long gpuaddr;     /* offset 8, size 8 — OUTPUT */
    size_t len;                /* offset 16, size 8 */
    size_t offset;             /* offset 24, size 8 */
    unsigned long hostptr;     /* offset 32, size 8 — INPUT: 用户虚拟地址 */
    enum kgsl_user_mem_type memtype;  /* offset 40, size 4 — 2=ADDR */
    unsigned int flags;        /* offset 44, size 4 */
};
```

### 20.5 memtype 枚举(修正)

| 值 | 类型 | 用途 |
|---|---|---|
| 0 | PMEM | 旧版 |
| 1 | ASHMEM | 旧版 |
| **2** | **ADDR** | **映射任意用户虚拟地址(get_user_pages)** |
| 3 | ION/DMABUF | dma-buf fd |

### 20.6 关键事实

- **cheese PoC 在 A6xx 上正常提交命令**(README: "On Adreno A6xx devices, running this prints: 41414141 42424242")
- **→ cheese 的提交基础设施在 A6xx 上完全可用**
- CVE-2025-21479 仅影响 A7xx(SDS IB_LEVEL=4, `4 & 3 == 0` 绕过特权检查)
- **A6xx 的 SDS 是 IB3, `3 & 3 == 3 != 0` → 特权检查通过, 不受影响**

### 20.7 实测(vivo iQOO Z6)

- `MAP_USER_MEM(type=2/ADDR, hostptr=malloc)` → **EFAULT**("Bad address")
- `get_user_pages` 无法锁定用户页面
- **可能是 vivo 内核限制** — cheese 在 Samsung/Meta Quest 上可用
- **或: 我们的 struct 布局与 vivo 内核的 kgsl 版本不完全匹配**

### 20.8 下一会话待办

1. 下载完整 cheese PoC(`adrenaline.h` + `cheese.c` + `kallsyms_lookup.c`)原样编译运行
2. 若在 vivo 上成功提交 → 逐步替换为我们的参数, 找出差异
3. 若也 EFAULT → 确认 vivo 限制, 尝试通过 ION heap + GPUOBJ_ALLOC + USE_CPU_MAP(0x10000000) 替代
4. 尝试 `GPUOBJ_ALLOC flags = KGSL_MEMFLAGS_USE_CPU_MAP(0x10000000)` — cheese 注释提到"normal user mapping should work as well, it would just need to use uint64_t and drop the flags"

---

## 二十一、第十六轮(§BM): cheese 框架验证 —— **GPU 命令执行链路打通**(2026-09-16)

按 §二十 待办执行, 四条全部闭环, 并产生项目最大突破。

### 21.1 待办执行结果

| 待办 | 结果 |
|---|---|
| 1. 下载 cheese 原样编译运行 | ✅ `cheese/`(adrenaline.h + cheese.c + kallsyms_lookup.c), NDK r27 clang 一遍过 |
| 2. 若可用 → 逐参数对比 | ✅ 找到完整工作配方(见 21.3), 旧失败全部有了解释 |
| 3. 若 EFAULT → 确认 vivo 限制 | ❌ **假设被推翻**: cheese 原版 MAP_USER_MEM(ADDR) 在本机成功(gpuaddr=0x4000030000)。§20.7 的 EFAULT 是我们自己的 struct 布局 bug |
| 4. GPUOBJ_ALLOC+USE_CPU_MAP | alloc 成功但 id=0/无 VA(GPUOBJ_INFO/mmap 均 EINVAL, 需 SET_INFO 绑 VA), **不再需要**(ADDR 已够), 路径关闭 |

### 21.2 cheese 全链在 vivo 的表现

```
kgsl_ctx_create0(0x1812)   → ctx=30 ✅
kgsl_map(ADDR, mmap 页)     → gpuaddr=0x4000030000 ✅ (无 EFAULT!)
GPU_COMMAND(flags=0)        → ret=0 ✅
marker 0x41414141 喷洒页扫描 → "can't find target" ❌
```

marker 不落页与 §20.6 预判一致: A6xx SDS=3, `3&3≠0` → CP_SMMU_TABLE_UPDATE 特权检查不通过被跳过 → 假页表未安装 → marker 写到无映射假 VA。**CVE-2025-21479 仅 A7xx, 本机不可用**(结论维持)。

### 21.3 🎉 工作配方(探针 probe2 实测, 三次执行全部成功, 全程零 fault)

```
ctx      = DRAWCTXT_CREATE(0x13) flags=0x1812        ← prio=1 → rb0(关键!)
内存     = MAP_USER_MEM(0x15) memtype=2(ADDR), hostptr=mmap 页
           (不要用 GPUOBJ_ALLOC/ION 对象 —— 它们在 GPU 页表外, 取指即 fault)
提交     = GPU_COMMAND(0x4A) flags=0(不是 0x2!), cmdsize=32, numcmds=1
           条目 {offset=0, gpuaddr, size, flags=KGSL_CMDLIST_IB(1), id=0}
PM4 包头 = 必须带奇偶校验位(adrenaline.h 的 cp_type7_packet)
缓存     = 提交前对 IB+数据页 cvac 清洗(行必须干净); 读回前 civac
           (v1 曾因脏行被 civac 回写而掩盖成功结果 —— 缓存顺序是生死线)
```

实测结果:
```
[1]  CP_MEM_WRITE → out+0x100 = 0x11111111  <<< GPU 执行成功
[1b] 同 ctx 第二批次                            <<< 执行成功
[2]  CP_MEM_TO_MEM GPU 侧拷贝 0xCAFEBABE        <<< 执行成功
[3]  4xCP_NOP 健康                              <<< 全程 0 hard fault
trace: queued → drawctxt_switch(rb level=0, newctx) → submitted(rb_id=0, r/w=38/dd)
       → retired(recovery=none) —— 无 fault 事件
```

### 21.4 被推翻/修正的旧结论

| 旧结论 | 修正 |
|---|---|
| §AJ/§AO.5 "GPU 从未取过 IB" | **作废**。当时观测的是 0x4A flags=0x2(MARKER)路径(不进 RB)+ 0x10 路径(fault)。真执行路径(flags=0)从未测过 |
| §AM "结构性无法驱动 GPU" | **作废**。软件链路+GPU 执行全部打通 |
| "flags bit1 必须置位"(§十五) | 那是 MARKER(0x2)语义; **flags=0 才是真提交路径** |
| §20.7 "MAP_USER_MEM EFAULT = vivo 限制" | 是我们的 struct 布局 bug; ADDR 映射真实可用 |
| "0x10 与 0x4A 同构" | **0x10 legacy 路径在本机仍 hard fault**(即使 0x1812+ADDR), 只有 0x4A(flags=0) 可用 |

新实测事实:
- cmdlist gpuaddr 无映射(0xDEAD0000) → **hard fault** → 证明 GPU 真取指 0x4A/flags=0 的提交
- hard fault 恢复后同 context 再提交 → **EDEADLK(35)**(context 被故障流程作废)
- retire 行的 `submitted_to_rb=0` 字段与"是否真进 RB"无关, 勿再据此推断

### 21.5 意义与下一步

**中央问题("用户态无法让 GPU 执行自己的命令")已解决。** 由此重开的面:

1. **§AB CVE-2026-21385 重估**: 现在能让 GPU 访问被破坏的 VA(align 溢出 → gpuaddr=0x0 对象) —— 用 CP_MEM_WRITE/MEM_TO_MEM 以 GPU 身份读写该 VA, 观察越界效果。
2. **特权 PM4 面系统枚举**: CP_PROTECT 17 项已读出(§十六轮); 逐个 opcode 实测哪些特权命令(CP_SMMU_TABLE_UPDATE/CP_CONTEXT_REG_WRITE 等)从 IB 可用。
3. **GPU 读别的 VA 区**: 我们的 context 页表内, 用 MEM_TO_MEM 探测 GPU VA 空间布局。
4. GPU 侧执行 + §V 符号地址 → 若找到 GPU 可写内核物理内存的路径(需 SMMU/页表杠杆), 提权链重活。

工具: `cheese/kgsl_cheese_probe.c`(v1, 有缓存顺序 bug 但给出取指判据) / `kgsl_cheese_probe2.c`(v2, 工作配方) / `kgsl_cheese_probe3.c`(USE_CPU_MAP 判定)。

---

## 二十二、§BM 后续三项检查(§BN, 2026-09-16): CVE-2026-21385 重估 / 特权 PM4 枚举 / GPU VA 布局

工具: `cheese/kgsl_tricheck.c`(reach/align/cve/ops/vas) + `cheese/kgsl_tricheck2.c`(wrva/memstore/regs/alignhi/ee)。
canary 故障预言器: 探测 op 后同 ctx 提交已知好 op(CP_MEM_WRITE), 提交失败(EDEADLK)=探测 op 触发 hard fault。

### 22.1 ① CVE-2026-21385 重估 —— 不可武器化(本路径)

- **旧结论修正**: §AB 的 "align 位 (16<<24)/(31<<24) → gpuaddr=0x0" **不是 CVE 的整型溢出**, 而是 **KGSL_MEMFLAGS_USE_CPU_MAP(bit28)** 的正常语义(bit28 置位 → gpuaddr 待绑定, 返回 0)。扫描 align 0..31: 0-15 正常, 16-31 全部 gpuaddr=0 —— 分界线恰在 bit28。
- 高位 flags 实测: bit29/30/31 单独置位 → 正常 gpuaddr; **0xFFFFFFFF → gpuaddr=0xee000000(异常值)**, 但 GPU 侧无后备(写丢弃/读零) —— 仅返回值记账损坏, 不可利用。
- `GPUOBJ_SET_INFO(0x4B)` 反汇编(kgsl_ioctl_gpuobj_set_info, VA 0xffffffc010a7c180): 结构 `{u64 flags(bit0=metadata/bit1=memtype), u64 metadata_ptr, u32 id, u32 metadata_len(≤64), u32 memtype(≤0xff)}` —— **无 va_addr/va_len 字段, 不能由用户绑 VA** → SVM 别名路线关闭(符号 kgsl_mmu_set_svm_region 存在但无用户态入口)。
- ⚠️ 结构体教训: GPUOBJ_ALLOC 正确布局 `{u64 size,flags,va_len,mmapsize; u32 id,metadata_len; u64 metadata}`(id 在偏移 32) —— 之前 probe3 用错布局导致 INFO EINVAL 的假象。
- **结论: CVE-2026-21385 在 GPUOBJ_ALLOC align 路径不可武器化。**

### 22.2 ② 特权 PM4 枚举 —— 获得 GPU 寄存器读原语

| opcode | 名称 | 结果 |
|---|---|---|
| 0x3e | CP_REG_TO_MEM | ✅ **可用!** GPU 硬件寄存器 → 内存读原语 |
| 0x3f | CP_INDIRECT_BUFFER | ✅ IB 链式调用可用 |
| 0x3c | CP_WAIT_REG_MEM | 接受, 不挂死(EQ 立即满足编码) |
| 0x21 | CP_REG_RMW | 对 0x200 无效果(寄存器写被保护/编码待查) |
| 0x53 | CP_SMMU_TABLE_UPDATE | 垃圾 TTBR0 无 fault → **IB1 上不执行**(A6xx 特权检查), 与 cheese SDS 结果互证 |

寄存器读表(真实值): 0x000→0x00000133, 0x200→0x00100001, 0x201→0x00100000, 0x206→0xff330005, 0x210→0x00800006, **0x611→0x76543210, 0x61d→0xdeafbead**(CP scratch/调试标记)。
未解: SMMU 测试轮 out[0x600] 出现一次 0x708a8000 写入(流被误解析的副产物?), 待干净缓冲复测。

### 22.3 ③ GPU VA 布局 —— 未映射数据访问是 RAZ/WI

- 20 个探测 VA(0x0 / 0x1000 / 0x100000 / 0xfc000000 / 0xfff00000 / 0x8000000000 / 0x400000000000 等) + 5 个写读回验 VA: **全部无 fault**。
- 只有本 fd 自己的 VA(0x4000000000+, ib/out/GPUOBJ) 有真实后备(VA 0x4000000000 读回 = 自己的流数据 0x70738005)。
- **未映射 VA: 数据读恒零、写丢弃(RAZ/WI), 无 fault 无恢复** —— 与**取指**行为完全不同(0xDEAD0000 取指 = hard fault)。
- memstore(0xfff00000) GPU 侧读零 → 不在本 context 页表(时间戳由内核写, §AO.5 一致)。
- 推论: CP_MEM_TO_MEM 扫描 VA 只能发现"有数据的映射", 无法区分"映射的零页"与"未映射"; 但无 fault 特性使扫描零风险。

### 22.4 新增原语与下一步

新增: **GPU 寄存器读(3e)** / IB 链(3f) / GPU↔GPU 拷贝 / GPUOBJ 双向可达(推翻"GPUOBJ 不在 GPU 页表")。
下一步: ① REG_TO_MEM 扫 RBBM_STATUS/CP_PROTECT 状态/性能计数器等敏感寄存器(信息面); ② 查 CP_REG_RMW 在非保护寄存器(scratch)上是否可写 → 寄存器写原语; ③ SMMU_TABLE_UPDATE 0x708a8000 异常复测; ④ CP_PROTECT 17 项配置与 REG_TO_MEM 可读范围对表。

---

## 二十三、§BN 后续三项 + 🚀 重大发现: TTBR0 切换可从用户 IB 执行(§BO, 2026-09-16)

工具: `cheese/kgsl_regscan.c`(sweep/rmw/smmu)。寄存器全量 dump: `analysis/reg-sweep-a642.txt`。

### 23.1 🚀 CP_SMMU_TABLE_UPDATE 正确编码 + 从 IB1 可执行(Adrenaline 原语复活)

- **编码修正(第二次修正, 最终版)**: 反汇编 `adreno_iommu_set_pt_generate_cmds`(VA 0xffffffc010b00e10, A642 分支 core≥0x1f4)逐字解码: **`0x70D30004`(count=4) 载荷 {TTBR0_lo, TTBR0_hi, CONTEXTIDR, flags}** —— 首次用 count=3 是误读(stp 双字解码错误), 导致流被误解析、fault 归因错误; 0x53 在 A642 上是别的命令(0x708a8000 异常由此解释)。
- **决定性实测(count=4 正确编码)**: 从 IB1 提交 `0x70D30004 {0xdeadbeef000, 0, 0, 0}` + 后续 CP_MEM_WRITE(RoQ 预取, 数据走新 TTBR0):
  ```
  queued → submitted → adreno_cmdbatch_fault(ctx=30 ts=1 type=hard) → 恢复重放 → retired
  out 写未落地, canary 事后健康(recovery=replay|throttle)
  ```
  实测: MEM_WRITE **未落地** + 恰好 1 个 hard fault → **0xD3 被执行, GPU TTBR0 被切成垃圾值**; 若被特权检查跳过, MEM_WRITE 会正常落地(判据: 落地=跳过, 未落地+fault=切换)。kgsl 恢复重装页表后 context 存活。
- **意义**: A642 固件对 0xD3 **没有 IB 级特权检查**(cheese README 分析的 `and $02,$12,0x3` 检查是 gen7 固件行为) → **Adrenaline 式攻击面在本机完全打开**: 喷伪造页表 → TTBR0 指向受控物理页 → GPU 侧任意物理内存读写 → 内核 patch → root。
- 对照: 0x53 复测(干净缓冲) MEM_WRITE 正常落地(0x53330003) → 0x53 只是吞掉载荷的普通命令, 无 SMMU 行为; 之前 0x708a8000 异常 = 流被 0x53 误解析的瞬态, 不再追。

### 23.2 寄存器读全量 + 写全被拦

- **REG_TO_MEM sweep 0x000-0x8FF 共 2048 个寄存器: 全部可读, 零 fault** —— CP_PROTECT 不拦读(或读保护寄存器返回毒值)。
- **读响应指纹: `0xdeafbead` = 未实现/保护的毒值**(CP 区 0x800+ 几乎全是; 0x611=0x76543210 是 kgsl scratch 初始化值)。
- 真实值亮点: 0x000=0x133, 0x001=0x11f00000, **0x002=0x025828a2(core 600 系)**, 0x200=0x00100001(RBBM_HW_VERSION), 0x206=0xff330005, 0x210, 0x604=0xf0004000。
- **寄存器写全被拦**: TYPE4(CP_REGISTER_WRITE) 与 CP_REG_RMW(0x21) 对 0x611/0x612/0x61d/0x200 全部无效(含 scratch —— kgsl 保护了时间戳 scratch) → 无寄存器写原语。

### 23.3 下一战役: 伪造页表 + TTBR0 切换 = GPU 任意物理内存读写(→root 路线图)

1. **受控物理页**: THP 为 `[madvise]` 模式 → `mmap 2MB 对齐 + madvise(MADV_HUGEPAGE) + MAP_POPULATE` → 物理连续 2MB 页(物理基 2MB 对齐)。RAM ~11.5GB。
2. **喷伪造页表**: 每个 4K 页 = 一份自包含假表(cheese setup_pagetables: L1[1]/L2[2]→ttbr 自指, L3[3]→target_pa, L3[4]→ttbr(marker 自映射), L3[5..20]→target+i*0x1000), 整块 2MB 填 512 份相同表。
3. **探测 B**: 2MB 步进探测候选物理基 B(~5800 个): 提交 `0x70D38003 {B,0,0}` + marker 写(VA 0x40404100) → fault=无效(B 处非我们的表, 取指 fault); **无 fault + marker 落在我们 VA 页 = B 找到**(THP 连续性 ⇒ 表页 phys = B + (VA&0x1FFFFF))。
4. **任意物理读写**: B 已知后, 从 CPU 改写假表的 L3 target_pa(改的是 B 处的同一物理页!) + cvac → GPU 经窗口 VA 读/写任意物理地址。
5. **内核利用**: GPU 窗口扫物理内存找内核映像(ARMd64 魔数) → 定位 swapper_pg_dir/selinux_state/init_cred(§V 符号虚拟地址已知, phys offset 可推) → patch → commit_creds 路线或直接改 creds → root。
风险注记: 每次无效探测 = 一次 hard fault + 恢复(~0.1-0.2s); 探测全程设备可恢复。marker 验证零扫描成本(落在已知 VA 页)。

---

## 二十四、TTBR0 战役第一轮: 编码修正 + 两次全扫零命中(§BP, 2026-09-16)

### 24.1 编码二次修正(关键)

`adreno_iommu_set_pt_generate_cmds` 逐字重解码(A642 分支):
```
stp w9, w20, [x12]        ; [x12]=0x70D30004(hdr count=4!), [x12+4]=ttbr_lo
stp w11, w0, [x12, #0x8]  ; [x12+8]=ttbr_hi, [x12+0xc]=contextidr
str  w10, [x12, #0x10]    ; [x12+0x10]=flags([ctxt+0xa8])
```
→ **正确编码 = `0x70D30004` 载荷 {TTBR0_lo, TTBR0_hi, CONTEXTIDR, flags}**(count=3 是 stp 双字误读)。
count=3 时代的"fault = 切换证据"全部作废 —— count=3 会把后续 MEM_WRITE 头当第 4 载荷吞掉, 流误解析级联产生的 fault 与切换无关。

### 24.2 正确编码下的判别实验(smmu4)

IB = {0x70D30004, 0xdeadbeef000, 0, 0, 0} + MEM_WRITE → **真映射 VA(ib 自身)**:
- 实测: submit=0, ib[+0x800] **未落地**, 恰好 1 个 hard fault。
- 判据: 落地 = 处理器被特权检查跳过; 未落地+fault = 切换执行(TTBR0=垃圾 → 数据 RAZ/WI 丢弃 → 后续取指 fault)。
- **结论: 切换在 IB1 上执行(无特权检查), §BO 成立。** 但注意歧义: 若 RoQ 预取深度不足以覆盖整个 IB, marker 指令可能在 post-switch 预取 fault 时尚未执行 —— 见 24.4 开放问题 1。

### 24.3 全量 B_probe 两次零命中

- sweep3/sweep4: 正确编码, 64 个 2MB THP 块(128MB 喷射, 每块 page0 = 自指假表, sweep4 再按块轮转 8 种 MemAttr), 候选 [0x80000000, 0x380000000) 2MB 步进 6144 个, ~6.1 探测/s。
- **结果: 两次全扫零命中**(sweep4 日志: `analysis/ttbr0-sweep4.log`)。每次探测恰好 1 个 hard fault(16/16、4/4 抽查确认)。
- 假表结构: p[0]=p[1]=p[2]=B|3(start-L0/L1/L2 自指链), p[3]=p[4]=B|attrs(marker: VA 0x40404100 → phys B+0x100)。

### 24.4 开放问题(下一会话按序)

1. **RoQ 预取深度**: marker 指令是否在 switch 后真的执行?(若预取只提前 1-2 条, post-switch 预取 fault 会先杀死批次 → walk 从未被测试)验证法: 构造 IB = {0xD3, marker 写} 且 marker 写在预取窗内的前提下, 用 trace fault 计数 + 时序区分。
2. **walk 结构性失败排查**: start level/TCR.T0SZ/TG 粒度/NS 位。Qualcomm "virtualized SMMU" context bank 步进 0x28(见 arm_smmu_setup_context_bank 反汇编, MAIR 真实值未提取)。
3. **marker 可见性**: NC(idx3) 假设未经证实; 8-attr 轮转已覆盖全部索引仍零命中 → 可见性假设弱化, walk 失败假设强化。
4. **THP 假设**: 物理基 2MB 对齐 + 不迁移; 16 分钟扫描期间 khugepaged/compaction 可能迁移页面。
5. **候选域**: 已扫 [0x80000000, 0x380000000); 未扫 [0x40000000, 0x80000000)。
6. 替代判据: per-probe fault 计数找"无 fault 候选"(= real pgd 特征, walk 成功 → 取指不 fault → 批次干净退役); real pgd 命中可证明 walk 通路。

### 24.5 资产

- `cheese/kgsl_ttbr0.c`: spray/probe/smmu4 一体化工具(含阶段 2/3: B 命中 → 层级重建 → 任意物理读写 → ARMd64 内核基扫描 —— 未触发, 待 B 命中)
- 日志: `analysis/ttbr0-sweep3.log`(count=3 作废), `ttbr0-sweep4.log`(8-attr, 零命中)

---

## 二十五、TTBR0 战役第二轮: v3/v4 探针 + 系统性零命中 + T1/T2 歧义定位(§BQ, 2026-09-16)

### 25.1 v3 探针(块喷洒 marker)

假表 v3: p[0]=p[1]=B|3(自指链, start-L0/L1 兜底), p[2]=B|blk(L2[2] 2MB BLOCK, 规范 bits[1:0]=01), p[3]=B|3, p[6..31]=(B+k*0x1000)|leaf(L3 叶, bit1=0 规范合法); MemAttr 按块轮转 0-7。
IB = switch + 64 发(L2-block 路径, VA 0x4040k000) + 26 发(L3-leaf 路径, VA 0x4060k000), 每发 {magic 精确值, k}。
扫描: 全块精确匹配 0x41414141/0x42424242。

**教训(假阳性)**: 首版扫描模式 0x4141xxxx 与自表描述符 (B+k*0x1000)|0xE41 在 B=0x41400000 时精确撞车(0x41410E41) → 虚假 HIT → 阶段 2 在假 B 上空转。已改精确值匹配(描述符数学上不可能等于 0x41414141/0x42424242, 已验证)。

### 25.2 sweep4/5/7 三轮全扫零命中

- sweep4: v1 表 + 8-attr, [0x80000000, 0x380000000) — 零
- sweep5: v2 表(L2-block), 补扫 [0x40000000, 0x3C0000000) — 零
- sweep7: v3 表(双路径精确 marker), [0x40000000, 0x3C0000000) 7168 候选 — 零(28 分钟)
- 每次探测恰好 1 个 hard fault(抽查 16/16, 4/4, 64/64)。

### 25.3 v4 NOP-sled 时序判别(绕开 marker 可见性)

设计(`cheese/kgsl_ttbr2.c`): 假表把 VA 0x4000001000-1FFF → 物理块内 page5(NOP 雪橇: 0x80000000=type2 NOP + 内嵌 marker MEM_WRITE + CP_INDIRECT_BUFFER 自跳转无限循环)。IB = switch + CIB(跳进雪橇)。
- walk 成功 → CP 落入 NOP 死循环 → 批次挂起 → kgsl ~2s 超时(SLOW=HIT)
- walk 失败 → 取指立即 fault → 快速恢复(~25ms=MISS)
- 全扫 [0x40000000, 0x3C0000000) 7168 候选: 全部 ~25ms, 零挂起 → **walk 失败**(`analysis/ttbr2-sweep1.log`)

### 25.4 结论: T1/T2 歧义 —— 战役的核心未决问题

所有观测与两个假设都相容:
- **T1**: 切换执行, 但 walk 对所有候选失败(假表格式/对齐/粒度仍有错)
- **T2**: **0xD3 handler 在 IB1 级直接保护性报错(protection fault → 批次死)**, 切换从未发生(vivo/A642 固件行为与 cheese 引用的 gen7 "skip" 行为不同; 也与 cheese 的 A6xx 可用声明矛盾 —— 该声明出处薄弱且其喷洒地址是 Quest 专用的)

区分实验均已尝试且不可行(marker 可见性、时序、fault 计数全部两假设相容)。**唯一决定性路径: 反汇编 A642 的 SQE 微码** —— /vendor/firmware 对 shell 关闭; 备选: ① 从 OTA 的 EROFS vendor 提取 a6xx_sqe.fw(需 erofs 工具); ② 从 linux-firmware 下载 a650_sqe.fw(通用版本, 处理器结构可参考但 vivo 版本可能不同); ③ 用 afuc(mesa)或自写 mini 反汇编器解码 0xD3 处理器的特权检查逻辑。

### 25.5 其他观测

- WAIT_REG_MEM(0x3c) 编码未解决: 挂起对照组不挂(24ms) → 编码错误, 内核镜像中无 0x703c 发射点(GMU 时代不用), 需从 mesa adreno_pm4.xml 查
- 8-attr(MemAttr 0-7 轮转)不影响结果 → 属性假设弱化
- THP 64/64 块完整(每轮 smaps 验证)
- 工具: `cheese/kgsl_ttbr2.c`(v4 NOP-sled); 日志: `analysis/ttbr2-sweep1.log`

---

## 二十六、TTBR0 战役第三轮: pgscan + VA 行为测试 → **T1 实锤**(§BR, 2026-09-17)

### 26.1 pgscan(4K 细粒度干净签名扫描)

工具 `cheese/kgsl_pgscan.c`: switch-only 探针({0x70D30004{B,0,0,0}}) + canary-EDEADLK oracle。
- **意外发现: switch-only 批次对 [0x80000000, 0x8003F000) 全部 64 个候选 CLEAN(零 fault)** —— 与 sweep 的"每探测 1 fault"形成鲜明对比。
- 三个数据点联立(switch-only=CLEAN; switch+marker=fault; smmu4=not-landed+fault) → **切换执行后, 批次内后续指令的取指/数据访问在切换后的 TTBR0 下进行** —— 即切换真实生效。

### 26.2 VA 0x40404100 行为测试(无 switch)

`kgsl_pgscan va`: 纯 marker 写(无 switch) × 3 → **全部静默丢弃、零 fault、ctx 存活**。
→ sweep 的每探测 fault **不是** marker 写造成的(无 switch 时它们静默) → **fault 只能来自切换后的取指/walk → T1 实锤: 0xD3 在 IB1 执行且改变翻译**。T2(handler 报错)被否定。

### 26.3 walk 全失败的根因收窄

v5(`cheese/kgsl_ttbr3.c`)已把切换后取指区域(VA 0x4000000000-0x4001FFFFF)全部映射到 NOP 雪橇页, 仍零命中(sweep1/2, `analysis/ttbr3-sweep2.log`)。剩余根因假设:
1. **SMMU TCR 配置不匹配**: TG 粒度(16KB?)、T0SZ、start level —— 我们的 4KB/标准索引可能全错。→ **TCR 常量在内核镜像里**(io-pgtable-arm 初始化或 kgsl_iommu 写 CB_TCR) —— 可离线搜索提取!
2. handler 对 TTBR0 有额外校验(如要求表在特定区域/对齐/内容特征)。
3. descriptor 的某个保留位要求(如 NS/APTable 组合)。

### 26.4 下一轮(按序)

1. **离线提取 TCR**: 在内核镜像搜 io-pgtable-arm 的 TCR 常量(arm_lpae_s1_cfg.tcr 的特征位: TG0=00/IRGN/RGN/ORGN/PS/T0SZ) → 解出真实 TG/T0SZ/start-level → 修正假表索引(若 TG=16KB, L3 索引 = VA[23:14], 全变!)。
2. 修正后重跑 v5 扫描(分钟级)。
3. 若仍零 → SQE 微码 RE(linux-firmware a650_sqe.fw + mini-afuc)。

---

## 二十七、TTBR0 战役第四轮: v5 取指区映射 + TCR 确认 + 仍零命中(§BS, 2026-09-17)

### 27.1 v5 设计(取指区 NOP 化)

`cheese/kgsl_ttbr3.c`: 假表 v5 —— 把切换后取指区域(VA 0x4000000000-0x4001FFFFF)经 pg0[0x100]→pg1[0x100]→pg3/pg4 全部叶子映射到块内 page5 = **PM4 type2 NOP 雪橇 + 自跳转无限循环**(CIB count=504 含自跳转) + 内嵌 marker(VA 0x400001090 → phys B+0x5090)。切换后 CP 落入 NOP 死循环 → 挂起 = HIT; 取指 fault = MISS。

### 27.2 结果

全扫 [0x40000000, 0x3C0000000) 7168 候选: 全部 ~25ms, 零挂起零 marker(`analysis/ttbr3-sweep2.log`)。**v5 与 v3/v4 一致: walk 对所有候选失败。**

### 27.3 TCR 确认(排除配置假设)

arm_smmu_setup_context_bank 反汇编提取 **TCR = 0x38010**: TG0=00(**4KB**)、T0SZ=16(**48-bit, start level 0**)、SH0=11、IRGN/ORGN=00(NC walk)、PS=011。
→ v5 假表的 4KB/start-L0 假设与 SMMU 配置**完全一致**, walk 却仍失败 → 排除"索引/粒度/start-level 配错"假设。

### 27.4 剩余解释(SQE 微码必答)

1. 0xD3 handler 对 TTBR0 有额外校验(读取表内容验证? 检查 NS/区域?)且我们的表不满足其隐含要求。
2. handler 写 TTBR0 到非活动 bank / 需要 kgsl 流中 0xD3 之后的配套包({0x7013, 0x48083101, 1, 1})做提交/TLBI。
3. 微码层面存在对"用户级来源"的隐式拒绝(表面无检查但下游 TLBI/write 被抑制)。

### 27.5 资产与下一步

- 工具: `cheese/kgsl_ttbr3.c`(v5), `cheese/kgsl_pgscan.c`(pgscan/va), `cheese/kgsl_ttbr2.c`(v4)
- 日志: `analysis/ttbr3-sweep1/2.log`
- **下一步 = SQE 微码 RE**(0xD3 handler 的完整逻辑): ① 内核镜像确认 fw 名为 a630/a650/a660_sqe.fw(A642L → a650 家族); ② linux-firmware 拉 a650_sqe.fw 或从 OTA EROFS vendor 提取 vivo 版; ③ 自写 mini-afuc 反汇编(freedreno afuc ISA 文档); ④ 解码 0xD3 handler → 检查逻辑/提交条件 → 修正探测。
- 战略评估: 若 SQE 显示 handler 有不可绕过的来源校验 → 本设备该向量终结; 剩余资产 = 2048 寄存器读面 + 迁移手册 + 全套工具链。

---

## 二十八、🚀🚀 SQE 微码逆向成功: 0x53 handler 完整解码 —— payload[2] = 上下文记录基址(§BT, 2026-09-17)

### 28.1 工具链突破

- 发现 `locus-x64/ida-adreno-qrisc`(Python 版 Adreno CP 微码逆向工具包, MIT) → 拉取 `qrisc_isa_tables.py`(65KB, mesa isaspec 自动生成) + `qrisc_disasm.py` + `qrisc_fw.py` → 本地可反汇编 a6xx SQE 微码。
- **关键更正: 0xD3 不是 opcode!** PM4 type7 opcode 只有 7 位(bits[22:16]), bit23 = 校验位。`0x70D30004` 的真实 opcode = **0x53 = CP_SMMU_TABLE_UPDATE**。SQE 跳转表(0x80 项 @ instrs[0x1eb6]) 0x53 → handler **word idx 0x0a62 (pc 0x1a62)**。
- 跳转表项 = 指令流字索引(非 0x1000 基地址)。

### 28.2 0x53 handler 解码

```
0x1a62: brne $12, 0x0, #0x143e    ← $12(级别状态)≠0 → 走 0x143e "非 RB 实现"(不是拒绝!)
0x1a63: mov $0d, $data            ← payload[0] = TTBR0_lo
0x1a64: mov $0e, $data            ← payload[1] = TTBR0_hi
0x1a65: mov $10, $data            ← payload[2] = 上下文记录基址(★完全受控!)
0x1a66: breq $rem, 0x0, #0x1a69   ← payload[3] → $11 = flags << 10
0x1a74: mov $addr, 0x80 << 24
0x1a78: call #0xa7c               ← SMMU 寄存器编程序列
...
0x1ac9: cwrite $0d, [@REG_WRITE]  ← ★ 我们的 TTBR0 写入 SMMU 寄存器
0x1aca: cwrite $0e, [@REG_WRITE]
0x1a7a (RB路径): waitin
```
**0x143e = 非 RB 级的完整 SMMU 上下文切换实现**(不是错误路径!): 从 $10(记录基址)+0x320/0x354/0x35c/0x3c4/0x688/0x9a8 等 `load` 出全部上下文配置 → 编程 @MEM_READ_ADDR/@MEM_READ_DWORDS(SQE 内存读取引擎) → REG_WRITE 写 SMMU 寄存器(0x8c0/0x8c1/0x8c2/0x88f0/0x9e00/0x9300/0x9100/0x9200...)。

### 28.3 观测统一解释

- switch-only(payload[2]=0) → 0x143e 路径读 SQE 数据空间 0x320+ 区域(零记录) → MEM_READ 编程为空 → 无害 → CLEAN ✓
- switch+marker(payload[2]=0) → 同上 + marker 写走真表静默 → 应 CLEAN — 但 sweep 观测 fault → **说明 payload[2]=0 时 0x143e 路径有副作用(后续段)** — 待分析 400 行全 dump
- sweep 的 fault = 切换后翻译变化(marker 写走候选表 walk 失败) ✓ 与 T1 一致

### 28.4 攻击面(payload[2] 完全受控)

1. **$10 = 任意 SQE 数据空间偏移** → handler 从任意位置 load {64位地址, dword数} → **@MEM_READ 内存读取引擎读任意地址** → 结果 → SMMU 寄存器
2. **RB 路径把 payload[0]/[1] 存入记录** → 若非 RB 路径也有 store → **任意 SQE 数据空间写**
3. 记录里含**真实页表的 TTBR0(物理地址!)** → 读取/利用
4. drawctxt_id 可能就是记录索引 → 跨上下文记录访问

### 28.5 下一步

1. 分析 0x143e 全路径(400 行已 dump 至 /tmp/handler_143e.txt): marker 数据流、payload 存储行为、SMMU 编程序列
2. 实验: payload[2] = drawctxt_id / ctxid±N / 精心构造值, 观测 fault 与 SMMU 状态变化
3. 目标: 控制 {addr, count} → MEM_READ 引擎读任意内存 → SMMU TTBR0 = 我们的数据 → GPU 侧任意物理读写

---

## 二十九、🚀🚀🚀 walk 成功实证 + SQE load/store 引擎暴露(§BU, 2026-09-17)

### 29.1 落点 dump(B=0x40000000, 块 0)

probe(B=0x40000000) 后 dump 块 0 的 0x5000-0x53FF:
- 0x5080-0x508F(sled 原 MEM_WRITE 指令位置) = **被 NOP 覆盖**
- 0x5100-0x510F = ** sled 的 MEM_WRITE 指令 + payload 原样出现**: {0x703D8003, 0x1090, 0x40, ...}
- 0x5118 = 0x41414141 (marker) ✓
- 其余 = NOP 雪橇 ✓

→ **GPU 通过我们的假页表执行了 sled 并产生了内存副作用: sled 尾部从 0x5080 被复制到 0x5100(+0x80), marker 落在复制区。**

### 29.2 解释: SQE load/store 引擎 = GPU 内存拷贝原语

0x143e 路径中的 `load $02, [$04+imm]`(读 SQE 数据空间=记录) + `@LOAD_STORE_HI`/`cwrite $10,[0x11d]` + `call #0x1bf3` 等序列 = **SQE 的 load/store 引擎在 GPU 内存中搬运"上下文记录"**(上下文保存/恢复)。
- 记录基址 $10 = payload[2] = **我们完全控制** → 引擎读写的地址 = 我们选择
- 观测到的 +0x80 复制 = 引擎把sled尾部当作"记录字段"搬运
- **= 任意 GPU 内存读写原语的雏形**(需解码 #0x1bf3/#0x1c1e/#0x1de4 等 helper 的地址空间语义)

### 29.3 当前确定的完整事实链

1. 0x70D30004{ttbr_lo, ttbr_hi, rec_base, flags} 从 IB1 执行(T1 实锤, 多重证据)
2. handler 按 $12 分流: RB 走 0x1a63(RB 实现), 非 RB 走 0x143e(记录驱动实现)
3. 非 RB 实现: 从 rec_base+$off load 上下文配置 → 编程 SMMU/MEM_READ/LOAD_STORE 引擎
4. **rec_base(payload[2]) 完全受控 → 引擎按我们的指针读写 GPU 内存**
5. 实证: probe(B=块0基) → GPU 经假表执行 sled 并产生 +0x80 内存复制 + marker 落地

### 29.6 下一步(利用阶梯)

1. 解码 0x143e 的 load/store helper(#0x1bf3, #0x1c1e, #0x1de4, #0x1cea, #0x1c92, #0x1df1) → 确定地址空间(物理? GPU VA? 数据空间?)与拷贝方向
2. 设计"记录"内容: 在我们的块内构造伪造记录 → payload[2] 指向它 → 引擎按我们的指针搬运 → 任意 GPU 内存读写
3. 若 load/store 地址 = 物理地址 → 直接任意物理读写 → TTBR0 → 内核 → root
4. 0x88 偏移差(0x5118 vs 0x5090)与 +0x80 复制的精确机制 → 反推引擎语义

### 29.7 👑 决定性结论: SQE load/store 数据空间 = 物理地址 → **任意物理内存读写原语成立**

关键证据链:
1. payload[2] = 0x40000000 = **我们 THP 块 0 的物理基址**(非任何 VA) → handler 的 load/store 据此访问了**物理内存**: 我们 sled 的内容(phys B+0x80 起)被引擎按物理地址搬运(0x80→0x100 复制), marker 落地 phys B+0x5118。
2. sled 的 MEM_WRITE(VA 0x400001090) 经假表 walk 落到物理 B+0x5118 → **SMMU walk 用我们的假表成功翻译** ✓
3. 两个位移的一致性: 指令 hdr 0x80→0x100(×2), value 0x8C→0x118(×2) → 引擎按"记录基址×2"或类似语义搬运 → 地址计算完全由 payload[2] 驱动 → **物理地址受控**。

**= 任意物理内存读写原语成立**:
- payload[2] = 任意物理地址 → handler 的 load 序列读该物理地址的内容 → 编程 SMMU/寄存器(可观测)
- RB 路径还会把 payload[0]/[1](我们的 8 字节)存入记录(物理写) → **任意物理写(8字节×多字段)**
- 组合: 先写后读/观测量化 → **任意物理内存 R/W**

### 29.8 → root 的路径(全部构件已就绪)

1. 任意物理读: 扫描物理内存找内核映像(ARMd64) → 内核物理基
2. 读内核 → 定位 selinux_state/init_cred/commit_creds(§V 虚拟地址 + phys offset)
3. 任意物理写: patch(关 SELinux / 改 cred / 覆写 sys_capset 为 commit_creds shellcode)
4. capset() 触发 → uid 0 → root

**此前 29 节的全部"判死"结论围绕"缺物理地址知识"——现在物理地址已是 payload 参数。**

### 29.9 💥 物理地址访问的最终确认(全块扫描诊断)

256 候选诊断运行(全块扫描): **B=0x40000000(候选 0)→ marker 0x41414141 落在块 0 偏移 0x5118**。
- 0x508C(sled 静态 value)与 0x5080(sled 静态 hdr)的内容出现在 **×2 位移处**(0x5118 = 2×0x8C ✓, 0x5100 = 2×0x80 ✓) → **SQE 引擎按 [B+X] → [B+2X] 搬运 —— X 为块内偏移, B = payload[2] = 物理基址**。
- 早期 sweep 的 gate-scan(count=500 无循环 + ms>1200 才扫)错过了已落地的 marker; 修正后(unconditional scan)立即命中。

### 29.10 总结: 完整利用链已打通

| 构件 | 状态 |
|---|---|
| 0xD3(=opcode 0x53) switch 从 IB1 执行 | ✅ T1 实锤(多重证据) |
| payload[2] = 物理地址(记录基址) | ✅ 实证(块 0 物理基 0x40000000 命中) |
| SQE load/store 引擎按 payload[2]+偏移 读写物理内存 | ✅ 实证(×2 复制 + marker 落地) |
| 已知物理地址(我们自己的 THP 块) | ✅ 0x40000000(2MB, CPU 可读写) |
| 任意物理读 | 🔧 需精确解码 helper(#0x1bf3 等)的拷贝语义 |
| 任意物理写 | 🔧 同上(RB 路径的 payload 存储已证实) |
| → 内核扫描 → patch → root | 🔧 构件齐备 |

**本设备"临时 root 不可行"的历史结论正式作废。剩余工作为工程实现细节, 非可行性问题。**

---

## 三十、利用架构定型: "记录 → mem-read → SMMU 编程" 链路 + 分离批次实验(§BV, 2026-09-17)

### 30.1 0x53 handler 的真实语义(微码解码结论)

**0x53 = "从 DRAM 记录恢复 SMMU 上下文银行"**:
- payload[2] = 记录基址(**物理地址, 受控!**)
- handler 从记录+0x320+{0x34/0x38, 0x2c/0x30, 0x24/0x28, 0x1c/0x20, 0x14/0x18, 0x0} load {MEM_READ addr, count} 参数对
- @MEM_READ 引擎按 {addr, count} 读 GPU 内存 → $memdata → SMMU 寄存器(0x8c1/0x8c2 ← $15/$16 等)
- = **SMMU 上下文银行的"从内存恢复"操作**(preemption 上下文切换用)

### 30.2 分离批次实验: marker 未落地

switch 批次与 marker 批次分离 → marker 仍未落地 → **切换的效果 = 批次内有效**(批次结束恢复) 或 **记录字段语义未满足**(TTBR0 编程未发生)。

### 30.3 利用架构(已定型)

```
我们的块(phys B0, CPU 可写):
  [B0+0x10000]  伪造 GPU 页表(GPU VA → 任意物理)  ← CPU 写 PTE
  [B0+0x5000]   sled(切换后执行的指令)
  [B0+0x320+]   伪造"上下文记录"(SMMU 配置: TTBR0=B0+0x10000 等)
数据缓冲(ib_ga VA, 真映射): [ib+off] = SMMU 配置值(mem-read 经 VA 读取)

批次: {0xD3{ttbr, rec=B0+0x320, flags} + CIB → sled(经新表映射)}
→ handler 按记录编程 SMMU(TTBR0=我们的表) → CIB fetch 走新表 → sled 执行
→ marker 经新表映射写任意物理 → 验证 → root 链
```

### 30.4 剩余未知(下一轮)

1. 记录字段的精确语义: 0x320+{0x34/0x38...} = {addr, count} 对 → mem-read 读什么(上下文银行寄存器 shadow 的布局)
2. mem-read 的结果 → SMMU 寄存器的映射($memdata[i] → 0x8c0/0x8c1/0x8c2... = TTBR0/CONTEXTIDR/SCTLR?)
3. TTBR0 之外的字段(SCTLR/MAIR/CONTEXTIDR)的合法值 → SMMU 编程不崩
4. 分离批次的切换生效条件(preemption 触发?)

**资产: 全部工具链 + 微码反汇编 + 物理访问原语(机制层) —— 剩余为记录格式的精确逆向。**

---

## 三十一、helpers 解码: $memdata → SMMU 寄存器直写通道确认(§BW, 2026-09-17)

### 31.1 helper_1de4 = SMMU 状态装载原语

```
mov $08, 0x500 → @REG_READ_ADDR          (SMMU 寄存器读口 = 0x500)
mov $02, 0x1 → @REG_WRITE (reg 0x500 ← 1)
mov $02, 0x540 → @REG_WRITE_ADDR
mov $rem, 0x16                            (22 dwords)
(rep)cwrite $memdata, [@REG_WRITE]        (22 dwords → SMMU 寄存器 0x540-0x597)
```
**$memdata[0..21] → SMMU 上下文银行寄存器组 0x540+ 直写** — $memdata 来自对记录(payload[2]=物理地址)的 mem-read → **完全受控!**

### 31.2 helpers = CP preemption 操作码处理器

0x1cea/0x1c92/0x1bd5/0x1da0/0x1bf3/0x1c1e 均含 `0xfade<<16 | 0xbacX` 签名验证 → **CP preemption 包处理器**(GMU 抢占序列的操作码 handler), PREEMPT_COOKIE 区分。

### 31.3 22-dword SMMU 状态布局

0x540-0x597 = SMMUv2 CB 寄存器组: TTBR0(0x540/0x544?), TCR, MAIR0/1, SCTLR, CONTEXTIDR...
→ 填充: TTBR0 = 我们表物理(0x40010000), TCR = 0x38010(已提取), MAIR0 = 0x44(NC), 其余 = 合法值
→ SMMU 编程 = 我们的配置 → GPU 经我们的页表翻译 → 任意物理 R/W

### 31.4 root 路径(最终)

1. payload[2] = 我们的块(phys 已知) + 记录内容 = {TTBR0=表物理, TCR=0x38010, MAIR0=NC, ...} 22 dwords
2. 0xD3 → mem-read 拉取 → $memdata → helper_1de4 → SMMU = 我们的配置
3. 后续批次: GPU 经我们的表翻译 → 任意物理 R/W → 内核 → root

---

## 三十二、假阳性修正 + 记录格式权威解码 + FADEBACX 魔数家族(§BX, 2026-09-17)

### 32.1 ❗❗ 假阳性修正(互斥验证法)

- kgsl_ttbr3 改用互斥 marker(0xDEADBEEF, 静态仅在指令立即数@0x508C)+精确落点扫描(仅 0x5090) → **marker 未落地**。
- → **§BT "walk 成功"作废**(扫到的是 sled 指令自身立即数)。
- → **find_base 同样假阳性**: fill_probe 静态 pg5[35]=0x41414141@+0x508C, 扫描 0x5000-0x5400 必然 k=0 首轮命中 → **"B0=0x40000000 LIFO 稳定复用"不可信, 块物理基实际未知**。
- 教训: **验证值绝不能与指令立即数/静态填充值相同**; 必须扫"静态为 0"的精确位置。

### 32.2 0x53 handler 记录布局权威解码(handler head 0x243e-0x24e0)

payload[2]($10/$11) = 记录基址。字段(绝对偏移):
- +0x320+{0x34/0x38, 0x2c/0x30, 0x24/0x28, 0x1c/0x20, 0x14/0x18, 0x0c/0x10, 0x00} = 7 组 {MEM_READ addr_lo, count} 对(hi 地址来自 $11)
- **三个内联块被 MEM_READ 直接从记录自身读取**: +0x3c4(40d)→0x1bf3, +0x688(0xc7=199d)→0x1da0, +0x9a8(count 来自 +0x320+0)→0x1e0b
- helper 调用链: 读#1#2→0x1cea($02=0x40); 读#3→0x1c92; 读#4→直写 REG_WRITE(0xbe30/0x9e60/0x8e80)→0x1d44; +0x688→0x1da0→0x1bd5; save 区判非空→读 22d→**0x1de4(SMMU 0x540+ 直写)**; 0x8c2←$16, 0x8c1←$15; 读#5→0x1e0b; 读#6(REG_READ 0x8c0)→0x1c1e; +0x3c4(40d)→0x1c55×2→0x1bf3

### 32.3 FADEBACX 魔数家族(43 处, 生产者+消费者)

- **每个记录数据块以 0xFADEBACX 开头**, helper 校验 $memdata[0], 不过 → 跳 0x2eb3 错误路径(静默放弃) = **此前一切无效果的统一解释**
- 消费者: 0x1cea→BAC9, 0x1c92→BAC8, 0x1d44→BACA, 0x1da0→BAC7, 0x1bd5→BAC5, 0x1c1e→BAC4, 0x1e0b→BAC6, 0x1c55→BAC0+$03 动态, 0x2b46→BACB
- 生产者(save 阶段 0x2600-0x2af5): BAC0@0x2600, BAC5@0x2643, BAC7@0x2669, BAC6@0x26cf, BAC8@0x270d, BAC9@0x2794, BACA@0x27fb, BAC4@0x2a8e, BAC1 动态@0x2ac6, BAC3@0x2af4

### 32.4 BAC0 块 = CP 寄存器文件快照(22 寄存器)

- builder @0x2600: `store $01..$16, $sp, $lr, $rem`(恰好 22 个)+栈转储 → **helper_1de4 写 SMMU 0x540+ 的 22 dwords = CP 寄存器文件快照**
- handler 直写 0x8c1←$15, 0x8c2←$16 印证 $15/$16 = TTBR0 相关联
- **控制链闭合**: 记录块 → mem-read → $memdata → (rep)cwrite 装载 CP 寄存器(0x1cea 写 $37-$3D, regfile 索引后递增) → 保存区 → SMMU 寄存器

### 32.5 关键推论: 记录必须在 GPU VA

- MEM_READ 地址经翻译; payload[2] 此前传物理 0x40000000 → VA 翻译无映射 → mem-read 全失败 → 签名校验不过 → 静默放弃
- **kgsl 抢占记录本来就是 gpuaddr(VA)**; 记录 ~0xA00 字节 → 一个 0x1000 的 ib 映射即够
- 下一步: 用 ib_ga 作记录基址, 每块填正确魔数+最小合法 payload → 先验证 handler 存活(不 brick GPU), 再逐块加数据

---

## 三十三、0x53 handler 入口解码: $12 = IB_LEVEL + RB 直写路径 + 抢占实证(§BY, 2026-09-17)

### 33.1 handler 真入口 = index 0xa62(pc 0x1a62); 跳转表 opcode 0x53 → 0x0a62

```
0x1a62: brne $12, 0x0, #0x143e     ; $12≠0 → 记录路径(0x143e)
0x1a63: mov $0d, $data             ; payload[0]  → TTBR0 lo
0x1a64: mov $0e, $data             ; payload[1]  → TTBR0 hi
0x1a65: mov $10, $data             ; payload[2]
0x1a66: breq $rem,0x0,#0x1a69
0x1a68: shl $11, $data, 0xa        ; payload[3] << 10 = SMMU 上下文银行基址
0x1a99: add $06,$11,0x186 / $08,$11,0xc / $07,$11,0x8 / $0b,$11,0xd / $09,$11,0x1fc / $0a,$11,0x1fd
0x1aa4: call 0xaa9                 ; 寄存器写入序列
```
- **$12 = @IB_LEVEL**(全局搜索确认: `cwrite $12, [$00+@IB_LEVEL]`, 进 IB +1 / 退出 -1)
- → **level 0(内核 RB 级): payload 直写 TTBR0; level ≥1(我们的 IB1): 走记录路径** = A6xx 拒绝 CVE-2025-21479 的微码级根因
- 索引坑: 跳转表值是 **index**(0xa62), 不是 pc(0x1a62); 此前按 index 0x1a62 dump 得到的是数据区(寄存器保存列表 {0x9200,0x1f},{0x9e78,0x100}…)

### 33.2 helper 语义补充

- **0x1da0(BAC7, +0x688 199d 块)**: sig 后 `REG_WRITE_ADDR=(1<<20)|0x90f`, $rem=0x80 → 128 dwords; 再 0x50 → 80 dwords → **批量写寄存器**
- **0x1bd5(BAC5)**: draw state 恢复(DRAW_STATE_SEL/SDS_BASE/SDS_DWORDS/DRAW_STATE_HDR, 循环 0x20×6)
- **0x1cea(BAC9)**: sig 后 `(rep)cwrite $memdata, [$02+0x1]!`($02=0x37, $rem=7) → 写 CP 寄存器 $37-$3D + PERFCNTR_CNTL

### 33.3 真机实证: 抢占确实发生

tracefs 事件(可写!): `adreno_preempt_trigger from id=2 to id=0 cntl=341` + `adreno_preempt_done level=0`; `adreno_drawctxt_switch: rb level=0 oldctx=56 newctx=57`
→ **内核切换就是在 RB level 0 执行 SMMU 更新**(与 33.1 完全吻合); 双 context(0x1812/0x2812)可创建并触发切换

### 33.4 ❗❗ CP_MEM_TO_MEM 只有 1 dword(推翻此前所有"大块扫描")

- 包 = `{opcode(0x73,cnt=5), cntl, dst_lo, dst_hi, src_lo, src_hi}`, **无 size 字段**
- 实测 12 种 cntl(0/1/2/4/0x10/0x40/0x100/0x400/0x1000/0x80000000/0x10000/0x100000) → **恒定拷贝 1 dword**
- **cntl≠0 或 cnt=7 → 提交被拒**(内核/CP 校验); cnt=6 接受但仍 1 dword
- → **此前所有基于 MEM_TO_MEM 的"64KB/1MB 扫描"实际只读到每块首 dword, 结论全部作废**(包括"低 256MB 无记录")
- 修正方案: 一包一 dword, 用 **numcmds>1 的多 IB 条目**批量化(4KB IB ≈ 682 包 ≈ 2.7KB/条)

### 33.5 新工具

- `kgsl_vascan.c` — GPU VA 扫描器(密度测绘+魔数命中), 待按 33.4 改造成 1dword/包多条目版
- `kgsl_m2m.c` — CP_MEM_TO_MEM 语义实测器

### 33.6 下一步(二选一)

- **A(记录路线)**: 修好扫描器 → 找真实记录(FADEBACx) → 复制到自有缓冲 → 改寄存器快照 → 0x53 恢复
- **B(RB 投毒路线, 更短)**: 用 CP_REG_TO_MEM 找 CP_RB_BASE(寄存器扫描已有候选: **REG 0x200=0x00100001, 0x201=0x00100000**, 疑似 WPTR/RPTR; 0x001=0x11f00000) → CP_MEM_WRITE 把 CP_SMMU_TABLE_UPDATE 写入 RB 中 RPTR 前方 → **level 0 执行 → payload 直写 TTBR0 → 任意物理 R/W**

---

## 三十四、CP_RB_BASE 确认失败 + GPU VA 可见性测绘: RB 投毒路线否决(§BZ, 2026-09-17)

### 34.1 CP_RB_BASE 未找到

- REG 0x200 = 0x00100001 → 提交两份 dummy 后变 **0x00000001**(bit20 清零) → **是状态位, 不是 WPTR/RPTR**
- 补扫 0x500-0x57f / 0x900-0x97f: 仅 REG 0x500=0x1, 0x50b=0x2f7fff 可读, 其余整批 submit FAIL(保护)
- 0x800+ 全部 deafbead(保护)

### 34.2 ❗ GPU VA 可见性测绘(页级, 每页读 +0/+0x100/+0x400/+0x800)

| 范围 | 非零页 |
|---|---|
| 0x0 + 64MB | **0 / 16384** |
| 0x100000000 + 64MB | **0 / 16384** |
| 0x3f00000000 + 64MB | **0 / 16384** |
| 0x4000000000 + 8MB | **6 / 2048**(全部是我们自己的 ib + out 缓冲) |

候选点读(0x0/0x100000/0x400000/0x1000000/0xfff00000/0x8000000000) → **全零**; 只有 0x4000000000 返回真实内容。
→ **本 context 的 TTBR0 只映射自己的用户缓冲; RB / memstore / 抢占记录 / 内核全局均在另一条翻译路径(SMMU 私有上下文银行, 对应 0x53 payload[3]<<10 选中的银行)**

### 34.3 结论: 两条路线的生死

- **B(RB 投毒) 否决**: RB 不可读更不可写(CP_MEM_WRITE 同样走 TTBR0) → 无法把 CP_SMMU_TABLE_UPDATE 塞进 RB
- **A(记录路线) 反而被强化**: handler 的 mem-read **读的是 payload[2] 记录内的地址** —— 只要 payload[2] = 我们自己的 ib_ga, 所有读取都落在我们可控内存里 → **不需要 kgsl 的真实记录, 可以完全自造**
- 也解释了此前一切失败: 传物理/全局地址 → 读零 → $memdata[0]=0 → BACx 签名校验失败 → 跳 0x2eb3 静默放弃

### 34.4 新假设(下一轮可直接测)

- **$memdata ↔ CP 寄存器 $01..$16(+$sp/$lr/$rem, 恰 22 个)** —— 证据: helper_1de4 写 SMMU 0x540+ 的 22 dwords 与 BAC0 保存块的 22 寄存器一一对应
- handler 随后 `0x8c2 ← $16, 0x8c1 ← $15`
- → **若把记录首个 mem-read 指向我们自己构造的 ≥22 dword 块, 则 $15/$16 = 我们的 dword[20]/[21] → 直接写入 SMMU 0x8c1/0x8c2**
- 首个块需以 0xFADEBAC9 开头(过 helper_0x1cea 签名), 其后 21 个 dword 自由填充
- 判据: 提交 0x53{rec=ib_ga} 后 GPU 若 hang / 后续批次 fault = SMMU 被改(成功信号); 若安静退役 = 签名未过或未生效

### 34.5 新工具

- `cheese/kgsl_rbfind.c` — 寄存器读+推进测试+候选内存 dump+PM4 打分
- `cheese/kgsl_vamap.c` — GPU VA 页级存在性测绘(注意: IB 4KB 上限, 每批 ≤160 包否则溢出段错误)

---

## 三十五、GPU 提权路线终局判定: 0x53 在 IB1 被丢弃(§CA, 2026-09-17)

### 35.1 错误路径 0x2eb3 = 死循环(重要判据)

```
0x2eb3: jump #0x2eb3     ; 自身死循环
```
→ 任何 FADEBACx 魔数校验失败 ⇒ SQE **永久卡死**(不是"静默放弃", 此前理解错误)。
→ 反推: 若 handler 真运行且记录无效, 必然卡死。**我们从未卡死 ⇒ handler 从未运行。**

### 35.2 决定性实验(kgsl_root3.c)

payload = {ttbr_lo=0, ttbr_hi=0, **rec_lo=rec_ga, rec_hi=0x40**}(正确的 64 位 GPU VA), 记录全在自有 4KB 缓冲:

| 变体 | 首块魔数 | 结果 |
|---|---|---|
| V0 | 0xDEADBEEF(故意错) | submit=0, retire 0ms, **canary1=0xcafebabe 落地, 后续批次正常, GPU 存活** |
| V1 | 0xFADEBAC9(正确) | 同上, 完全静默 |

→ **0x53 包被 CP 静默丢弃, handler 从未进入**(否则 V0 必卡死)

### 35.3 逐一排除的旁路

| 旁路 | 结果 |
|---|---|
| 0x54 / 0x55(SMMU 更新变体) | 入口同为 `brne $12,0x0,#0x143e`, **同样检查 IB_LEVEL, 无漏网** |
| CP 寄存器写(TYPE4 / CP_REG_RMW 0x21) | 全部"未变", 无 fault, **被保护** |
| SMMU 寄存器 0x8c0-0x8c2 | `deafbead` 受保护; **SQE 控制空间 ≠ CP 寄存器空间** |
| RB 投毒 | RB 不在 TTBR0 可见空间(页级测绘 0 命中) |
| 抢占记录自造 | 记录可达但包根本不执行 |
| preamble / CTX_SWITCH gflags | §BJ4 已证: 全部 MARKER |

### 35.4 本设备 GPU 能力的最终边界

- 可执行: 任意非特权 PM4(CP_MEM_WRITE / MEM_TO_MEM(1 dword) / NOP / IB 链 / REG_TO_MEM 读非保护寄存器)
- **不可执行**: 一切特权 opcode(0x53 系列)、一切寄存器写
- **可见内存**: 仅自己的用户映射(TTBR0); RB/memstore/记录/内核全局均在私有上下文银行

### 35.5 结论

**本设备(iQOO Z6 / A6xx / SPL 2024-02)的 GPU 提权路线硬件级封死** —— 与 §BL "A6xx 拒绝 CVE-2025-21479" 一致, 且现已从"推测"升级为"实测确认"。
下一步应转向: ① 内核 5.4.281-qgki 未修 CVE(见 `analysis/kernel-lpe-conclusions.md`) ② 其他子系统(vendor 驱动 / TEE / 音频-DSP / 相机 / NPU) ③ 等待更晚 SPL 之前不再刷 OTA(保持现有 CVE 窗口)
