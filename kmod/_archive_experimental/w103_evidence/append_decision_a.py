# -*- coding: utf-8 -*-
import io, os

root = r"G:/项目/Windows管理/usb/临时root"
p = root + r"/kmod/ROUTE-B-OFFSET-INVERSION.md"

sec = """
- **★方向决断（用户 15:5x 选 A：接受稳定路线）**：社区 sucompat 路线判负（装载即崩、删打印不够）后，用户明确选择 **(A) 回到已证 `rc80+0x0` 纯 `/dev/ksud`+ioctl 路线，社区 su 伪装放弃**。(B) 重构钩子、(C) 更窄 mask 均不立项。**⇒ 本设备的 going-forward root 路＝`rc80 + ksu_hook_mask=0x0`**：装完 ko 不死、`/dev/ksud`(10,78,0666) + `ioctl(GRANT_ROOT=0x4B01)` 名单内 uid 得 `uid=0`、名单外 EPERM（第 12 发已实证，可重复）。社区 `which su`/`su -c id` 伪装在本机**永远不装**。
  - **配置已对齐**：`kmod/ksu_args.txt` 与 `bak_delivery` 均为 `fec3d301…`(`0x0`)（§6.588 崩溃打断后已复原、`diff` 复证空）；实验件 `ksu_args.txt.community_0x1a`(`7f2a8606…`) 留作证据、不再被推。设备经 teardown 回干净态（`mod=0`/`Enforcing`/无 ksud/`overlay=0`）。
  - **不再做的事**：不重开 syscall 钩子、不动出货包 `z6root.zip`(rc78+`0x1a`)、不立项升级出货 ko、不为过整包造厂商没有的策略类型。
  - **状态收口**：枪数 13、`load` 累计 8（零写入）、所有实验链已 TaskStop 且 args 复原、设备干净。下一步如要活窗口，按稳定形状再开一发即可（同第 12 发 `NOREBOOT=1 KO=kmod/kernelsu_rc80.ko`）。
"""

with io.open(p, "a", encoding="utf-8", newline="\n") as f:
    f.write(sec)
print("ledger decision-A appended, size:", os.path.getsize(p))

logp = root + r"/.workbuddy/memory/2026-11-10.md"
lg = """
## 15:5x 方向决断：用户选 A（接受稳定 rc80+0x0 路线，社区 sucompat 放弃）
- 社区路线判负（rc80+0x1a 装载即崩）后，用户明确选 A：回到已证 rc80+0x0 纯 /dev/ksud+ioctl 路线，社区 su 伪装放弃。B(重构钩子)/C(更窄 mask) 均不立项。
- going-forward root 路锁定＝rc80 + ksu_hook_mask=0x0（第12发实证：装完不死/ksud 0666/ioctl 正负对照可重复）。
- 配置已对齐：ksu_args.txt 与 bak_delivery 均 fec3d301(0x0)，community_0x1a 留作证据不再推；设备 teardown 干净。不做的事：不重开钩子/不动出货包/不升级出货 ko。
- 状态收口：枪数13、load仍8、实验链已停且args复原、设备干净。要活窗口按稳定形状再开一发即可。
"""
with io.open(logp, "a", encoding="utf-8", newline="\n") as f:
    f.write(lg)
print("daily log appended, size:", os.path.getsize(logp))

# MEMORY.md 当前方向：把 A 已选写进现状与方向段
m = root + r"/.workbuddy/memory/MEMORY.md"
with io.open(m, "r", encoding="utf-8", newline="\n") as f:
    mt = f.read()

# 更新一句话现状时间戳/方向已定
old1 = ("## 一句话现状（11-10 15:5x，第 13 发重打判负后）\n"
        "iQOO Z6（V2220A/PD2220, SM7325, `5.4.281-qgki`, A14 **user**, SN `<DEVICE_SERIAL>`）：GhostLock(CVE-2026-43499) 临时 root 开窗 → `insmod` 自编 KernelSU 外部 `.ko` → 未改官方 Manager v3.3.0 授权。**第 12 发（rc80 + `0x0`）实证成功**：装完 ko 不死、`up` 单调 400s、`/dev/ksud` 0666、ioctl 正负对照齐。**第 13 发重打（rc80 + `0x1a`）判负＝装载成功(`mod=1`)后 ≈20s 内核崩溃**（`HARD_RESET/PS_HOLD`）⇒ **社区 sucompat 路线在本机武装 stat/access 钩子即崩，不可稳定**（删打印/限流救不了，决定性对照见 §6.588）。当前＝teardown 回干净关窗态（`mod=0`/`Enforcing`/无 ksud/`overlay=0`）；**枪数 13、load 累计 8（零写入）**；**方向决断待用户 A/B/C**（接受稳定 `0x0` 路线 / 重构钩子 / 试更窄 mask）。")
