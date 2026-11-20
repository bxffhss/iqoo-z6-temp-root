#!/bin/bash
# w1100_shot87.sh —— 第 87 发＝#226 两枪串联的**第一枪**：把机器打死的那一发与第 85 发**逐字相同**，唯一变化＝**打完不许 reboot**。
#   为什么(§6.514／#226)：还剩的那一格＝分开 (a)"我们那类死没走 `panic()`" 与 (b)"走了，但被中间那次 warm reboot 抹掉"。
#   唯一还能带内的证人窗口＝**死后的第一个 boot** 里读 `/sys/fs/pstore`。第 86 发读的是"死 ⟶ 两次软重启 ⟶ 才读"，
#   所以它那个 `PS_FILES=0` 只配写"未证"——**这一发改的不是被测，是我在死之后做什么**。
#   ★单变量声明：ko `20b15b11…`(`rt_abi=85`) × 腿 `w1093` × `rt_steps=2 rt_slack_kb=64` × args＝交付默认 ⇒ 与第 85 发一字不动；
#     所以这一发**不产生新的机制结论**，它只负责把一次死亡放进一个干净的 boot 里，并把"这是死后第一个 boot"钉成可核的读数。
#   ★★这一发**不许**沿用第 85 发那条链的收尾(`adb reboot`)：那一次软重启正是要读的东西被抹掉的原因(§6.514)。
#     收尾改成：等机器自己回来 → 现读三个复位证人(`ro.boot.bootreason`／`persist.sys.boot.reason.history`／`epoch−up`)
#     → **在被人删之前**把死亡 boot 的 `ksu_stage.log`/`dmesg.live`/`punch.log`/`w184_sample.out` 先 pull 回来
#     (下一发开窗时 go.sh 会归档/删掉它们——这一发是第一次有机会留全)→ 写标记件给第 88 发当"串联"的凭据。
#   ★开枪前闸照旧：总闸 w413 全绿＋STALE＋`w1071` 机制预检 `MECH_RC=0`＋腿四把闸(x 位／plain s0／两端 md5／设备 `sh -n`)＋ko md5＝登记。
#   ★顺带把第 88 发要用的只读腿(`w1098`)也铺好并过同样四把闸：死后那几分钟越短越好，而且那时不该再有时间做铺垫。
set -u
cd "$(dirname "$0")/.." || exit 1
EV=kmod/w103_evidence
SHOT=${SHOT:-87}
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
#   ★这把闸 11-02 第 87 发被自己绕过过一次：`-n` 只测"非空"，而 msys 测的是"**有没有定义**"。
#     我用 `MSYS_NO_PATHCONV=`(空值)去满足旧闸 ⇒ 闸绿了，msys 却照样**关掉路径转换** ⇒ 链里三个 python 夹具
#     拿到没转换的 `/tmp/...`／`/g/项目/...` 路径全部打空(两次 0 消耗，枪没烧)。⇒ 改成"定义了就拒"。
if [ -n "${MSYS_NO_PATHCONV+set}" ]; then echo "[x] MSYS_NO_PATHCONV 被定义了(哪怕是空值) ⇒ 拒跑：空值会让 msys 关掉路径转换，链里的 python 夹具会拿到没转换的 /tmp 路径而假红"; exit 3; fi

echo "[1/6] 离线总闸(链内现跑)"
PYTHONUTF8=1 bash kmod/w413_selftest_sweep.sh > $EV/w413_console_latest.txt 2>&1
W=$?; tail -2 $EV/w413_console_latest.txt; [ "$W" = 0 ] || { echo "[x] 总闸 rc=$W ⇒ 不开枪(红的是闸就补前置，不是改闸)"; exit 1; }
STALE=$(find kmod analysis cm57 -type f \( -name '*.sh' -o -name '*.c' -o -name '*.py' -o -name '*.md' \) -not -path '*/w103_evidence/*' -newer $EV/w413_console_latest.txt 2>/dev/null)
[ -n "$STALE" ] && { echo "[x] 有源码比绿闸新 ⇒ 拒跑:"; printf '%s\n' "$STALE" | sed 's/^/      /'; exit 1; }

