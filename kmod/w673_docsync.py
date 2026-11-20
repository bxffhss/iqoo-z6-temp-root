#!/usr/bin/env python3
"""w673_docsync.py —— 把 #180(恢复腿三把闸)这轮换掉的哈希，成对写回四份对外件。
   ★规矩：所有新值一律由本脚本现跑 md5sum 得到，**不手抄**；锚点(旧值那截原文)必须**恰好命中一次**，
     命中数不对就整个不写文件(例 152：半改的台账会骗过审计)。
   跑法：PYTHONUTF8=1 python kmod/w673_docsync.py
"""
import hashlib
import io
import sys

ROOT = "."


def md5(p):
    return hashlib.md5(io.open(ROOT + "/" + p, "rb").read()).hexdigest()


def first(h):
    return h[:8]


# ---------- 1) 先把新测量件注册进总闸的 bash -n 清单(唯一锚点) ----------
W413 = "kmod/w413_selftest_sweep.sh"
s = io.open(ROOT + "/" + W413, encoding="utf-8").read()
OLD413 = "kmod/w629_B_loop.sh cm57/build_sustatic.sh; do"
NEW413 = "kmod/w629_B_loop.sh kmod/w670_gate_test.sh cm57/build_sustatic.sh; do"
if "kmod/w670_gate_test.sh" in s:
    print("  [skip] w413 里已有 w670(这一轮已注册过)")
elif s.count(OLD413) != 1:
    print("[x] w413 锚点命中 %d 次(应为 1)⇒ 不改" % s.count(OLD413))
    sys.exit(1)
else:
    io.open(ROOT + "/" + W413, "w", encoding="utf-8", newline="\n").write(s.replace(OLD413, NEW413))
    print("  [OK] w413：w670 已接进 bash -n 清单")

# ---------- 2) 现取全部新值 ----------
H = {}
for p in ["kmod/w625_seedrestart.sh", "kmod/z6root.sh", "kmod/w431_pack_z6root.sh",
          "kmod/_tmp_selftest_rdst/run_z6pack.sh", "kmod/w558_mk_rm3.py", "kmod/w558_rm3.sh",
          "kmod/w597_arm_selftest.sh", "kmod/w413_selftest_sweep.sh", "kmod/w161_teardown.sh",
          "kmod/w670_gate_test.sh", "kmod/w629_B_loop.sh", "z6root/MANIFEST", "z6root/教程.txt",
          "z6root/w625_seedrestart.sh", "z6root/z6root.sh", "z6root.zip", "kmod/kernelsu_rc67.ko",
          "kmod/ksu_args.txt", "kmod/ksu_one_stage.sh"]:
    H[p] = first(md5(p))
print("  现取值：" + " ".join("%s=%s" % (p.split("/")[-1], v) for p, v in sorted(H.items())))

Z6 = H["kmod/z6root.sh"]
LEG = H["kmod/w625_seedrestart.sh"]
PACK = H["kmod/w431_pack_z6root.sh"]
GATE = H["kmod/_tmp_selftest_rdst/run_z6pack.sh"]
MKRM = H["kmod/w558_mk_rm3.py"]
RM3 = H["kmod/w558_rm3.sh"]
ARM = H["kmod/w597_arm_selftest.sh"]
SWP = H["kmod/w413_selftest_sweep.sh"]
MAN = H["z6root/MANIFEST"]
TUT = H["z6root/教程.txt"]
ZIP = H["z6root.zip"]

# ---------- 3) 四份对外件的成对改写 ----------
R = []   # (文件, 旧串, 新串)

# DELIVERY 第 1B 节里那三处"现值＝"
R.append(("kmod/DELIVERY.md",
          '`kmod/z6root.sh`＝`e5aad997…`（★10-24 00:2x 现值＝#176 那条恢复腿烤进包',
          '`kmod/z6root.sh`＝`%s…`（★10-24 03:5x 现值＝#180：恢复腿加三把硬闸(冷却 150 秒／每 boot 6 次／已在位不动进程)'
          '＋两条出口各加那句"别把它当刷新键按"；当时 `e5aad997`＝#176 那条恢复腿烤进包' % Z6))
R.append(("kmod/DELIVERY.md",
          '打包器 `kmod/w431_pack_z6root.sh`＝`f4df35a4…`（★10-24 00:2x 现值＝教程第 8 条按 §6.407 整段重写',
          '打包器 `kmod/w431_pack_z6root.sh`＝`%s…`（★10-24 03:5x 现值＝教程第 8 条加那三条闸的口径＋铁律补一句；'
          '当时 `f4df35a4`＝教程第 8 条按 §6.407 整段重写' % PACK))
