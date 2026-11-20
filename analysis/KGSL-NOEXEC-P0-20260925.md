# P0 结论: KGSL 提交链从未真正执行过任何 GPU 命令 (Day 79 · 2026-09-25 夜)

> 本文推翻 `HANDOVER-20260925.md` §5.1/§5.2 与 Day 72-78 全部基于 "submit ret=0 ⇒ GPU 在跑" 的推论。
> 实验: `C:/qemu_test/appdapk/jni_p0.c` (P0) / `jni_p0b.c` (P0b) / `jni_p0c.c` (P0c) / `jni_p0d.c` (P0d)
> 构建/运行链已脚本化: `./build.sh <jni_x.c> <native方法名> [trace文件]` + `./read.sh [trace]`

---

## 1. 一句话结论

**app 域下的 kgsl 提交(legacy `SUBMIT_COMMANDS 0x3d` 与现代 `GPU_COMMAND 0x4a`)只在内核里记账, GPU 一步都没执行。**
所有 "GPU 写回/竞态窗口/hang" 结论的前提 (有东西 in-flight) 不成立。

## 2. 证据链 (四个独立判据, 全部阴性)

| # | 判据 | 结果 | 意义 |
|---|---|---|---|
| 1 | **marker 命中** (oracle 已修: 独立目标对象 objT+0x800, 每轮唯一 marker, 提交前 CPU 不读不写, 控制轮全页扫描) | 4 种编码 × 3 轮 = **0 命中**; 控制轮 objT 全 0 (页确实零初始化) | GPU 没写过任何内存 |
| 2 | **timestamp retire** (`READTIMESTAMP 0xc00c0916`, 结构体 `{u32 context_id, u32 type, u32 ts_out}` 由内核 `0xffffffc010a78a54` 反汇编钉死) | 每次 submit 后 **queued=1, retired=0**, 轮询 1s 不变 | 内核自己认为命令没完成 |
| 3 | **`gpubusy` 计数器** (read-to-clear) — 我们整轮实验期间 (含 30+ 次提交与 sleep) | **`0 0`** (busy=0 **且 elapsed=0** ⇒ GPU 时钟根本没起来) | 设备压根没被唤醒 |
| 4 | 正对照: `monkey -p com.android.settings` 触发真图形栈 | **`17941 1449896`** (提交前基线 18978/1011721) | 判据 3 有效, 不是读数问题 |

判据 2 与 3 相互独立, 且 3 有正对照 ⇒ "GPU 未执行" 是实锤, 不是记账误读。

## 3. 顺带纠正的四条既有事实

1. **P0 那次 "第 3 次 submit 起 EAGAIN" 不是队列上限**: 真上限 = **64 个未完成 ts** (P0b: 同一 ctx 连续提交成功 64, 第 65 次 errno=35)。
   P0 之所以第 3 次就 EAGAIN: 每轮 `usleep(500ms)` 让 **hangcheck 把这个"永不 retire"的上下文标坏/排队 unbind**, 之后提交一律 -EAGAIN。
   ⇒ Day 76 的 "进程卡死在内核 ioctl(疑 GPU hang)" 也要重读: 更像**在等一个永不 expires 的 timestamp**, 而非 GPU 挂了。
2. **Day 73 "GPU 任意命令执行确认" 作废** (判据自满足 + 从未 retire)。
3. **交接文档 §6 P2 的 `freememontimestamp` ioctl 号写错**: 真值 = **0x40180917** (`CMDSTREAM_FREEMEMONTIMESTAMP_CTXTID`, 24B, 已在 ioctl 全表); 0xc0300915 是 `MAP_USER_MEM` (厂商全 -95)。
4. **PM4 头编码之争无意义**: 0x703d0002 / 0x903d0004 × 有/无 NOP 填充四种全测, 全 0 命中 —— 不是编码错, 是**没有 CP 在解析**。

## 4. 参数面已扫尽的部分 (P0c, 结论: 不是参数问题)

