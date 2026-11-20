#!/usr/bin/env bash
# w360_arm_newboot.sh —— 修 `w356_arm_after_boot.sh` 在这一发里踩到的坑：**它把"上一个 boot 还开着"读成了"这一 boot 起来了"**。
#   一手(第 124 发 23:04:12)：本脚本前身第一次轮询就拿到 `boot_completed=1`，而那一刻设备还在**开窗前那个 24.5 小时的 boot** 里；
#   紧接着 go.sh 的 reboot 落地 ⇒ 下一条 adb 直接 `no devices/emulators found` ⇒ 它按自己的闸停手(停是对的，曲线确实没起来)。
#   和例 77 同族但换了形态：残留的不是文件，是**"就绪位"这个读数本身跨 boot 为真**。
# 前提(用之前必须成立)：调用时设备**正在掉线重启**，所以"第一次见到在线"=新 boot。本脚本会先把这个前提验一遍。
set -u
export MSYS_NO_PATHCONV=1
N=${1:-2400}
OUTF=/data/local/tmp/w356_storm.out
S(){ timeout 30 adb shell "$1" 2>&1 | tr -d '\r'; }

echo "=== 0) 先确认'此刻不在线'这个前提(否则后面全不成立) ==="
if [ "${I_SAW_IT_OFFLINE:-0}" = 1 ]; then
    echo '  ★跳过轮询：调用方声明**已经一手见过它掉线**(本脚本的 adb devices 会立刻抓到在线的新 boot，轮询反而永远不成立)'
    echo "  要求：把'在哪一分钟看到 no devices'记进存证，否则这一格等于没闸"
else
for i in 1 2 3; do
    LV=$(timeout 20 adb devices | tr -d '\r' | grep -c device$)
    echo "  第 $i 次 adb devices 在线数=$LV"
    [ "$LV" = 0 ] && { echo "  ✓ 离线 ⇒ 第一次见到在线就是**新 boot**"; break; }
    [ "$i" = 3 ] && { echo "[x] 三次都在线 ⇒ 我没资格替你断定这是新 boot。手工确认后再跑，或直接用 w356_arm_after_boot.sh"; exit 5; }
    sleep 5
done
fi

echo; echo "=== 1) 等它回来(wait-for-device)，再等 boot_completed=1 ==="
timeout 900 adb wait-for-device || { echo "[x] 15 分钟没等到在线 ⇒ 停(这一发的 reboot 没成功，或机器掉了)"; exit 3; }
BC=""
for i in $(seq 1 120); do
    BC=$(S "getprop sys.boot_completed" | tr -dc '0-9')
    [ "$BC" = 1 ] && { echo "  boot_completed=1 (第 $i 次, $(date +%H:%M:%S))"; break; }
    [ $((i % 10)) -eq 0 ] && echo "    还在等: 第 $i 次 ($(date +%H:%M:%S)) 上次读数=[$BC]"
    sleep 10
done
[ "$BC" = 1 ] || { echo "[x] 等满 20 分钟 boot_completed 不是 1 ⇒ 停"; exit 3; }
sleep 25

echo; echo "=== 2) 记下这一 boot 的身份(boot_id)，并回读起点 ==="
BID=$(S "cat /proc/sys/kernel/random/boot_id" | tr -d ' \r')
UP0=$(S "cut -d' ' -f1 /proc/uptime" | tr -dc '0-9.')
echo "  boot_id=[$BID]  起点 up=[$UP0]  ★这两个要一起进存证：以后任何'曲线接在同一个文件里'的怀疑都能用 boot_id 一刀切开"
[ -n "$BID" ] || { echo "[x] boot_id 读不到 ⇒ 停(没有身份，事后没法证明曲线属于哪一次 boot)"; exit 3; }

echo; echo "=== 3) 起曲线之前把同名残留删掉并复证(复证这条 adb 会撞重启边界，所以要重试) ==="
GONE=""
for i in 1 2 3 4 5; do
    S "rm -f $OUTF" >/dev/null 2>&1
    GONE=$(S "ls $OUTF 2>&1" | head -1)
    case "$GONE" in *"No such file"*) echo "  第 $i 次复证=[$GONE] ✓"; break;; esac
    echo "  第 $i 次复证=[$GONE] 不像'已删' ⇒ 再试"; sleep 8
done
case "$GONE" in *"No such file"*) ;; *) echo "[x] 旧曲线没删掉 ⇒ 停(跨 boot 相接的曲线会让速率判据算出假东西)"; exit 3;; esac

echo; echo "=== 4) 检测是不是已经有东西在写这条曲线 —— ★**不用 ps**(一手：ps 那条恒 0=假闸)"
# 一手教训(第 124 发 23:06)：`ps -A | grep -c w356_storm_dev` 在采样器明明活着的时候数到 **0** ⇒
#   这台设备 ps 的 NAME 列只有可执行文件名(mksh 脚本显示成 sh)，**脚本名压根不出现** ⇒ 按脚本名数进程=恒 0 的假闸(例 75/例 79 同族)。
#   与'被测物'同层的检测只有一条：**这条文件会不会自己长出来**。
S "rm -f $OUTF" >/dev/null 2>&1
sleep 4
PRE=$(S "ls $OUTF 2>&1" | head -1)
case "$PRE" in
  *"No such file"*) echo "  删掉后等 4 秒仍然不在 ⇒ 没有别的东西在写这条曲线 ✓" ;;
  *) echo "  !! 删掉 4 秒后又出现=[$PRE] ⇒ **有别的采样器在写** ⇒ 停(别叠第二个，也别让两条曲线相接)"; exit 3 ;;
esac

echo; echo "=== 5) 起采样(设备侧固定 1 fork/秒)并用**文件增长**自证它真活着 ==="
S "setsid nohup /data/local/tmp/w356_storm_dev.sh $N >/dev/null 2>&1 </dev/null &"
sleep 6
S 'head -2 /data/local/tmp/w356_storm.out; echo 当前_up=$(cut -d" " -f1 /proc/uptime)' | sed 's/^/  /'
L1=$(S "wc -l < /data/local/tmp/w356_storm.out" | tr -dc '0-9')
sleep 8
L2=$(S "wc -l < /data/local/tmp/w356_storm.out" | tr -dc '0-9')
echo "  行数 t0=[$L1] → t+8s=[$L2]  ★必须增长(文件存在≠在跑)"
if [ -z "$L2" ] || [ "$L2" -le "${L1:-0}" ]; then echo "[x] 曲线没长 ⇒ 采样器没活着 = 这一发没有仪器，停"; exit 3; fi
echo "  ✓ 仪器活着(判据的生产者已确认)"
echo
echo '★读数(复位之后)：'
echo '    MSYS_NO_PATHCONV=1 adb pull //data/local/tmp/w356_storm.out kmod/w103_evidence/<这一发的名>_curve.out   ★名字自己换，别接上一发的文件(例 77)'
echo '    PYTHONUTF8=1 python kmod/w356_rate.py kmod/w103_evidence/<这一发的名>_curve.out'
echo '★判据**不在这里写死**：曲线末格只给不晚于(例 99)，死亡时刻一律用两个 boot 的 epoch 夹再减复位延迟 25~35 秒。'
echo '★这一发的判据与前置闸看 kmod/W345_RC68_WINDOW.md 最新那一节(10-15 晚间＝§15＝C4 单条目+空 args；§14 那发已作废)。'
echo "★存证要带上 boot_id=[$BID] 与起点 up=[$UP0]。"
