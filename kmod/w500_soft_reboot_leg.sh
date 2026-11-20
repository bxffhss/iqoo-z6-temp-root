#!/usr/bin/env bash
# w500_soft_reboot_leg.sh —— 0 枪：在**当前这扇已开着的窗**里照 Z5 的做法跑一次"软重启"
#   (= kill -9 system_server/zygote64/zygote，init 重拉，内核不动)，然后量三件事：
#     甲 内核确实没重启(/proc/uptime 连续) ＋ ko 还在(/proc/modules)
#     乙 框架确实重启了(新 zygote64 pid ≠ 载荷里记的旧 pid)   ★这一条是**反假绿**：相同就判"没发生"，整格不算通过
#     丙 交付的 su 形状活不活得过它(Termux 里同一条 /system/bin/su -c id 是否还出 uid=0)
#   形状纪律：①正对照(杀之前必须先出 root)不过 ⇒ **不开火**；②载荷自带 .out(生产者＝它自己，#172)；
#   ③IME 恢复在成功出口**显式做一次**，trap 只兜失败出口(#180)；④push 一律**单个前导 /** 的绝对路径(#179)。
set -u
cd "$(dirname "$0")/.." || exit 1
SER=<DEVICE_SERIAL>
EV=kmod/w103_evidence
DEV=/data/local/tmp/w500_soft.sh
OUTD=/data/local/tmp/w500_soft.out
KD=/data/local/tmp/kd
MD5_SHIM=f7a441d2a7aa0445bc9c7139df4838a3
ID_TEXT='/system/bin/su%s-c%sid'
FIRE_TEXT='/system/bin/su%s-c%s/data/local/tmp/w500_soft.sh'
IME_NEW='com.locnet.gamekeyboard2/.SoftKeyboard'
IME_RESTORE=''
mkdir -p "$EV"; OUT="$EV/w500_soft_reboot.txt"; : > "$OUT"
S() { adb -s $SER shell "$1" 2>&1 | tr -d '\r'; }
fail() { echo "  [STOP] $1 (rc=$2)"; printf 'STOP %s rc=%s\n' "$1" "$2" >> "$OUT"; exit "$2"; }
restore_ime() {
    [ -n "$IME_RESTORE" ] || return 0
    S "ime set $IME_RESTORE" >/dev/null 2>&1; sleep 1
    echo "    输入法装回读回：[$(S 'settings get secure default_input_method')](应为 $IME_RESTORE)" >> "$OUT"
}
bail() { restore_ime; }
trap bail EXIT
fresh_termux() { S "am force-stop com.termux" >/dev/null 2>&1; sleep 2; S "am start -n com.termux/.app.TermuxActivity" >/dev/null 2>&1; sleep 3; }
type_and_enter() { S "input text '$1'" >/dev/null 2>&1; sleep 1; S "input keyevent 66" >/dev/null 2>&1; sleep 4; }
shot() {
  S "screencap -p /data/local/tmp/w500_t.png" >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 adb -s $SER pull //data/local/tmp/w500_t.png "$EV/$1" >/dev/null 2>&1
  S "rm -f /data/local/tmp/w500_t.png" >/dev/null 2>&1
  ls -l "$EV/$1" 2>/dev/null | awk '{print $5" B  "$9}'
}

echo "# w500 $(date '+%m-%d %H:%M:%S') 软重启实测(0 枪；形状照 iqooz5/soft_reboot(软重启).sh，§6.384)" >> "$OUT"
echo "=== ① 基线读数 ==="
S "getenforce; grep -ac '^kernelsu ' /proc/modules; cat /proc/uptime; pidof zygote64; pidof system_server; md5sum $KD; cat /data/local/tmp/ksu_nosuw 2>&1" | tee -a "$OUT"
UP0=$(S "cat /proc/uptime" | cut -d. -f1)
Z0=$(S "pidof zygote64" | awk '{print $1}')
M0=$(S "grep -ac '^kernelsu ' /proc/modules")
[ "$M0" = "1" ] || fail "ko 不在了(mod=$M0) ⇒ 这一格没有可测对象" 2

echo "=== ② 推载荷(单个前导 / 的绝对路径)＋设备 mksh 语法闸＋chmod＋md5 读回 ==="
MSYS_NO_PATHCONV=1 adb -s $SER push kmod/w500_soft.sh "$DEV" 2>&1 | tail -1 >> "$OUT"
S "chmod 755 $DEV; sh -n $DEV && echo MKSH_N_OK; ls -l $DEV; md5sum $DEV" | tee -a "$OUT"
# ★闸自己必须有生产者：这里重新跑一遍"sh -n && 打印证人串"，而不是去 grep 上面那条命令的输出
#   (第一版就栽在这——上面明明打了 MKSH_N_OK，闸却 grep 一条不打印它的命令，把自己判成红，例 147 同族)
S "sh -n $DEV && echo MKSH_N_OK2" | grep -qa 'MKSH_N_OK2' || fail "载荷没过设备 mksh 的 sh -n ⇒ 不开火" 3

