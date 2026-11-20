import io, os, sys

CH = "analysis/CONTINUE_HERE.md"
CS = "analysis/CURRENT-STATUS.md"

NEW_CH = """## ★★★★★★★★★★★★★★★★★★ **10-25 16:4x 更新（本节最新）—— 第 57 发(1 枪，rc74c 首发)：★cap 那条症状**没再现**（窗活到 keeper 第 143 轮≈48 分钟＝历史最长；你报「关掉 Manager 再打开还是越狱模式」）；随后第 4 次未归因自发复位（这次 bootreason 直接给 `USB_CHARGER/PS_HOLD/0x01+0x01`）；★乙组 20 轮**整批作废记未测**（跑在刚重启、`mod=0` 的机器上）。同一时段你把约束重定了一次，见下面「约束重定」那条**

- **本发装上去的东西(现取)**：rc74c＝rc74b＋helper 表(`libksud.so`/`crash_dump64`/`debuggerd64`；★`usap64` 故意不排——第 51 发证过主进程排队时 comm 就是它)＋预算 `cap` 64→**4096**＋速率窗 `ksu_mgr_birth_rate=8`(用 `start_time` 的 ns 差，**不引 `jiffies`/`HZ`**)。ko `kmod/kernelsu_rc74c.ko`＝**`324eda4d…`**(5,113,968 B，未定义符号 **158＝rc73 的 158**⇒零新内核依赖)；包 `z6root.zip`＝**`880e9ef2…`**。
- **甲组①-⑥ 直证**：`Z6ROOT_DONE up=10436.79 mod=1 enforce=Permissive`、`判据⑥ 到了（第 865 秒）`。⑦牌子这格的凭据是**你的一句话**（重开仍越狱模式）＝**症状未再现**，不等于乙组已过。
- **乙组＝未测，两条仪器自坏我都认**：①第一版把 `keyevent 4` 排在 `am start` **之后**＝我自己把 Manager 踢下焦点(19/20 轮"焦点没拿到"是仪器动作)；②组件名 `.MainActivity` 凭印象写 ⇒ `Error type 3`，改成运行时 `cmd package resolve-activity` 现取＋非空断言。修完 12 轮焦点全对，但 `up=470~615` 说明**那 12 轮跑在没有窗的设备上** ⇒ 牌子必然读 `无`。★新记一条嘴：**没窗时我的判据词打的是「掉牌子」**——"没测"与"结论"同形，已改成 `未测(不是掉牌)`＋先断言 `mod` 再说话。
- **★约束重定（你 16:4x 的原话，逐字存）**：「我期望的只是硬重启root丢失（越狱模式不就是硬重启丢失吗，我说的不留痕，实际只是不想增加不必要的检测面），获取越狱模式哪些地方是否留痕，参照社区即可。另外，如果有反root策略/模块的话，社区的做法是使其失效/绕过吧？」⇒ **三条后果**：①**没开新战线**——「重启失效，重跑即复活」正是本机现状(运行期 insmod，不在 boot 镜像)，"开机自动回来"仍关闭；②**放松**：`.allowlist` 与 `/data/adb/ksu/*` 允许跨窗跨 boot 留着(§6.366/#153 已证 ko 下次装载会读进活表) ⇒ `z6root.sh:318`「改授权要重启重跑」那条限制第一次能往前走；改道落点不再必须钉 tmpfs，但**那要一发只动它**；③**反 root 那一问实物答掉：这台机摘不掉**——`/proc/modules` 给 `vr 36864 0 [permanent]`，全机 permanent 只 4 条 ⇒ `rmmod` 永远 EBUSY，且 `/sys/module/vr/parameters` 不存在(没有运行期旋钮)。社区(Z5 那份)其实也不是摘模块：`gl_lkm_nr` 走「先把全局执法打成 Permissive 再 `finit_module`」，而它的 `shim_81236.ko`＝`description=KSU symbol shim v3`＋导出 `selinux_state`/`selinux_blob_sizes`/…＝**给我们 `dev_syms.c` 同一问题的另一种解法，不是反 root 件**。⇒ 我们这一栏保持"绕过"口径(#78 夹 cred＋`killguard`＋3 条桩写回)，"原地改写厂商模块代码段"不做默认、不单方面试。
- **交付决定＝仍不升**：#190 乙组没跑完 ⇒ 默认仍是第 53 发 `24664916…`(快照 `/sdcard/z6root_shot54_24664916`)；`880e9ef2…` 等一发带乙组的窗。
- **下一发只要这几条命令**：`I_KNOW=1 bash kmod/go.sh`（默认已是 rc74c＋包 `880e9ef2`）→ 一键包 `/system/bin/sh /sdcard/z6root/z6root.sh` → **窗内**跑 `bash kmod/w824_birth_cycles.sh 20`（脚本已修好，判据看 `cap`＝0 行、`total≈20`、helper 证人在位、20 轮牌子仍亮）→ 顺带那条 0 枪的活：把 `su` 的参数契约做成 Magisk 兼容(`-v`/`-M`/带 uid 前缀/管道交互)好让 Scene 这类 app 能用。

"""

