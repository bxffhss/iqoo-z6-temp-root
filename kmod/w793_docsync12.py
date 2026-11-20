import hashlib
import io
import os
import sys

# w793_docsync12.py —— 第 54 发的文档同步（台账 §6.427 ＋ 三份入口件的新顶部小节 ＋ DELIVERY 登记）。
#   ★两条规矩写进代码里（都是欠过的）：
#   ①**fail-closed 必须是全量的**：先在内存里把**所有**文件的所有锚核完，任何一条不唯一 ⇒ 一个字都不写
#     （旧版逐文件「核锚＋写」，写过一半才在下一个文件红，恢复要靠 file-history）。
#   ②**可重入**：认出「这一节的标记已经在里面」就跳过，不当失败 ⇒ 换 @@W413@@ 之后可以反复跑。
#   ★回填占位的教训(本轮第二次)：插入件写完之后再改常量＋重跑**不会**补写已插入的小节(可重入逻辑会跳过)。
#     所以末尾多做一步：把四份文档里残留的 @@W413@@ 直接换成实哈希，并复证全文再无 @@ 残留。
#   ★文案里一律用「」不用 ASCII 双引号：CJK 串里混 ASCII 引号＝SyntaxError（今天第四次踩）。
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LB = os.path.join(ROOT, "kmod", "ROUTE-B-OFFSET-INVERSION.md")
CH = os.path.join(ROOT, "analysis", "CONTINUE_HERE.md")
CS = os.path.join(ROOT, "analysis", "CURRENT-STATUS.md")
DL = os.path.join(ROOT, "kmod", "DELIVERY.md")

GATE = "9af3f39e"
PLAN = "8d844a3d"
BREAK = "fab9f33a"
CLOSE = "b59a3c08"
TOOL = "26736f70"
ANA = "f3b01a6e"
GUARD = "ba96853a"

