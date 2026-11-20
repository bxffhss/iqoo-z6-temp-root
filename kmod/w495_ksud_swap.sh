#!/usr/bin/env bash
# w495_ksud_swap.sh v3 —— 0 枪：把 ko 改道目标 /data/local/tmp/kd 的**内容**换成官方 ksud，
#   从 Termux 敲绝对路径 /system/bin/su -c id ⇒ 看官方 ksud 能不能在我们 ko 上直接当 root agent。
#   为什么不用重编 ko：sucompat 每次 exec 都 kern_path/filp_open 现读那个路径串
#   (kmod/dev_src/sucompat_rc67.c:115-124 与 :389/:392)，0444 只锁"参数值"，不锁"那串路径指向谁"。
#   ★v3 的来历(§6.383，两条现场换来的)：
#     ①**这个实验根本不需要传输通道**：官方 ksud 已经在设备上(/data/adb/ksud，Manager 自己 13:17 装的，
#        shell 读得到)，换件一律设备侧 rm+cp。v1/v2 用 adb push 是多余动作。
#     ②**adb push 的远端目标必须写成单个前导 / 的绝对路径**：相对形式(`data/local/tmp/kd`)与
#        双斜杠形式(`//data/local/tmp/x`)都会报 `remote fchown failed: Operation not permitted`，
#        **并且 adb 随即把目标文件删掉**；同一台机同一时刻推 `/data/local/tmp/w496_big.bin`(2.2 MB)
#        与 915 B 文本件都正常 ⇒ 死因是"路径写法"，不是文件大小、也不是"覆盖已存在件"(我第一版这样
#        归因过，错的，探针把它劈开了：一手 kmod/w103_evidence/w496_push_form_probe.txt)。
#   ★双向：正对照(真 ksud)与反对照(原 shim)各敲同一条命令；两格之间 force-stop 重开 Termux，
#     否则第一格若起了交互壳，第二格就不在同一形状上(那不算对照)。
set -u
cd "$(dirname "$0")/.." || exit 1
SER=<DEVICE_SERIAL>
EV=kmod/w103_evidence
KD=/data/local/tmp/kd
DEV_KSUD=/data/local/tmp/w495_ksud        # 设备侧 cp 自 /data/adb/ksud
DEV_SHIM=/data/local/tmp/ksud             # 设备上本来就有的那份(与台账 kd 同一 md5)
MD5_SHIM=f7a441d2a7aa0445bc9c7139df4838a3
MD5_KSUD=de059ed8ffd896129a0a4bae338c946a
CMD_TEXT='/system/bin/su%s-c%sid'         # 空格只能 %s(%20 会留字面量)
IME_NEW='com.locnet.gamekeyboard2/.SoftKeyboard'
IME_RESTORE=''
mkdir -p "$EV"; OUT="$EV/w495_ksud_swap.txt"; : > "$OUT"
S() { adb -s $SER shell "$1" 2>&1 | tr -d '\r'; }
md5dev() { S "md5sum $1 2>/dev/null" | cut -c1-32 | tr -d '[:space:]'; }
fail() { echo "  [STOP] $1 (rc=$2)"; printf 'STOP %s rc=%s\n' "$1" "$2" >> "$OUT"; exit "$2"; }
put_kd() { S "rm -f $KD; cp $1 $KD; chmod 755 $KD" >/dev/null 2>&1; }   # 设备侧换件，绝不用 push
restore_ime() {
    [ -n "$IME_RESTORE" ] || return 0
    S "ime set $IME_RESTORE" >/dev/null 2>&1; sleep 1
    echo "    输入法装回读回：[$(S 'settings get secure default_input_method')](应为 $IME_RESTORE)" >> "$OUT"
}
bail() { put_kd "$DEV_SHIM"; restore_ime; }
trap bail EXIT
fresh_termux() { S "am force-stop com.termux" >/dev/null 2>&1; sleep 2; S "am start -n com.termux/.app.TermuxActivity" >/dev/null 2>&1; sleep 3; }
type_and_enter() { S "input text '$CMD_TEXT'" >/dev/null 2>&1; sleep 1; S "input keyevent 66" >/dev/null 2>&1; sleep 4; }
shot() {   # pull 用 //绝对路径(这条只对 pull 成立)
  S "screencap -p /data/local/tmp/w495_t.png" >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 adb -s $SER pull //data/local/tmp/w495_t.png "$EV/$1" >/dev/null 2>&1
  S "rm -f /data/local/tmp/w495_t.png" >/dev/null 2>&1
  ls -l "$EV/$1" 2>/dev/null | awk '{print $5" B  "$9}'
}

