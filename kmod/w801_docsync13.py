import hashlib
import io
import os
import sys

# w801_docsync13.py —— 第 55 发的文档同步：台账 §6.428 ＋ 三份入口件的新顶部小节 ＋ 四处「登记值已经变成假话」的轮转。
#   ★这一版把哈希改成**运行时现算**(md5 直接读仓内文件)，从根上取消「先跑再回填」那一格——
#     第 54 发那轮回填的 token 名写错(PLAN vs @@W791@@)，一条也没换上、文档里留下 19 处字面量占位符。
#   ★两条老规矩仍在：①fail-closed 是**全量**的(所有锚先在内存里核完，任何一条不唯一就一个字都不写)；
#     ②可重入(插入认「新节标记已在」、替换认「新文案已在且旧文案不在」)。
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LB = os.path.join(ROOT, "kmod", "ROUTE-B-OFFSET-INVERSION.md")
CH = os.path.join(ROOT, "analysis", "CONTINUE_HERE.md")
CS = os.path.join(ROOT, "analysis", "CURRENT-STATUS.md")
DL = os.path.join(ROOT, "kmod", "DELIVERY.md")
W3 = os.path.join(ROOT, "kmod", "W345_RC68_WINDOW.md")


def h(rel, n=8):
    p = os.path.join(ROOT, rel.replace("/", os.sep))
    if not os.path.exists(p):
        print("  [x] 要算哈希的件不存在：%s ⇒ 全批不写" % rel)
        sys.exit(1)
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()[:n]


V = {
    "PLAN": h("kmod/w796_shot55_plan.md"),
    "PROBE": h("kmod/w797_umount_only.sh"),
    "ENTRY": h("kmod/z6root.sh"),
    "CLOSE": h("kmod/w450_close.sh"),
    "KEEPER": h("kmod/w774_pbin_keeper.sh"),
    "STAGE": h("kmod/ksu_one_stage.sh"),
    "PACKER": h("kmod/w431_pack_z6root.sh"),
    "GATE": h("kmod/w413_selftest_sweep.sh"),
    "ZPACK": h("kmod/_tmp_selftest_rdst/run_z6pack.sh"),
    "GUARD": h("kmod/w795_leg_guard.py"),
    "ANA": h("kmod/w787_live_analyze.py"),
    "ZIP": h("z6root.zip"),
    "JC": h("z6root/教程.txt"),
    "KO": h("z6root/kernelsu.ko"),
}
print("  现算的登记值：" + " ".join("%s=%s" % (k, v) for k, v in sorted(V.items())))

OLD_GATE = "9af3f39e"
OLD_JC = "94d54851"
OLD_JC2 = "94d54851…"
ZIP_CERT = "24664916"          # 第 53 发认证过那一份(仓内已被本发重打包覆盖，设备侧留了整目录快照)

REPS = [
    (DL, "`z6root/教程.txt`＝`" + OLD_JC + "`",
     "`z6root/教程.txt`＝`" + V["JC"] + "`（★10-25 第 55 发改写了第 4 条「宿主必须是 uid=2000 的 shell」与第 7 条「收尾腿三件事」；当时 `" + OLD_JC + "`）"),
    (W3, "`z6root/教程.txt`=`" + OLD_JC2 + "`",
     "`z6root/教程.txt`=`" + V["JC"] + "…`（第 55 发改第 4/7 条；当时 `" + OLD_JC2 + "`）"),
    (CH, "`kmod/w413_selftest_sweep.sh`＝`" + OLD_GATE + "…`",
     "`kmod/w413_selftest_sweep.sh`＝`" + V["GATE"] + "…`（第 55 发把 ⑭ 组与 w797 注册进来；§6.427 那行的 `" + OLD_GATE + "…` 是第 54 发时刻的值）"),
    (CS, "`kmod/w413_selftest_sweep.sh`＝`" + OLD_GATE + "…`",
     "`kmod/w413_selftest_sweep.sh`＝`" + V["GATE"] + "…`（第 55 发注册 ⑭ 组与 w797；`" + OLD_GATE + "…` 是第 54 发时刻的值）"),
]