echo "=== ③ 切输入法(读回)＋正对照：杀之前 su 必须先出 root，否则整格作废、不开火 ==="
CUR=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
S "ime enable $IME_NEW" >/dev/null 2>&1; S "ime set $IME_NEW" >/dev/null 2>&1; sleep 2
G=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
[ "$G" = "$IME_NEW" ] || fail "切输入法没生效(读回 [$G]) ⇒ 不打字" 4
IME_RESTORE="$CUR"; echo "  已切 $IME_NEW(原 $CUR)" | tee -a "$OUT"
fresh_termux; type_and_enter "$ID_TEXT"
echo "  截图(杀之前) $(shot w500_a_before.png)" | tee -a "$OUT"
S "ls -l $OUTD 2>&1 | tail -1" | tee -a "$OUT"

echo "=== ③b 开火开关(默认关；这一跑先看截图，人判过再 FIRE=1 重跑) ==="
echo "  开关现值读回：FIRE=${FIRE:-0}(=1 才允许杀框架)" | tee -a "$OUT"
if [ "${FIRE:-0}" != "1" ]; then
    echo "  ⇒ **未开火**：只做到基线＋推载荷＋正对照截图，设备状态没被动过(输入法稍后装回)。" | tee -a "$OUT"
    restore_ime; trap - EXIT; exit 0
fi

echo "=== ④ 开火：让 root 跑载荷(kill 在它自己落盘之后) ==="
S "rm -f $OUTD" >/dev/null 2>&1
type_and_enter "$FIRE_TEXT"
sleep 8
echo "  载荷的 .out(入口证人，也是它自己那一份基线)：" | tee -a "$OUT"
# ★重试而不是一次定生死：杀完框架 adb 会掉一会儿(载荷说"USB 断 1-2 分钟")，
#   一次读空就判"载荷没跑"会是**假红**(例 172 那一族：等不到回执≠没发生)。
P=0
for i in $(seq 1 12); do
    T=$(S "cat $OUTD 2>/dev/null")
    case "$T" in *z64=*) P=1; echo "  第 $i 次读到 .out" | tee -a "$OUT"; echo "$T" | tee -a "$OUT"; break ;; esac
    sleep 5
done
[ "$P" = "1" ] || fail ".out 里没有 z64=(重试 12 次/60 秒) ⇒ 载荷根本没跑：不开第二枪，先查 su 那步" 5

echo "=== ⑤ 等框架回来：boot_completed=1，最多 300 秒(adb 会先掉一会儿) ==="
OK=0
for i in $(seq 1 60); do
    B=$(adb -s $SER shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | tr -dc '0-9')
    [ "$B" = "1" ] && { echo "  第 $i 次轮询：boot_completed=1(约 $((i*5)) 秒)" | tee -a "$OUT"; OK=1; break; }
    sleep 5
done
[ "$OK" = "1" ] || { echo "  [!] 300 秒框架仍没回来 ⇒ 交回控制权，先报现场，不自己 reboot(那会毁掉这扇窗)" | tee -a "$OUT"; exit 6; }
# boot_completed=1 只代表框架起来了，输入法/窗口动画还在 settle ⇒ 给足 45 秒再打字(否则丙条会打在空处)
echo "  settle 45 秒后再做丙条" | tee -a "$OUT"; sleep 45

echo "=== ⑥ 甲乙丙三条判据 ==="
UP1=$(S "cat /proc/uptime" | cut -d. -f1)
Z1=$(S "pidof zygote64" | awk '{print $1}')
M1=$(S "grep -ac '^kernelsu ' /proc/modules")
echo "  甲1 uptime：杀前=$UP0 → 杀后=$UP1  (必须连续递增＝内核没重启；掉回个位数＝真重启了)" | tee -a "$OUT"
echo "  甲2 kernelsu 在 /proc/modules 的行数：杀前=$M0 杀后=$M1" | tee -a "$OUT"
echo "  乙 zygote64 pid：载荷里旧值=$(S "grep -a '^z64=' $OUTD" | cut -d= -f2 | awk '{print $1}')  本机现读新值=$Z0→$Z1" | tee -a "$OUT"
echo "  ss pid：$(S "pidof system_server")  boot_completed=$(S "getprop sys.boot_completed")  enf=$(S "getenforce")" | tee -a "$OUT"
[ -n "$Z1" ] || fail "读不到新 zygote64 pid ⇒ 乙条不成立" 7
[ "$Z1" != "$Z0" ] || { fail "乙条不成立：zygote64 pid 没变(=$Z1) ⇒ 软重启**根本没发生**，丙条不许当通过" 8; }

echo "=== 丙：重新起 Termux 敲同一条 su，字还在不在 ==="
fresh_termux; type_and_enter "$ID_TEXT"
echo "  截图(杀之后) $(shot w500_b_after.png)" | tee -a "$OUT"

echo "=== ⑦ 收尾：pull 载荷 .out 存证后删掉两件临时件，恢复输入法与 kd(没动) ==="
MSYS_NO_PATHCONV=1 adb -s $SER pull //data/local/tmp/w500_soft.out kmod/w103_evidence/w500_payload_out.txt 2>&1 | tail -1 >> "$OUT"
S "rm -f $DEV $OUTD $OUTD.chmod $KD.chmod 2>/dev/null; ls $DEV $OUTD 2>&1 | tail -2; md5sum $KD" | tee -a "$OUT"
S "getenforce; grep -ac '^kernelsu ' /proc/modules; cat /proc/uptime" | tee -a "$OUT"
echo "  ★丙条只看两张截图里那行字(w500_a_before / w500_b_after)；rc=0 只代表三判据都跑到了" | tee -a "$OUT"
restore_ime
trap - EXIT