NEW_CS = """## ★★★★★★★★★★★★★★★★★★ 2026-10-25 16:4x 更新（本节最新，取代 12:5x 那节）—— **第 57 发(1 枪，rc74c 首发)：cap 症状未再现(窗到 keeper 第 143 轮≈48 分钟＝最长)；第 4 次未归因复位 `USB_CHARGER/PS_HOLD`；乙组整批作废记未测；★同时段用户重定约束＝只要求"硬重启才丢"，留痕参照社区；★反 root 答死：`vr` 是 `[permanent]`，摘不掉**

- **一手读数**：`Z6ROOT_DONE up=10436.79 mod=1 enforce=Permissive`、`判据⑥ 到了（第 865 秒）`、维持件终行 `16:16:11 up=13285.22 第 143 轮：好(su 在，deleted行=0 源内文件=4)`；用户一手「关掉 Manager 再打开还是越狱模式」⇒ **rc74c 要修那件事的症状未再现**（但**不是**乙组通过）。
- **复位标签**：新 boot `ro.boot.bootreason`＝`USB_CHARGER/PS_HOLD/0x01+0x01`；`persist.sys.boot.reason.history` 四条按时刻＝`reboot,shell,1792873574`／`hard,1792898156`(第 55 发)／`cold,charger,1792902902`(第 56 发收尾)／`cold,charger,1792916221`(本发)。⇒ **第 4 次未归因，仍零归因**；社区对照(Z5 包 `z5root.sh:59`)自己写着「arming 约 1/3 失败→黑屏自动重启」——同族 exploit 在同类机自带复位代价，**这是对照物不是归因**（他们死在 arming，我们死在 insmod 后 10~48 分钟）。
- **乙组＝未测**：`w824_cycles.csv` 那 12 行是**刚重启、`mod=0`** 的设备(`up=470~615`)；两处仪器自坏已修(`keyevent 4` 的位置／组件名现取)，并把「没窗时打印『掉牌子』」这条判据词改成 `未测(不是掉牌)`＋先断言 `mod`。
- **★约束重定（决定后续口径）**：只要求**硬重启才丢 root**；"不留痕"本意＝**不增加不必要的检测面**；留痕位置**参照社区**。⇒ 放松：`.allowlist`/`/data/adb/ksu/*` 允许跨窗跨 boot 留着(`z6root.sh:318` 那条「改授权要重跑」出现前进口子)、改道落点不再必须 tmpfs(要**单变量**一发)；不变：不碰 boot 期挂钩(＝他要的"硬重启丢")、关窗铁律、1 boot 1 枪、不 rmmod 活窗。
- **★反 root 那一问（0 枪，实物答）**：`vr 36864 0 [permanent]`＋全机 permanent 仅 4 条(`mem_ddr_size`/`boardinfo`/`vr`/`vivo_bsp_engine`)⇒ **`rmmod` 这条路结构上不存在**；`/sys/module/vr/parameters` 不存在。社区 Z5 那份的真实做法是 `gl_lkm_nr` 把执法打成 Permissive 再 `finit_module`（一手串 `[+] stage-1 (CVE-2026-43499) done: SELinux permissive`／`[realroot] cred patched -> exec /system/bin/sh`），其 `shim_81236.ko`＝`KSU symbol shim v3`(参数 `nsym`/`stage`，导出 `selinux_state` 等)＝**补符号件，不是反 root 件**。⇒ 我们继续用已结案的**绕过**(#78 谓词＝cred 脏位 ⇒ `capclamp`；`killguard=1`；rc61 写回 3 条桩)，"原地改写厂商模块代码段"不做默认。
- **交付**：不升——默认仍第 53 发 `24664916…`；本发这份 ko `324eda4d…`／包 `880e9ef2…` 等一发带乙组的窗一起认证。现值：总账 `md §6.430/§6.431`｜ko `324eda4d`｜包 `880e9ef2`｜机器 `Enforcing mod=0`、**10-25 枪数＝4**。

"""

def insert_before(path, anchor_prefix, block, label):
    s = io.open(path, encoding="utf-8").read()
    # 阶段一：全局核锚
    n = sum(1 for line in s.split("\n") if line.startswith(anchor_prefix))
    if n != 1:
        print("[x] %s 里锚点前缀 %r 命中 %d 行(必须恰好 1) ⇒ 停，一条都不写" % (path, anchor_prefix, n))
        return None
    if block.strip().split("\n")[0] in s:
        print("[x] %s 里已经有这份新块 ⇒ 不许重复插(会写两份)" % path)
        return None
    return (s, anchor_prefix)

jobs = [
    (CH, "## ★★★★★★★★★★★★★★★★★★ **10-25 12:0x–12:4x 第 56 发", NEW_CH, "CONTINUE_HERE"),
    (CS, "## ★★★★★★★★★★★★★★★★★★ 2026-10-25 12:5x 更新", NEW_CS, "CURRENT-STATUS"),
]
prepared = []
for path, anchor, block, label in jobs:
    r = insert_before(path, anchor, block, label)
    if r is None:
        sys.exit(1)
    prepared.append((path, anchor, block, label))

for path, anchor, block, label in prepared:
    lines = io.open(path, encoding="utf-8").read().split("\n")
    idx = [i for i, l in enumerate(lines) if l.startswith(anchor)]
    assert len(idx) == 1
    lines[idx[0]:idx[0]] = block.rstrip("\n").split("\n") + [""]
    io.open(path, "w", encoding="utf-8", newline="").write("\n".join(lines))
    back = io.open(path, encoding="utf-8").read()
    head = back.split("\n")[back.split("\n").index([l for l in back.split("\n") if l.startswith("## ★")][0])]
    print("[ok] %s 已插到最前；最新块标题：%s" % (label, head[:78]))
    for kw in ("USB_CHARGER/PS_HOLD", "[permanent]", "880e9ef2", "324eda4d"):
        assert kw in back, "%s 少证人 %s" % (label, kw)
    print("     四条一手证人(PS_HOLD／[permanent]／包 880e9ef2／ko 324eda4d)都在；行数=%d" % back.count("\n"))