- `DRAWCTXT_CREATE 0xc0080913` flags 扫描 25 个值: 仅 **0x12 / 0x13** 被接受, 其余 EINVAL; 两种都 q=1/r=0。
- `SUBMIT_COMMANDS` 的 `sc.flags` 扫描 12 个值 (0x0..0x2000): 全部 q=1/r=0。
- `DEVICE_WAITTIMESTAMP_CTXTID 0x400c0907` 结构 = **`{u32 context_id, u32 timestamp, u32 flags}`** (布局2 ret=0/18ms, 布局1 EINVAL)。
  ⚠ 注意它对未 retire 的 ts 也**立即返回 0** ⇒ 此 ioctl 不能当 retire 判据, 别再依赖它。
- `DEVICE_GETPROPERTY 0xc0180902`: 我的结构体布局错(返回 0 但缓冲未被写), 键 3/4/5/10..12/14/16..19/28..31 直接 **ENODEV(19)** ⇒ 该 ioctl 族需要设备处于唤醒态, 待重做布局后重扫。
- `dlopen /vendor/lib64/libgsl.so` ⇒ 被 linker namespace 拒绝 (`clns-4`), `libGLESv2_adreno.so` 也不能直载 ⇒ **不能借用真实驱动**。

## 5. 现代路径 GPU_COMMAND 的可用进展 (P0d, 唯一亮点)

内核 `kgsl_ioctl_gpu_command @ 0xffffffc010a780cc` 反汇编 + libgsl.so `ioctl_kgsl_gpu_command @ 0x1eed18`
(帧槽 sp+0x60 起 64 字节, `mov w3,#0x40` 传大小) 交叉钉出的布局:

```c
struct kgsl_gpu_command {         /* 0x40 = 64B, cmd 0xc040094a */
    unsigned long long flags;     /* +0x00  bit1→SYNC obj, bit10(0x400)→CMD obj */
    unsigned long long ptrA;      /* +0x08 */  unsigned int a10, numA;   /* +0x10,+0x14 (≤100000) */
    unsigned long long ptrB;      /* +0x18 */  unsigned int b20, numB;   /* +0x20,+0x24 (≤100000) */
    unsigned long long ptrC;      /* +0x28 */  unsigned int c30, numC;   /* +0x30,+0x34 (≤32) */
    unsigned int context_id;      /* +0x38 → kgsl_context_get(priv, id) */
    unsigned int ts;              /* +0x3c 输出 (libgsl: ldr w0,[sp,#0x9c] 回取) */
};
struct kgsl_command_object {      /* 24B (libgsl calloc(...,24) 证实) */
    unsigned long long gpuaddr; unsigned long long size; unsigned int id; unsigned int flags;
};
```
实测 (每条独立新 ctx, IB 内容 = 4×CP_NOP 0x70100000):
- **M0** 只填 context_id (三组计数全 0) → **ret=0**, ts=1, q=1/r=0 ⇒ 空 marker 提交被接受。
- **M2** ptrB=对象数组(n=1, size=4, flags=0) → **ret=0** (⇒ B 组是被接受的对象列表); A 组/C 组同样填法 → EINVAL。
- 全部 11 个变体 **r=0, gpubusy 无活动** ⇒ 现代路径同样不执行。

⇒ 布局对了, 但**派活没发生**。剩下的可能性集中在"提交后缺一步触发"或"上下文/RB 归属"上, 见 §6。

## 6. 下一步 (未定, 需选路)

现代路径仍不通, 说明 libgsl 做了而我们没做的**决定性一步**还没找到。候选(按性价比):

1. **顺 libgsl 的真实调用序列**: 它对同一 fd 的 ioctl 顺序里, 我们漏了哪一步? 无 root 条件下可 **syscall 层观测自己的对照进程**不可行 ⇒ 改为静态跟 `ioctl_kgsl_gpu_command` 的**调用方**(谁准备 ptrB 数组、gpuaddr 从哪来、flags=0x400 从哪来), 重点看它是否要求对象由 **GPUOBJ_ALLOC(0xc0300945)/GPUOBJ_IMPORT** 而非 GPUMEM_ALLOC_ID 分配 —— 我们一直用 0x34/0x35 (gpumem) 通道, **很可能现代提交只认 gpuobj 通道的 id**(表 §3 记录旧结论"双 idr 不互通已作废"需要重新检验)。
2. **KGSL_TIMELINE_* (0x58-0x5d)**: 现代提交的 retire 通过 timeline 前进体现; `TIMELINE_CREATE` 零参数即成功(表已记 OK0)。用 `TIMELINE_QUERY/WAIT` 作第三个独立存活判据, 并试 `synclist` 指向 timeline 同步点。
3. **确认设备是否被唤醒**: 重做 `DEVICE_GETPROPERTY` 布局后读 `KGSL_PROP_DEVICE_POWER`/`FEATURES`/`GPU_CMDSUPPORTED`; 若 power 查询在提交期间仍 ENODEV ⇒ 内核从未尝试唤醒 GPU ⇒ 提交被更早的校验挡掉(回到候选 1)。
4. **重启对照** (需用户批准): 排除 Day 76 之后 legacy RB 被 hangcheck/recover 打死的可能。注意 P0c 里"新建 ctx 依然 r=0"+"gpubusy elapsed=0"已使"历史污染"解释很弱, 但成本低可作为终审。
5. 若 1-3 全灭 ⇒ **kgsl 线整体判死**, 回到 §已关闭 列表外的面重开情报扫描。