LEGREPO=kmod/w1093_hist_pol_leg.sh; LEGDEV=/data/local/tmp/w1093_hist_pol_leg.sh; LEGOUT=/data/local/tmp/w1093_hist_pol.out
POUTDEV=/data/local/tmp/w1093_hist.txt; PERRDEV=/data/local/tmp/w1093_hist.err
KOREPO=kmod/w986_polround_v7_substep.ko; KODEV=/data/local/tmp/w986_polround_v7_substep.ko
KO_MD5_WANT=20b15b11e43bd3b057d69d4b847c041a
PLEGREPO=kmod/w1098_pstore_leg.sh; PLEGDEV=/data/local/tmp/w1098_pstore_leg.sh; PLEGOUT=/data/local/tmp/w1098_pstore.out

echo "[2/6] 0 枪机制预检(w1071：这台机的小数 sleep 与内建 read 到底会不会动)"
MSYS_NO_PATHCONV=1 adb push kmod/w1071_poll_mech_dev.sh /data/local/tmp/w1071_poll_mech_dev.sh 2>&1 | tail -1
A "chmod 755 /data/local/tmp/w1071_poll_mech_dev.sh" >/dev/null
A "rm -rf /data/local/tmp/w1071_mech; /system/bin/sh /data/local/tmp/w1071_poll_mech_dev.sh; echo MECH_RUN_RC=\$?; cat /data/local/tmp/w1071_mech/tick.txt" > $EV/w1071_mech_shot${SHOT}.txt 2>&1
grep -aE 'MECH|SLEEP_PROOF|LONGREAD' $EV/w1071_mech_shot${SHOT}.txt | cut -c1-170 | sed 's/^/      /'
grep -aq 'MECH_RC=0' $EV/w1071_mech_shot${SHOT}.txt || { echo "[x] 机制预检没判 0 ⇒ 不开枪"; exit 1; }
grep -aq 'MECH_RUN_RC=0' $EV/w1071_mech_shot${SHOT}.txt || { echo "[x] 预检件自己退出码不是 0 ⇒ 不开枪"; exit 1; }

echo "[3/6] 铺三件＋四把闸(第 87 发的腿／ko，和第 88 发要用的只读腿)"
LM=$(md5sum $LEGREPO | cut -d' ' -f1); PLM=$(md5sum $PLEGREPO | cut -d' ' -f1)
MSYS_NO_PATHCONV=1 adb push $LEGREPO $LEGDEV 2>&1 | tail -1
MSYS_NO_PATHCONV=1 adb push $KOREPO $KODEV 2>&1 | tail -1
MSYS_NO_PATHCONV=1 adb push $PLEGREPO $PLEGDEV 2>&1 | tail -1
A "chmod 755 $LEGDEV $PLEGDEV" >/dev/null
KDEV=$(A "md5sum $KODEV 2>/dev/null" | cut -d' ' -f1)
echo "  ko设备=$KDEV 登记=$KO_MD5_WANT"
[ "$KDEV" = "$KO_MD5_WANT" ] || { echo "[x] 设备上不是登记那份件 ⇒ 不开枪"; exit 1; }
gate() { # $1=设备路径 $2=本机 md5 $3=标题 —— 四把闸：x 位／plain s0／两端 md5／设备 mksh sh -n
    local P L D S
    P=$(A "ls -l $1 2>/dev/null" | awk 'NR==1{print $1}'); L=$(A "ls -Zd $1 2>/dev/null" | awk 'NR==1{print $1}')
    D=$(A "md5sum $1 2>/dev/null" | cut -d' ' -f1)
    #   ★这条串以 `/system/bin/sh` 开头 ⇒ 必须显式带 MSYS_NO_PATHCONV=1：不带时 msys 把它当**路径**转换，
    #     设备收到坏命令 ⇒ 永远 SHN=BAD(11-02 第 87 发实测：同一条命令加前缀就 OK，不加就 BAD)。A() 里没有这个前缀。
    S=$(MSYS_NO_PATHCONV=1 adb shell "/system/bin/sh -n $1 >/dev/null 2>&1 && echo SHN=OK || echo SHN=BAD" 2>&1 | tr -d '\r')
    echo "  $3 权限=$P 标签=$L 设备md5=$D 本机md5=$2 $S"
    [ "${P:3:1}" = x ] || { echo "[x] $3 没 x 位 ⇒ 不开枪"; exit 1; }
    case "$L" in *:s0) : ;; *) echo "[x] $3 标签不是 plain s0 ⇒ 不开枪(带类别挡 execute＝#114)"; exit 1 ;; esac
    [ "$D" = "$2" ] || { echo "[x] $3 设备上不是本机这支(旧件会静默换形状＝§6.155)⇒ 不开枪"; exit 1; }
    grep -q SHN=OK <<<"$S" || { echo "[x] $3 没过设备语法闸 ⇒ 不开枪"; exit 1; }
}
gate "$LEGDEV" "$LM" "第87发的腿"
gate "$PLEGDEV" "$PLM" "第88发的只读腿"

