#!/bin/bash
# w996_shot64.sh —— 第 64 发一条链：离线总闸 → 开窗 → **第一派就打合并腿** → 读参数 → 拉产物。
# 为什么要链起来：窗预算只有 insmod+≈600–700 秒（§6.466），手抄步骤每步都在吃它。
set -u
cd "$(dirname "$0")/.." || exit 1
# ★★不导出 MSYS_NO_PATHCONV！第 64 发第一次尝试就是被这一条废掉的：它会把路径转换关掉，
#   于是**离线自测**里喂给 Windows python 的 `/g/项目/...` 不再变成 `G:\项目\...` ⇒ w458/rowpick 两格
#   一起报红(实得 FileNotFoundError＋14 条 BAD)，而红的是仪器不是被测。带/不带这个变量各跑一遍＝A/B 已证。
#   只对**需要它的 adb 调用**逐条加(MSYS_NO_PATHCONV=1 adb …)。
EV=kmod/w103_evidence
A() { adb shell "$1" 2>&1 | tr -d '\r'; }

# ★★自保闸：环境里带着 MSYS_NO_PATHCONV 就直接拒跑（它会让离线自测假红，见 §6.468）。
#   ★上一版这块闸**没有牙**：python 串接字符串时漏了一个换行符，exit 3 被拼进前一行 echo 的参数里
#     ⇒ 闸变成只打印不拦（今天 15:00 那次就是它没拦住，白跑 7 分钟闸；幸好闸自己红在总闸上，没花枪）。
#   所以这次的规矩是：**改完闸要当场跑一次负例、并且读到它拒绝的那一行**才算装上。
if [ -n "${MSYS_NO_PATHCONV:-}" ]; then
  echo "[x] 环境里带着 MSYS_NO_PATHCONV=$MSYS_NO_PATHCONV ⇒ 拒跑这条链"
  echo "    原因：它关掉 Git Bash 的 POSIX→Windows 路径翻译，w458/run_rowpick 会 FileNotFoundError/14 条 BAD"
  echo "    做法：去掉它；需要 // 路径的那两条 adb 调用已经各自逐条加了"
  exit 3
fi

echo "[1/5] 离线总闸 w413（#158 的规矩：绿了才许开枪）"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W413=$?
tail -3 $EV/w413_console_latest.txt
if [ "$W413" -ne 0 ]; then
  echo "[x] 总闸 rc=$W413 ⇒ **不开枪**（红的是闸就补前置，不是改闸）"
  exit 1
fi

echo "[1b/5] ★绿闸新鲜度：任何**源码**比这轮绿闸的日志新 ⇒ 那盏灯已经不是现在这套代码的(第 70 发那条链里已验过有效)"
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
if [ -n "$STALE" ]; then
  echo "[x] 以下文件比绿闸日志新 ⇒ 拒跑，重跑闸："
  printf '%s\n' "$STALE" | sed 's/^/      /'
  exit 1
fi
echo "  比绿闸新的源码件=0(判据由上面那条 find 现数)"

echo "[2/5] 开窗（reboot + punch，1 枪）＋★判据⑥到手那一瞬就派合并腿(go.sh 3.5 的 LEG1 钩子)"
# 为什么交给 go.sh 派而不是我这边派：§6.468 第 65 发一手——判据⑥在 up≈600，go.sh 走完 4~8 步到 up≈683，
# 我再派腿就只剩 ~150 秒(设备 up≈841 硬复位)，结果 out 文件都不存在＝腿根本没跑(同 boot 的 root 写件都活着)。
# ★10-27 21:4x 换成 w1014：w995 那一支写的是 `insmod $K` **不带 rt_steps**(模块默认 0)
#   ⇒ 它结构上跑不到往返那一步，`rt_same` 永远是 -1(见 md §6.472)。w1014 显式传段并回抄该参数。
LEGREPO=kmod/w1014_b2_leg.sh
LEGDEV=/data/local/tmp/w1014_b2_leg.sh
LEGOUT=/data/local/tmp/w1014_b2.out
KOREPO=kmod/w986_polround_v4_cfi.ko
KODEV=/data/local/tmp/w986_polround_v4_cfi.ko
KO_MD5_WANT=f0e8ee245b231d827665b7aed9f30db7
LEG_MD5=$(md5sum $LEGREPO | cut -d' ' -f1)
echo "  合并腿本机 md5=$LEG_MD5(随链推给 go.sh 做两端对表)  件=$LEGREPO"
# ★先把腿与 ko 铺到设备上(0 枪动作；md5 不符 go.sh 那道两端闸会拦)
MSYS_NO_PATHCONV=1 adb push $LEGREPO $LEGDEV 2>&1 | tail -1
MSYS_NO_PATHCONV=1 adb push $KOREPO $KODEV 2>&1 | tail -1

