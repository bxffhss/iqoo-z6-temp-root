import hashlib
import re
import io
import os
import sys

# w814_docsync14.py —— 第 56 发的文档同步：台账 §6.429 ＋ 两份入口件的新顶部小节 ＋ DELIVERY 登记 ＋ 总闸哈希轮转。
#   ★哈希一律运行时现算（第 54 发那回把 token 名写错，静默留下 19 处占位符 ⇒ 不再用占位符）。
#   ★拼接串里一律「」，不用 ASCII 双引号（这一版第一次写出来就是踩在这条上，第四次）。
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LB = os.path.join(ROOT, "kmod", "ROUTE-B-OFFSET-INVERSION.md")
CH = os.path.join(ROOT, "analysis", "CONTINUE_HERE.md")
CS = os.path.join(ROOT, "analysis", "CURRENT-STATUS.md")
DL = os.path.join(ROOT, "kmod", "DELIVERY.md")


def h(rel, n=8):
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.exists(p):
        print("  [x] 要算哈希的件不存在：%s ⇒ 全批不写" % rel)
        sys.exit(1)
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()[:n]


V = {
    "PLAN": h("kmod/w811_shot56_plan.md"),
    "WATCH": h("kmod/w810_window_watch.sh"),
    "PROBE": h("kmod/w797_umount_only.sh"),
    "ENF": h("kmod/w813_enforce_only.sh"),
    "GATE": h("kmod/w413_selftest_sweep.sh"),
    "ZPACK": h("kmod/_tmp_selftest_rdst/run_z6pack.sh"),
    "ZIP": h("z6root.zip"),
    "ENTRY": h("kmod/z6root.sh"),
    "CLOSE": h("kmod/w450_close.sh"),
    "KO": h("z6root/kernelsu.ko"),
    "GUARD": h("kmod/w795_leg_guard.py"),
}
print("  现算：" + " ".join("%s=%s" % (k, v) for k, v in sorted(V.items())))
OLD_GATE = "57b582fe"
ZIP_CERT = "24664916"

REPS = [
    (CH, "`kmod/w413_selftest_sweep.sh`＝`" + OLD_GATE + "…`",
     "`kmod/w413_selftest_sweep.sh`（当时）＝`" + OLD_GATE + "…`"),
    (CS, "`kmod/w413_selftest_sweep.sh`＝`" + OLD_GATE + "…`",
     "`kmod/w413_selftest_sweep.sh`（当时）＝`" + OLD_GATE + "…`"),
]