NEW_LB = u"""

## §6.427 —— 10-25 03:30–04:3x（**第 54 发，1 枪**）：★维持件真机判正——`rm -rf` 掉 root-only 的 bind 源之后**第 9 秒 `/product/bin/su` 自己长回来**，并且同窗另一条打字腿照样出 `uid=0`（＝恢复的不只是文件，是整条 root 通道）；两件取证：★**cap 的前提被打掉**（本窗预算 `total` 只到 **7/64**、`KSUBIRTH cap`=0 行）⇒ #185 的 A(抬 cap) 出局；★**收回我先前那句「今晚那次是源被 `rm -rf` 掉了」**——旧 `/data/local/tmp/pbin` 的目录 mtime 一直是 01:41，说明它在 04:22 之前从没被 unlinked 过

- **判据与读数全文**＝`kmod/w791_shot54_plan.md`＝`@@W791@@`（开枪前写死的那三条也在里面）；产物 `kmod/w103_evidence/shot54/`（`w774_keeper.log`／`w786.out`／`w777_read1.out`／`dmesg.live` 整份快照 6,381,167 B／`ksu_args.txt` 发后读回＝`67199f48…` 与登记值逐字节同一份）。
- **②维持件：源被删那一态判正**。一手序列（`w786.out`，破坏器经 Termux `su -c` 跑，`uid=0`）：前态 `/product/bin/su=在 源内文件=4` ⇒ `rm -rf /data/adb/ksu/pbin rc=0` ⇒ **立刻** `su=没了`＋mountinfo 变 `/adb/ksu/pbin//deleted`（今晚那个坏态被原样复现）⇒ **第 9 秒 `su` 回来了**；keeper 那两行＝`第 88 轮：…不在(deleted行=0 源内文件=0) ⇒ 重建#1` → `修好了`；计数 `重建=1 修好了=1 GIVEUP=0`。★判据不是「文件在」：破坏之后另派一条 `w777 read` 腿，回执 `uid=0` ⇒ **PATH 落点恢复了、root 通道通了**（这才是官方 Manager 依赖的那件事）。
- **②的另一半＝未测**：「源没被删、只是被 umount」这一态没上机造过——造它要用 root 腿，而当时的 root 腿就是被测对象（自指），我没做。离线 selfcheck 的样本 C 只证**判定形状**，不等于真机读数 ⇒ 挂 **#188**。
- **★维持件的真实边界（写清，别当万能）**：它重建时只放回 `su` 一支 ⇒ 源内文件 4→1（stage 那句 `cp -a /product/bin/.` 的三份原件没被补回）。后果局限在本窗（umount 后真 `/product/bin` 回来；复位后实测＝`f2fs_io init.qti.display.sh qvirtmgr` 三件、无 `su`）。口径＝**它是「把 su 放回去」，不是「把整层放回去」**。
- **③cap 取证（离线件 `kmod/w787_live_analyze.py`＝`@@W787@@`，夹具双向验过）**：`dmesg.live` 覆盖 `up=202→1886`（1684 秒，跟随件 03:53 停笔）；`KSUBIRTH` 45 行**全部**落在 `up 900–1200`（＝装载那一刻），之后零；`queued self fd`=3（`total` 最大 **7**，上限 64）＋`seen Manager`=2＋`dupskip`=13（`n` 最大 10241）＋`childskip`=27（合计正好 45，账平）；**`KSUBIRTH cap`=0**、`received signal 6`=0、`SIGSYS`=0。⇒ **#185 那条「长窗里 cap 极可能已吃光」的指认不成立**：一扇 ~44 分钟的窗只花掉 7/64，那把闸从没踢过。**A（抬 cap）出局**，B（cmdline 谓词把 `libksud.so`/`usap64` 这类 helper 排掉）只剩卫生理由、不再卡「长期存在」。
- **★仪器自坏一次（例 176③ 第二次兑现，所以转成了工具）**：第一版分析脚本用行锚定的方括号正则找时间戳 ⇒ 6 万行只数到 1,873 行「带时刻」，覆盖区间被读成 1190 秒、`total`/`dupskip` 最大值直接读成 `None`（＝假否据）。改成行内搜（允许 `<6>` 前缀）后才对上；`w787` 现在**自带一条死牙**：带时刻的行不到一半就 `[BAD]`＋rc=1。
- **④「谁删了 pbin」＝收回我说过的那句**。我说「源被 `rm -rf` 掉了」——实物证人驳掉：旧 `/data/local/tmp/pbin` 目录 mtime＝**01:41** 且一直活到今天 04:22 那条收尾腿把它删掉为止；被删过再重建的话 mtime 会是重建时刻。同一窗对得上时刻的**自己人**动作：01:41 的 `w135_um.err`（umount 动作发生过）与 **02:05 的 `w625_seedrestart.out`**——而用户口述「那文件十几分钟后消失」正落在 01:41+≈20 分钟。⇒ 更可能是**挂载被我们自己那条腿收回**（源还在、mountinfo 那行没了 ⇒ `/product/bin` 回到真空目录 ⇒ 裸 `su` 找不到），不是外部系统在自愈；inotify 那条**没做**，精确动作仍**未定** ⇒ 留在 **#184**。
- **⑤收尾腿自己暴露两个缺陷（都已修，但修正版**没上过机＝未认证**）**：
  1. **umount 失败照样 `rm -rf` 源** ⇒ 本窗收尾后 mountinfo 真的是 `/adb/ksu/pbin//deleted`——**本发要防的那个形状，被收尾腿自己复现了一次**（靠随后 reboot 清掉；复位后 pbin 行=0）。修法＝`-D` 重试一次＋**只有挂载行确实=0 才许删源**，否则只删名单、源留给下一发 stage 的前置闸重建（挂载不活过重启 ⇒ 留源不会变成常驻脚印）。
  2. **`chmod 666` 排在恢复执法之后** ⇒ 产物 `w789.out` 实得 `root:root 0600`，PC 侧只数得出 2967 字节、内容取不到 ⇒ 收尾里的 `umount rc`／`/data/adb 清之后`／`keeper 退了没` 三项是**「读不到」，不是「通过」**。修法＝权限在写第一行之前就好。⇒ 这条已固化成新闸 `kmod/w795_leg_guard.py`＝`@@W795@@`（夹具四格＋豁免表有牙；扫全仓 195 支设备腿：四支新红的里三支进豁免（`w223`/`w579`/`w767`——它们的哈希已当「现取」登记在台账，**改文件会把登记变成假话**，下次谁动这些件必须连带把登记改成「当时＝」），本发的 `w777`/`w789` 真修）。
- **⑥牌子的同发读数（0 额外枪）**：`up=3569.85`（≈**insmod+2633 秒**）焦点 OK ⇒ `工作中／32601-2／越狱有`、页签=3、包在场=是、pid 仍是 13506。这中间发生过：一次源删除＋维持件重建＋两条打字 root 腿。⇒ 「不重启长期存在」又添一个带时刻的格子；**「什么操作会让它灭」仍未捕获**（#52/#53/#54 三发累计：没复现过一次「灭」）。
- **交付口径**：出货默认**不变**——仍是第 53 发认证过的 `z6root.zip`＝`24664916…`（包内 ko＝`18750560…`＝rc74b，args 未动）。本发证明的是**形状**（root-only 源＋维持件在真机上救得回来），不是新包；`w450_close.sh` 里那条收尾腿**还没接维持件的 kill switch／root-only 源**（按用户放宽后的口径：root-only 那份留到下一发由 stage 前置闸 rm -rf 重建，可接受）⇒ 与 #187 一起做，**不许现在宣布升级**。
- **复位与本轮枪账**：收尾腿跑完后 `adb reboot`；复位独立读回 `Enforcing`／`mod=0`／pbin 挂载行=0／`/product/bin`＝3 件真文件、无 `su`／reason=`reboot,shell,1792873574`。★`/data/adb` 这一格本发**没能复证**（产物 0600 root 读不到）——记「未查」，下一发开窗时用 root 腿读回。10-25 枪数＝1。
- **登记(现取)**：判据＋读数 `kmod/w791_shot54_plan.md`＝`@@W791@@`｜破坏器 `kmod/w786_break_dev.sh`＝`@@W786@@`｜收尾腿修正版 `kmod/w789_close_dev.sh`＝`@@W789@@`(未上机)｜root 手修正版 `kmod/w777_root_tool.sh`＝`@@W777@@`｜离线分析 `kmod/w787_live_analyze.py`＝`@@W787@@`｜新闸 `kmod/w795_leg_guard.py`＝`@@W795@@`｜维持件 `kmod/w774_pbin_keeper.sh`＝`79752988…`(未动)｜stage `kmod/ksu_one_stage.sh`＝`1ee14343…`(未动)｜总闸 `kmod/w413_selftest_sweep.sh`＝`@@W413@@`。
"""

