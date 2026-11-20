# w1216 — 第 16 枪（Exp-8b）预登记：用「拉」的方式取决定性见证

> 写于开火**之前**（11-11 18:3x），任何一条判据事后不得修改。产物：`kmod/kernelsu_serial2.ko`。

## 为什么还要打这一枪

第 15 枪（`w1210`）现场结论是 **"未测"**，不是"失败"，也不是"通过"：

- insmod 行里确实有 `ksu_exp6_serial=1`、`insmod rc=0`、机器码也证实闸是真的（`bl _common` → `adrp/ldr w8` → `cbnz w8`）；
- 但 dmesg 里 `KSUBEAT SER` **一条都没有**，日志只覆盖 `up=740.03→747.37`（死亡在 `760.39`），中间 13 秒盲区；
- **★查明那不是"没打印"，是那份内核日志被过滤了**：`syscall_hook_manager.c:180-199` 里装完钩子后**无条件**打的 `KSUBEAT M2`/`M3`、以及 `ksu_sucompat_init()` 首句 `M5`，一条都不在日志里；而同一日志里明明有 `SLOTTBL slot=221 -> ksu_syscall_trampoline`（钩子确实装上了 ⇒ 那三句必然执行过）。
- ⇒ 结论：**这条链上"某打印为 0"不能推出"某路径没跑"**。所以第 16 枪不再靠"推"（pr_info → 环形缓冲 → stage 抽取），改成 **"拉"**。

## 形状（与第 15 枪单变量）

- ko：`kmod/kernelsu_serial2.ko` ＝ `kernelsu_serial.ko`（`80ade589…`）**逐字相同**的 A/B 补丁 ＋ 新增 D：
  - `#include <linux/proc_fs.h>`
  - `ksu_ser_read()` + `ksu_ser_fops`：**read 时现算**一行
    `SERD serial=%u mode=%u mask=0x%x enter=%lu skip=%lu busy=%d`
  - `ksu_sucompat_init()` 里 `proc_create("ksu_ser", 0444, ...)`，同句 pr_info 报告建没建出来
- args：仍用 `kmod/ksu_args_serial.txt` ＝ `56c0ff52…`（`hook_mask=0x2 … exp6_mode=1 exp6_serial=1`）
- 开火命令：`ARGS_FILE=kmod/ksu_args_serial.txt KO=kmod/kernelsu_serial2.ko I_KNOW=1 bash kmod/go.sh`
- **采集器（本发的核心）**：`kmod/w1217_poll_ser.sh` —— PC 侧 1 s/拍 `adb shell cat /proc/ksu_ser`，直到死亡或满 10 分钟，逐行落 `kmod/w103_evidence/exp8b_ser_poll.txt`。
  - 它**不看 dmesg、不看 stage 日志**，因此与那条不可靠通道完全解耦。

## 判据（逐条；缺一条就是"未测"，不许当"通过"）

1. **通道成立（前置）**：poll 文件里至少出现一行 `SERD …`。
   - 一行都没有 ⇒ `/proc/ksu_ser` 没建出来或没读到 ⇒ **本发口径＝未测**，先查 `ksu_sucompat_init` 有没有跑（回退看 stage 日志里的 `KSUBEAT SERD proc=`）。
2. **参数是否生效（本发的第一目的）**：那行里 `serial=` 的值。
   - `serial=1` ⇒ 参数通路成立 ⇒ 第 15 枪的"19.32 s 死亡"就**是一个有判别力的负结果**（闸真武装了还是死）。
   - `serial=0` ⇒ **参数通路是坏的** ⇒ 第 15 枪只是 Exp-6 的复刻，那一发的"零收益"结论作废，先修参数再谈死因。
3. **热路径到底有没有进（本发的第二目的）**：`enter=` 的走势。
   - `enter` 随时间增长（≥ 几个数）⇒ 进过热路径。
   - 全程 `enter=0` ⇒ 在这次窗口里 **execve 流量根本没送到 sucompat**（那第 15 枪的"19 秒死"与 sucompat 调用无关，另案）。
4. **并发真的发生过（原 Exp-8 的判据）**：某个时刻 `skip > 0`。
   - 只有 `skip>0` 才说明"同一时刻有别的线程被闸拦住"⇒ 串行化这个自变量真的被施加过。
5. **存活（沿用主判据）**：insmod 后同一 boot 活 ≥ 30 min。
   - 死亡时刻**只用同源 `up=`**（PC poll 里同时记 `up=`），不拿 epoch 夹。
6. **功能面**（只有活到 30 min 才做）：名单内 uid `su -c id` → `uid=0`；名单外 → `EPERM`。

## 三种结局对应的结论（先写死，防事后圆场）

- **`serial=1` + `enter` 增长 + `skip>0` + 仍 ~19 s 死**
  ⇒ 串行化真被施加且真拦到了，仍然死 ⇒ **"并发交错"不是死因**（这是本项目第一次拿到"见证过的负结果"）。社区路线按 §6.608 正式关线，不再以"还没试够"留尾巴。
