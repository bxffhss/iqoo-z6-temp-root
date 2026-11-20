# -*- coding: utf-8 -*-
import io, os

root = r"G:/项目/Windows管理/usb/临时root"
p = root + r"/kmod/ROUTE-B-OFFSET-INVERSION.md"

sec = """
- **★第 13 发重打（shot13b，15:40 起，rc80+0x1a，全新 boot）判负＝社区路线装载即崩（决定性）**：
  - **开窗成功**：punch 层这次没冻死（punch.log 5678→9594B、pr 两线程 CPU 时间持续增长 ⇒ phase 2 慢但活着，非 §6.573 同款焊死）；本地独立时间轴 `shot13b_local_timeline.txt` 在 **`15:45:02`/`15:45:08` 出现 `mod=1 / Permissive / ksud 0666`**（与 `go_run_rc80_shot13b.log` 的 punch 进展吻合）⇒ **窗口真开了、ko 装载成功**。★这反过来证明 **punch 成功与否与 args 无关，是概率性 flake**（同 ko 同 exploit 的 `0x0` 第 12 发也成功开过窗）。
  - **≈20 秒后内核崩溃**：`15:45:21` PC 侧采样器报 `error: closed`、随后 adb `device not found`；设备回来时 **`boot_id` 已变、`up=62→121`、`mod=0`**、`bootreason=HARD_RESET/PS_HOLD/0x01+0x01`（PMIC 硬复位签名，与第 11 发逐字同款）。`NOREBOOT=1` 下 go.sh 不会自己 reboot ⇒ **自发崩溃被 PMIC 复位，非我方触发**。
  - **★决定性对照（证伪 §6.588 的单变量假设）**：
    - rc80 + `0x0`（第 12 发）：装载后活 **400s+** 不崩；
    - rc80 + `0x1a`（shot13b）：装载后 **≈20s** 崩；
    - rc79 + `0x1a`（第 11 发）：装载后 **≈18s** 崩；
    ⇒ 三发用**同一份 GhostLock exploit 开窗**（punch 在两种 mask 下都能成功），唯一差异是 `ksu_hook_mask`；**`0x1a`（stat/access 钩子武装）就是崩因**，且**与分发器入口打印无关**（rc80 已删 BN 打印仍崩）。⇒ §6.588 原假设「删打印即够」**被证伪**；stat/access 钩子路径本身（每秒几千次 `strncpy_from_user_nofault`+`memcmp`+`orig_syscall_table` 查表 + trampoline）在本机高频下会把机器搞崩。
  - ★**诚实口径**：本发**没有**取到崩溃现场（dmesg 随崩溃重启蒸发，第 12 发起就记的「无内核事后日志」限制），所以只能凭「同 exploit 两种 mask 的存活时长差」做对照定崩因，不能给崩溃栈。这点照例写明，不编栈。
- **★社区路线判负结论（方向级）**：官方 KSU 的 `sucompat` 伪装**必须**武装 stat/access 钩子（`newfstatat`/`faccessat`，`0x1a` 的 bit3/4）才能把 `/system/bin/su` 内核改道——而这两条钩子在本机武装并在正常 syscall 负载下**约 20 秒必崩**。⇒ **社区 sucompat 路线在本设备根本不可稳定**，删打印、限流都救不了；要它活，得重构钩子路径（5.4 移植的 hook 机制在本机高频下不稳），属重大工程、非本次范围。
- **★隔离探针有效、§6.573 坑又踩一次**：重打前 `shot13_isolation_probe.sh` 全绿（40 ping 0 败、无残留 pr/shd、推件 md5 两端一致、boot_id 不变、`mod=0`）⇒ 设备/adb/推件层健康，空枪与它们无关，纯属 punch flake。但崩溃打断 go.sh 后 **`kmod/ksu_args.txt` 又停在 `7f2a8606…`(`0x1a`)**（EXIT 兜底没跑到）⇒ 已从 `bak_delivery` 复原成 `fec3d301…`(`0x0`) 并 `diff` 复证空（§6.573 同族坑第 2 次）。
- **★本发判据落点（§6.588 预登记 6 条）**：①装完不死＝**FAIL**（≈20s 崩）；②社区 su 伪装＝**未及测**（崩在钩子武装后极短窗口，su 判据链来不及跑）；③B(once)武装＝**未及读**（dmesg 随崩蒸发）；④callbacks suppressed＝**未及读**；⑤ioctl 回归＝**未及测**；⑥BN=0 编译期事实（仍成立）。⇒ 6 条里只有「不死」被证伪，其余因崩溃打断未达，全部记「未及测」不读成通过。
- **状态**：枪数 **13**（第 13 发重打算第 13 枪，开枪前是 12）；`load` 累计仍 **8**（零写入）；出货包 `z6root.zip` 未动；`rc80` 是实验候选 ko。设备经 `w161_teardown.sh`（后台 `agB78P`）回出厂态。
- **★给用户的方向决断（停一下问）**：「继续按社区路线走」现在撞到**硬墙**——社区 sucompat 路线在本机装载即崩（≈20s），删打印不够，需重构钩子路径才有望活，工程量大且本机 5.4 移植 hook 机制不稳。可选：
  (A) **接受稳定路线**：回到已证 `rc80+0x0`（纯 `/dev/ksud`+ioctl 拿 root，活 400s+），社区 su 伪装不要了；
  (B) **立项重构钩子**：把 stat/access 钩子路径在 5.4 本机改成不崩（深挖 `strncpy_from_user_nofault` 在高频下的行为/竞态），属大工程、不保证成功；
  (C) **试更窄 mask**：只留 bit1(execve) 不留 bit3/4，看能否部分伪装又不崩——但 `which su`/`ls -l` 伪装靠 bit3/4，留了才崩、不留就伪不成，大概率无解。
  ⇒ 按硬纪律「方向变更/不可逆/重大改动停下问」，本发不替你拍板，等选 A/B/C 或新指令。
"""