NEW_CH = (u"## ★★★★★★★★★★★★★★★★★★ **2026-10-25 03:30–04:3x 第 54 发(1 枪)：★维持件真机判正——"
          u"`rm -rf` 掉 root-only 的 bind 源后**第 9 秒 `/product/bin/su` 自己长回来**，同窗另一条打字腿仍出 `uid=0`"
          u"(＝恢复的是整条 root 通道，不只是文件)；★cap 取证把 #185 的前提打掉(本窗 `total` 只到 **7/64**、`KSUBIRTH cap`=0)；"
          u"★牌子的最长同窗读数 `insmod+2633 秒` 仍 `工作中／32601-2／越狱有`；并**收回**我先前那句「今晚是源被 rm -rf 掉了」\n\n"
          u"- **机器现在是干净基线**：收尾腿已跑完并 `adb reboot`(reason=`reboot,shell,1792873574`)；复位后实测 "
          u"`Enforcing`／`mod=0`／pbin 挂载行=0／`/product/bin`＝3 件真文件、无 `su`。★10-25 枪数＝1(第 54 发)。\n"
          u"- **判正的是哪半格、没测的是哪半格**：判正＝「**源被删**」那一态(≤9 秒＋`重建#1`/`修好了`/`GIVEUP=0`＋通道实测 `uid=0`)；"
          u"**未测**＝「只被 umount、源还在」那一态(造它要用 root 腿，而 root 腿当时就是被测对象＝自指，我没做)⇒ #188。"
          u"离线 selfcheck 的样本 C 只证判定形状，不许当真机读数。\n"
          u"- **维持件的真实边界**：它只把 `su` 一支放回源里(源内文件 4→1)，**不是「把整层 /product/bin 放回去」**；"
          u"后果局限在本窗(umount 后真目录回来，复位实测三件真文件)。\n"
          u"- **两条我自己腿里的缺陷(都修了，但修正版没上过机＝未认证)**：①umount 失败仍 `rm -rf` 源 ⇒ "
          u"**本窗收尾后 mountinfo 真的是 `/adb/ksu/pbin//deleted`**(本发要防的形状被收尾腿自己复现，靠 reboot 清)；"
          u"②`chmod 666` 排在恢复执法之后 ⇒ 收尾产物 0600 root 读不到，`umount rc`/`/data/adb 复证`/`keeper 退了没` "
          u"三项**是「读不到」不是「通过」**。②已转成常驻闸 `kmod/w795_leg_guard.py`(夹具四格＋豁免表有牙，扫 195 支设备腿)。\n"
          u"- **取证两件**：**cap**＝离线整份 `dmesg.live`(覆盖 `up=202→1886`)数出 `KSUBIRTH` 45 行全在装载那一刻那格、"
          u"`queued`=3(`total` 最大 **7**／64)、`dupskip`=13(`n` 最大 10241)、`childskip`=27、**`cap`=0** ⇒ "
          u"**#185 的「2.4 小时长窗里吃光」不成立，A(抬 cap)出局**，B 只剩卫生理由；**pbin 删除者**＝旧目录 mtime 01:41 一直没变 ⇒ "
          u"**收回**「源被 rm -rf」那句，改判为「更可能是挂载被 02:05 那条 `w625_seedrestart` 腿收回」，精确动作**仍未定**(inotify 没做)⇒ #184。\n"
          u"- **★仪器又绊了一次(例 176③ 第二次兑现)**：用行锚定的方括号正则找 dmesg 时间戳 ⇒ 6 万行只数到 1873 行带时刻、"
          u"覆盖区间读成 1190 秒、`total` 读成 `None`(假否据)。现在分析件 `kmod/w787_live_analyze.py` 自带一条死牙："
          u"带时刻的行不到一半就 `[BAD]`＋rc=1。\n"
          u"- **交付口径不变**：出货默认仍是第 53 发认证过的 `z6root.zip`＝`24664916…`(包内 ko＝rc74b `18750560…`、args `67199f48…` 未动)。"
          u"本发证明的是**形状**(root-only 源＋低频维持件救得回来)，不是新包；`w450_close.sh` 那条收尾腿还没接 kill switch/新源 ⇒ 与 #187 一并做，"
          u"**现在不许宣布升级**。\n"
          u"- **登记(现取)**：判据＋读数 `kmod/w791_shot54_plan.md`＝`" + PLAN + u"…`｜破坏器 `kmod/w786_break_dev.sh`＝`" + BREAK + u"…`｜"
          u"收尾腿修正版 `kmod/w789_close_dev.sh`＝`" + CLOSE + u"…`(未上机)｜新闸 `kmod/w795_leg_guard.py`＝`" + GUARD + u"…`｜"
          u"分析件 `kmod/w787_live_analyze.py`＝`" + ANA + u"…`｜维持件 `kmod/w774_pbin_keeper.sh`＝`79752988…`｜总闸 `kmod/w413_selftest_sweep.sh`＝`" + GATE + u"…`。\n"
          u"- **下一步(要一发)**：**#188**「只 umount、源还在」那一态补测＋**#187**「收尾腿两处修正上机，顺带把维持件的 kill switch/root-only 源接进 `w450_close.sh` 并重打包一次做完」——"
          u"两件同窗做掉最省；**#184** 那一格(UI 真点进超级用户页＋同刻 `logcat -b crash`)仍是「什么操作让它灭」的唯一未捕获项；"
          u"**#185 已降级**：A 出局、B 只是卫生，别为它烧枪。\n\n")

