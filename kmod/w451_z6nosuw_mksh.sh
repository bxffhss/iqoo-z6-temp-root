#!/bin/bash
# w451_z6nosuw_mksh.sh —— 把 kmod/z6root.sh 里那块 **3.6) 免界面入口(B)** 原样切片，
#   在 **PC 的 bash** 与**设备 mksh** 上各跑一遍同一批夹具，要求两边逐字一致。
# 为什么要有这条腿：包里那段是新写的、决定"这一跑是 A 还是 B"的形状闸；而交付口径里
#   "设备侧脚本都过设备 mksh"以前只到 `sh -n`（语法）为止——**语法过不等于执行一致**
#   （#146 那颗雷就是 mksh 的算术与 PC 不同）。本条不开枪、不占窗口，只花设备侧几秒。
# 判据＝7 种形状下三元组 (入口形状 Z6B, 开关内容, 文件在不在)＋退回话条数：
#   ①期望值写死在下面；②bash 与 mksh 现读数必须相同（两壳不许各跑一种形状）；
#   ③"没铺成"那几支必须**同时**打了那句退回话（静默换形状＝例 116/142）；
#   ④"写了但读回不符"那一支有真夹具（把开关路径先占成目录）＝反夹具，证明 [ "$Z6NW" = 2 ] 那道闸不是摆设。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
fail=0; nchk=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

Z=kmod/z6root.sh
LW=kmod/_tmp_w451
DW=/data/local/tmp/w451
rm -rf "$LW"; mkdir -p "$LW" || exit 1
adb shell "rm -rf $DW; mkdir -p $DW" >/dev/null 2>&1

echo "=== ①切片：锚点唯一，起点=3.6) 那行注释，终点=第 4 步之前 ==="
awk '/^# ---------- 3\.6\)/{f=1} /^# ---------- 4\)/{f=0} f' "$Z" > "$LW/block.sh"
NBLK=$(grep -ac . "$LW/block.sh")
[ "$NBLK" -ge 15 ] || { echo "[x] 只切到 $NBLK 行 ⇒ 锚点失效(别把『切片空』读成『形状没问题』)"; exit 1; }
chk "①切片非空(行数=$NBLK)且三件齐：Z6B／ksu_nosuw／pm 现取" \
    "$(grep -aq 'Z6B' "$LW/block.sh" && grep -aq 'ksu_nosuw' "$LW/block.sh" && grep -aq 'pm list packages -U' "$LW/block.sh" && echo 1 || echo 0)"
grep -aq 'die ' "$LW/block.sh" && { echo "[x] 切片里混进了 die ⇒ 终点锚越界(那几句属于第 4 步)"; exit 1; }
grep -aq 'swid\|SWITCH_FILES' "$LW/block.sh" && { echo "[x] 切片把开关清单吞进来了 ⇒ 起点锚不对"; exit 1; }

echo "=== ②夹具：7 种形状(含『两个同前缀包』这种最容易串的，和『开关路径被占成目录』) ==="
mkfix() { printf '%s\n' "$2" > "$LW/fix_$1.txt"; }
mkfix 1 'package:com.termux uid:10667'
mkfix 2 ''
mkfix 3 'package:com.termux uid:0'
mkfix 4 'package:com.termux uid:abc'
mkfix 5 'package:com.termux uid:10667
package:com.termux.api uid:10817'
mkfix 6 'package:com.termux uid:10667
package:com.termux.api uid:10817'
mkfix 7 'package:com.termux uid:10667'
# B=形状  C=开关内容  F=文件在不在  BACK=退回话条数
EXP1='B=1 C=[10667 com.termux] F=Y BACK=0'
EXP2='B=0 C=[] F=N BACK=1'
EXP3='B=0 C=[] F=N BACK=1'
EXP4='B=0 C=[] F=N BACK=1'
EXP5='B=1 C=[10817 com.termux.api] F=Y BACK=0'
EXP6='B=1 C=[10667 com.termux] F=Y BACK=0'
EXP7='B=0 C=[] F=Y BACK=1'

# 外壳：pm 走夹具、say 走 echo；PRE 让某一格能把开关路径先占成目录
{
    echo 'TMP=${CT:-/data/local/tmp/w451/cx}'
    echo 'mkdir -p "$TMP"; rm -f "$TMP/ksu_nosuw"'
    echo 'if [ "${Z6PRE:-0}" = 1 ]; then mkdir -p "$TMP/ksu_nosuw"; fi'
    echo 'say(){ echo "$@"; }'
    echo 'pm(){ cat "$FIX"; }'
    cat "$LW/block.sh"
    echo 'BACK=$(grep -acE "不写开关|读回不符" "$LOGFILE")'
    echo 'echo "B=$Z6B C=[$(cat "$TMP/ksu_nosuw" 2>/dev/null)] F=$([ -e "$TMP/ksu_nosuw" ] && echo Y || echo N) BACK=$BACK"'
} > "$LW/run.sh"
bash -n "$LW/run.sh" || { echo "[x] 外壳本身语法不过 ⇒ 这批全不算测到"; exit 1; }
adb push "$LW/run.sh" $DW/run.sh >/dev/null 2>&1
for i in 1 2 3 4 5 6 7; do adb push "$LW/fix_$i.txt" $DW/fix_$i.txt >/dev/null 2>&1; done
LN=$(md5sum "$LW/run.sh" | cut -c1-32); RN=$(A "md5sum $DW/run.sh" | cut -c1-32)
chk "②推上去的外壳两端 md5 一致(本机=$LN 设备=$RN)；★这里连设备侧那份都被真跑过" "$([ "$LN" = "$RN" ] && echo 1 || echo 0)"
DS=$(A "sh -n $DW/run.sh; echo RC=\$?")
chk "②b 外壳过设备 mksh 语法闸($DS)" "$(printf '%s' "$DS" | grep -q 'RC=0' && echo 1 || echo 0)"