R.append(("kmod/DELIVERY.md",
          '忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`171be7a4…`（★10-24 00:2x 现值＝**新增 ⑨ 组八口**',
          '忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`%s…`（★10-24 03:5x 现值＝**⑨ 组再加八口 ⑨i~⑨p**(那八口量的都是'
          '**包内那一份**，不是仓库那份：三把闸词元齐／默认值抽得出／教程的秒数次数与腿一致／锁与标记在删净名单里／'
          'nogate 在包里零生产者／腿在清单里)，含两条反夹具，自数 53→**61**；当时 `171be7a4`＝**新增 ⑨ 组八口**' % GATE))
# DELIVERY 重打包那一长句(清单＋包内三件＋分发件)
R.append(("kmod/DELIVERY.md",
          '`MANIFEST`＝`dbc83a62…`（★10-24 00:2x 现值＝**#176 恢复腿烤进包**那一次重打包：包内 `z6root/z6root.sh`＝`e5aad997…`、'
          '`z6root/教程.txt`＝`6e4d86c3…`、**新增 `z6root/w625_seedrestart.sh`＝`5600865d…`**，`z6root/kernelsu.ko` 仍 `40e0c25d…`；'
          '分发件 `z6root.zip`＝`5ac725d2…`',
          '`MANIFEST`＝`%s…`（★10-24 03:5x 现值＝**#180 重打包**：包内 `z6root/z6root.sh`＝`%s`、`z6root/教程.txt`＝`%s`、'
          '`z6root/w625_seedrestart.sh`＝`%s`，`z6root/kernelsu.ko` 仍 `40e0c25d…`；分发件 `z6root.zip`＝`%s`；'
          '#177 那一组(`e5aad997`/`6e4d86c3`/`5600865d`/`dbc83a62`/`5ac725d2`)作废留链' % (MAN, Z6, TUT, LEG, ZIP)))
# DELIVERY 第 49 发登记段：把四条已换版的**去成对**(名字与哈希不再相邻)，避免"看着像现值"
R.append(("kmod/DELIVERY.md", '恢复腿 `kmod/w625_seedrestart.sh`＝`5600865d…`',
          '恢复腿 `kmod/w625_seedrestart.sh`（当时 `5600865d`，现值见下一段）'))
R.append(("kmod/DELIVERY.md", '清理名单生成器 `kmod/w558_mk_rm3.py`＝`0d034877…`＋生成件 `kmod/w558_rm3.sh`＝`9860c9ce…`（**149 条**；',
          '清理名单生成器 `kmod/w558_mk_rm3.py`（当时 `0d034877`）＋生成件 `kmod/w558_rm3.sh`（当时 `9860c9ce`，**149 条**；现值见下一段；'))
R.append(("kmod/DELIVERY.md", '专属自测 `kmod/w597_arm_selftest.sh`＝`dad365a6…`（21 条牙；',
          '专属自测 `kmod/w597_arm_selftest.sh`（当时 `dad365a6`，21 条牙；现值见下一段；'))

# DELIVERY：#180 新登记段(插在"第 49 发…新登记"段之后、"工具件不进名单的真机凭据"那句之前)
R.append(("kmod/DELIVERY.md",
          '★**"工具件不进清理名单"这条规矩的真机凭据**：',
          '**10-24 #180（§6.411）新登记／改值的件**：恢复腿 `kmod/w625_seedrestart.sh`＝`%s…`（★三把闸：SR-COOL 冷却 150 秒／'
          'SR-BUDGET 每 boot 6 次／SR-ALREADY 当前进程就是上次种过 fd 的那个就不动它；凭据落 `/data/local/tmp/w625_lock`(0644，shell 读得到)；'
          '测量用另有 `w625_nogate` 标记，**包里零生产者**；已过设备 mksh `sh -n` rc=0＋两端 md5 一致）｜'
          '分支逻辑认证腿 `kmod/w670_gate_test.sh`＝`%s…`（★0 枪；它从仓库那份**现生**两份夹具、只重定向四个路径＋两处 fd 读数，'
          '归一化后与出货件逐字节同一份(cmp)；六格全踢到：C1 落锁／C2 SR-COOL／C3a-C3b SR-BUDGET／C4 SR-NOGATE／C5a-C5b SR-ALREADY，'
          '跑完自删夹具并 `ls` 复证）｜入口件 `kmod/z6root.sh`＝`%s…`、打包器 `kmod/w431_pack_z6root.sh`＝`%s…`、'
          '忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`%s…`(61 项全绿)、生成器 `kmod/w558_mk_rm3.py`＝`%s…`、'
          '生成件 `kmod/w558_rm3.sh`＝`%s…`(**151 条**＝名单里多了 `w625_lock`/`w625_nogate` 两枚脚印；工具件仍然一条都不在)、'
          '专属自测 `kmod/w597_arm_selftest.sh`＝`%s…`(26 条牙)、总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`｜'
          '包与分发件：`z6root/MANIFEST`＝`%s…`(21 行)、`z6root/教程.txt`＝`%s…`、`z6root.zip`＝`%s…`(zip 条目 22、'
          '非 ASCII 缺 UTF-8 标志=0)；设备 `/sdcard/z6root/` 已同步并用**设备自己那把 md5** 逐条对表＝不符 0／缺 0。'
          '★**这轮的边界(不许读成"闸已在真机上挡过")**：三把闸的**分支逻辑**是在夹具上认证的(那一发没有窗口，`mod=0`、触发口不在)；'
          '"牌子亮着时第二条命令真被 SR-ALREADY 挡住"那一格只能等 #178 那一发(它本来就要连敲两次)。\n'
          '★**"工具件不进清理名单"这条规矩的真机凭据**：' % (LEG, H["kmod/w670_gate_test.sh"], Z6, PACK, GATE, MKRM, RM3, ARM, SWP, MAN, TUT, ZIP)))

