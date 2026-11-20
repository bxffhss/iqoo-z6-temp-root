# rc82b 复验结果（2026-11-14 02:34 → 02:46，第二发·再触发内核崩溃/硬复位）

> 上游：`RC82B_FIRE_RESULT_1114.md`（第一发）、`RC82B_FIRE_RUNBOOK_1114.md`、`RC82KP_RESULT.md`。
> 本文件只记录复验结果 + 综合结论，判据口径、形状锁定在 runbook，不在此重述。

## 0. 一句话结论

**复验再次证明：rc82 系列 ko 在 insmod/apply 阶段会触发内核崩溃/硬复位，非偶发 ⇒ rc82 线暂停（不要再烧 boot 验它）。**
**但「设备电源层恶化 / 连普通 reboot 都 PS_HOLD / 需换机」这一推断已被 17:11 的实测推翻**（见 §7）：`cold,charger` 只是本机 `adb reboot` 的**正常** bootloader 记录，用户干净 reboot 也记它、设备完全健康 ⇒ 那是 ko 缺陷，不是设备问题，LSPosed 攻关 / B 线 / rc80 复验均可恢复。

## 1. 证据链（全部落盘）

| 来源 | 关键行/值 | 读什么 |
|---|---|---|
| `RC82B_RECHECK_1114.txt`（02:34 安全闸门） | `boot_id=a4622f7a`、`uptime=1814s`、`HISTORY` 与原 3 条一致 | 复验前设备稳定 30min、无新增硬复位 ⇒ 闸门通过 |
| `RC82B_FIRE2_1114.log` | L27–29 `ok kernelsu.ko 2807a4ca`/`ok ksu_args.txt b5db1c0a`；L37 采样器起；**L38 `OUTER_GO_RC=124`** | push 形状正确；`timeout 600` 在比第一发更早处（连 boot 锚点 L43 都没打印）把 go.sh 杀了 ⇒ 卡在 **reboot 后等 boot_completed** |
| `RC82B_REFIRE_PROBE_1114.txt`（02:45） | `boot_id=878c7ff9`（新）、**`ENF=Permissive`**、`MOD=0`、`/proc/ksu_kp_stat` 不存在；`HISTORY` 新增 **`cold,charger,1794595036`**；`ksu_stage.log` pull 失败 | 复验触发硬复位；**Permissive 暗示 ko 一度真正 insmod 成功 + keep_permissive 设 Permissive 后硬复位**（比第一发"截断在 insmod"更彻底）；硬复位铁证 ★但 `cold,charger` 本身不是铁证（见 §7） |
| `RC82B_REFIRE_TEARDOWN_1114.txt`（02:46） | `boot_id=567f177c`（新）、`ENF=Enforcing`、`MOD=0`；`HISTORY` 新增 **`cold,charger,1794595692`** | **收窗的普通 `adb reboot`（无 ko/无 root）也以 `cold,charger` 起来**——但 17:11 证实这只是本机 reboot 的正常记录（见 `DEVICE_REPROBE_1711.txt`），**不是设备不稳** |

## 2. 与第一发对比

| 项 | 第一发（01:39） | 复验证实（02:34） |
|---|---|---|
| 日志卡点 | 到第 3 步「等 agent fd」（L43 boot 锚点 + L44–45） | 连 boot 锚点都没到（卡 reboot 后等 boot_completed） |
| SELinux 终态 | `Enforcing`（ko 没装上） | **`Permissive`**（ko 一度装上 + keep_permissive 设了，再硬复位） |
| 硬复位证据 | stage 截断在 `insmod`、设备未自行回 `boot_completed` | 新 `boot_id=878c7ff9` + Permissive 残余（确属 ko 加载后 reboot） |
| 收窗 reboot | 设备正常起来（`a4622f7a`，后稳定 19.5min），记 `cold,charger` | 设备正常起来（`567f177c`），记 `cold,charger`（同属正常记录，非硬复位） |

## 3. 根因判定

- ✅ **持续性 ko 触发硬复位，非偶发**：rc82_kp 第 1 发 + rc82b 第 1 发 + rc82b 复验 = **同一类内核崩溃/硬复位复现三次**，推翻「静置后疑似偶发」假设。
- ✅ **与 rc82 ko 增量强相关**：rc80（最稳交付形状，多发稳定、B 线已出 root）不硬复位；rc82_kp（加 watchdog）/rc82b（加只读 `/proc` 节点）加载必硬复位。具体触发点应在 insmod 后很短时间（watchdog 注册/定时器，或 `/proc` 节点注册）触达硬件看门狗。
- ✅ **判定 ko 触发硬复位的真实证据**：stage 日志在 `insmod` 截断（第一发，无 insmod 回执/无后续步骤）、设备未能自行回到 `boot_completed`（go.sh 被 timeout 杀、OUTER_GO_RC=124 出现在 boot 锚点前）、复验终态 `MOD=0` 但 `Permissive` 残余（ko 装上后 reboot）。**这些才可靠，不是 HISTORY 的 `cold,charger`**。
- ❌ **不是温度/电量/网络**：复验前两轮诊断已排除（温度 28–30°C、电量 100%、TCP 重传=0）；内核事后日志整机不可读（dmesg restricted / pstore 空 / 无 last_kmsg），无法拿到 panic 前打印。
- ❌ **（17:11 撤回）不是"设备电源层恶化 / 连 reboot 都不稳 / 需换机"**：见 §7，`cold,charger` 是本机 `adb reboot` 的正常 bootloader 记录，用户 17:11 干净 reboot 也记它且设备完全健康。原 §3 的"PMIC 复位原因/看门狗卡死可恢复状态""彻底断电验证"等推论**全部基于误读，已删除**。

