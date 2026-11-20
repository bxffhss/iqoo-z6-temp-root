#!/bin/bash
# w1021_shot68.sh —— #219 一条链（v2：问"**装载期 DOM 请求里那段 MLS 范围落没落在在线 subject 上**"）。
# ★v1 问的是"范围能不能支配带类别的对象"，那一格**没有判别力**：10-28 拿活策略(pol.live_1027＝282a6861)现查——
#   管 dir/file 的 20 条 mlsconstrain **每条都带 `( t1 == mlstrustedsubject )`**，而 `shell` 就在那个属性里，
#   且 `/data/local/tmp` 的 `shell_data_file` 本身还在 `mlstrustedobject` 里 ⇒ 这把 subject 的绿/红都证不了范围在起作用(例 187①)。
#   ⇒ 支配那一半改由 **PC 侧 run-as(域 runas_app，不在可信集合)** 当正对照(本链第 [5/6] 步的 MLS_LIVE)。
# 为什么必须链起来：窗预算 ≈ insmod+600–700 秒(§6.466)，手抄步骤每步都在吃它；而这一发的腿**自己会翻执法**，
#   翻完之后 go.sh 第 4~7 步那些 root 腿必然红(§6.441) ⇒ 用新加的 `LEG1ONLY=1` 把它们显式跳过并记**未测**，
#   而不是留一串会误导的红灯。
# ★★不导出 MSYS_NO_PATHCONV(第 64 发就是被它废的，§6.468)；只对需要它的 adb 调用逐条加。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT="${SHOT:-69}"   # ★证件名跟着发号走：第 68 那发的证据不许被这一发覆盖
WANT_DOM=u:r:shell:s0-s0:c0.c1023
LEGREPO=kmod/w1018_mlsrange_leg.sh
LEGDEV=/data/local/tmp/w1018_mlsrange_leg.sh
LEGOUT=/data/local/tmp/w1018_mls.out
# 尺子的两个组(与腿里同名，改动时两处一起看)：A 组＝PC 侧 run-as 的正对照；S 组＝腿里的仪器正控制
AP=/data/data/com.termux/files/W18_P
AQ=/data/data/com.termux/files/W18_Q
SP=/data/local/tmp/w1018_sP
SQ=/data/local/tmp/w1018_sQ
A() { adb shell "$1" 2>&1 | tr -d '\r'; }

if [ -n "${MSYS_NO_PATHCONV:-}" ]; then
  echo "[x] 环境里带着 MSYS_NO_PATHCONV ⇒ 拒跑这条链(它会让离线自测里的 Windows 路径假红，§6.468)"
  exit 3
fi

echo "[1/6] 离线总闸 w413（#158 的规矩：**链内现跑**，不复用旧绿灯）"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > "$EV/w413_console_latest.txt" 2>&1
W413=$?
tail -2 "$EV/w413_console_latest.txt"
[ "$W413" -eq 0 ] || { echo "[x] 总闸 rc=$W413 ⇒ **不开枪**(红的是闸就补前置，不是改闸)"; exit 1; }

echo "[1b/6] ★绿闸新鲜度：任何**源码**比这轮绿闸的日志新 ⇒ 那盏灯已经不是现在这套代码的"
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer "$EV/w413_console_latest.txt" 2>/dev/null)
N=$(printf '%s\n' "$STALE" | grep -c '[^[:space:]]')   # ★条数由 find 的产出现数(空串经 grep -c 得 0；wc -l 会把空串数成 1)
if [ -n "$STALE" ]; then
  echo "[x] 以下文件比绿闸日志新 ⇒ 拒跑，重跑闸："
  printf '%s\n' "$STALE" | sed 's/^/      /'
  exit 1
fi
echo "  比绿闸新的源码件=$N (判据由上面那条 find 现数，不是抄下来的 0)"

echo "[2/6] 铺腿(0 枪动作)＋两端对表"
MSYS_NO_PATHCONV=1 adb push "$LEGREPO" "$LEGDEV" 2>&1 | tail -1
LMD5=$(md5sum "$LEGREPO" | cut -d' ' -f1)
DMD5=$(A "md5sum $LEGDEV 2>/dev/null" | cut -d' ' -f1)
echo "  腿两端：本机=$LMD5 设备=$DMD5"
[ -n "$DMD5" ] && [ "$DMD5" = "$LMD5" ] || { echo "[x] 设备上不是本机这支腿 ⇒ 不派(旧件会静默换形状 §6.155)"; exit 1; }