with io.open(p, "a", encoding="utf-8", newline="\n") as f:
    f.write(sec)
print("ledger §6.588 crash-verdict appended, size:", os.path.getsize(p))

logp = root + r"/.workbuddy/memory/2026-11-10.md"
lg = """
## 15:4x 第 13 发重打（shot13b）判负＝社区路线装载即崩（决定性）
- rc80+0x1a 全新 boot 重打：punch 这次没冻死（punch.log 5678→9594B，pr CPU 增长⇒phase2 慢非焊死），**15:45:02/15:45:08 出现 mod=1/Permissive/ksud 0666 ⇒ 窗口真开、ko 装载成功**（证明 punch 成败与 args 无关，纯概率 flake）。
- **≈20s 后内核崩溃**：15:45:21 PC 采样器报 error:closed→adb device not found；回来时 boot_id 变/up=62→121/mod=0/bootreason=HARD_RESET/PS_HOLD/0x01+0x01（PMIC 硬复位，与第11发同款；NOREBOOT=1 下非我方 reboot）。
- **决定性对照证伪单变量假设**：rc80+0x0(第12发)活400s+；rc80+0x1a(shot13b)崩≈20s；rc79+0x1a(第11发)崩≈18s。同 exploit 两种 mask 都开得了窗，唯一差异 hook mask ⇒ **0x1a 的 stat/access 钩子武装+高频负载＝崩因**，与分发器打印无关（rc80 已删 BN 仍崩）。
- **社区 sucompat 路线本机根本不可稳定**（必须武装 bit3/4 才改道 /system/bin/su，而这两条武装即崩）。删打印/限流救不了，重构钩子路径才有望活——工程量大、5.4 移植 hook 机制本机不稳。
- 隔离探针 shot13_isolation_probe.sh 全绿（40ping 0败/无残留/推件md5一致/boot_id不变/mod=0）⇒ 空枪与设备层无关。§6.573 坑又踩：崩溃打断 go.sh，args 停在 0x1a，已从 bak_delivery 复原成 0x0 并 diff 复证空。
- 判据落点：①装完不死=FAIL；②~⑤未及测(崩打断)；⑥BN=0 编译期事实。枪数 13；load 仍 8；出货包未动。
- **方向决断交用户**：社区路线撞硬墙，给 A(接受稳定 rc80+0x0 ioctl 路线)/B(立项重构钩子)/C(试更窄 mask) 三选一或新指令。不替用户拍板。
"""

with io.open(logp, "a", encoding="utf-8", newline="\n") as f:
    f.write(lg)
print("daily log appended, size:", os.path.getsize(logp))