NEW_LB = u"""

## §6.428 —— 10-25 10:4x–11:2x（**第 55 发，1 枪**）：★这份新包的一键链在设备侧**跑通**(甲组①②③④⑤直证)；★但窗口在 **insmod+≈635 秒**被 `HARD_RESET/PS_HOLD` 打断，死前 100 秒内核打印到了 **127.8 行/秒**(第 54 发＝25.8)、`dupskip n` 从 10,241 冲到 **177,921**、`queued self fd` 的 `comm` 是 `crash_dump64`/`libksud.so` ⇒ **「窗口为什么会在 10 分钟里死」新的一格立在 #188/#187 前面**；甲组⑥⑦与乙组丙组＝**四格未测**

- **两条我自己犯的错(都当场被抓、都不是被测件的错)**：
  1. **宿主选错**：10:46 我把一键**打进 Termux** ⇒ Termux 是 app 域，`grep /proc/modules: Permission denied`、也写不动 `/data/local/tmp`。包在第 0 步停下、**一枪没打**(mod 仍 0，配额没花)。⇒ 教程第 4 条原来写「Stellar 或任何能提供 shell 的 app，等价 adb shell」**是错的**，已改成「必须是 uid=2000 的 shell 宿主(adb shell 最直接)」。
  2. **自家闸把「缺读数」说成「已有模块」**：旧写法 `[ "$MOD" = 0 ] || die "本 boot 已经有 kernelsu 模块"`——空读数照样 die 并给出**假原因**(例 174/178 那一族)。⇒ 改成三支(0／非数字＝宿主不对／其余＝真已装载)，并进了闸(run_z6pack ⑭a/⑭b/⑭c)。
- **0 枪抓到的一处真缺陷(包内入口件)**：`chmod 755` 那行在上一轮被我写成**引号粘连**(`" "$TMP/w774_pbin_keeper.sh"$TMP/w135_fix.sh"`) ⇒ keeper／`w135_fix.sh`／`w450_close.sh` **三只没拿到 x 位**，而句尾 `2>/dev/null` 把失败咽掉、包照样打得出来、清单照样逐条绿(＝例 176② 那一族：腿被 `su -c <绝对路径>` 直接 execve 时是 `exit=126`)。⇒ 改成**从 MANIFEST 现数**(`case "$N" in *.sh)`)，读数行 `chmod 的 .sh 件=[7 条清单命中] 实到=[…]` 把每只名字打出来；本发实测这行齐了 7 只(含 z6root.sh 自己)。★教训形状：**「契约写两处就会漂一处」——把名字列表的单一来源交给清单**。
- **甲组读数(这份新包＝`z6root.zip`＝`@@ZIP@@`，包内 ko＝`@@KO@@`＝rc74b)**：`入口形状=1`／目标包 com.termux 现取 uid=10667；`判据⑥ 到了（第 425 秒）`；活表 `count=1 total=1`＋`allow[0] uid=10667`＋`granted[10667] rc=0 granted=1`；MANIFEST 22 条逐条 `ok <名> <md5>`；`NOSUW_BIND_RC=0`、`NOSUW_CP_N=4`、`NOSUW_HEALTH=OK`、mountinfo 源＝`/adb/ksu/pbin`(**无 `//deleted`**)、`/product/bin/su`＝`-rwxr-xr-x root root 2241944`；args 读回＝`67199f48`(登记值同一份)；`=== Z6ROOT_DONE up=23971.79 mod=1 enforce=Permissive ===`。
  **未测的两格**：⑥「x 位的**活**证人」(要派打字腿 exec 一条包内 `.sh`，窗口没活到)——**静态证人不许顶替它**；⑦牌子(第一次 `adb shell` 就 `no devices`，那一刻已经掉了)。★乙组(#188 只 umount 那一态)与丙组(#187 包内收尾腿修正版)＝**未测**，这一发对它们**结论为零**，不许写成"跑输了"。
- **复位定量**：insmod≈`11:05:0x`(stage `11:05:01` 实参行／`11:05:03` allowlist 行) → keeper 最后一轮 `11:14:50 up=24531.68 第 29 轮：好(su 在，deleted行=0 源内文件=4)` → 环里最后一次写 `11:15:09.45 up=24550.48` → 新 boot≈`11:15:41`(现 `11:23:09 up=448.28` 反推)。⇒ **寿命≈10 分 35 秒，复位空档≈32 秒**。定性只认 `ro.boot.bootreason=HARD_RESET/PS_HOLD/0x01+0x01`＋history 里 `hard,1792898156`。
  ★**两条别上当**：①环里那 10 处 `PS_HOLD` **不是**死因打印，是 `cms_v5: check_uvlo_trigger: pon=HARD_RESET, poff=PS_HOLD` 每 11 秒的状态行，且它内嵌的是 **UTC**(比设备钟早 8 小时)——第一次读会以为日志属于另一段时间；②`ps -A` **看不到**维持件(comm=`sh`，脚本名不在列里)，`pgrep -f w774` 还会命中我自己的命令行 ⇒ 「keeper 在不在」只认**它自己的日志在推进**。
- **★死前的量化差别(同一支 ko、同一 args、两份件都在仓里，可复算)**：

  | 段 | 环覆盖 | KSUBEAT | KSUBIRTH | queued | `total` 最大 | `dupskip n` 最大 | `crash_dump64` 引用 |
  |---|---|---|---|---|---|---|---|
  | 第 54 发(活到 insmod+2633 s) | 1684 s | 43,433＝25.8/s | 45 | 3 | 7／64 | 10,241 | 7 |
  | 第 55 发(死前) | **100 s** | 12,783＝**127.8/s** | 396 | 9 | **25**／64 | **177,921** | 28 |

  死前两条 `queued self fd` 的 `comm`＝`crash_dump64`／`libksud.so` ⇒ 出生检查被大量进程创建反复命中、且同期确有进程在反复崩溃(环里没有 `Fatal signal` 行，logcat 不活过重启 ⇒ 只能算"有崩溃活动"，**不能算"谁崩"**)。
  **口径收住**：这**不是**"证明出生安装杀死窗口"。能说的只有：同一支 ko 两扇窗的被动成本差 5–17 倍；`KSUBIRTH cap` **仍然=0**(`total` 才 25/64，再次支持 #185 的 A 出局)；`dupskip` 数到 17 万说明**被调用次数**远超"Manager 出生"这件事。§6.198 那次同类 PS_HOLD 的风暴是**我们自己的 root sh** 造的，而这一次 insmod 之后我**一条 root 腿都没派**、只做了几次 shell 只读。
- **下一发的设计(单变量，先于 #188/#187)**：**空窗对照**——跑完一键后什么都不派(不打字、不点 UI、不起看门狗)，只让包自带的 stage/keeper 自己跑，看寿命与三个计数(KSUBEAT/s、`dupskip n`、`total`)。空窗也死在 ~10 分钟 ⇒ 是我们 ko 的**被动成本**(tracepoint 被调过多次＋打印洪水)；空窗活过 30 分钟 ⇒ 死因在本发派出去的那些动作里。★这一发顺带就能补甲组⑥⑦与 #188/#187(它们需要在窗内派腿)，但**顺序是先量寿命、再派腿**，别让补格污染对照。
- **交付口径(要说清，别含糊)**：本发这份 `@@ZIP@@` **不算认证完成**(甲组 5/7，⑥⑦未测、且没跑到收尾)。默认仍是第 53 发认证过的 `@@ZIPCERT@@` 那一份——★**那份的字节在仓里已被这次重打包覆盖**，但设备侧留了完整快照 `/sdcard/z6root_shot54_24664916`(23 件)。下一发要么把新包跑到七条齐＋收尾复证，要么把默认指回那份快照。**不许现在宣布升级。**
- **登记(现取)**：判据＋读数 `kmod/w796_shot55_plan.md`＝`@@PLAN@@`｜只-umount 探针 `kmod/w797_umount_only.sh`＝`@@PROBE@@`(未上机)｜入口件 `kmod/z6root.sh`＝`@@ENTRY@@`｜包内收尾腿 `kmod/w450_close.sh`＝`@@CLOSE@@`(**修正版仍未上机**)｜打包器 `kmod/w431_pack_z6root.sh`＝`@@PACKER@@`｜分发件 `z6root.zip`＝`@@ZIP@@`、包内 ko＝`@@KO@@`、包内教程＝`@@JC@@`｜忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`@@ZPACK@@`(**79 项全绿**，本发新加 ⑨e2/⑬a–j/⑭a–c)｜总闸 `kmod/w413_selftest_sweep.sh`＝`@@GATE@@` rc=0｜新常驻闸 `kmod/w795_leg_guard.py`＝`@@GUARD@@`｜分析件 `kmod/w787_live_analyze.py`＝`@@ANA@@`｜维持件＝`@@KEEPER@@`、stage＝`@@STAGE@@`(均未动)。
- **机器现态**：`Enforcing`、`mod=0`、pbin 挂载行=0、`/product/bin` 无 `su`(复位后自带真空目录)；`/data/adb/ksu/{pbin,sustatic}` 与开关 `ksu_pbin_keep` **还在**(按用户放宽的口径可留，下一发 stage 的前置闸会 rm -rf 重建)。★10-25 枪数＝**2**(第 54、55 发)。产物 `kmod/w103_evidence/shot55/`(`dmesg2.log` 2,050,761 B／`ksu_stage.log`／`w774_keeper.log`／一键 stdout `shot55_run.log`)。
"""