## 7. 方法论记录 (本轮新增铁律)

- **"ret=0" 永远不等于"生效"**; 任何执行类原语必须先有 **三个独立判据**: 目标内存 marker(唯一值+CPU 不碰) / 内核记账(retire) / 硬件活动(gpubusy), 且必须有一个**正对照**(用真实图形栈制造活动)。
- `gpubusy` 是 read-to-clear 且 **第二个数=elapsed ticks**; elapsed=0 直接证明 GPU 没被唤醒, 比 busy=0 信息量更大。
- shell 域 sysfs 可读面极窄: `/sys/class/kgsl/kgsl-3d0/` 目录列表被拒, 逐个试出仅 `gpubusy`(read-to-clear)、`gpu_model` 可读, `temp`/`devfreq` 权限拒; **dmesg(klogctl EPERM)/debugfs(无 kgsl)/pstore 全不可用** ⇒ 崩溃与执行归因只能靠 ioctl + gpubusy。

---

## 8. ★★ 重要修正与新结论 (P2r / P3t · 2026-09-26 00:40)

### 8.1 本文 §2 判据 2 有错: `readtimestamp` 的 type 枚举用错了
gen7 实际枚举 = **`{CONSUMED = 1, RETIRED = 2}`**（实测 type=0 → -EINVAL，type=1/2 正常返回；
内核 `_rb_readtimestamp @ 0xffffffc010e14628`，CFI typeid 里带 `kgsl_timestamp_type`）。
⇒ 此前所有 "retired=0" **都是读取失败后缓冲未回写留下的零值，不是真的 0**。§2 表判据 2 作废。

### 8.2 重测: **timestamp 确实 retire**
`jni_p2r.c` 6 变体（legacy/现代 × NOP / 0x703d0002 / 0x903d0004）全部 `consumed=1 retired=1`。

### 8.3 但硬件依然没跑 —— `jni_p3t.c` 给出三条更强的否定证据
- **retire 延迟 vs IB 长度**：ndw = 4 / 55 / 0x400 / 0x4000 / 0x20000 / **0x40000(1MB)** ⇒ 延迟恒为
  **16.0–18.5ms**（一个 jiffy，HZ=64），**零标度关系**；
- **非法包体对照**：整块填 `0xDEADBEEF`（非法 packet type）⇒ 同样 ret=0、同样 ~16ms retire、**无故障/无 hang/无 EAGAIN**；
- **硬件活动**：30s / 9 次提交期间 `gpubusy` 每 0.5s 采样，除开机残留外全为 **`0 0`**（GPU 从未上电）；真图形栈正对照 17941~55482 busy ticks。
- marker：仍全 0 命中（oracle 有效：控制轮目标页全 0、marker 每轮唯一）。

### 8.4 判读
**内核接受并"退休"了我们的 drawobj，但从未把它交给硬件。** CP 若真解析过 1MB NOP 流，延迟必随长度增长；
若真解析过 0xDEADBEEF 流，必出包故障。两者皆无 ⇒ 退休是**纯软件定时记账**，无硬件参与。
这也解释了为何 ctx flags（prio bit12-15 × type bit20-24 共 21 组合）、PM4 头、对象通道全不影响结果。

### 8.5 下一个假设与备选战线
- **待验证**：我们的 drawobj 被挂到了不做硬件的环上（gen7 `punctilio` = CPU 侧占位环，软件立即退休，
  特征与观测吻合），真实客户端走 hwsched 的 CB 环。要读 rb 选择逻辑 / `RB_PUNCTILIO` / CB 分配入口，
  确认 app 域上下文能否拿到真 RB。
