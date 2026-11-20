#!/usr/bin/env bash
# w501_after_leg.sh —— 0 枪：把 w500 的"丙条"补成**文件证人**(别只靠屏幕字)。
#   背景：w500 里甲(uptime 连续 16702→16783、kernelsu 1→1)与乙(zygote64 1021→14973、ss 1605→15079)都成立，
#   但丙那张截图回来的是 `bash: system/bin/su: No such file`——**开头的 `/` 被吃掉**(新 Termux 第一次按键丢首字符)，
#   所以那一条当时是**未测**，不许当成"软重启后 su 坏了"，也不许当成"没问题"。
#   ★这一腿的形状纪律：
#     ①先做**反夹具**：让 su 跑一个不存在的脚本 ⇒ .out 必须不出现(证"出现"真有生产者，不是自动)；
#     ②每次读 .out 前先 rm(排掉陈旧文件冒充)；
#     ③打字前先"暖一行"(# + Enter)把首字符丢失这个坑填掉；
#     ④IME 恢复在成功出口显式做一次，trap 只兜失败(#180)；push 用单个前导 /(用 #179 学到的写法)。
set -u
cd "$(dirname "$0")/.." || exit 1
SER=<DEVICE_SERIAL>
EV=kmod/w103_evidence
P=/data/local/tmp/w501_probe.sh
O=/data/local/tmp/w501_probe.out
IME_NEW='com.locnet.gamekeyboard2/.SoftKeyboard'
IME_RESTORE=''
mkdir -p "$EV"; OUT="$EV/w501_after_leg.txt"; : > "$OUT"
S() { adb -s $SER shell "$1" 2>&1 | tr -d '\r'; }
fail() { echo "  [STOP] $1 (rc=$2)"; printf 'STOP %s rc=%s\n' "$1" "$2" >> "$OUT"; exit "$2"; }
restore_ime() {
    [ -n "$IME_RESTORE" ] || return 0
    S "ime set $IME_RESTORE" >/dev/null 2>&1; sleep 1
    echo "    输入法装回读回：[$(S 'settings get secure default_input_method')](应为 $IME_RESTORE)" | tee -a "$OUT"
}
bail() { restore_ime; }
trap bail EXIT
fresh_termux() { S "am force-stop com.termux" >/dev/null 2>&1; sleep 2; S "am start -n com.termux/.app.TermuxActivity" >/dev/null 2>&1; sleep 3; }
warm() { S "input text '#warm'" >/dev/null 2>&1; S "input keyevent 66" >/dev/null 2>&1; sleep 2; }   # 暖一行：把"第一个字符被吞"这个坑填掉
type_run() { S "input text '$1'" >/dev/null 2>&1; sleep 1; S "input keyevent 66" >/dev/null 2>&1; }
read_out() {   # 重试读 .out(adb 可能不稳)；$1=要等的关键词
    for i in $(seq 1 10); do
        T=$(S "cat $O 2>/dev/null")
        case "$T" in *"$1"*) echo "  第 $i 次读到："; echo "$T"; return 0 ;; esac
        sleep 3
    done
    return 1
}
shot() {
  S "screencap -p /data/local/tmp/w501_t.png" >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 adb -s $SER pull //data/local/tmp/w501_t.png "$EV/$1" >/dev/null 2>&1
  S "rm -f /data/local/tmp/w501_t.png" >/dev/null 2>&1
  ls -l "$EV/$1" 2>/dev/null | awk '{print $5" B  "$9}'
}

echo "# w501 $(date '+%m-%d %H:%M:%S') 软重启之后的第二证人(文件，不是屏幕)；0 枪" >> "$OUT"
echo "=== ① 现场读数(应与 w500 收尾一致：同一 boot、ko 还在、zygote 是新 pid) ==="
S "getenforce; grep -ac '^kernelsu ' /proc/modules; cat /proc/uptime; pidof zygote64; pidof system_server; ls -l /data/local/tmp/kd" | tee -a "$OUT"
UPA=$(S "cat /proc/uptime" | cut -d. -f1)
[ "$(S "grep -ac '^kernelsu ' /proc/modules")" = "1" ] || fail "ko 已经不在了 ⇒ 这一格没有可测对象" 2