NEW_LB = u"""

## §6.429 —— 10-25 12:0x–12:4x（**第 56 发，1 枪**）：★★**#184 的机制抓到了——那块牌子会灭，是因为 64 格 fd 预算被「活不到 1 秒的 helper pid」占满、死后不还**（`total=64`、`KSUBIRTH cap` 1203 行／5.2 秒、当前 Manager `fd_ksu=0`、牌子读 `不支持` 而同刻 root 腿仍 `uid=0`＝用户那句「灭时 su 仍可用」逐字对上）；★**#188 判负**（维持件**看不见**别的 mount namespace 里的 umount）；★**#187 判正**（包内收尾腿修正版首次上机，三判据齐）；另量到**我们 `sys_enter` 回调 ≈104,000 次/秒**的全局被动成本

- **本发的性质换了**：判据本来是「空窗对照」（跑完一键什么都不派）。12:1x 用户按日常方式用了 Manager（他报「经常卡死闪退、重进能恢复越狱模式、现在掉回不支持」）⇒ **对照作废**，本发改判为「有动作」窗——代价是没拿到空窗寿命，收益是**拿到了灭的原因**。寿命只补一条：这窗带着风暴与 cap 耗尽**活到 insmod+1751 秒（≈29 分钟）没自己断** ⇒ 第 55 发那次 insmod+635 秒的 `HARD_RESET/PS_HOLD` **仍未归因**（「风暴→复位」这条嫌疑没被证实，也不排除；样本各 1）。
- **★机制（一手，全在同一 boot）**：insmod≈`up 2913` → 首次 `KSUBIRTH cap` 在 `up 3643.95`（**距装载 ≈731 秒**）→ 该段环里 `total=64`（＝上限）＋**`KSUBIRTH cap … refusing more birth fds this boot` 1203 行／5.2 秒 ≈233 次/秒** → 当前 Manager `pid=13767`、**`fd_ksu=0`**、`Seccomp=2` → 牌子（焦点 OK）＝**`不支持`**，同时刻 `mod=1`、root 腿 `uid=0` 照常。烧预算的：`logcat -b crash` 里成对的 `Fatal signal 31 (SIGSYS) syscall 142 … (libksud.so)`（12:15:22×2／12:16:10×2／12:16:23×2…；窗内 crash 15→29），且窗内 Manager 换过 pid（`18892→32020→13767`）。
  ⇒ **这不是「cap 设小了」，是槽位泄漏**：每个活不到 1 秒的 helper（`libksud.so`／`crash_dump64`）各占一格，**死后不还**。用户三句观察一次全解释：旧进程手里有 fd 就一直亮；反复进出超级用户页＝一格一格烧；烧光后新起进程一律拿不到 ⇒ 掉 `不支持` 且**重进也救不回来**（他早先「重进能恢复」＝复用了耗尽之前已装过 fd 的那个进程）。
  ⇒ ★**#185 要改判**：上一轮我写「A（抬 cap）出局、B 只是卫生」**错**——B（只给真主进程计预算／释放死 pid 的槽）是治因，A 是续命；合起来＝**rc74c**。
- **★被动成本（23 轮纯只读采样，`kmod/w810_window_watch.sh`）**：`fired#` 从 54,808,764 涨到 202,927,378 ⇒ **平均 103,901 次/秒**，风暴退去后仍 ≈79,934 次/秒 ⇒ `sys_enter` 回调是**全局每次 syscall 都进**（打印只是尾巴）。这条既是寿命问题的候选，也是「环只剩最后 100 秒」的原因。同期 `/proc/stat processes` 21.4 fork/秒（12:21 后 6.6）、`ctxt` ≈5,516/秒。
- **乙组＝#188 判负**：`w797_umount_only.sh` 真跑通——`umount rc1=0` ⇒ 它自己 ns 里 `挂载行=0`、`su 没了`、**`源内文件=4`（源还在＝形状对）**；**60 秒没回来**、`重建=0 修好了=0`，而 keeper 每轮照写 `好(su 在…)`：因为**在我和它所在的那个 ns 里挂载根本没动**（全程 `pbin行=1`、`su=在`）。⇒ 不是维持件坏，是**它和被保护对象不在同一 mount namespace**。口径改死：**维持件只覆盖「源被 unlink」这类跨 ns 可见的事；「被 umount」不覆盖**（判负，不是未测）。
- **丙组＝#187 判正**（包内那条腿第一次上机，三判据齐）：产物 `/sdcard/w450_close.txt` **PC 侧 `adb pull` 读得到**（＝第 54 发那处「权限排在执法之后」的缺陷已修的直接证人）；七个键全在：`killswitch_rm_rc=0`／`KEEPER_LEFT=退了`（keeper 自报 `开关被删 ⇒ 自退(第 68 轮)，不留孤儿`）／`umount_rc=1`＋`MOUNT_LEFT=0`／`rm_allow_rc=0`／`ALLOW_LEFT=[…No such file…]`／`rm_pbin_src_rc=0`（`pbin` 与 `sustatic` 复证都不在）／`KEEPER_NAMES=[]`。★顺带证到那道新闸**按可观察状态判、不按 rc 判**（`umount` 报 `Invalid argument`(rc=1) 而挂载行已 0 ⇒ 放行删源，符合设计）。★**甲组⑥（x 位的活证人）由此判正**：包自己铺的 `.sh` 能被 `su -c <绝对路径>` 直接 execve 跑通（第 55 发抓到的「三只没 x 位」在真链路上已修）。
- **★关窗铁律第三次实测**：翻回执法后同一个 root 壳里 `grep`/`tr`/`sync`/`cut` 全部 `inaccessible or not found`（这次连 `sync` 都没跑到，靠 reboot 兜）⇒ 恢复执法必须排在所有 root 腿之后。
- **复位标签的又一课**：我们命令的 `adb reboot` 这次在 `persist.sys.boot.reason.history` 里记成 **`cold,charger`**（上一次同样命令记的是 `reboot,shell`）⇒ **这条 property 的标签不能用来区分「我们收尾的复位」与「异常冷启动」**，只能靠时刻对齐。
- **交付口径（决定＝不升）**：本发这份 `z6root.zip`＝`@@ZIP@@` 手里有甲组①②③④⑤⑥直证＋丙组复证＋一键链两次实跑（55/56），但**甲组⑦「亮」这格读到的是「灭」**（被 ko 的 64 格预算挡住，不是包的形状问题）⇒ 按 #152/#178 的规矩，**默认仍是第 53 发认证过的 `@@ZIPCERT@@` 那一份**（其字节已不在仓里，快照在设备侧 `/sdcard/z6root_shot54_24664916`）；等 **rc74c** 随包发一次、把「亮」补上再一次性认证新包。**现在不许宣布升级。**
- **登记(现取)**：判据＋读数 `kmod/w811_shot56_plan.md`＝`@@PLAN@@`｜只读采样器 `kmod/w810_window_watch.sh`＝`@@WATCH@@`｜只-umount 探针 `kmod/w797_umount_only.sh`＝`@@PROBE@@`（已上机，判负）｜执法腿 `kmod/w813_enforce_only.sh`＝`@@ENF@@`｜入口件 `kmod/z6root.sh`＝`@@ENTRY@@`｜包内收尾腿 `kmod/w450_close.sh`＝`@@CLOSE@@`（**已上机判正**）｜分发件 `z6root.zip`＝`@@ZIP@@`、包内 ko＝`@@KO@@`｜忠实性闸 `run_z6pack`＝`@@ZPACK@@`（79 项全绿）｜常驻闸 `kmod/w795_leg_guard.py`＝`@@GUARD@@`｜总闸 `kmod/w413_selftest_sweep.sh`＝`@@GATE@@`。产物 `kmod/w103_evidence/shot56/`（`run.log`／`w810_shot56.csv`／`w797.out`／`w450_close.txt`／`w777_read1.out`／`w813.out`／`ksubirth_cap_segment.txt`＝600,000 B，内含那 1203 行 cap 原文）。
- **机器现态**：`Enforcing`、`mod=0`、pbin 挂载行=0、无 `/product/bin/su`；★10-25 枪数＝**3**（第 54/55/56 发）。
"""