- **备选（若判死）**：放弃自建提交，改用**本进程内真实 GLES/EGL 负载**制造货真价实的 in-flight GPU 工作，
  再用已完全掌握的 ioctl 层对象生命周期（free / unmap / va 回收）对它打竞态——派活与上电交给厂商驱动，
  我们只需要"同进程 GPU 地址可见性"这一个人手。

---

## 9. Day 79 深夜追加：legacy dispatcher 与"假退休"（P4/P5/P6/P7）

### 9.1 本进程能开真实 GL（新能力，重要）
`jni_p5.c` 里 dlopen+链接 `-lEGL -lGLESv2` 成功：
`GL_VERSION=OpenGL ES 3.2 V@0530.49`，`GL_RENDERER=Adreno (TM) 642L` ⇒ **untrusted_app 可以在自己进程里驱动厂商 GL 栈**（注意：链接期必须真的把 libEGL/libGLESv2 写进 DT_NEEDED，dlopen 取符号不够）。

### 9.2 静态侧定论（子代理，全带地址）
- 本 build 走 **legacy dispatcher，不是 hwsched**：kgsl 段内唯一 ftbl 写点 `0xffffffc010aab884`（x11=adreno_functable）；
  `adreno_queue_cmds@0xaaf9cc` 按 `[[dev]+0x198]` bit7 分流，我们落在 clear → `adreno_dispatcher_queue_cmds@0xaeb598`。
- **退休者是纯软件 sink `_retire_timestamp@0xaee0dc`**：只做 `kgsl_sharedmem_writel([dev+0x40], id*40, ts)` @0xaee13c
  与 `..., id*40+8, ts)` @0xaee158 —— **同一 ts 同时写 consumed 与 retired**，零 MMIO 零上电；
  两个调用者都在 adreno_dispatcher.c 且都不来自中断/HFI：`drawctxt_queue_markerobj@0xaebed0`、
  `_process_drawqueue_get_next_drawobj@0xaeebac`（默认分支直落"head++ 并退休"）。
  ⇒ **timestamp 前进 = 软件记账，不代表执行**。这解释了 P2r 的 `con==r`。
- 读侧 `adreno_readtimestamp@0xaaf950`：type1/2 = `kgsl_sharedmem_readl([dev+0x40], id*40[+8])`，type3 = `context+0x138`
  ⇒ **type 枚举真实取值 {1,2,3}**（0 无效 → 之前 EINVAL 之谜）。
- punctilio 假设作废：全符号表 `punctilio|RB_PUNCTILIO|rb_create|cind|gen7_` 零命中。
- `dev+0x2b58` 是 dispatcher halt **引用计数**（`stadd@0xaed78c` / `subs #1; b.mi@0xaed7b8`），正常渲染时必为 0 ⇒ "门挡住我们"与"系统 UI 在渲染"矛盾。
- **真派发的唯一入口**：type switch `0xaeb870`（判 `[obj+0x10]-1 ≤ 15`）中**只有 `type==1`** 走
  `drawctxt_queue_cmdobj@0xaeb8a8 → sendcmd@0xaeec48 → adreno_active_count_get@0xaac6a8`（上电+派发）。
  ⇒ 结论：**ioctl 自建提交不是结构性不可能，缺的是把 drawobj 变成 type==1**。

### 9.3 P7 实测：flags 维度已扫（19 组合，仍 0 命中）
`GPU_COMMAND.flags` ∈ {0,0x1,0x2,0x10,0x20,0x40,0x80,0x100,0x200,0x1000,0x4000,0x40400,…} + legacy `sc.flags` ∈ {0,0x10,0x100,0x400,0x1000}：
- **flags=0x2 → consumed=2 且 retired=2 且 7µs 完成**（对应静态里的 SYNC 型 drawobj，被软件 sink 立即双写退休）；
- **flags=0x400 → -EINVAL**（静态里"bit10→CMD"的读法不成立，至少在有 cmdlist 时被拒）；
- 其余一律 con 涨 / r 不涨或延迟 6–19ms，**marker 全 0**；
- 注意 P5 与 P7 的差别：P5 有 GL 线程狂渲染时我们的 ts 在 ~460µs 就被 retire；P6/P7 里 GL 线程被饿（每例仅 1 帧）时 retired 长时间不动
  ⇒ **软件 sink 的运行本身依赖真实 GPU 活动把 dispatcher 推着走**，进一步说明我们的 drawobj 只是被"顺带清账"。