echo "[4/6] 开枪前把"这一 boot 还没开窗"钉下来，然后开窗(1 枪＝punch＋派致死腿)"
PU=$(A "cut -d' ' -f1 /proc/uptime"); PD=$(A "date +%s")
PSTART=$(( ${PD:-0} - ${PU%.*} ))
echo "  开枪前：enf=$(A getenforce) kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules") up=$PU hist=[$(A "getprop persist.sys.boot.reason.history")]"
echo "  ★钉住的旧 boot：kernel 起点≈$PSTART(第 88 发要证明"新 boot 晚于它"，不然就是"机器根本没死、我把同一个 boot 当成了死后的第一个")"
#   ★`LEG1ONLY=1` 用在**致死这一发**上的理由(不改死亡本身)：go.sh 第 4~7 步排在 LEG1 **后面**，
#     而这台机在 LEG1 里那句 insmod 之后就冻住了 ⇒ 那四步只在"复位回来的新 boot"里空转超时(约 10 分钟)，
#     而那 10 分钟正是**新 kernel 往 ramoops 里写自己日志**的时间 ⇒ 会把我唯一要读的东西冲掉。
#     死亡时刻、被测、args、腿全都不变(那几步在死之后)，只是把"读"提前 ⇒ 记这里，别让下一个人以为我换了形状。
LEG1ONLY=1 LEG1=$LEGDEV LEG1OUT=$LEGOUT LEG1MD5="$LM" I_KNOW=1 bash kmod/go.sh > $EV/w1100_shot${SHOT}_go.log 2>&1
GO=$?; echo "GO_RC=$GO(不判：这一发的结局本来就是机器被打死)"; tail -3 $EV/w1100_shot${SHOT}_go.log | sed 's/^/  go: /'

echo "[5/6] ★不许 reboot：等机器自己回来，并把"死后的第一个 boot"的身份现读钉下来"
for i in $(seq 1 40); do [ -n "$(adb get-state 2>/dev/null | grep device)" ] && break; sleep 5; done
until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 5; done
UP=$(A "cut -d' ' -f1 /proc/uptime"); DEVNOW=$(A "date +%s"); PCNOW=$(date +%s)
#   ★标记件里的数字必须能用(第 88 发拿它做减法)，所以这里先把两个都验成纯数字，不行就重来一轮。
for i in 1 2 3 4 5; do
    case "${UP%.*}" in ''|*[!0-9]*) UP="" ;; esac
    case "$DEVNOW" in ''|*[!0-9]*) DEVNOW="" ;; esac
    [ -n "$UP" ] && [ -n "$DEVNOW" ] && break
    echo "    等一个节拍重量 up/设备钟(第 $i 轮)：up=[$UP] devnow=[$DEVNOW]"; sleep 5
    UP=$(A "cut -d' ' -f1 /proc/uptime"); DEVNOW=$(A "date +%s")