NEW_CH = (u"## ★★★★★★★★★★★★★★★★★★ **2026-10-25 10:4x–11:2x 第 55 发(1 枪)：★这份新包的设备侧一键**跑通**(甲组①②③④⑤直证：入口形状=1／活表 count=1 uid=10667 granted=1／bind 源=/adb/ksu/pbin 且带 x 位／MANIFEST 22 条逐条 ok／判据⑥第 425 秒到)；★但窗口在 **insmod+≈635 秒**被 `HARD_RESET/PS_HOLD` 打断，死前 100 秒 KSUBEAT 打到 **127.8 行/秒**(第 54 发 25.8)、`dupskip n`＝**177,921**、`queued` 的 comm 是 `crash_dump64`/`libksud.so` ⇒ 「窗口为什么 10 分钟就死」立在 #188/#187 之前；甲组⑥⑦＋乙组丙组＝**四格未测**\n\n"
          u"- **0 枪抓到的一处包内真缺陷(已修)**：入口件那句 `chmod 755` 上一轮被我写成**引号粘连** ⇒ keeper／`w135_fix.sh`／包内收尾腿**三只没拿到 x 位**，而 `2>/dev/null` 把失败咽掉、包照打、清单照绿(例 176② 那一族＝execve 无 x 位 ⇒ `exit=126`)。"
          u"⇒ 改成**从 MANIFEST 现数**，读数行把 7 只名字逐个打出来；**契约写两处就会漂一处**。\n"
          u"- **我自己的两条仪器错(都说清在哪一步)**：①把一键打进 Termux(app 域)⇒ 读不动 /proc、写不动 /data/local/tmp，包在第 0 步停下、**一枪没打**；教程第 4 条那句「任何能提供 shell 的 app 等价 adb shell」是错的，已改成「必须 uid=2000 的 shell 宿主」。"
          u"②拦下我的那把自家闸把**空读数**报成「本 boot 已经有 kernelsu 模块」＝假原因 ⇒ 改成分三支(0／非数字＝宿主不对／其余＝真已装载)，并进了闸(run_z6pack ⑭a–c)。\n"
          u"- **复位定量与两条别上当**：insmod≈11:05:0x → keeper 第 29 轮 `11:14:50 up=24531.68` 还在「好」→ 环最后写 `11:15:09 up=24550.48` → 新 boot≈11:15:41 ⇒ **寿命≈10 分 35 秒**。"
          u"环里 10 处 `PS_HOLD` **不是**死因，是 `cms_v5 check_uvlo_trigger` 每 11 秒的状态行(它内嵌 **UTC**，比设备钟早 8 小时)；`ps -A` 看不到维持件(comm=`sh`)、`pgrep -f w774` 会命中我自己的命令行 ⇒ keeper 在不在只认**它自己的日志在推进**。\n"
          u"- **量化对比(两份件都在仓里可复算)**：第 54 发＝25.8 行/秒、`total` 7/64、`dupskip n` 10,241；第 55 发死前＝**127.8 行/秒**、`total` 25/64、`dupskip n` **177,921**、`crash_dump64` 引用 28。"
          u"★`KSUBIRTH cap` **仍然=0** ⇒ #185 的 A 再次出局。**口径收住**：这不是「证明出生安装杀死窗口」，只能说同一支 ko 的被动成本差 5–17 倍；§6.198 那次同类风暴是我们自己的 root sh 造的，这次 insmod 后我**一条 root 腿都没派**。\n"
          u"- **交付口径**：本发这份 `z6root.zip`＝`" + V["ZIP"] + "…` **不算认证完成**(甲组 5/7，⑥x 位活证人与⑦牌子未测，且没跑到收尾)⇒ 默认仍是第 53 发认证过的 `" + ZIP_CERT + "…` 那一份——★那份字节在仓里已被重打包覆盖，**设备侧留了完整快照 `/sdcard/z6root_shot54_24664916`(23 件)**。不许现在宣布升级。\n"
          u"- **下一步(要一发，设计已定)**：**空窗对照**——一键跑完后**什么都不派**(不打字、不点 UI、不起看门狗)，只看寿命与三个计数(KSUBEAT/s、`dupskip n`、`total`)；"
          u"顺序是**先量寿命、再补 #188/#187 那三格**(它们要在窗内派腿，别让补格污染对照)。空窗也 ~10 分钟死 ⇒ 被动成本(打印洪水/tracepoint)；空窗活过 30 分钟 ⇒ 死因在本发派出去的动作里。\n"
          u"- **登记(现取)**：判据＋读数 `kmod/w796_shot55_plan.md`＝`" + V["PLAN"] + "…`｜入口件 `kmod/z6root.sh`＝`" + V["ENTRY"] + "…`｜包内收尾腿 `kmod/w450_close.sh`＝`" + V["CLOSE"] + "…`(仍未上机)｜"
          u"分发件 `z6root.zip`＝`" + V["ZIP"] + "…`(包内 ko＝`" + V["KO"] + "…`、教程＝`" + V["JC"] + "…`)｜忠实性闸＝`" + V["ZPACK"] + "…`(79 项全绿)｜总闸 `kmod/w413_selftest_sweep.sh`＝`" + V["GATE"] + "…`。\n\n")