echo "=== ③逐形状真跑(同一夹具在 bash 与设备 mksh 各一遍) ==="
run_case() { # $1=夹具号 $2=目标包 $3=Z6PRE(1=先把开关路径占成目录，用来逼出"读回不符"那一支)
    local i=$1 pkg=$2 pre=${3:-0} E LB RB
    case "$i" in 1) E=$EXP1;; 2) E=$EXP2;; 3) E=$EXP3;; 4) E=$EXP4;; 5) E=$EXP5;; 6) E=$EXP6;; 7) E=$EXP7;; esac
    rm -rf "$LW/ct$i"
    LB=$(FIX="$PWD/$LW/fix_$i.txt" LOGFILE="$LW/log_b$i.txt" CT="$LW/ct$i" Z6PRE="$pre" Z6TARGET_PKG="$pkg" \
         bash "$LW/run.sh" >"$LW/log_b$i.txt" 2>&1; grep -a '^B=' "$LW/log_b$i.txt")
    RB=$(A "rm -rf $DW/ct$i; mkdir -p $DW/ct$i; CT=$DW/ct$i FIX=$DW/fix_$i.txt LOGFILE=$DW/log_d$i.txt Z6PRE=$pre Z6TARGET_PKG=$pkg sh $DW/run.sh >$DW/log_d$i.txt 2>&1; grep -a '^B=' $DW/log_d$i.txt")
    echo "  夹具$i pkg=[$pkg] Z6PRE=$pre"
    echo "      bash=[$LB]"
    echo "      mksh=[$RB]"
    chk "③$i 设备 mksh 现读数＝期望值($E)" "$([ "$RB" = "$E" ] && echo 1 || echo 0)"
    chk "③$i b 同夹具下 PC bash＝设备 mksh(两壳不许各跑一种形状)" "$([ "$LB" = "$RB" ] && echo 1 || echo 0)"
}
run_case 1 com.termux 0
run_case 2 com.termux 0
run_case 3 com.termux 0
run_case 4 com.termux 0
run_case 5 com.termux.api 0
run_case 6 com.termux 0
run_case 7 com.termux 1

echo "=== ④静态牙：包体的两条分支不许写成一行共用文案 ==="
chk "④第 9 步在 B 形状下**不派 suw 单**，派单那句只在 else 支里" \
    "$(awk '/^# ---------- 9\)/{f=1} /^# ---------- 10\)/{f=0} f' "$Z" | grep -q 'Z6B" = 1' && echo 1 || echo 0)"
NB=$(awk '/^# ---------- 9\)/{f=1} /^# ---------- 10\)/{f=0} f' "$Z" | grep -ac 'am start -f 0x4000000')
chk "④b 数一下第 9 步里带 CLEAR_TOP 的派单行数(实得 $NB，必须=1：只在 A 支) ⇒ 反夹具：两分支都派就是 2" "$([ "$NB" = 1 ] && echo 1 || echo 0)"
chk "④第 9 步 B 支的证人是 NOSUW_BIND_RC/NOSUW_HEALTH，来源换成 stage 日志" \
    "$(grep -aq 'NOSUW_BIND_RC' "$Z" && grep -aq 'NOSUW_HEALTH=OK' "$Z" && echo 1 || echo 0)"
chk "④第 11 步 B 支把收尾腿与 rm_allow_rc 讲清楚了(不是只说 reboot 就行)" \
    "$(grep -aq 'w450_close.sh' "$Z" && grep -aq 'rm_allow_rc=0' "$Z" && echo 1 || echo 0)"
chk "④b 清单里 w450_close.sh 有指名消费者(z6root.sh 里点了它的名字) ⇒ 不是孤儿件" \
    "$(grep -aq '^w450_close\.sh ' z6root/MANIFEST && echo 1 || echo 0)"
chk "④agent 起不来时 B 支不许 die(A 支仍 die) ⇒ 失败出口按形状分两支" \
    "$(awk '/^# ---------- 4\)/{f=1} /^# ---------- 5\)/{f=0} f' "$Z" | grep -q 'B 形状不依赖它' && echo 1 || echo 0)"

adb shell "rm -rf $DW" >/dev/null 2>&1
echo "  (读回：设备侧临时件已清 ⇒ $(A "ls $DW 2>&1 | head -1"))"
echo
[ "$fail" = 0 ] && echo "=== w451 自测 PASS($nchk 项，条数由 chk 自数) ===" || echo "=== FAIL($nchk 项里有红) ==="
[ "$fail" = 0 ]