# ★★★第 69 发那发空枪的形状：`adb push` 落 0666，一个 x 位都没有，而 sushd 走的是 execve 那个路径
#   ⇒ root 也一样被 DAC 挡(exit=126 / can't execute)。所以**开枪之前**就把 x 位／标签／语法三件查掉
#   （全是 0 枪动作；go.sh 3.5 里那道派前闸是第二层，不是替代）。
A "chmod 755 $LEGDEV" >/dev/null
PERM=$(A "ls -l $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}')
LBL=$(A "ls -Zd $LEGDEV 2>/dev/null" | awk 'NR==1{print $1}')
KODEV_MD5=$(A "md5sum $KODEV 2>/dev/null" | cut -d' ' -f1)
echo "  腿设备侧权限=$PERM(第 4 列要看到 x)  标签=$LBL"
echo "  ko 两端 md5：本机=$(md5sum $KOREPO | cut -d' ' -f1)  设备=$KODEV_MD5  登记=$KO_MD5_WANT"
[ "${PERM:3:1}" = x ] || { echo "[x] 补完还是没有属主 x 位 ⇒ **不开枪**(§6.474：execve 必 EACCES)"; exit 1; }
case "$LBL" in *:s0) : ;; * ) echo "[x] 腿的标签不是 plain s0(=$LBL) ⇒ **不开枪**(带类别会挡 execute＝#114)"; exit 1 ;; esac
[ "$KODEV_MD5" = "$KO_MD5_WANT" ] || { echo "[x] 设备上的 ko 不是登记那份(现读 $KODEV_MD5) ⇒ **不开枪**(旧件会静默换形状 §6.155)"; exit 1; }
SHN=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $LEGDEV >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
echo "  设备侧 mksh 语法检查：$(tr '\n' ' ' <<<"$SHN")"
grep -q 'SHN=OK' <<<"$SHN" || { echo "[x] 腿没过设备侧 sh -n ⇒ **不开枪**(上面那行就是仪器/语法读数)"; exit 1; }
# ★★这里**不许**给 QUIET=1(第 68 发那颗空枪)：quiet 分支不装 agent fd ⇒ @sushd 没人听，腿一句都不跑。
LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LEG_MD5"   I_KNOW=1 bash kmod/go.sh > "$EV/w997_shot64_go.log" 2>&1
GO=$?
echo "GO_RC=$GO"
tail -6 "$EV/w997_shot64_go.log" | sed 's/^/  go: /'
if [ "$GO" -ne 0 ]; then
  echo "[x] go.sh rc=$GO ⇒ 不往下走；先看日志再决定（别在没窗的情况下猜）"
  exit 1
fi

echo "[3/5] 取腿的判据面（go.sh 已把全文抄进 $EV/leg1_out.txt）"
A "cat $LEGOUT" > "$EV/$(basename $LEGOUT).out" 2>&1
echo "  证件行数=$(wc -l < "$EV/$(basename $LEGOUT).out")  设备 up=$(A 'cat /proc/uptime')  enf=$(A getenforce)  mod=$(A "grep -c '^kernelsu' /proc/modules")"
grep -aE 'STEPS|ARGV|ko_md5|insmod_rc|MODULES_LINE|PARAM rt_|WR_rc|POST_rc|POLICY_UNCHANGED|B2_VERDICT|CLEANUP|END up=|\[x\]|\[!!\]' "$EV/$(basename $LEGOUT).out" | cut -c1-165 | sed 's/^/  /'

echo "[4/5] 拉产物（两份活策略＋模块重序列化那份）回来，离线跑语义尺"
for f in w1014_pol.pre w1014_pol.post w986_wr_v4.bin; do
  MSYS_NO_PATHCONV=1 adb pull //data/local/tmp/$f "$EV/b2_$f" >/dev/null 2>&1
  rc=$?
  echo "  $f pull_rc=$rc size=$(wc -c < "$EV/b2_$f" 2>/dev/null) md5=$(md5sum "$EV/b2_$f" 2>/dev/null | cut -d' ' -f1)"
done

echo "[5/5] 关窗：机器是量产机，不留窗过夜(§6.478 修法④的同款两条：stayon 复原＋读回，再 reboot 复核基线)"
A "svc power stayon false" >/dev/null
STAY=$(A "settings get global stay_on_while_plugged_in")
echo "  stay_on_while_plugged_in 读回=[$STAY]  (期望 null 或 0)"
case "$STAY" in null|0|0*) echo "  STAYON=已复零" ;; *) echo "  [x] STAYON=没复原(现值 $STAY) ⇒ 手动补：adb shell svc power stayon false" ;; esac
adb reboot; echo "  reboot 已发出 $(date +%H:%M:%S)"
adb wait-for-device
sleep 20
echo "  基线复核：getenforce=$(A getenforce) mod=$(A "grep -c '^kernelsu ' /proc/modules") our_probe=$(A "grep -c '^w985_probe ' /proc/modules") stay_on=$(A "settings get global stay_on_while_plugged_in")"
echo "SHOT64_DONE  证件：$EV/w997_shot64_go.log  $EV/$(basename $LEGOUT).out  $EV/b2_*"