NEW_CS = (u"## ★★★★★★★★★★★★★★★★★★ 2026-10-25 11:3x 更新（本节最新，取代 04:3x 那节）—— "
          u"**第 55 发(1 枪)：新包的设备侧一键跑通(甲组 5 条直证)，但窗口 insmod+≈635 秒撞 `HARD_RESET/PS_HOLD`；死前打印密度 127.8 行/秒、`dupskip n` 177,921 ⇒ 「窗口为什么这么短命」成了新的首要格**\n\n"
          u"- **能说的最强口径**：这份包(现 `z6root.zip`＝`" + V["ZIP"] + "…`，包内 ko＝rc74b `" + V["KO"] + "…`)在设备侧一条命令把链跑到底——"
          u"`入口形状=1`、活表 `count=1 uid=10667 granted=1`、root-only bind `NOSUW_BIND_RC=0` 且 `/product/bin/su` 带 x 位、`判据⑥` 第 425 秒到、`Z6ROOT_DONE mod=1`。"
          u"**它还没被认证完**：⑥x 位的活证人与⑦牌子两格未测(窗口没活到)，收尾腿也没跑。\n"
          u"- **新的墙(比牌子更硬的一层)**：窗口在 **insmod+≈635 秒**被 PMIC 硬复位(`ro.boot.bootreason=HARD_RESET/PS_HOLD/0x01+0x01`，history `hard,1792898156`)。"
          u"死前 100 秒的内核打印密度是第 54 发的 **5 倍**(127.8 vs 25.8 行/秒)、`dupskip n` **177,921**(vs 10,241)、`queued self fd` 的 comm 是 `crash_dump64`/`libksud.so`。"
          u"★这不是「证明了出生安装致死」——只能说同一支 ko 的被动成本差别巨大；`KSUBIRTH cap` 仍=0。\n"
          u"- **四格未测(别记成跑输)**：甲组⑥(x 位活证人)、⑦(牌子)、乙组 #188(只 umount 那一态)、丙组 #187(包内收尾腿修正版)。\n"
          u"- **0 枪修掉的包内缺陷**：入口件 `chmod 755` 的名字列表被我写漂(引号粘连)⇒ 三只腿静默没 x 位；已改成**从 MANIFEST 现数**并加读数。另：教程第 4 条「任何能提供 shell 的 app 等价 adb shell」是错的 ⇒ 已改成「必须 uid=2000 的 shell 宿主」；自家铁律闸把空读数报成「已有模块」⇒ 已分三支。\n"
          u"- **下一步**：空窗对照(一键跑完什么都不派，只量寿命与三计数)，**先量寿命再补那四格**。\n"
          u"- 现值：判据＋读数 `kmod/w796_shot55_plan.md`＝`" + V["PLAN"] + "…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`" + V["GATE"] + "…` rc=0、`w415` 命中 0｜机器已复位(`Enforcing mod=0`、pbin 挂载行=0)、**10-25 枪数＝2**。\n\n")