- **`serial=1` + `enter` 全程 0**
  ⇒ 热路径没被调用 ⇒ 第 15 枪的 19 秒死**与 sucompat 无关**，此前把死亡归给 sucompat 的整条推理都要重审（这比"关线"更重要）。
- **`serial=0`**
  ⇒ 参数没生效 ⇒ 第 15 枪作废（＝Exp-6 复刻）⇒ 先把 `module_param` 通路修好（例如换成 ini 文件读取/`/proc` 写入），再谈这一发。
- **没拉到任何 `SERD` 行**
  ⇒ 通道没建立（`/proc/ksu_ser` 没建或 `ksu_sucompat_init` 没跑）⇒ 判"未测"，先修仪器。

## 现场纪律（照旧，不因"只是读"而松）

- 一次开机一枪、`I_KNOW=1`、`KO=` 必须显式给（`push_ksu.sh:9` 默认 rc74c）。
- args 由 `ARGS_FILE=` 带入，`go.sh` 的 EXIT 兜底会从 `.bak_delivery` 还原；收口后**手动复读两份 md5＝`fec3d301…`**（SIGKILL 会绕过陷阱）。
- 窗口不留过夜；MAC 恢复排在所有 root 腿之后；活窗口里绝不 `rmmod`。
- poll 循环只用 `sleep 1`，不并发开重活（本身 <1 execve/s，相对实测的几十次/s 可忽略）。

---

# 结果（11-11 18:43–18:57，现场已收口）—— **第一种结局：见证过的负结果**

## 产物
`kmod/kernelsu_serial2.ko` **5,118,008 B** / **`47788edb40fa6e4a76ee55917550b534`**（远端 `/home/lucy/kernelsu_serial2.ko` 同名同 md5）。
构建 `build_serial2.py --apply` ⇒ `EXITCODE=0`、`SERIAL2_KO_OK`；远端两份源与 `kernelsu.ko` 已无条件还原（`26dd9a0a`/`0a305171`/`98bf4052`）。
离线闸：`ksu_ser_read`(t)/`ksu_ser_fops`(r) 在；`SERD` 两串在；未定义符号 **156→157，只多 `scnprintf`**（5.4 导出符号，`proc_create`/`default_llseek` 本来就被 dev_syms.c 引用过 ⇒ 不新增）；vermagic 双边 `5.4.281-qgki-g2a88cd145def`。

## 开火与采集
`ARGS_FILE=kmod/ksu_args_serial.txt KO=kmod/kernelsu_serial2.ko I_KNOW=1 bash kmod/go.sh`；push 复证 `kernelsu.ko 47788edb` + `ksu_args.txt 56c0ff52`；punch → 新 boot `df08c16d` → `load1=3 up=366` 放行 → `insmod rc=0 up=624.39`。
采集器 `kmod/w1217_poll_ser.sh`（1 s/拍 `cat /proc/ksu_ser`）**抓到 9 行**，随后设备 OFFLINE。

## 拉到的那 9 行（原文，未修改）
```
18:53:57  up=625.36 mod=1 | SERD serial=1 mode=1 mask=0x2 enter=107 skip=2  busy=0
18:53:59  up=627.51 mod=1 | SERD serial=1 mode=1 mask=0x2 enter=199 skip=7  busy=0
18:54:02  up=629.69 mod=1 | SERD serial=1 mode=1 mask=0x2 enter=273 skip=8  busy=0
18:54:04  up=631.88 mod=1 | SERD serial=1 mode=1 mask=0x2 enter=352 skip=14 busy=0
18:54:06  up=634.02 mod=1 | SERD serial=1 mode=1 mask=0x2 enter=436 skip=18 busy=0
18:54:08  up=636.26 mod=1 | SERD serial=1 mode=1 mask=0x2 enter=509 skip=20 busy=0
18:54:10  up=638.40 mod=1 | SERD serial=1 mode=1 mask=0x2 enter=567 skip=25 busy=0
18:54:12  up=640.57 mod=1 | SERD serial=1 mode=1 mask=0x2 enter=684 skip=30 busy=0
18:54:15  up=642.65 mod=1 | SERD serial=1 mode=1 mask=0x2 enter=757 skip=31 busy=0
18:54:17  OFFLINE …
```

## 判据核对（逐条，全部命中）
1. **通道成立**：9 行 `SERD` ✅（拉取式通道在 19 秒窗口里工作正常，彻底绕开被过滤的内核日志）。
2. **参数生效**：`serial=1` ✅ ⇒ **参数通路成立**，第 15 枪的 19.32 s 死亡是**有判别力的**负结果，不是"闸没开"的复刻。
   - 同批还读到 `mode=1`、`mask=0x2` ⇒ args 三条关键值逐条回证（这在本项目里是第一次做到"运行期读回"）。
