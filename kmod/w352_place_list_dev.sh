#!/system/bin/sh
# w352_place_list_dev.sh —— 第 118 发的**一条 root 腿里做完**三件事：
#   ①放样本模块(调 w345，原样) → ②立刻以 root exec 官方 APK 里那份 libksud.so 跑 `module list`
#   → ③问内核名单(granted 10104/10319/10304 + NEW_GET_ALLOW_LIST count)。
#
# ★为什么要合并：§6.255③ 实测 `/data/adb/modules` 会在几分钟内消失，而"放→列→截图"必须都挤在这几分钟里。
#   拆成两条 root 腿要付两次 suw 往返(各 ~20-40s) ⇒ 合并成一条，把省下的时间全给截图那一格。
# ★判据顺序也是设计过的：count/granted 在**放模块之后**读没关系(它是内核 init 期 load 的，与模块无关)，
#   但 libksud 的 `module list` 必须紧跟在放置之后，中间不能插别的 leg。
# ★产物名**故意**取 `<脚本名去 .sh>.out`：w211_ui.sh 的 rleg 轮询的就是这个拼出来的名字
#   (w345/w347 都对不上 ⇒ 每次白等 36s，§6.251 那条'rleg 说没等到 DONE'的根因之一)。这里对上， DONE 一到就回。
OUT=/data/local/tmp/w352_place_list_dev.out
exec > "$OUT" 2>&1
echo "[$(date +%H:%M:%S)] uid=$(id -u) enf=$(getenforce) up=$(cut -d' ' -f1 /proc/uptime)"
[ "$(id -u)" = "0" ] || { echo "!! 不是 root ⇒ 什么都不做"; exit 1; }

echo "--- ① 放模块：调 w345，然后把它的回执**吸进本文**(不靠我记得它写了什么) ---"
if [ ! -f /data/local/tmp/w345_samplemod_dev.sh ]; then echo "!! 设备上没 w345 ⇒ 放置这一格作废"; else
    timeout 60 sh /data/local/tmp/w345_samplemod_dev.sh /data/local/tmp/testmod
    echo "  w345 rc=$?"
    grep -a -E 'SAMPLEMOD_OK|SAMPLEMOD_FAIL|modules 目录里现有|ls -Zl' /data/local/tmp/w345_samplemod.out 2>/dev/null | sed 's/^/    /'
fi
T_PLACE=$(date +%H:%M:%S)

echo "--- ② ★立刻 root 列一次(libksud.so module list) ---"
KSUD=$(find /data/app -name 'libksud.so' 2>/dev/null | head -1)
echo "  libksud.so=[$KSUD]  放置时刻=$T_PLACE  现在=$(date +%H:%M:%S)"
[ -n "$KSUD" ] || { echo "!! find 也没找到 ⇒ 这一格作废(别把'没找到'当'列不出')"; }
if [ -n "$KSUD" ]; then
    timeout 25 "$KSUD" module list 2>&1 | head -20
    echo "  LIST_RC=$?"
    echo "  ★判读：有 suwmarker ⇒ ksud+格式+可见性全通，剩下纯是 Manager 侧；空 [] ⇒ 放置到列之间出了问题(看上面的放置回执)"
fi

echo "--- ③ 内核侧：granted + 名单条数(正对照 10304 必须在，Manager 按设计不进列表) ---"
C=/data/local/tmp/ksuctl88
[ -x "$C" ] || { echo "!! 设备上 ksuctl88 不在或不可执行 ⇒ 名单判据作废"; }
for u in 10104 10319 10304; do
    echo "   uid=$u : $(timeout 10 "$C" granted $u 2>&1 | grep -a UID_GRANTED_ROOT | cut -c1-120)"
done
timeout 15 "$C" allowlist 2>&1 | grep -a -E 'count=|allow\[' | head -8
echo "   .allowlist 文件=$(ls -l /data/adb/ksu/.allowlist 2>&1 | tr '\n' ' ')"

echo "--- ④ 模块目录存活读数(带时刻，供'会不会消失'那格) ---"
echo "  modules=[$(timeout 10 ls /data/adb/modules 2>&1 | tr '\n' ' ')]"
timeout 10 stat -c '  %y|%s|%n' /data/adb/modules /data/adb/modules/suwmarker 2>&1

echo "--- ⑤ ★这一条就是'SX2 的**点页面之前**基线'(省一条 36s 的 root 腿) ---"
DM=$(timeout 20 dmesg 2>/dev/null)
echo "  SX2_COUNT=$(echo "$DM" | grep -a -c 'SX2 selfexec-pre')"
echo "  SD1_UID10104=$(echo "$DM" | grep -a 'KSUBEAT SD1 decline' | grep -a -c 'uid=10104')"
echo "  SD1_ALL(噪声参照)=$(echo "$DM" | grep -a -c 'KSUBEAT SD1 decline')"
echo "  现在=$(date +%H:%M:%S)(截图之后还要用 w347 再读一次，两次的**差值**才算数)"
echo "[===== DONE =====]"