NEW_DL = (u"**10-25 11:3x 第 55 发（§6.428，1 枪）新登记／改值的件**：★**交付默认不变**——认证过的那一份是第 53 发的 `z6root.zip`＝`" + ZIP_CERT + "…`；"
          u"**注意那份的字节已不在仓里**(本发改包内件后重打包覆盖了它)，完整快照在设备侧 `/sdcard/z6root_shot54_24664916`(23 件)。"
          u"当前仓里这份＝`" + V["ZIP"] + "…`(包内 `kernelsu.ko`＝`" + V["KO"] + "…`＝rc74b、args `67199f48…` 未动)，本发把它**跑到了一键链全绿**："
          u"`入口形状=1`／活表 `count=1 uid=10667 granted=1`／`NOSUW_BIND_RC=0`＋`/product/bin/su` 带 x 位／MANIFEST 22 条逐条 `ok`／`Z6ROOT_DONE mod=1 enforce=Permissive`。"
          u"★但它**不算认证完成**：甲组⑥「打字 exec 一条包内 `.sh`」与⑦牌子两格未测(窗口在 insmod+≈635 秒被 `HARD_RESET/PS_HOLD` 打断)，收尾腿也没跑到。"
          u"本发改动都登记在 §6.428：入口件 `chmod 755` 改成从 MANIFEST 现数(抓到三只腿静默没 x 位)、包内收尾腿 `kmod/w450_close.sh`＝`" + V["CLOSE"] + "…`(kill switch 先删＋挂载没收回就不许删源＋权限排在第一行之前，**仍未上机**)、"
          u"教程第 4 条(宿主必须 uid=2000)与第 7 条(收尾三件事)重写。**对用户的话**：现在能说的是「一键真的能跑通、su 落点带着可执行位被铺好了」；"
          u"不能说的是「牌子能长到不用重启」——这一扇窗 10 分半就被硬复位打断了，而**为什么**这一格是新立的首要问题。\n\n")

