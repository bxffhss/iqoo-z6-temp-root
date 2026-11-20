# Exp-8（§6.609）开枪判据 —— 写死于 11-11 17:3x，**在任何窗口打开之前**

## 这一发问的唯一问题
**「同一时刻只允许一个线程进 handler body」会不会不死？**
（八发里没人回答过：6d=全不进，6f/6g=少进。本发＝串行。）

## 形状（与 Exp-6 单变量对照）
- ko：`kmod/kernelsu_serial.ko`（待构建；＝基线 `0a305171` ＋ 清 63 行重复 ＋ 串行闸包装）
- args：`kmod/ksu_args_serial.txt`＝`56c0ff521cdf795d34ea85ffa0995369`
  `ksu_mass_mark=0 ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/data/local/tmp/kd ksu_exp6_mode=1 ksu_exp6_serial=1`
- 对照基准：Exp-6（`0x2` 原形）**19.50 s 死**；Exp-6d（cut=1，全不进）≥193.5 s；Exp-6f（rate=4）20.75 s；Exp-6g（rate=200）≥1384 s。

## 判据（逐条，缺一条就是"未测"而不是"通过"）
1. **主判据：存活 ≥ 30 分钟同一 boot。**
   - 双证人：①设备侧采样器 `w184_sample.out`（3 s/行，`mod=1` 持续、`up` 单调无回落、`boot_id` 不变）；②PC 侧独立时间轴（5 s/行，不依赖 `GO_RC`）。
   - ★`GO_RC=0` **不算**（可能是设备复位回来后的假绿，§6.585）。
   - ★死亡时刻只认**同源 `up=`**，不拿 epoch 夹出来的时间当死亡时刻（§6.506）。
2. **闸真的在工作（正面见证）**：dmesg 里 `KSUBEAT SER` 至少出现 `enter=1`/`enter=100` 这一档，且 `skip=` 读数 **> 0**。
   - ★`skip>0` 是"并发真的发生过、闸真拦到"的证据；若 `skip=0` ⇒ 本机 execve 从不并发（不可信）⇒ 本发对这个假设**没有判别力**，判"未测"。
3. **不是"根本没进"**：`enter=` 计数必须随时间增长（至少到 `enter=1000` 档）。若 `enter` 停在 1 ⇒ 串行位泄漏（内层没返回），要按事故查，不算通过。
4. **功能面（若活到 30 分钟才做）**：名单内 uid `su -c id` → `uid=0(root)`；名单外 uid → `EPERM` 且仍原 uid。
   - ★这一条是"活下来但 su 不通"与"活下来且可用"的分界，必须单独报。
5. **不是判据**：`which su` / `/system/bin/su` 存不存在（`0x2` 下 sucompat 只挂 execve，stat/access 不伪装 ⇒ 空值不算失败，§6.587 已定）。

## 三种结局对应的结论（先写死，防止事后圆场）
- **活过 30 分钟且 `skip>0`** ⇒ 死因是**并发交错**（不是逻辑、不是累积、不是打印）。⇒ 社区路线**有救**：把串行闸改成"每 CPU 一个位"（保住 8 核并行）再验一发，可能连性能代价都能压掉。
- **仍 ~20 s 死** ⇒ 并发**不是**因，且八发已排除打印/慢路/累积/uid 族/进函数本身 ⇒ 剩下的只能是"改 sys_call_table + 高频进入"这一层本身在本机不成立。**那时正式关线**，并把这句写进对外件，不再以"还没试够"留尾巴。
- **死得比 19.5 s 更早**（例如 < 5 s）⇒ 串行闸本身引入了新问题（例如原子位泄漏导致大量 execve 被跳过）⇒ 先查 `enter/skip` 再判，不当成"并发有罪"的证据。

## 现场纪律
一次开机一枪、`I_KNOW=1`、`KO=kmod/kernelsu_serial.ko` **必须显式给**（`push_ksu.sh:9` 默认是 rc74c）。
开火前两份 args 同改（`ksu_args.txt` ＋ `.bak_delivery` → `56c0ff52…`），收口后**手复原两份到 `fec3d301…` 并复读 md5**（SIGKILL 会绕过 EXIT 陷阱）。
窗口不留过夜；收口＝`I_KNOW=1 bash kmod/w161_teardown.sh`，可顺带清 `/data/local/tmp/kd` 与 `/data/adb/ksu/.allowlist` 两个残留。

---

## 构建验证回执（开后火前，11-11 17:2x–17:3x，未接触设备）

**构建**：`kmod/build_serial.py --apply` ⇒ `EXITCODE=0`（`kmod/w103_evidence/serial_build_console.log:192`）。
产物 `kmod/kernelsu_serial.ko` **5,111,752 B** / md5 **`80ade589e0e16b6929ed54dce81f4b61`**；远端 `/home/lucy/kernelsu_serial.ko` 同名同 md5（本地=远端，非同名异体）。
**复原**：`w1211_restore_remote.py` 把两份源复原到基线（`sucompat.c`→`26dd9a0a…`、`seb.c`→`0a305171…`）；`w1213_ko_probe_restore.py` 把 `kernel/kernelsu.ko` 复原成 rc80（`98bf4052…`）。⇒ 远端树不是"改了没退"的脏状态。