echo "=== ② 推探针(单个前导 /)＋设备 mksh 闸＋md5 读回 ==="
MSYS_NO_PATHCONV=1 adb -s $SER push kmod/w501_probe.sh "$P" 2>&1 | tail -1 >> "$OUT"
S "chmod 755 $P; sh -n $P && echo MKSH_N_OK2; ls -l $P; md5sum $P" | tee -a "$OUT"
S "sh -n $P && echo MKSH_N_OK2" | grep -qa 'MKSH_N_OK2' || fail "探针没过设备 mksh ⇒ 不做" 3

echo "=== ③ 切输入法(读回) ==="
CUR=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
S "ime enable $IME_NEW" >/dev/null 2>&1; S "ime set $IME_NEW" >/dev/null 2>&1; sleep 2
G=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
[ "$G" = "$IME_NEW" ] || fail "切输入法没生效(读回 [$G])" 4
IME_RESTORE="$CUR"; echo "  已切 $IME_NEW(原 $CUR)" | tee -a "$OUT"

echo "=== ④ 反夹具(先证仪器会红)：su 跑一个**不存在**的脚本 ⇒ .out 必须不出现 ==="
fresh_termux; warm; S "rm -f $O" >/dev/null 2>&1
type_run '/system/bin/su%s-c%s/data/local/tmp/w501_NOPE.sh'; sleep 5
NOPE=$(S "ls $O 2>&1 | tail -1")
echo "  .out 应当不存在，实读：$NOPE" | tee -a "$OUT"
case "$NOPE" in *"No such file"*) echo "  [OK] 反夹具成立：出现与否真的有生产者" | tee -a "$OUT" ;; *) fail "反夹具翻红：不存在的脚本也留下了 .out ⇒ 这台机上有别的写者，判据不可信" 5 ;; esac

echo "=== ⑤ 正题：su 跑探针 ⇒ .out 里必须写 uid=0，且文件属主是 root ==="
fresh_termux; warm; S "rm -f $O" >/dev/null 2>&1
type_run '/system/bin/su%s-c%s/data/local/tmp/w501_probe.sh'; sleep 4
# ★不能把 if 塞进管道：那样里头的 fail 只在子 shell 退出，rc 会被盖成 0(刚记下的那条毛病)
RD=$(read_out 'who='); RC=$?
if [ "$RC" = 0 ]; then
    { echo "  文件证人到手："; echo "$RD"; } | tee -a "$OUT"
else
    echo "  [!] 读不到 .out(重试 10 次) ⇒ 先取截图看是不是又被吞字；这一格记**未测**，不记失败" | tee -a "$OUT"
    echo "  截图 $(shot w501_miss.png)" | tee -a "$OUT"
    fail "丙条：文件证人缺席(未测)" 6
fi
S "ls -l $O" | tee -a "$OUT"
UPB=$(S "grep -a ^up= $O" | cut -d= -f2 | cut -d. -f1)
echo "  对账：本机现读 up=$UPA；.out 里 root 自报 up=$UPB(两个必须接近＝同一次开机)" | tee -a "$OUT"

echo "=== ⑥ 第二证人：屏幕上再拍一张(先暖行，避开首字符被吞) ==="
warm; type_run '/system/bin/su%s-c%sid'; sleep 5
echo "  截图 $(shot w501_c_after_softreboot.png)" | tee -a "$OUT"

echo "=== ⑦ 收尾：删探针与 .out，装回输入法，回读三件 ==="
S "rm -f $P $O; ls $P $O 2>&1 | tail -2" | tee -a "$OUT"
restore_ime; trap - EXIT
S "getenforce; grep -ac '^kernelsu ' /proc/modules; cat /proc/uptime; md5sum /data/local/tmp/kd" | tee -a "$OUT"
echo "  ★判定看 ⑤ 那行 who= 与 ⑥ 那张图；rc=0 只代表两条都取到了" | tee -a "$OUT"