OPS = [
    (LB, u"## §6.428 ——", NEW_LB, u"台账 §6.428", "append-guard"),
    (CH, u"\n## ★★★★★★★★★★★★★★★★★★ **2026-10-25 03:30–04:3x 第 54 发(1 枪)", NEW_CH, u"CONTINUE_HERE 新顶部小节", "insert-before"),
    (CS, u"## ★★★★★★★★★★★★★★★★★★ 2026-10-25 04:3x 更新（本节最新，取代 00:2x 那节）", NEW_CS, u"CURRENT-STATUS 新顶部小节", "insert-before"),
    (CS, u"（本节最新，取代 00:2x 那节）", u"（已被 11:3x 那节取代）", u"CURRENT-STATUS 旧顶节改标签", "replace"),
    (DL, u"**10-25 04:3x 第 54 发（§6.427，1 枪）新登记／改值的件**", NEW_DL, u"DELIVERY 第 55 发登记", "insert-before"),
]
OPS += [(p, a, r, u"轮转登记值：" + os.path.basename(p), "replace") for p, a, r in REPS]


def fill(s):
    for k, v in V.items():
        s = s.replace("@@" + k + "@@", v)
    return s.replace("@@ZIPCERT@@", ZIP_CERT)


print("=== w801 文档同步(第 55 发)：先全量核锚，再统一写 ===")
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
            print("  [跳过] %s ⇒ §6.428 已在台账里" % label)
            continue
        plan.append((p, "append", None, r, label))
        continue
    marker = r.strip().split("\n")[0][:70]
    if kind == "replace":
        if a not in cur and r in cur:
            print("  [跳过] %s ⇒ 新文案已在(替换已做过)" % label)
            continue
        if cur.count(a) != 1:
            print("  [x] %s 的锚命中 %d 次(要求恰好 1) ⇒ 全批不写" % (label, cur.count(a)))
            fail = 1
            continue
    else:
        if marker and marker in cur:
            print("  [跳过] %s ⇒ 认出这一节的标记(已写过)" % label)
            continue
        if cur.count(a) != 1:
            print("  [x] %s 的锚命中 %d 次(要求恰好 1) ⇒ 全批不写" % (label, cur.count(a)))
            fail = 1
            continue
    plan.append((p, kind, a, r, label))