# DELIVERY §0 那条对外口径(第 113 行区域)
R.append(("kmod/DELIVERY.md",
          '`kmod/w625_seedrestart.sh`＝`5600865d…`（root 侧跑：`force-stop`→起 Manager→**0.1 秒**节拍盯新 pid→立刻写触发口→读回 fd）。',
          '`kmod/w625_seedrestart.sh`＝`%s…`（root 侧跑：`force-stop`→起 Manager→**0.1 秒**节拍盯新 pid→立刻写触发口→读回 fd）。'
          '★**别把它当刷新键按**(10-24 #180，一手＝用户连着敲之后硬复位)：它自己带三把闸——亮着再敲打 `SR-ALREADY`(不动任何进程)、'
          '150 秒内再敲打 `SR-COOL`、一个 boot 到 6 次打 `SR-BUDGET`；被拒不是坏，那期间 su 照常出 root。' % LEG))

# CONTINUE_HERE：现值整行重算
R.append(("analysis/CONTINUE_HERE.md",
          '- **现值(全部现取，别再抄旧文档)**：入口件 `kmod/z6root.sh`＝`e5aad997…`｜恢复腿 `kmod/w625_seedrestart.sh`＝`5600865d…`｜'
          '打包器 `kmod/w431_pack_z6root.sh`＝`f4df35a4…`｜清单 `z6root/MANIFEST`＝`dbc83a62…`(21 行)｜教程 `z6root/教程.txt`＝`6e4d86c3…`｜'
          '分发件 `z6root.zip`＝`5ac725d2…`(zip 条目 22)｜忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`171be7a4…`(**自数 53 项全绿**，含两条反夹具)｜'
          '总闸 `kmod/w413_selftest_sweep.sh`＝`daf3bdd1…`。',
          '- **现值(全部现取，别再抄旧文档；10-24 03:5x＝#180 之后)**：入口件 `kmod/z6root.sh`＝`%s…`｜恢复腿 '
          '`kmod/w625_seedrestart.sh`＝`%s…`(★加了三把闸：冷却 150 秒／每 boot 6 次／已在位不动进程)｜打包器 '
          '`kmod/w431_pack_z6root.sh`＝`%s…`｜清单 `z6root/MANIFEST`＝`%s…`(21 行)｜教程 `z6root/教程.txt`＝`%s…`｜'
          '分发件 `z6root.zip`＝`%s…`(zip 条目 22)｜忠实性闸 `kmod/_tmp_selftest_rdst/run_z6pack.sh`＝`%s…`(**自数 61 项全绿**，含四条反夹具)｜'
          '分支夹具腿 `kmod/w670_gate_test.sh`＝`%s…`｜收尾件生成件 `kmod/w558_rm3.sh`＝`%s…`(151 条)｜'
          '总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`。' % (Z6, LEG, PACK, MAN, TUT, ZIP, GATE,
                                                            H["kmod/w670_gate_test.sh"], RM3, SWP)))