### 9.4 已彻底排除的执行证据（五条独立判据）
① marker 0 命中（4 种 PM4 头 × legacy/modern × 30+ 参数组合 × 正确 64 位目标地址，且目标区清零后复测）
② `gpubusy` 全程 0（正对照：本进程 EGL 渲染 / monkey 起 Settings）
③ retire 延迟与 IB 长度**无标度关系**（10 dwords 0.46ms vs 512KB 3.5ms，且再大不增）
④ 整块非法包体 `0xDEADBEEF` 照常退休、**不产生任何故障**
⑤ **free 掉 2MB in-flight IB 无任何故障特征**（P6 A–H：二次提交照常成功、ctx 不坏、GL 不受扰、无 EAGAIN、无重启）

### 9.5 下一步（唯一还值得打的点）
静态确认 **`kgsl_drawobj_create@0xa83300` 把什么写进 `obj+0x10` 才能等于 1**（CMD），
以及 `0xaeb6fc-708` 那三道门（`soctype ∈ [0x12c,0x18f]` 且 `obj+0x18 bit4 → -95`）。
若确认 app 侧无法产出 type==1 ⇒ kgsl 执行原语判死，转 §8.5 或转其他面。

---

## 10. 子代理③结论 + 一个**必须留档的矛盾**（2026-09-26 01:2x）

### 10.1 否证内容（可审计）
- **type 映射表**（`0xa78134–0xa7816c`；legacy 同构 `0xa77e10–0xa77e48`）：
  flags bit1→2；flags bit10→4；否则 auxcount(GPU_CMD +0x34 / legacy +0x20)≠0→5；**cmdlist 数(+0x14/+0x10)≠0→1**；全 0→2。
  `kgsl_drawobj_create` 在 0xa83354 `and w24,w20,#3` → 0xa83428 `str w24,[obj+0x10]`。
  ⇒ **我们 flags=0 + 合法 cmdlist 时，obj+0x10 本来就 == 1**（不再是缺口）。`obj+0x18 = ioctl_flags & 0x93B`。
- **跳转表读法**（PC 相对偏移，不受 .rodata 未重定位警告影响；表字节直接从文件读）：
  - dispatcher 表 `@0xffffffc01219a750` = `18 00×7 10 00×7`，基址 0xaeb850 → idx0(CMD) 落 `0xaeb8b0`
    = "cmdobj 调用失败后的 ret=0 收尾"，**永远不会执行 0xaeb8a8 的 `bl 0xaec08c`**（进 0xaeb898 需表字节 0x12，全表没有；
    且 0xa00000–0xb80000 码段内 `bl 0xaec08c` 仅此一处）。
  - `_process_drawqueue_get_next_drawobj` 表 `@0xa760` = `19 00×7 10 00×7`，基址 0xaeeb60
    → idx0(CMD)→0xaeebc4「跳过该环继续」，idx1–7→0xaeeb60「返回 NULL」：
    **dispatcher 线程对任何对象都不弹出真派发**，随后一律走 0xaeebac 的 `_retire_timestamp` 软退休。
- 三道门 `0xaeb6fc–0xaeb708`：soctype = `[[dispatcher+0x12c8]]` u32 ∈[0x12c,0x18f] 且 obj+0x18 bit4(⇐submit flags 0x10) → -95。
  （子代理标注为**推测**：更像 SoC 代际而非 context->type；其初始化写点未钉死。避开方法：submit flags 别设 0x10。）
- 判定：**不存在**任何 app 可填参数能触发 `sendcmd/active_count_get` 真派发 ⇒ legacy 自建提交判死。