new1 = ("## 一句话现状（11-10 15:5x，方向已定：稳定 rc80+0x0 路线）\n"
        "iQOO Z6（V2220A/PD2220, SM7325, `5.4.281-qgki`, A14 **user**, SN `<DEVICE_SERIAL>`）：GhostLock(CVE-2026-43499) 临时 root 开窗 → `insmod` 自编 KernelSU 外部 `.ko` → 未改官方 Manager v3.3.0 授权。**第 12 发（rc80 + `0x0`）实证成功**：装完 ko 不死、`up` 单调 400s、`/dev/ksud` 0666、ioctl 正负对照齐且可重复。**第 13 发重打（rc80 + `0x1a`）判负＝装载成功(`mod=1`)后 ≈20s 内核崩溃**（`HARD_RESET/PS_HOLD`）⇒ **社区 sucompat 路线在本机武装 stat/access 钩子即崩，不可稳定**。★**用户已选 A：going-forward 锁定 `rc80 + 0x0` 纯 `/dev/ksud`+ioctl 路线，社区 su 伪装永久放弃**（B 重构钩子 / C 更窄 mask 均不立项）。当前＝teardown 回干净关窗态（`mod=0`/`Enforcing`/无 ksud/`overlay=0`）；**枪数 13、load 累计 8（零写入）**；配置默认两份均为 `fec3d301…`(`0x0`)。")
assert old1 in mt, "MEMORY 一句话现状锚点未匹配"
mt = mt.replace(old1, new1)

# 把"当前方向"段末的"等选 A/B/C 或新指令再动"改成已选 A 的收口
old2 = ("- **★给用户的方向决断（按硬纪律停下问，本栏不替你拍板）**：「继续按社区路线走」撞到硬墙——社区 sucompat 在本机装载即崩（≈20s），需重构 5.4 钩子路径才有望活。可选：\n"
        "  - (A) **接受稳定路线**：回到已证 `rc80+0x0`（纯 `/dev/ksud`+ioctl 拿 root，活 400s+），社区 su 伪装放弃；\n"
        "  - (B) **立项重构钩子**：把 stat/access 钩子路径在 5.4 本机改成不崩（深挖 `strncpy_from_user_nofault` 高频竞态/行为），大工程、不保证成功；\n"
        "  - (C) **试更窄 mask**：只留 bit1(execve) 不留 bit3/4——但 `which su`/`ls -l` 伪装靠 bit3/4，留了才崩、不留就伪不成，大概率无解。\n"
        "  ⇒ 等选 A/B/C 或新指令再动。")
new2 = ("- **★方向已定（用户 15:5x 选 A，本栏收口）**：社区 sucompat 在本机装载即崩（≈20s）⇒ 用户明确 **(A) 接受稳定路线**：going-forward 锁定 `rc80 + ksu_hook_mask=0x0`（纯 `/dev/ksud`+ioctl 拿 root，第 12 发实证活 400s+），**社区 su 伪装永久放弃**。(B) 重构钩子、(C) 更窄 mask 均不立项。**配置已对齐**：`ksu_args.txt`/`bak_delivery` 均 `fec3d301…`(`0x0`)；实验件 `community_0x1a`(`7f2a8606…`) 留作证据不再推。不再做的事：不重开 syscall 钩子、不动出货包 `z6root.zip`(rc78+`0x1a`)、不升级出货 ko。要活窗口按稳定形状再开一发即可（同第 12 发 `NOREBOOT=1 KO=kmod/kernelsu_rc80.ko`）。")
assert old2 in mt, "MEMORY 当前方向锚点未匹配"
mt = mt.replace(old2, new2)

with io.open(m, "w", encoding="utf-8", newline="\n") as f:
    f.write(mt)
print("MEMORY.md updated, size:", os.path.getsize(m))