NEW_CH = (u"## ★★★★★★★★★★★★★★★★★★ **10-25 12:0x–12:4x 第 56 发(1 枪)：★**#184 抓到机制——牌子会灭是因为"
          u"64 格 fd 预算被「活不到 1 秒的 helper pid」占满、死后不还**（`total=64`、`KSUBIRTH cap` 1203 行／5.2 秒、"
          u"当前 Manager `fd_ksu=0`、牌子 `不支持`，而同刻 root 腿仍 `uid=0`＝你说的「灭时 su 仍可用」逐字对上）；"
          u"★#188 **判负**：维持件看不见别的 mount namespace 里的 umount；★#187 **判正**：包内收尾腿修正版首次上机三判据齐；"
          u"另量到我们 `sys_enter` 回调 **≈104,000 次/秒** 的全局成本\n\n"
          u"- **性质换了**：本来是「空窗对照」，你 12:1x 按日常方式用了 Manager ⇒ 对照作废，改判「有动作」窗。"
          u"**没拿到空窗寿命，拿到了灭的原因。**寿命只补一条：这窗带着风暴与 cap 耗尽活到 **insmod+1751 秒(≈29 分)没自己断** "
          u"⇒ 第 55 发那次 insmod+635 秒的 `HARD_RESET/PS_HOLD` **仍未归因**。\n"
          u"- **机制链（同一 boot）**：insmod≈`up 2913` → 首次 `cap` 拒绝在 `up 3643.95`（**距装载 731 秒**）→ `total=64` 满 → "
          u"Manager `pid=13767`、`fd_ksu=0` → 牌子 `不支持`；烧预算的是 `Fatal signal 31 (SIGSYS) syscall 142 … (libksud.so)` 成对刷屏"
          u"（窗内 crash 15→29，Manager 换过 pid `18892→32020→13767`）。⇒ **是槽位泄漏，不是 cap 太小**："
          u"helper 的短命 pid 各占一格、死后不还；你早先「重进能恢复」＝复用耗尽前已装 fd 的旧进程，耗尽后重进也没用。"
          u"★#185 改判：**B 是治因、A 是续命**（合起来＝rc74c）。\n"
          u"- **被动成本**：`fired#` 在 1425 秒里 54,808,764 → 202,927,378 ⇒ **≈103,901 次/秒**（风暴退去后仍 ≈8 万/秒）——"
          u"`sys_enter` 回调是全局每次 syscall 都进；这也是「环只剩最后 100 秒」的原因。`/proc/stat processes` 21.4 fork/秒（后降到 6.6）。\n"
          u"- **#188 判负（形状要说准）**：探针那侧 `umount rc1=0／挂载行=0／su 没了／源内文件=4`(源还在)，60 秒没回来，"
          u"而 keeper 每轮写 `好(su 在)`——因为它和我所在的 ns 里挂载**没动** ⇒ **root 壳的 umount 不跨 ns，维持件覆盖不到**；"
          u"它只保「源被 unlink」这种跨 ns 都可见的事（第 54 发已判正）。\n"
          u"- **#187 判正**：包内 `w450_close.sh` 产物 PC 侧读得到（＝权限位置那处缺陷已修），七键齐"
          u"（`killswitch_rm_rc=0`／`KEEPER_LEFT=退了`＋keeper 自报 `开关被删 ⇒ 自退(第 68 轮)，不留孤儿`／`MOUNT_LEFT=0`／`rm_allow_rc=0`／`rm_pbin_src_rc=0`）；"
          u"★闸门被证是**按可观察状态判、不按 rc 判**（umount 报 Invalid argument 但挂载行已 0 ⇒ 才放行删源）。甲组⑥(x 位活证人)随之判正。"
          u"★还有第三条关窗铁律的实测：翻回执法后同一个 root 壳里 `grep`/`tr`/`sync`/`cut` 全部 `inaccessible or not found`。\n"
          u"- **交付决定＝不升**：这份 `z6root.zip`＝`" + V["ZIP"] + "…` 有 ①-⑥ 直证＋丙组复证，但⑦读到的是「灭」（被 ko 的预算挡住，不是包的形状）⇒ "
          u"默认仍是第 53 发那份 `24664916…`（快照 `/sdcard/z6root_shot54_24664916`）；等 rc74c 随包发一次、把「亮」补上再一次性认证。\n"
          u"- **下一步（要一发，先编 ko）**：**rc74c**＝(B) 出生安装只数「Manager uid 的线程组领头且 comm 不是 `libksud.so`/`crash_dump64`/`usap64` 这类 helper」"
          u"＋槽位可复用（死后归还）＋(A) `cap` 64→512；判据＝窗内反复进出超级用户页 20 次后 `total` 不再涨、`cap`=0 行、牌子仍亮；同窗顺手把新包认证补齐（⑦亮）。\n"
          u"- **登记(现取)**：判据＋读数 `kmod/w811_shot56_plan.md`＝`" + V["PLAN"] + "…`｜采样器 `kmod/w810_window_watch.sh`＝`" + V["WATCH"] + "…`｜"
          u"探针 `kmod/w797_umount_only.sh`＝`" + V["PROBE"] + "…`｜包内收尾腿 `kmod/w450_close.sh`＝`" + V["CLOSE"] + "…`(已上机判正)｜"
          u"总闸 `kmod/w413_selftest_sweep.sh`＝`" + V["GATE"] + "…`。\n\n")