### 10.2 ★ 矛盾：如果 dispatcher 全局死，真 GL 为什么能动？
`[[dev]+0x198]` bit7（`adreno_queue_cmds@0xaaf9dc` 的分流位）是**设备级**状态，不随进程变；
若本设备所有提交都走"永不派发"的 dispatcher，系统 UI / 我们进程内的 Adreno GL 就不可能工作 —— 而实测它们在动 gpubusy。
⇒ 两种可能，**都还没钉死**：
 (a) 设备其实在 **hwsched 分支**（子代理②链路），dispatcher 是死代码；那 10.1 的否证只打在一条我们并不在的分支上，
     真正的阻塞点应回到 hwsched 的 drain 门（`dev+0x33c8` / `dev+0x2b58` / `jobs[prio]` 链表）——但那些门若关着真 GL 也该死，仍需解释；
 (b) 真 GL 不走 `kgsl_ioctl_gpu_command`，而走别的入口（例如 vendor HAL / swctl / "hwsched 用户态代理"），
     app 侧 ioctl 确实被刻意做成"记账不派活"（这会是**厂商对非白名单进程的结构性限制**，即 kgsl 线判死的真理由）。

### 10.3 判读立场
10.1 的否证 + 五条实测判据（§9.4）已经足够支撑**行动决策：停止在 kgsl 自建提交上继续投入**。
但"机制上为什么"这一栏**尚未证完**，不要把 §10.1 当作最终机理写进任何结论；下次若要复访 kgsl，
先用一个实验把 (a)/(b) 分开（读 `[[dev]+0x198]` bit7 的间接可观测量，或找真 GL 提交的实际 ioctl 入口）。

---

## 11. ★ 正向信号：改写驱动的 IB 指针会引发故障 ⇒ CP 确实按指针取指（P12/P13/P14/P15）

### 11.1 抄到真驱动配方（P12，GOT-hook libgsl 的 ioctl 槽）
```
GPU_COMMAND(0xc040094a, 64B): flags=0x8   cmdlist=1×32B(esize=0x20,num=1)   objlist=0   synclist=0
cmdlist 元素: off=0  gpuaddr=0x400020c000/0x4000230000(两块池交替)  size=244(字节)  type=1  id=0
随后每帧一次 DEVICE_WAITTIMESTAMP_CTXTID(0x400c0907) {ctx=0x1c, ts 递增}
```
⇒ 之前两处猜测被纠正：**id 要填 0**（按 gpuaddr 解析），**size 单位是字节**；驱动从不用 objlist。
P13 复刻该形状（flags=8/id=0/244B/无 objlist）→ **ret=0 且 retire 正常**。

### 11.2 阴性面（内容无关）
P14 A/B：**只有 CP_NOP** 与 **CP_NOP+CP_MEM_WRITE** 两组行为完全一致（各自上下文都是"2 次提交后 EAGAIN(35)"，
新上下文照常可用，真 GL 帧数持续上涨）⇒ 上下文死掉与包体内容无关，marker 也从未被写。

### 11.3 ★ 关键正向信号（P15 借刀）
在钩子里把**驱动自己**那帧的 cmdlist 元素改成指向我们 fd 的对象（其余原样），转发后：
| 事件 | 结果 |
|---|---|
| 放行期驱动自提交 2059 帧 | 全部正常，上下文不死 |
| 篡改 #1 / #2 | **内核接受 ret=0** |
| 篡改 #3 | **ret=-1 errno=35 ⇒ 该上下文死亡** |
| 我们的 marker | 未写 |

读法：驱动上下文原本极健康，一旦 IB 指向**不属于它的页表域**的对象就很快坏掉 ——
这正符合 "CP 真去取指 → 落在未映射 VA → SMMU 故障 → 上下文被标坏"。
⇒ **"按指针取指"这件事是真的**；marker 没写只是因为目标/源不在同一地址空间。
（注意这也说明 kgsl 的 GPU 页表**不是**简单按进程共享：我们的 0x4000000000 对驱动的上下文不可用。）

### 11.4 下一步（唯一一条还没打的洞）
**改内容而不是改指针**：再 hook 一层 `mmap`（同 GOT 手法），由 `offset=id<<12` 与 hook 到的 gpuaddr 建立
`驱动 IB 的 gpuaddr → 宿主虚拟地址` 映射；然后**就地改写那块已正确映射的命令流**（保留原指针与 size），
用驱动自己的派发获得 GPU 写。这才是"借刀"的正确用法。