NEW_CS = (u"## ★★★★★★★★★★★★★★★★★★ 2026-10-25 04:3x 更新（本节最新，取代 00:2x 那节）—— "
          u"**第 54 发(1 枪)：维持件真机判正「源被删 ⇒ 第 9 秒 su 自己回来、root 通道实测仍通」；cap 取证判「#185 前提不成立」(7/64、cap=0)；牌子同窗最长读数 insmod+2633 秒**\n\n"
          u"- **现在能说的最强口径**：`z6root` 一键包(包内 ko＝rc74b)跑完之后，**bind 源被删也能自己恢复**——"
          u"源在 root-only 的 `/data/adb/ksu/pbin`，维持件 20 秒一拍、只在坏态动手；一手＝`rm -rf` 后 mountinfo 出现 "
          u"`/adb/ksu/pbin//deleted`(整层空壳)，**第 9 秒** `su` 回来，keeper 日志 `重建#1`→`修好了`、`GIVEUP=0`，"
          u"随后一条打字腿仍 `uid=0`。牌子在 `up=3569.85`(≈insmod+2633 秒)仍读 `工作中／32601-2／越狱有`。\n"
          u"- **三格如实挂着**：①「只 umount、源还在」那一态**未测**(＝#188)；②维持件**只放回 `su` 一支**(源内文件 4→1)，"
          u"别把它读成「整层都能自愈」；③收尾腿的两处缺陷(umount 失败仍删源／chmod 排在执法之后)**已修但修正版没上过机**＝#187。\n"
          u"- **收口状态**：机器已复位并独立读回——`Enforcing`、`mod=0`、pbin 挂载行=0、`/product/bin`＝3 件真文件、无 `su`；"
          u"`/data/adb` 本发**没能复证**(收尾产物 0600 root 读不到，记「未查」)。★10-25 枪数＝1。\n"
          u"- **取证与闸**：cap＝离线整份 `dmesg.live` 数出 `total` 最大 7/64、`KSUBIRTH cap`=0 ⇒ **#185 的 A 出局**；"
          u"新闸 `kmod/w795_leg_guard.py`(设备腿「产物权限必须排在恢复执法之前」，夹具四格＋豁免表有牙)；"
          u"分析件 `kmod/w787_live_analyze.py` 带「带时刻行数不到一半就红」的死牙(例 176③ 第二次兑现转成的牙)。\n"
          u"- 现值：判据＋读数 `kmod/w791_shot54_plan.md`＝`" + PLAN + u"…`｜`kmod/w789_close_dev.sh`＝`" + CLOSE + u"…`(未上机)｜"
          u"总闸 `kmod/w413_selftest_sweep.sh`＝`" + GATE + u"…`｜出货包(未变)`z6root.zip`＝`24664916…`、包内 ko＝`18750560…`。\n\n")