NEW_CS = (u"## ★★★★★★★★★★★★★★★★★★ 2026-10-25 12:5x 更新（本节最新，取代 11:3x 那节）—— "
          u"**第 56 发(1 枪)：牌子「为什么会灭」抓到了＝64 格 fd 预算被 helper pid 占满且死后不还；#188 判负(umount 不跨 ns)；#187 判正(包内收尾腿修正版上机)**\n\n"
          u"- **一手读数**：`total=64`(满)＋`KSUBIRTH cap … refusing more birth fds this boot` **1203 行／5.2 秒**；"
          u"当前 Manager `pid=13767` `fd_ksu=0` ⇒ 牌子 `不支持`，同刻 `mod=1` 且 `su -c` 仍 `uid=0`。首次踢在距 insmod **731 秒**；"
          u"烧它的是 `libksud.so` 的 `SIGSYS syscall 142` 崩溃循环（窗内 crash 15→29）。⇒ **定性为槽位泄漏**"
          u"（helper 的短命 pid 各占一格、死后不还），不是 cap 太小；**#185 改判：B 治因＋A 续命＝rc74c**。\n"
          u"- **被动成本新量到**：`sys_enter` 回调 ≈**103,901 次/秒**（全局每次 syscall 都进；风暴退去后仍 8 万/秒）——它同时解释「环只剩 100 秒」。\n"
          u"- **#188 判负**：只 umount 那一态造成功了（该 ns 里 `挂载行=0`、`su 没了`、源还在），但 60 秒没恢复——"
          u"因为 root 壳的 umount **不跨 mount namespace** 传播 ⇒ 维持件看不见 ⇒ 覆盖范围改死为「只管源被 unlink」。\n"
          u"- **#187 判正**：包内 `w450_close.sh` 产物 PC 侧可读＋七键齐；甲组⑥(x 位活证人)随之判正；"
          u"闸门被证是**按可观察状态判**（umount rc=1 但挂载行=0 ⇒ 才放行删源）。执法翻转后同一个 root 壳连 `sync` 都跑不动（关窗铁律第三次实测）。\n"
          u"- **寿命只得到一条**：这窗带着风暴与 cap 耗尽活到 **insmod+1751 秒**没自己断 ⇒ 第 55 发 insmod+635 秒那次复位**仍未归因**。\n"
          u"- **交付**：`z6root.zip`＝`" + V["ZIP"] + "…` **不升**（⑦「亮」缺凭据，被 ko 的预算挡住）；默认仍第 53 发那份（快照 `/sdcard/z6root_shot54_24664916`）。"
          u"**下一发**：编 rc74c（B＋A）→ 随包发一次 → 同窗把「亮」补上并认证新包。\n"
          u"- 现值：判据＋读数 `kmod/w811_shot56_plan.md`＝`" + V["PLAN"] + "…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`" + V["GATE"] + "…` rc=0、`w415` 命中 0｜"
          u"机器已复位 `Enforcing mod=0`、**10-25 枪数＝3**。\n\n")