# ★★★第 69 发空枪的一手原因就落在这两行之外：`adb push` 把腿落成 **0666**，一个 x 位都没有，
#   而 sushd 是 execve 那个路径(不是 `sh 路径`)⇒ root 也一样被 DAC 挡：
#   sushd.log 一手回执 `cmd=[…w1018_mlsrange_leg.sh]` → `exit=126` → `KSU_EXEC: … can't execute: Permission denied`
#   ⇒ 通道是好的、授权答了 granted=1，一发就这么白花掉。补 x 位＋读回＋mksh 语法检查**全部排在开枪之前**
#   (这些都是 0 枪动作；go.sh 里那道派前闸是第二层，见 go.sh 3.5 段)。
A "chmod 755 $LEGDEV" >/dev/null
PERM=$(A "ls -l $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}')
LBL=$(A "ls -Zd $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}')
echo "  腿设备侧权限=$PERM(第 4 列要看到 x)  标签=$LBL"
[ "${PERM:3:1}" = x ] || { echo "[x] 补完还是没有属主 x 位 ⇒ **不开枪**(§6.474：execve 必 EACCES)"; exit 1; }
case "$LBL" in *:s0) : ;; * ) echo "[x] 标签不是 plain s0(=$LBL) ⇒ **不开枪**(带类别会挡 execute＝#114)"; exit 1 ;; esac
# ★这条必须逐条带 MSYS_NO_PATHCONV=1：不带时 Git Bash 把 `/system/bin/sh` 翻成 `K:/Git/system/bin/sh`
#   ⇒ 设备回 `inaccessible or not found` ⇒ SHN=BAD ⇒ **我的闸把合法腿拦在开枪之前**(假红＝仪器坏)。
#   10-28 现场 A/B 过：不带=BAD／带=OK／故意写坏的夹具带=BAD(闸有牙)。
SHN=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $LEGDEV >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
echo "  设备侧 mksh 语法检查：$(tr '\n' ' ' <<<"$SHN")"
grep -q 'SHN=OK' <<<"$SHN" || { echo "[x] 腿没过设备侧 sh -n ⇒ **不开枪**(上面那行就是仪器/语法读数，先分清哪种)"; exit 1; }

echo "  本轮 DOM=$WANT_DOM  (type 仍是交付的 shell；唯一变量＝串尾那段 MLS 范围)"

echo "[3/6] 开窗：1 枪(reboot+punch)，判据⑥一到就派腿，派完即跳过第 4~7 步"
# ★★这里**不许**给 QUIET=1：第 68 发就是抄了别的链的这个旗标，stage 于是走"静默版"分支(不装 agent fd)，
#   它自己那行写着"判据⑥…只为让 go.sh 往下走"⇒ @sushd 没人听，腿一句都没执行(out 件不存在)，白花一发。
#   go.sh 现在有道闸会在这种情况下拒绝派腿(自测 kmod/_tmp_selftest_rdst/run_quietguard.sh 四格齐)。
DOM="$WANT_DOM" LEG1="$LEGDEV" LEG1OUT="$LEGOUT" LEG1MD5="$LMD5" LEG1ONLY=1 \
  I_KNOW=1 bash kmod/go.sh > "$EV/w1023_shot${SHOT}_go.log" 2>&1
GO=$?
echo "  GO_RC=$GO"
tail -8 "$EV/w1023_shot${SHOT}_go.log" | sed 's/^/  go: /'

echo "[4/6] 腿的判据面"
A "cat $LEGOUT 2>/dev/null" > "$EV/w1022_leg_shot${SHOT}.out" 2>&1
echo "  证件行数=$(wc -l < "$EV/w1022_leg_shot${SHOT}.out")"
grep -aE 'BEGIN|WANT_DOM|S0 |LBL |DAC |PRE |PRE_OK|CHCON_|M_S|M_A|DOM_AGREE|DOM_STABLE|FLIP_rc|MLS_RANGE_VERDICT|MLS_SHELL_ARM|CLEANUP|PENDING|END up|can.t open|line [0-9]+:|\[[0-9]+\]:' \
  "$EV/w1022_leg_shot${SHOT}.out" | cut -c1-175 | sed 's/^/    /'