## 4. 五条判据（两发全部 N/A）

| # | 判据 | 结果 |
|---|---|---|
| 1 | `getenforce` 回 0 | N/A（最终 Enforcing/或 Permissive 残余但无 root 窗口） |
| 2 | `asuid 10342 /product/bin/su -c id` 出 root | N/A（MOD=0，无 root 通道） |
| 3 | `mountinfo` 仍有 lsposed 挂载 | N/A |
| 4 | `lspd`/`zn-daemon` 在跑 | 未测（窗口未活） |
| 5 | LSPosed 显示已激活 | N/A |
| + | `/proc/ksu_kp_stat` started/hits | 节点不存在（ko 未加载） |

⇒ rc82b 的「看门狗五条判据」**两次都没验证到**；LSPosed 根因（zygote 重启时机）依旧未解，但**因设备健康，现在可以另建窗口攻关**（不再受"设备不稳"限制）。

## 5. 下一步

1. **rc82 线暂停**：不再复验 rc82b/rc82_kp，**任何带 rc82 增量的 ko 都不打**（加载即触发硬件看门狗/panic，纯 ko 缺陷，与设备无关）。
2. **设备健康，可恢复其他工作**：
   - **LSPosed 攻关 / Zygisk 注入窗口**：可重新建干净 boot 窗口攻关（zygote 重启时机问题），设备已确认能正常 reboot、正常起窗口。
   - **B 线复验**：官方 manager + rc80 稳定交付件已在 11-12 实证出 root，可随时复验。
   - **rc80 复验**：作为稳定交付基线，设备健康前提下随时可重打确认。
3. **排查 rc82 硬复位根因（可选，纯 ko 侧）**：用 ftrace/kprobe 过滤 insmod 后 watchdog 注册/定时器触发点，或二分 rc82 增量（watchdog vs `/proc` 节点），定位触达硬件看门狗的具体代码——这是 ko 代码问题，不依赖设备换机。
4. **设备现状（17:11 复探 `DEVICE_REPROBE_1711.txt`）**：`8faa06fa`/`Enforcing`/`MOD=0`/`boot_completed=1`/uptime 277s、无 su/ksud/root 窗口、adb shell 正常 ⇒ 干净且健康。

## 6. 纪律复核

- ✅ 一次开机一枪：a4622f7a 这一发花掉（复验），当前 567f177c 不再打 rc82。
- ✅ 窗口零接触：go.sh 跑期间未做额外 adb；判读只读落盘日志。
- ✅ 不可逆动作前等到用户点头（「帮我复验」）。
- ✅ 无 root 时 `reboot` 收窗（终态回到 Enforcing 干净）。
- ⚠️ 反思：`timeout 600` 比第一发 1200 合理，但两次都卡在 reboot/第 3 步，说明问题不在等待时长，而在 ko 触发硬复位本身。

## 7. ★17:11 重大更正（用户实测推翻"设备不稳/换机"结论）

**用户反馈**：「这里使用 `adb reboot`，可以正常重启，也可以正常使用 `adb shell`。」
**实测复探 `DEVICE_REPROBE_1711.txt`**：用户干净 `adb reboot` 后 `boot_id=8faa06fa`、uptime 277s、`boot_completed=1`、`Enforcing`、无 ko、adb shell 正常；HISTORY 最新条目＝**`cold,charger,1794647466`**。

⇒ **结论**：`cold,charger` 是本机 `adb reboot` 的 **NORMAL bootloader 记录**，不是 PS_HOLD 硬复位特征。本文件 §0/§1(teardown 行)/§2(收窗 reboot 行)/§3 末段原写的「设备电源层恶化 / 连收窗 reboot 都 PS_HOLD / 永久损坏 / PMIC 卡死可恢复 / 彻底断电验证」**全部基于这一误读，已于 17:11 撤回**。

**修正后的二分**：
- **ko 触发硬复位（真实、ko 缺陷）**：rc82 家族 ko 加载即在 insmod/apply 阶段崩内核/触发硬件看门狗 ⇒ 暂停 rc82 线。证据＝stage 截断于 insmod + 设备未回 boot_completed + 复验 Permissive 残余＋新 boot_id。
- **设备健康（真实、与 ko 无关）**：普通 `adb reboot` 正常、adb shell 正常、能稳定 uptime、开机后运行正常 ⇒ **无需换机**，LSPosed/B 线/rc80 工作可恢复。

**判据纪律新增**：判设备硬复位**绝不看 `cold,charger`**（本机 reboot 必记它）；看 stage 日志是否在 `insmod` 截断 + 设备能否正常回到 `boot_completed` + 终态 `MOD`/SELinux 残余。`ro.boot.bootreason` 仍是 sticky（记上一次复位原因），同样不可作本发证据。