### 11.5 顺带钉死的两件事
- 分支判定仍不干净：`cmd=84` 未触发静态代理预测的 -22（那条 0x53 上限管的不是 cmdlist 条目数），
  但 -35(EDEADLK) 的来源地址 0xaf3b68 在 hwsched 段内 ⇒ 倾向"我们在 hwsched 分支"，与"真 GL 能跑"一致；
  `adreno_hwsched_queue_cmds` 自带软退休臂(0xaf3f8c–0xaf3fb0) 解释了我们的提交为何"退休但不执行"。
- vivo 安装闸：必须唤醒+解锁，弹窗**先勾选"已了解风险"再点"继续安装"**（已固化进 install.sh）。

---

## 12. ★ 终局判别（P16–P21 · 2026-09-26 02:5x）：变量是"我们的对象"，kgsl 线判死

### 12.1 新能力：GOT-hook 同时拦驱动的 ioctl 与 mmap，得到完整对象图
在 libgsl 的可写 PT_LOAD 里替换 `libc ioctl` 与 `libc mmap` 两个槽（实测 ioctl 槽 ×1、mmap 槽 ×2）。
必须**先只 `eglInitialize/eglChooseConfig` 把 libgsl 载入，装好钩子，再创建上下文**，
否则驱动的 alloc/getinfo/mmap 全发生在装钩之前（P16 就因此两张表全空）。
于是拿到驱动的完整对象表：`GPUOBJ_ALLOC(0x45) id → GPUOBJ_INFO(0x47) gpuaddr → mmap(fd, id<<12) 宿主地址`，
例如 `id=25 → 0x4000208000 → 0x77a4438000`、`id=26 → 0x400020c000 → 0x77a43af000`（两块 IB 池交替使用）。

### 12.2 借刀实验族（全部同一结果）
| 实验 | 做法 | 结果 |
|---|---|---|
| P18 | 把驱动那帧元素指向我们 `GPUMEM(0x34)` 分配的**非缓存**对象，写我们的 CP_MEM_WRITE | ret=0 ×2 → 第 3 次 **EAGAIN(35)**；marker 不落 |
| P19 | 同上，改用驱动自己的 **`GPUOBJ(0x45)`** 通道 + GPUOBJ_INFO | 完全相同 |
| P20 | 再把 alloc flags 对齐驱动的实测值 **0xc1000**（并试 0x101000） | 完全相同 |
| **P21** | **原样复制驱动自己写的 244 字节合法命令流**到我们的对象，再重定向（尾追加一次写，目标在同对象内 ⇒ 必在域内） | **仍然相同**：ret=0 ×2 → EAGAIN；marker 不落 |

P21 是关键：被重放的是**厂商驱动亲手写、肯定合法、平时肯定在跑**的命令流，唯一变化的就是"内存归属"。
⇒ **排除 PM4 编码 / cache 可见性 / 分配通道 / alloc flags / 提交形状 / flags 位 / 上下文 flags 全部解释**；
⇒ 真实约束是：**属于我们上下文/对象的 GPU 内存永远不会被 CP 访问**（最可能是 hwsched 下我们没有 CB/HW 队列，
    我们的 drawobj 与内存根本没进入固件可见的状态 —— 与 §10 的"软退休臂"吻合）。

### 12.3 判死结论（含复活条件）
**在 iQOO Z6 / SM7325 / 5.4.281-qgki 上，untrusted_app（及 shell）经 `/dev/kgsl-3d0` 无法获得任何 GPU 内存读写原语**：
可提交、可退休、可分配、可映射，但硬件永不触碰我们的内存 ⇒ 不存在可竞争的 in-flight 窗口，
KGSL UAF/竞态类利用（含 CVE-2025-38352 / 21479 / 21480 家族在本机的落地）全部不可达。
**复活条件**（任一出现即可复访）：① 找到让 app 上下文获得真实 CB/HW 队列的入口；
② 发现某条 ioctl 会把我们对象注入驱动的域（如 sparse/`GPUOBJ_IMPORT` 的分支差异）；③ 内核侧对"我们的对象"存在可绕过的映射缺陷。

### 12.4 顺带修正 §11.3 的过度推断
"改指针导致上下文死亡"并非"CP 取指到域外 VA 而故障"的证据 —— 因为 **P14 已显示我们自己的上下文无论 NOP 还是写包都是 2 次后 EAGAIN**，
P21 又显示重放驱动合法流也一样。死亡与内容无关，与"对象归属"有关。§11.3 的正向信号解释作废（记录在案以免复犯）。