NEW_DL = (u"**10-25 04:3x 第 54 发（§6.427，1 枪）新登记／改值的件**：★**出货包没换**——仍是第 53 发认证过的 "
          u"`z6root.zip`＝`24664916…`(包内 `z6root/kernelsu.ko`＝`18750560…`＝rc74b、args `67199f48…`)。本发新增/改的是**工具形状**："
          u"root-only bind 源＋维持件 `kmod/w774_pbin_keeper.sh`＝`79752988…`(未动，本发判正的那半格＝「源被删」那态，"
          u"≤9 秒恢复＋`GIVEUP=0`，且随后打字 root 腿仍 `uid=0`)；破坏器 `kmod/w786_break_dev.sh`＝`" + BREAK + u"…`(无参数——"
          u"打字尾参会被输入法吃掉，今天三次退化成了默认模式)；收尾腿 `kmod/w789_close_dev.sh`＝`" + CLOSE + u"…`(★修正版**未上机**："
          u"加了 `-D` 重试＋「挂载行确实=0 才许删源」＋权限排在第一行之前)；常驻闸 `kmod/w795_leg_guard.py`＝`" + GUARD + u"…`。"
          u"**对用户的话**：现在包里那套东西在「源被删掉」这种意外下能自己长回 `su`(实测 9 秒)，"
          u"但**「不重启就永远亮着」我们仍然没证到**——三发累计没复现过一次「灭」，而「什么操作会让它灭」还是没捕获(要 UI 真点进超级用户页那一格)。\n\n")