echo "# w495v3 $(date '+%m-%d %H:%M:%S') 换件实验(0 枪)：正对照=真 ksud，反对照=原 shim；全程设备侧 cp" >> "$OUT"
echo "=== ① 台账核对：kd 与设备那份 ksud 都必须是 f7a441d2 ==="
A=$(md5dev $KD); B=$(md5dev $DEV_SHIM); echo "  kd=$A  $DEV_SHIM=$B" | tee -a "$OUT"
[ "$A" = "$MD5_SHIM" ] && [ "$B" = "$MD5_SHIM" ] || fail "台账形状不对 ⇒ 不动手(先查谁改的)" 2

echo "=== ② 取件：设备侧 cp /data/adb/ksud → $DEV_KSUD，读回必须 de059ed8 ==="
S "rm -f $DEV_KSUD; cp /data/adb/ksud $DEV_KSUD; chmod 755 $DEV_KSUD" | tee -a "$OUT"
S "ls -l $DEV_KSUD" | tee -a "$OUT"
C=$(md5dev $DEV_KSUD); echo "  读回 = $C(应 $MD5_KSUD)" | tee -a "$OUT"
[ "$C" = "$MD5_KSUD" ] || fail "取件读回不符 ⇒ 现有件一个都没动" 3

echo "=== ③ 切输入法(现值 iFlytek＝会吞字)，切完必须读回 ==="
CUR=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
S "ime enable $IME_NEW" >/dev/null 2>&1; S "ime set $IME_NEW" >/dev/null 2>&1; sleep 2
G=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
[ "$G" = "$IME_NEW" ] || fail "切输入法没生效(读回 [$G]) ⇒ 不打字" 4
IME_RESTORE="$CUR"; echo "  已切 $IME_NEW(原 $CUR)" | tee -a "$OUT"

echo "=== ④ 正对照(改道落点=真 ksud)：Termux 里 /system/bin/su -c id ＋截图 ==="
put_kd "$DEV_KSUD"; D=$(md5dev $KD); echo "  换件后 $KD = $D(应 $MD5_KSUD)" | tee -a "$OUT"
[ "$D" = "$MD5_KSUD" ] || fail "设备侧 cp 没换成功" 5
fresh_termux; type_and_enter
echo "  截图 $(shot w495_a_after_ksud.png)" | tee -a "$OUT"
echo "  ps 里带 ksud 的行：$(S "ps -A | grep -a ksud | head -4" | tr '\n' '|')" | tee -a "$OUT"
echo "  此刻 $KD 还在不在/还是不是它：$(md5dev $KD)" | tee -a "$OUT"

echo "=== ⑤ 反对照：把原 shim 放回同一路径，同一条命令再敲一次 ==="
put_kd "$DEV_SHIM"; E=$(md5dev $KD); echo "  复原后 $KD = $E(应 $MD5_SHIM)" | tee -a "$OUT"
[ "$E" = "$MD5_SHIM" ] || fail "复原读回不符 ⇒ 后面的对照不做(先把形状弄回来)" 6
fresh_termux; type_and_enter
echo "  截图 $(shot w495_b_after_shim.png)" | tee -a "$OUT"

echo "=== ⑥ 收尾：删临时件、回读四件(kd/输入法/MAC/模块在不在) ==="
S "rm -f $DEV_KSUD; ls $DEV_KSUD 2>&1 | tail -1" | tee -a "$OUT"
S "ls -l $KD; md5sum $KD; settings get secure default_input_method; getenforce; grep -ac '^kernelsu ' /proc/modules" | tee -a "$OUT"
echo "  ★结论只看两张截图里的字；rc=0 只代表两格都跑到(例 148)" | tee -a "$OUT"
# ★#180 的教训：原来这里直接 `trap - EXIT`，等于把"成功出口"的恢复动作一起注销了
#   ⇒ 第一跑跑完设备留在 GameKeyboard(读回证实)，我手工装回才补上。恢复必须**显式做一次**，
#   trap 只兜失败出口(例 105 那条的反面)。
restore_ime
trap - EXIT