3. **热路径真进**：`enter` 107 → 757（16.3 s 内单调增长，≈46 次/s）✅ ⇒ sucompat 真的被调用。
4. **并发真发生、闸真拦到**：`skip` 2 → 31，**>0** ✅ ⇒ "同一时刻有别的线程被拦住"这件事真的发生过，串行化这个自变量被真实施加。
5. **存活**：insmod `up=624.39` → 最后存活读数 `up=642.65` → 首次 OFFLINE（`18:54:17`，同源 `up` 推得 ≈643~645）⇒ **寿命 ≈ 18.6–20.6 s（中点 19.6 s）**。**不成立**（远不到 30 min）。
6. 功能面：未做（没活到 30 min）。
7. 附带读数：`busy=0` 全程 ⇒ 串行位**没有泄漏**（每次进入都释放了），内层返回很快。

## 结论（按预登记第一种结局，不越界）
> `serial=1` + `enter` 增长 + `skip>0` + 仍 ~19.6 s 死 ⇒ **"并发交错"不是死因。**

三发同量级并列，这是本项目第一次拿到"见证过的负结果"：

| 发 | 形状 | 进 sucompat 的速率 | 寿命 |
|---|---|---|---|
| Exp-6（第 13 发） | `0x2` 原形 | 727 次/s（decline） | **19.50 s** |
| Exp-8（第 15 枪） | `0x2` + 串行闸（见证未取到） | 同量级 | **19.32 s** |
| **Exp-8b（第 16 枪）** | `0x2` + 串行闸（**见证齐**） | **46 次/s（enter）+1.8 次/s（skip）** | **≈19.6 s** |

## ★额外发现（18:5x 已复核 rate 语义后修正，前一版这里的"与 6g 冲突"是我读错了）
三发的**深路速率**差 16 倍，死亡时刻却几乎逐秒相同（19.32 / 19.50 / 19.6）⇒ 死亡时刻对"深路速率"**不敏感**（在门槛之上时）。
但把各发的 `rate` 语义按源码读清后，四发能排成一条自洽的曲线——`build_exp6f.py` 的 rate 实现是
`if ((ksu_exp6_rate_ctr % ksu_exp6_rate) != 0) { skip }`，即 **每 N 次进入只放 1 次走深路**：

★**20:5x `w1221` 归因审计修正**：下表原版把「累计次数」当成「速率」（727/199 实为 738/180 次），并推定 6g 进 handler ~727/s（实测仅 ≈35.7 次/s）。改用账本实测值：

| 发 | 进 handler 基数 | **深路速率（实测）** | 累计深路 | 寿命 |
|---|---|---|---|---|
| Exp-6 原形 | — | **≈38 次/s** | 738 次 | 19.50 s |
| Exp-6e（noslow） | — | **≈35 次/s** | 667 次 | 19.27 s |
| Exp-6f（rate=4） | ≈54 次/s | **9.7 次/s** | 180 次 | 20.75 s |
| **Exp-8b（串行闸）** | ≈48 次/s | **≈46 次/s** | 757 次 | **~19.6 s** |
| Exp-6g（rate=200） | ≈35.7 次/s（`ctr=10000`/279.8 s） | **0.2 次/s** | ≈50 次 | **≥1384 s（活着）** |
| Exp-8c（第17枪 once） | ≈14 次/s | ≈0 | 1 次 | ≥1857 s（活着） |

⇒ 形状是「**门槛 + 引信**」：深路速率 ≳9.7 次/s ⇒ 一律在 **~19.5 s** 死（19.27~20.75 窄带）；0.2 次/s ⇒ 活 ≥1384 s；1 次 ⇒ 活 ≥1857 s。**门槛落在 (0.2, 9.7) 次/s 之间**（未二分）。
⇒ 这否掉"并发交错饱和"（本发已直证），但**对 (甲) 次数阈值 / (丙) 速率阈值 / (丁) 阈值+固定延迟 三格无判别力**：累计 50 次活、180 次死，次数线本身可以自洽；§6.604 判 per-call 累积被否也只对「半速应半命」成立。**机制未证到，连「是否存在累积」都未证**（深路无显式分配、全树无定时器、崩溃签名无 OOM，历发从未量资源计数）——详见 `kmod/w1221_mechanism_audit.md`。

## ★但这不改变 §6.608 的交付结论（重要）
门槛落在 (0.2, 9.7) 次/s（`w1221` 修正后的实测口径），而**要"能用"就必须全速深路**（§6.608：`rate=200` 下 199/200 次 su 原样返回 ⇒ su 不工作）。
能活下来的速率区间，正好是把 su 废掉的区间 ⇒ **"可用区间为空"仍然成立**。★这条是**现象学结论、不依赖机制**，因此不受 `w1221` 归因修正影响；只是现在知道了它的原因不是并发，而**具体机制仍未证到**。

## 建议的下一步（若要继续，属新方向，须另立预登记）
**"一次性进入"实验**：让 sucompat 只处理**头 1 次**调用（进入后置一个全局 done 位，之后一律走 orig），其余一切不变。
- 若仍 ~19.5 s 死 ⇒ 死因是"第一次进入后某个延迟 19.5 s 的定时/状态"（与流量彻底无关），这条线就没有"调参救活"的可能，只能重构该路径；
- 若活过 30 min ⇒ 死因是"次数"，且门槛在 1 次以上某个数，仍可用节流救。
代价：一次构建 + 一枪。