if fail:
    print("[x] 核锚没过 ⇒ 一个字都没写(全量 fail-closed)。")
    sys.exit(1)

for p, kind, a, r, label in plan:
    if kind == "append":
        work[p] = work[p].rstrip("\n") + "\n" + r
    elif kind == "insert-before":
        work[p] = work[p].replace(a, ("\n" + r + a.lstrip("\n")) if a.startswith("\n") else (r + a), 1)
    else:
        work[p] = work[p].replace(a, r, 1)
    print("  [备好] %s" % label)
n = 0
for p in work:
    if work[p] != texts[p]:
        io.open(p, "w", encoding="utf-8", newline="\n").write(work[p])
        n += 1
        print("  [写] %s" % os.path.relpath(p, ROOT).replace("\\", "/"))
# ★复证：不许有未替换的占位 token(第 54 发那一格：token 名写错＝静默留下 19 处字面量)
bad = 0
for p in work:
    t = io.open(p, encoding="utf-8").read()
    left = len([1 for x in ["@@PLAN@@", "@@ZIP@@", "@@GATE@@", "@@CLOSE@@", "@@JC@@"] if x in t])
    if left:
        print("  [x] %s 里还剩 %d 个占位 token" % (os.path.relpath(p, ROOT), left))
        bad = 1
print("  写了 %d 个文件；占位复证=%s" % (n, "干净" if not bad else "有残留"))
print("=== w801 完成 ===")
sys.exit(1 if bad else 0)