**六项闸（逐条读数）**

| # | 判据 | 读数 | 结论 |
|---|---|---|---|
| A | 串行闸新符号在 | `llvm-nm` 命中 ×1：`ksu_exp6_serial`／`ksu_serial_busy`／`ksu_serial_entered`／`ksu_serial_skipped`／`ksu_exp6_mode` | ✅ |
| B | 正面见证串在 | `strings` 里 `KSUBEAT SER` **2 处**，正是两种格式：`enter=%lu skip=%lu …` / `skip=%lu enter=%lu …` | ✅ |
| C | 不新增内核依赖 | 未定义符号 **156 = 156**（serial = rc80），双向 `diff` 空 | ✅ |
| D | 装载兼容 | vermagic 双边 `5.4.281-qgki-g2a88cd145def`；`__versions` 段大小双边 **0x2740** | ✅ |
| E | 代码增量合理 | `.text` +0x1fc(508)、`.bss` +0x28(40)、`.data` +0x20(32)、`.rodata` +0x40、`__param` +0x50、`__jump_table` +0x20 | ✅ |
| F | 参数通路 | 见下"F 的解释" | ✅（先疑后证） |
| G | 文件 +9,944 B 说清 | 见下 | ✅ |
| H | B-① 清理生效 | 预览源里 `path[0]=0;` **63 → 1**（原 63 条是构建期污染、HEAD 为 0） | ✅ |

**F 的解释（重要，别当缺陷）**：`.modinfo` 的 `parm=` 表双边**逐字相同**、没有 `ksu_exp6_serial` —— 这不是没注册。`parm=` 条目只由 `MODULE_PARM_DESC()` 生成，而这些实验参数都没写描述串。真正的判据是 `__param` 段：
`__param_ksu_exp6_serial` / `__param_ksu_exp6_mode` 在 serial 里各 **1**、在 rc80 里各 **0**；`__param` 段 `0x550 → 0x5a0`（+0x50 = 两个 `kernel_param` 结构 + 对齐）。⇒ `ksu_exp6_serial` 确是 `module_param(uint,0644)`，`ksu_args_serial.txt` 里的 `=1` 能被 insmod 吃进去，闸不会静默失效成"没测"。

**G 的解释**：文件 +9,944 B 与 `e_shoff` 差（5108232 − 5098288 = 9,944）**逐字节对上**，增量全在调试段：`.debug_info` +1513、`.rela.debug_info` +2664、`.debug_loc` +1328、`.rela.debug_loc` +408、`.debug_ranges` +144、`.rela.debug_ranges` +288、`.debug_frame` +80、`.debug_line` +296、`.debug_str` +388、`.rela.text` +720、`.rela__param` +192、`.symtab` +384、`.strtab` +309、`.modinfo` +58。段数双边 **55**，无新段、无 BTF 突增。

**包装器逐行复核**（`kmod/hermes_src/_preview_serial_sucompat.c:371-401`）：`likely(!ksu_exp6_serial)` 先短路（=0 时与基线逐字同，连原子操作都不做）→ `atomic_cmpxchg(&ksu_serial_busy,0,1)` 抢位 → 抢不到就 `skipped++`（1/100/1000/10000 档打印）并`返回原始 execve` → 抢到就 `entered++` 并进 `_inner` → 回来 `atomic_set(...,0)` 归还。与设计一致。

**开火前设备现状（只读，11-11 17:34–17:35）**：`boot_id=a33fd782-eca3-432c-84b2-77418a6e1f67`（与上一窗口 `8fcff782` 不同 ⇒ **过夜那个窗口已随重启自然收口**）、`uptime=3867 s`、`enforce=1`（MAC 已恢复）、`lsmod | grep -i kernelsu` **rc=1（无装载）**、`/dev/ksud` 不存在、`id -u=2000`。
⇒ 干净状态，Exp-8 开火＝**第 15 枪**，`KO=kmod/kernelsu_serial.ko` 显式给。

---

## 第 15 枪开火结果（11-11 17:54–18:20，现场已收口）

**开火程序**：`ARGS_FILE=kmod/ksu_args_serial.txt KO=kmod/kernelsu_serial.ko I_KNOW=1 bash kmod/go.sh`（PC 侧独立时间轴 `kmod/w1214_exp8_timeline.sh`，5 s/拍）。