OPS = [
    (LB, u"## §6.427 ——", NEW_LB, u"台账 §6.427", "append-guard"),
    (CH, u"\n## ★★★★★★★★★★★★★★★★★★ **2026-10-24 23:15–00:12 第 53 发(1 枪)", NEW_CH, u"CONTINUE_HERE 新顶部小节", "insert-before"),
    (CS, u"## ★★★★★★★★★★★★★★★★★★ 2026-10-25 00:2x 更新（本节最新，取代 22:4x 那节）", NEW_CS, u"CURRENT-STATUS 新顶部小节", "insert-before"),
    (CS, u"（本节最新，取代 22:4x 那节）", u"（已被 04:3x 那节取代）", u"CURRENT-STATUS 旧顶节改标签", "replace"),
    (DL, u"**10-24 17:3x 第 51 发（§6.416，1 枪）新登记**", NEW_DL, u"DELIVERY 第 54 发登记", "insert-before"),
]


def md5(p):
    return hashlib.md5(io.open(p, "rb").read()).hexdigest()


def fill(s):
    return (s.replace("@@W413@@", GATE).replace("@@W791@@", PLAN).replace("@@W786@@", BREAK)
             .replace("@@W789@@", CLOSE).replace("@@W777@@", TOOL).replace("@@W787@@", ANA)
             .replace("@@W795@@", GUARD))


print("=== w793 文档同步(第 54 发)：先全量核锚，再统一写 ===")
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
            print("  [跳过] %s ⇒ §6.427 已在台账里" % label)
            continue
        plan.append((p, "append", None, r, label))
        continue
    marker = r.strip().split("\n")[0][:70]
    if kind == "replace":
        # ★可重入的第二格(本轮第二次踩)：改标签这种「顶替」在第二次跑时锚必然=0——
        #   这时要看**替换后的文案**在不在，在就是已做过，不能当失败(否则整批 fail-closed 卡在一句已完成的改动上)。
        if a not in cur and r in cur:
            print("  [跳过] %s ⇒ 新文案已在(替换已做过)" % label)
            continue
    elif kind != "replace" and marker and marker in cur:
        print("  [跳过] %s ⇒ 认出了这一节的标记，说明已经写过" % label)
        continue
    n = cur.count(a)
    if n != 1:
        print("  [x] %s 的锚命中 %d 次(要求恰好 1) ⇒ **全批不写**" % (label, n))
        fail = 1
        continue
    plan.append((p, kind, a, r, label))

if fail:
    print("[x] 核锚没过 ⇒ 一个字都没写(全量 fail-closed)。修锚或确认是不是已写过。")
    sys.exit(1)

if not plan:
    print("  没有要写的东西 ⇒ 文档已经是第 54 发的形状")
else:
    for p, kind, a, r, label in plan:
        if kind == "append":
            work[p] = work[p].rstrip("\n") + "\n" + r
        elif kind == "insert-before":
            if a.startswith("\n"):
                work[p] = work[p].replace(a, "\n" + r + a.lstrip("\n"), 1)
            else:
                work[p] = work[p].replace(a, r + a, 1)
        else:
            work[p] = work[p].replace(a, r, 1)
        print("  [备好] %s" % label)
    for p in work:
        if work[p] != texts[p]:
            io.open(p, "w", encoding="utf-8", newline="\n").write(work[p])
            print("  [写] %s" % os.path.relpath(p, ROOT).replace("\\", "/"))

print("  写完后哈希(前 8)：CONTINUE=%s CURRENT=%s DELIVERY=%s 台账=%s"
      % (md5(CH)[:8], md5(CS)[:8], md5(DL)[:8], md5(LB)[:8]))
print("  ★还要做：把 w787/w793/w795 注册进 w413 的 py 闸 ⇒ 跑 w413 ⇒ 取新值回填 GATE ⇒ 重跑本件 ⇒ 再跑 w415(期望命中 0)")
print("=== w793 完成 ===")