NEW_DL = (u"**10-25 12:5x 第 56 发（§6.429，1 枪）新登记／改值的件**：★**交付默认仍不升**——当前仓里这份 `z6root.zip`＝`" + V["ZIP"] + "` 缺甲组⑦「亮」的凭据"
          u"（它读到的是「灭」：ko 的 64 格出生安装预算被 helper 崩溃循环烧光；认证过的那一份 `24664916` 快照在设备侧 `/sdcard/z6root_shot54_24664916`）。"
          u"本发改动：包内收尾腿 `kmod/w450_close.sh`＝`" + V["CLOSE"] + "`（**已上机判正**：kill switch 先删、`MOUNT_LEFT` 不为 0 就不删源、产物权限排最前）；"
          u"入口件 `kmod/z6root.sh`＝`" + V["ENTRY"] + "`（x 位改成从 MANIFEST 现数，本发实测 7 只全拿到并 execve 成功）。"
          u"**给使用者两句实话**：①同一 boot 内**反复进出超级用户页／反复让管理器起 root 服务**会把那块牌子的预算(64 格)烧光，之后牌子一直停在 `不支持`、"
          u"重进也回不来——但 `/system/bin/su` 那条 root 通道不受影响，`reboot` 后预算重置；②要长期亮着的正解是 **rc74c**"
          u"（只给真正的管理器主进程计预算＋槽位可复用＋抬上限），这活儿现在排在所有待办最前。忠实性闸 79 项全绿、"
          u"总闸 `kmod/w413_selftest_sweep.sh`＝`" + V["GATE"] + "` rc=0、`w415` 命中 0。\n\n")

OPS = [
    (LB, u"## §6.429 ——", NEW_LB, u"台账 §6.429", "append-guard"),
    (CH, u"\n## ★★★★★★★★★★★★★★★★★★ **2026-10-25 10:4x–11:2x 第 55 发(1 枪)", NEW_CH, u"CONTINUE_HERE 新顶部小节", "insert-before"),
    (CS, u"## ★★★★★★★★★★★★★★★★★★ 2026-10-25 11:3x 更新（本节最新，取代 04:3x 那节）", NEW_CS, u"CURRENT-STATUS 新顶部小节", "insert-before"),
    (CS, u"（本节最新，取代 04:3x 那节）", u"（已被 12:5x 那节取代）", u"CURRENT-STATUS 旧顶节改标签", "replace"),
    (DL, u"**10-25 11:3x 第 55 发（§6.428，1 枪）新登记／改值的件**", NEW_DL, u"DELIVERY 第 56 发登记", "insert-before"),
]
OPS += [(p, a, r, u"轮转登记值(全处改标)：" + os.path.basename(p), "replace-all") for p, a, r in REPS]