**关键回执（逐条）**
- 起点：`id=2000 mod=0 enf=Enforcing`、Termux=10667 suw=10342；args 取自 serial 那份，原样读回 `ksu_hook_mask=0x2 … ksu_exp6_mode=1 ksu_exp6_serial=1`。
- 设备侧 push 复证：`ok kernelsu.ko 80ade589e0e16b6929ed54dce81f4b61`、`ok ksu_args.txt 56c0ff521cdf795d34ea85ffa0995369`（推的不是默认 rc74c）。
- reboot → 新 boot `254b37d4`（`up=100` 起飞），等负载 11→5→4→3（`up=475` 放行）。
- Punch：`SLIDE 17fec00000`、`[SEN] ★★★ 2 道「只有 SELinux 会拦」的关卡放开 ⇒ MAC 真的失效了`（`enf=Permissive`）。
- 装载：`insmod rc=0 up=741.07`，`lsmod=[kernelsu 204800 0]`，`/dev/ksud crw-rw-rw- 10,78`。
- **★insmod 实参原文（stage 日志原文）**：`ksu_stage=7 ksu_mass_mark=0 ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/data/local/tmp/kd ksu_exp6_mode=1 ksu_exp6_serial=1 killguard=1` ⇒ 串行开关**确实传进去了**。
- 存活：PC 时间轴 `18:08:26 mod=1/ksud=1` → `18:08:45` 仍在 → `18:08:51 OFFLINE`；内核心跳最后 `HB up=760.39`。
- **死亡时刻（只用同源 `up=`）**：`760.39 − 741.07 = 19.32 s`。对照 Exp-6 基线 `19.50 s` ⇒ **差 0.18 s（<1%）**。
- 复位后：新 boot `8a81fd93`、`enf=Enforcing`、`mod=0`、`/dev/ksud` 无 ⇒ **窗口已随复位自然收口，关窗铁律达成**（不需要再跑 teardown 翻 MAC）。
- `go.sh` 自行走完第 8 步，`[EXIT 兜底]` 把两份 args 复原为 `fec3d301ff5a55a19720477f01dc71d9`（现读复证两份相等）。
- 附带强证据：`Crowning manager: me.weishu.kernelsu(uid=10104)` ⇒ 本 ko 加冕的是**官方 Manager**，再次印证"ko 接受官方签名、无需重编"（§6.590 更正的旁证）。

**判据核对（按预登记逐条，不圆场）**
1. 主判据（活 ≥30 min 同一 boot）：**不成立**（19.32 s）。
2. 闸的正面见证（`KSUBEAT SER enter=1/100` 且 `skip>0`）：**未取到**。dmesg 里 `KSUBEAT` 计数 = **0**（一条都没有）。
3. `enter` 持续增长：无法评（同上）。
4. 功能面：未做（没活到 30 min）。
5. 不是判据项（`which su`）：未测。

**★为什么第 2 条判"未取到"而不是"闸没工作"（这一条是本次最值钱的发现）**
stage 日志里那份内核日志覆盖 `up=740.03 → 747.37`，里面 `KSUBEAT` 只有 `P1/P4/X0..XC` 这些子类。而 `syscall_hook_manager.c:180-199` 的 `ksu_syscall_hook_manager_init()` 里，装完 `hook_mask` 各钩子后**无条件**打 `KSUBEAT M2`、`KSUBEAT M3`，再调 `ksu_sucompat_init()`（其首句就是 `KSUBEAT M5`）。这三句 **一条都不在**，而同一日志里明明白白有 `SLOTTBL slot=221 -> ksu_syscall_trampoline`（＝钩子确实装上了，所以那三句必然执行过）。
⇒ **那份内核日志是被过滤过的子集，不是全量。** 因此 `SER` / `SD5` 的缺席**不能当否据**（正是项目已登记的"计数=0 不是否据"）。
另外两条补强：(a) 反汇编证实闸在机器码里是真的——入口 `bl ksu_handle_execve_sucompat_common`，`_common` 里 `adrp/ldr w8`（读 `ksu_exp6_serial`）→ `cbnz w8` 非 0 才走串行路；(b) `ksu_exp6_serial=1` 在 insmod 行里且 `rc=0`（该参数在 `__param` 段里真实存在，见上节），而 `module_param` 的 cmdline 赋值没有失败路径 ⇒ 运行期该值应为 1。

**本发能说什么、不能说什么（口径）**
- **能说**：`0x2 + mode=1`（只留 sucompat 支）下，**装载后 19.32 s 必死**，与全速基线 19.50 s 同量级；把入口改成"同一时刻只准一个线程进"**没有换来任何存活收益**。
- **不能说**：①不能说"闸没生效"（见证被日志过滤吞掉）；②不能说"并发不是死因"（严格按预登记，见证缺一条就是**未测**，不能当"通过"）。
- **倾向性推断（未达判据，只作参考）**：若闸确实生效，则"减并发不减次数"零收益这一点与 Exp-6f"减到 1/3.65 次数只多活 7.7%"合起来，更像**"进 sucompat 这件事按次数/按时间累积，与并发度无关"**；但这仍与 6d（全不进 ≥193.5 s）/6g（1/200 ≥1384 s）的长度不自洽，模型未成立。