# CONTINUE_HERE：仍欠那半格(把当前版号换掉＋把"闸只在夹具上认证过"写进去)
R.append(("analysis/CONTINUE_HERE.md",
          '- ★**仍欠的那半格(别读成"包已认证")**：当前版 `5ac725d2` **没过真机一键认证**；',
          '- ★**仍欠的那半格(别读成"包已认证")**：当前版 `%s` **没过真机一键认证**(#180 之后)；'
          '而且那三把闸现在只有**夹具上的分支逻辑**凭据(0 枪那一发 `mod=0`，真触发口不在)⇒ "亮着时真被 SR-ALREADY 挡住"那一格也排在这发；' % ZIP))

# CURRENT-STATUS：这行的括号是半角、句式也不同 ⇒ 锚点只取"`名字`＝`旧哈希…`"这一小截(唯一命中即可)
R.append(("analysis/CURRENT-STATUS.md", '`kmod/z6root.sh`＝`e5aad997…`',
          '`kmod/z6root.sh`＝`%s…`(★10-24 03:5x＝#180 两出口各加"别把它当刷新键按"；上一版 e5aad997)' % Z6))
R.append(("analysis/CURRENT-STATUS.md", '`kmod/w431_pack_z6root.sh`＝`f4df35a4…`',
          '`kmod/w431_pack_z6root.sh`＝`%s…`(★10-24 03:5x＝#180 教程第 8 条加三条闸口径；上一版 f4df35a4)' % PACK))
R.append(("analysis/CURRENT-STATUS.md", '`z6root/MANIFEST`＝`dbc83a62…`',
          '`z6root/MANIFEST`＝`%s…`(★10-24 03:5x＝#180 重打包；上一版 dbc83a62)' % MAN))
R.append(("analysis/CURRENT-STATUS.md", '总闸 `kmod/w413_selftest_sweep.sh`＝`daf3bdd1…`',
          '总闸 `kmod/w413_selftest_sweep.sh`＝`%s…`(★10-24 03:5x＝把 #180 的夹具腿 w670 接进 bash -n；上一版 daf3bdd1)' % SWP))

# W345 runbook 两处
R.append(("kmod/W345_RC68_WINDOW.md", '现值：`kmod/z6root.sh`=`e5aad997…`(★#177 10-24 00:2x：',
          '现值：`kmod/z6root.sh`=`%s…`(★#180 10-24 03:5x：两出口各加那句"别把它当刷新键按"；当时 e5aad997＝#177：' % Z6))
R.append(("kmod/W345_RC68_WINDOW.md", '`kmod/w431_pack_z6root.sh`=`f4df35a4…`（★10-24 00:2x＝#177 教程第 8 条',
          '`kmod/w431_pack_z6root.sh`=`%s…`（★10-24 03:5x＝#180 教程第 8 条加三条闸口径；当时 f4df35a4＝#177 教程第 8 条' % PACK))
R.append(("kmod/W345_RC68_WINDOW.md", '1. **包与载荷现值**：`kmod/w431_pack_z6root.sh`=`f4df35a4…`(★10-24 00:2x＝#177 重写教程第 8 条＋映射加 w625；',
          '1. **包与载荷现值**：`kmod/w431_pack_z6root.sh`=`%s…`(★10-24 03:5x＝#180 教程第 8 条加三条闸＋铁律补一句；'
          '当时 f4df35a4＝#177 重写教程第 8 条＋映射加 w625；' % PACK))
R.append(("kmod/W345_RC68_WINDOW.md", '`z6root/w625_seedrestart.sh`=`5600865d…`',
          '`z6root/w625_seedrestart.sh`=`%s…`(★#180 三把闸；当时 5600865d)' % LEG))
R.append(("kmod/W345_RC68_WINDOW.md", '`z6root/教程.txt`=`6e4d86c3…`',
          '`z6root/教程.txt`=`%s…`(★#180 第 8 条那三条闸；当时 6e4d86c3)' % TUT))

# ---------- 4) 全部门窗校验通过才写 ----------
docs = {}
for f, old, new in R:
    if f not in docs:
        docs[f] = io.open(ROOT + "/" + f, encoding="utf-8").read()
    n = docs[f].count(old)
    if n != 1:
        print("[x] %s 的锚点命中 %d 次(应为 1)⇒ 一个文件都不写：%s…" % (f, n, old[:60]))
        sys.exit(1)
    docs[f] = docs[f].replace(old, new)
for f, t in docs.items():
    io.open(ROOT + "/" + f, "w", encoding="utf-8", newline="\n").write(t)
    print("  [OK] 写了 %s(%d 处改动落在这一批)" % (f, 1))
print("=== w673 完成：新值全部现取，锚点各命中 1 次 ===")