def fill(s):
    for k, v in V.items():
        s = s.replace("@@" + k + "@@", v)
    return s.replace("@@ZIPCERT@@", ZIP_CERT)


print("=== w814 文档同步(第 56 发)：先全量核锚，再统一写 ===")
texts = {}
for p, _, _, _, _ in OPS:
    if p not in texts:
        texts[p] = io.open(p, encoding="utf-8").read()
work = dict(texts)
plan = []
fail = 0
for p, anchor, repl, label, kind in OPS:
    a = fill(anchor)
    r = fill(repl)
    cur = work[p]
    if kind == "append-guard":
        if a in cur:
            print("  [跳过] %s ⇒ 已在台账里" % label)
            continue
        plan.append((p, "append", None, r, label))
        continue
    if kind == "replace-all":
        # 「全处改标」：同一句登记值在一份文件里出现多轮(第 54/55 发各写了一次)时，**每一处都要改成"当时＝"**，
        #   否则留着的那几处就是假话(w415 的 R9 逐条回看，会在 md5 不符时报红)。
        c = cur.count(a)
        if c == 0:
            if r in cur:
                print("  [跳过] %s ⇒ 已改过 %d 处" % (label, cur.count(r)))
            else:
                print("  [x] %s 的锚命中 0 次且新文案也不在 ⇒ 全批不写" % label)
                fail = 1
            continue
        plan.append((p, "replace-all", a, r, label))
        continue
    marker = r.strip().split("\n")[0][:70]
    if kind == "replace":
        if a not in cur and r in cur:
            print("  [跳过] %s ⇒ 新文案已在" % label)
            continue
        if cur.count(a) != 1:
            print("  [x] %s 的锚命中 %d 次 ⇒ 全批不写" % (label, cur.count(a)))
            fail = 1
            continue
    else:
        if r.strip().split("\n")[0][:70] in cur:
            print("  [跳过] %s ⇒ 标记已在" % label)
            continue
        if cur.count(a) != 1:
            print("  [x] %s 的锚命中 %d 次 ⇒ 全批不写" % (label, cur.count(a)))
            fail = 1
            continue
    plan.append((p, kind, a, r, label))
if fail:
    print("[x] 核锚没过 ⇒ 一个字都没写。")
    sys.exit(1)
for p, kind, a, r, label in plan:
    if kind == "append":
        work[p] = work[p].rstrip("\n") + "\n" + r
    elif kind == "insert-before":
        work[p] = work[p].replace(a, ("\n" + r + a.lstrip("\n")) if a.startswith("\n") else (r + a), 1)
    elif kind == "replace-all":
        work[p] = work[p].replace(a, r)
    else:
        work[p] = work[p].replace(a, r, 1)
    print("  [备好] %s" % label)
n = 0
for p in work:
    if work[p] != texts[p]:
        io.open(p, "w", encoding="utf-8", newline="\n").write(work[p])
        n += 1
        print("  [写] %s" % os.path.relpath(p, ROOT).replace("\\", "/"))
bad = 0
for p in work:
    t = io.open(p, encoding="utf-8").read()
    # ★只盯自家 token(`@@名字@@`)：正文里本来就有 `@@@PKGS` 和引用别人代码的 `count("@@")`，
    #   用裸 `@@` 当判据会假报警——这条在 §6.42x 里就记过一次(守卫太笼统)，别再来一遍。
    left = sorted(set(re.findall(r"@@[A-Z][A-Z0-9_]*@@", t)))
    if left:
        print("  [x] %s 里还有占位符 %s" % (os.path.relpath(p, ROOT), left))
        bad = 1
print("  写了 %d 个文件；占位复证=%s" % (n, "干净" if not bad else "有残留"))
print("=== w814 完成 ===")
sys.exit(1 if bad else 0)