done
{ [ -n "$UP" ] && [ -n "$DEVNOW" ]; } || { echo "[x] 拿不到数字的 up/设备钟 ⇒ 标记件写不出可信的 kernel 起点，停手别开第 88 发"; exit 1; }
BR=$(A "getprop ro.boot.bootreason"); HIST=$(A "getprop persist.sys.boot.reason.history")
START=$((DEVNOW - ${UP%.*} ))
#   ★这一发最容易自欺的形状＝"机器其实没死，我只是在同一个 boot 里等了半天"。用两个 boot 的 kernel 起点做减法判它：
#     新 boot 的起点必须**晚于**开枪前那个起点，否则"死后的第一个 boot"根本不成立 ⇒ 停手、不写标记件、第 88 发自然打不出。
[ "$START" -gt "$PSTART" ] || { echo "[x] 新 boot 的 kernel 起点($START)不晚于开枪前那个($PSTART)⇒ 机器**没死**或者我没等到复位 ⇒ 不许写标记件"; exit 1; }
echo "  ★两把 boot 的减法成立：旧起点 $PSTART → 新起点 $START(差 $((START - PSTART)) 秒)＝确实换了一个 kernel"
echo "  新 boot 自证：up=$UP bootreason=[$BR] kernelsu=$(A "grep -c '^kernelsu ' /proc/modules") probe=$(A "grep -c '^w985_probe ' /proc/modules") enf=$(A getenforce)"
echo "  hist=[$HIST]  设备钟=$DEVNOW 本机钟=$PCNOW ⇒ 本次 kernel 起点(设备钟算法)≈$START"
echo "  ★判读留给人：hist 最新那条应当是这一次复位；若它写着 reboot,shell ⇒ 中间有人(我)软重启过 ⇒ 这一 boot 不再是「死后第一个」，第 88 发会自己拒。"
{
    echo "MARK_SHOT=$SHOT"
    echo "MARK_PC_EPOCH=$PCNOW"
    echo "MARK_DEV_EPOCH=$DEVNOW"
    echo "MARK_UP=$UP"
    echo "MARK_KERNEL_START=$START"
    echo "MARK_OLD_KERNEL_START=$PSTART"
    echo "MARK_BOOTREASON=$BR"
    echo "MARK_HIST=$HIST"
    echo "MARK_PLEG_MD5=$PLM"
    echo "MARK_PLEG=$PLEGDEV"
    echo "MARK_PLEGOUT=$PLEGOUT"
} > $EV/w1100_death_marker.txt
cat $EV/w1100_death_marker.txt | sed 's/^/  标记件 /'

echo "  ---- 死亡 boot 的证件(★这一发第一次能在被人删之前把它们捞回来) ----"
for f in ksu_stage.log punch.log dmesg.live w184_sample.out ksu_ring_end.txt; do
    SZ=$(A "wc -c < /data/local/tmp/$f 2>/dev/null" | tr -dc '0-9')
    if [ -n "$SZ" ]; then
        MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/$f $EV/w1100_deathboot_$f 2>&1 | tail -1 | sed 's/^/      /'
        echo "      $f 设备字节=$SZ pull 后本机=$(wc -c < $EV/w1100_deathboot_$f 2>/dev/null) md5=$(md5sum $EV/w1100_deathboot_$f 2>/dev/null | cut -d' ' -f1)"
    else
        echo "      $f ⇒ 设备上不存在/读不到 ⇒ 这一件本轮不可用(不是"没发生"，例 208)"
    fi
done
PREVD=$(A "ls /data/local/tmp/ 2>/dev/null | grep -a '^dmesg.live.prev' | tr '\n' '|'")
echo "  设备上还留着的历史跟随器=$PREVD"

echo "  ---- 致死腿自己的三面(它们活在 /data，跨复位还在) ----"
A "cat $LEGOUT 2>/dev/null" > $EV/w1093_hist_shot${SHOT}.out 2>&1
A "cat $POUTDEV 2>/dev/null" > $EV/w1093_samp_shot${SHOT}.txt 2>&1
A "cat $PERRDEV 2>/dev/null" > $EV/w1093_serr_shot${SHOT}.txt 2>&1
echo "  证件行数=$(wc -l < $EV/w1093_hist_shot${SHOT}.out) 快照行数=$(wc -l < $EV/w1093_samp_shot${SHOT}.txt) stderr行数=$(wc -l < $EV/w1093_serr_shot${SHOT}.txt)"
grep -aE '^SAMP ' $EV/w1093_samp_shot${SHOT}.txt | tail -2 | cut -c1-260 | sed 's/^/    /'
grep -aE 'ARM=|ARGV|ko_md5|insmod_rc|MODULES_LINE|PARAM rt_abi|PARAM rt_stage|PARAM rt_seq|END up=|\[x\]|\[!!\]' $EV/w1093_hist_shot${SHOT}.out | cut -c1-175 | sed 's/^/    /'

echo "[6/6] ★收尾＝**不 reboot**"
A "svc power stayon false" >/dev/null; echo "  stay_on 读回=[$(A "settings get global stay_on_while_plugged_in")](这一 boot 没开窗所以它本来就该是 0/空)"
echo "SHOT${SHOT}_DONE ⇒ **现在立刻**跑第 88 发：bash kmod/w1101_shot88.sh"
echo "  ★中间不许 adb reboot、不许跑别的链(那会把要读的记录抹掉＝第 86 发白读的原因)"
echo "  证件：$EV/w1100_shot${SHOT}_go.log $EV/w1100_death_marker.txt $EV/w1100_deathboot_* $EV/w1093_{hist,samp,serr}_shot${SHOT}.* $EV/w1071_mech_shot${SHOT}.txt"
