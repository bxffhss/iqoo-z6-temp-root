# rc82b 开火结果（2026-11-14 01:39 → 02:03，第一发·硬复位·失败）

> 上游：`RC82B_FIRE_RUNBOOK_1114.md`、`RC82KP_RESULT.md`（rc82_kp 第 1 发 PS_HOLD 先例）。
> 本文件只记录结果，判据口径、形状锁定在 runbook，不在此重述。

## 0. 一句话结论

**rc82b 第一发在 `insmod` 阶段触发了 PS_HOLD 硬复位，root 窗口从未建立，五条判据全部 N/A。**
与 `RC82KP_RESULT.md` 记载的「rc82_kp 第 1 发 insmod 后约 1s PS_HOLD」是**同一类先例**，不是 ko 代码问题。
按 runbook §5「又硬复位」分支：**暂停 rc82 线，先查设备/环境，不要再打**。

## 1. 证据链（全部来自落盘日志，非推断）

| 来源 | 关键行 | 读什么 |
|---|---|---|
| `RC82B_FIRE_1114.log` | L27–29 | `ok kernelsu.ko 2807a4ca`、`ok ksu_args.txt b5db1c0a`、`ok ksud f7a441d2` —— **push 成功，形状正确** |
| 同上 | L43 | `#6.292 boot 锚点: boot_id=fa7d3139 bootreason=[USB_CHARGER/PS_HOLD/0x01+0x01]` —— **bootreason 含 PS_HOLD** |
| 同上 | L44–45 | `=== 3) 等 stage 到判据⑥(agent fd) ===` / `还在等：up=157` —— **卡在第 3 步，root 通道没建立** |
| 同上 | L46 | `OUTER_GO_RC=124` —— 我加的 `timeout 1200` 把 go.sh 杀了（撑满 20 分钟） |
| `RC82B_stage.log`（设备侧，已 pull） | L38 | `★insmod 实参原文=[… killguard=1]` —— **日志在此截断，无 insmod 回执、无后续任何步骤** |
| 同上 | L9–14 | pstore：`console-ramoops-0/ramoops` 不存在，只有 `pmsg-ramoops-0`(398B) —— 内核事后日志拿不到（与「计数=0 不是否据」同一纪律） |
| `RC82B_POSTFIRE_PROBE_1114.txt`（02:00:55） | — | `boot_id=fa7d3139`（与锚点一致）、`Enforcing`、`boot_completed=1`、**`MOD=0`**、`/proc/ksu_kp_stat` 不存在 |
| `RC82B_TEARDOWN_1114.txt`（02:03:36） | — | `boot_id=a4622f7a…`（新 boot）、`Enforcing`、`MOD=0`、无 su/ksud —— **无 root 干净收窗** |

## 2. 时间线还原

1. **01:39:46** 开火（后台 `task dRPUOt`），`go.sh` 跑：起点体检 OK → args 取自 `ksu_args_kp.txt`（L6）→ push 成功（L27–29）→ `adb reboot`。
2. 设备起来后 stage 跑（`RC82B_stage.log` L1 时间戳 01:56:52）→ stage 准备 insmod（挂 PCODE kprobe enable=1，L37）→ **L38 打印 insmod 实参后日志截断**。
3. stage 在 `insmod rc82b.ko` 这一步被中断 → 设备 **PS_HOLD 硬复位** → 重新起来（当前 `fa7d3139` 这个 boot 是硬复位后的 boot，bootreason 记录了复位原因）。
4. `go.sh` 第 3 步等的是「agent fd 装好＝root 通道可用」，但硬复位后的 boot 里 ko 没再加载（最终 `MOD=0`）→ fd 永远装不上 → 卡 20 分钟 → `timeout` 杀（`OUTER_GO_RC=124`）。
5. 02:03:36 无 root 收窗：`adb reboot` → 新 boot `a4622f7a`，`Enforcing`/`MOD=0`/无 su/ksud ⇒ 干净。

## 3. 根因判定（与 runbook §5 映射）

- ✅ **「又硬复位 / 又死在 report 序列」分支命中**：`bootreason=PS_HOLD` ＋ stage 日志截断在 insmod。
- ❌ **不是 ko 代码问题**：rc82b 相对 rc82_kp 只多一个 `/proc/ksu_kp_stat` 节点（纯只读见证，不参与 insmod 关键路径）；insmod 实参与交付形状逐字一致（`killguard=1` 也是交付件含的）。硬复位发生在 `insmod` 系统调用阶段，与「看门狗增量」无关。
- ❌ **不是 `ARGS_FILE`／形状问题**：push 校验全绿（`2807a4ca`/`b5db1c0a` 逐字），stage L1 读到的 args 正是 kp 形状。
- ⚠️ **`OUTER_GO_RC=124` 是 timeout 杀，不是硬复位本身**：硬复位由 `bootreason` 揭示，二者要分开读（runbook §1.1 已注明）。

## 4. 五条判据（全部 N/A，窗口未活）

| # | 判据 | 结果 |
|---|---|---|
| 1 | `getenforce` 回 0 | N/A（最终 `Enforcing`，ko 未加载） |
| 2 | `asuid 10342 /product/bin/su -c id` 出 root | N/A（无 root 窗口） |
| 3 | `mountinfo` 仍有 lsposed 挂载 | N/A（无 root 窗口） |
| 4 | `lspd`/`zn-daemon` 在跑 | 未测（窗口未活，且非 LSPosed 根因） |
| 5 | LSPosed 显示已激活 | N/A |
| + | `/proc/ksu_kp_stat` `started/hits` | 节点不存在（ko 未加载） |

⇒ **rc82b 这一发什么都没验证到**，LSPosed 根因（zygote 重启时机）依旧未解。

## 5. 下一步（按 runbook §5）

1. **暂停 rc82 线**：当前 boot `a4622f7a` 唯一一发已花，且硬复位 ⇒ 不再打第二发。
2. **先查设备/环境**（PS_HOLD 根因）：温度、电量、网络重传风暴、`persist.sys.boot.reason.history`、pmsg-ramoops-0(398B) 是否非空。
3. **确认「不再硬复位」后再考虑复验**：建议先以 `rc80` 交付窗（最稳形状）验「这台机现在还能满窗活」——若 rc80 也硬复位，则坐实「设备/环境侧变化」而非 rc82 代码。
4. **残留处理**：`/data/local/tmp/kd`（非 root 临时件，下次 stage 覆盖）、`/data/adb/ksu/.allowlist`（root 件，无 root 删不掉；内容为交付形状单条目 10342 suw，下次 stage L23 重写，**不污染**）。

## 6. 纪律复核

- ✅ 一次开机一枪：本发花掉，未重打。
- ✅ 窗口零接触：go.sh 跑期间未做额外 adb；判读只读落盘日志。
- ✅ 不可逆动作前等到用户点头（「开始」）。
- ✅ 无 root 时 `reboot` 即干净收窗。
- ⚠️ 唯一新增教训：**`timeout` 包 go.sh 是合理的**，但 20 分钟对于「卡在第 3 步」偏长；下次开火若仍用 timeout，建议 600s（10 分钟）即可，早杀早判读。