echo "[5/6] PC 侧两条**独立**证人(不依赖腿自己的读法)"
echo "  执法态现读：getenforce=$(A getenforce)   mod=$(A "grep -c '^kernelsu ' /proc/modules")   up=$(A 'cut -d" " -f1 /proc/uptime')"
# ★正对照(=本题的"MLS 此刻确实在管"证人)：run-as 的域是 `runas_app`，现查活策略它**不在** mlstrustedsubject 里，
#   所以两把只差类别的 A 组尺对它**必须**一同一否；两把都通＝这台机这一窗 MLS 没在执法 ⇒ 本发所有"绿"都不算证人。
echo "  窄 subject 正对照(第 62 发那把尺，同窗复证)："
RC_CTRL=$(A "run-as com.termux sh -c 'ls -d $AP 2>&1; echo P_rc=\$?; ls -d $AQ 2>&1; echo Q_rc=\$?; cat /proc/self/attr/current'" | tr '\n' ' ')
echo "      $RC_CTRL"
PR=$(sed -n 's/.*P_rc=\([0-9]*\).*/\1/p' <<<"$RC_CTRL"); QR=$(sed -n 's/.*Q_rc=\([0-9]*\).*/\1/p' <<<"$RC_CTRL")
if [ "$PR" = "0" ] && [ "$QR" != "0" ] && [ -n "$QR" ]; then
  echo "  MLS_LIVE=是  (执法下同一 subject：plain s0 通、带类别拒 ⇒ 这台机此刻 MLS 确实在管)"
elif [ "$PR" = "0" ] && [ "$QR" = "0" ]; then
  echo "  MLS_LIVE=否 ★(两把都通＝MLS 没在管或没翻成执法) ⇒ 本发腿里所有『绿』都不许当判据，只能记未测"
else
  echo "  MLS_LIVE=未取 (P_rc=[$PR] Q_rc=[$QR] 里有一把没读到 ⇒ 正对照缺席，别把'没读数'读成'没放行')"
fi

echo "[5b/6] 收掉 S 组尺(TE 现查 shell 对 shell_data_file 有 unlink/remove_name，adb shell 就删得动)"
A "rm -rf $SP $SQ" >/dev/null
STILL=$(A "ls -d $SP $SQ 2>&1" | tr '\n' ' ')
grep -qi 'No such file' <<<"$STILL" && [ "$(grep -c 'No such file' <<<"$STILL")" = 2 ] \
  && echo "  S 组删净复证 OK(两行 No such file)" || echo "  [x] S 组没删净：$STILL ⇒ 记进下一发 root 腿清单"

echo "[6/6] 关窗：机器是量产机，不留窗过夜"
# ★§6.473 那条"已改回 false"是假的——stayon 会**跨重启留着**(第 70 发现读＝15)，而链里一直没人复原它。
#   ⇒ 现在显式关＋读回＋把读数打证件(读不回就写"未复证"，不许默认成功)。
A "svc power stayon false" >/dev/null
STAY=$(A "settings get global stay_on_while_plugged_in")
echo "  stay_on_while_plugged_in 读回=[$STAY]  (期望 null 或 0)"
case "$STAY" in null|0*|0) echo "  STAYON=已复零" ;; *) echo "  [x] STAYON=没复原(现值 $STAY) ⇒ 手动补：adb shell svc power stayon false" ;; esac
adb reboot; echo "  reboot 已发出 $(date +%H:%M:%S)"
adb wait-for-device
sleep 20
echo "  基线复核：getenforce=$(A getenforce) mod=$(A "grep -c '^kernelsu ' /proc/modules") stay_on=$(A "settings get global stay_on_while_plugged_in")"
echo "SHOT${SHOT}_DONE  证件：$EV/w1023_shot${SHOT}_go.log  $EV/w1022_leg_shot${SHOT}.out"
