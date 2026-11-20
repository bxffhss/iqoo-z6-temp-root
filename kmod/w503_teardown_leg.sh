#!/usr/bin/env bash
# w503_teardown_leg.sh —— 0 枪：把这扇窗收干净并回出厂态。顺序是**先 pull 存证 → 再删 → 复证 → 才 reboot**。
#   ★为什么收尾腿走 Termux 而不是 suw：本发是 B 形状(名单只有 10667 com.termux)，`@sushd:` 没人接(第 31/36 发口径)。
#   ★三条形状纪律：①打字前暖一行(#186 吞首字符)；②判据看文件与读回，不看 rc=0(例 148)；
#     ③push 一律单个前导 / 的绝对路径，且推完 md5 读回当硬闸(#179)；软重启后 `boot_completed` 会骗人(#188)
#     ⇒ 这一腿里"真重启"只认 uptime 掉回小数 + `kernelsu` 行数变 0。
set -u
cd "$(dirname "$0")/.." || exit 1
SER=<DEVICE_SERIAL>
EV=kmod/w103_evidence
T=/data/local/tmp
CLOSE_SRC=kmod/w450_close.sh
CLOSED=$T/w450_close.sh
OUTD=/sdcard/w450_close.txt
IME_NEW='com.locnet.gamekeyboard2/.SoftKeyboard'
IME_RESTORE=''
mkdir -p "$EV"; OUT="$EV/w503_teardown.txt"; : > "$OUT"
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
warm() { S "input text '#warm'" >/dev/null 2>&1; S "input keyevent 66" >/dev/null 2>&1; sleep 2; }
type_run() { S "input text '$1'" >/dev/null 2>&1; sleep 1; S "input keyevent 66" >/dev/null 2>&1; }

echo "# w503 $(date '+%m-%d %H:%M:%S') 收尾(0 枪)：先 pull→删→复证→reboot→复核" >> "$OUT"
echo "=== ① 删前存证：现场清单 + 三份日志 ==="
S "ls -A $T | tr '\n' ' '; echo; ls -l $T/kd $T/shd $T/ksud 2>&1 | tail -3; getenforce; grep -ac '^kernelsu ' /proc/modules; cat /proc/uptime" | tee -a "$OUT"
for f in ksu_stage.log shd.log ksu_nosuw ksu_args.txt kernelsu.ko ksuctl; do
    MSYS_NO_PATHCONV=1 adb -s $SER pull //$T/$f "$EV/w503_pre_$f" >/dev/null 2>&1 && echo "  pull $f = $(wc -c < "$EV/w503_pre_$f" 2>/dev/null) B" | tee -a "$OUT" || echo "  pull $f 没有(跳过)" | tee -a "$OUT"
done

echo "=== ② 送收尾腿：push(单个前导 /)＋设备 mksh 闸＋md5 读回 ==="
MSYS_NO_PATHCONV=1 adb -s $SER push "$CLOSE_SRC" "$CLOSED" 2>&1 | tail -1 >> "$OUT"
S "chmod 755 $CLOSED; sh -n $CLOSED && echo MKSH_N_OK; md5sum $CLOSED" | tee -a "$OUT"
S "sh -n $CLOSED && echo MKSH_N_OK2" | grep -qa 'MKSH_N_OK2' || fail "收尾腿没过设备 mksh(闸自己带生产者)" 2
[ "$(md5sum $CLOSE_SRC | cut -c1-32)" = "$(S "md5sum $CLOSED" | cut -c1-32)" ] || fail "收尾腿两端 md5 不符 ⇒ 不派" 3

echo "=== ③ 切输入法(读回)＋暖行＋派腿 ==="
CUR=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
S "ime enable $IME_NEW" >/dev/null 2>&1; S "ime set $IME_NEW" >/dev/null 2>&1; sleep 2
G=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
[ "$G" = "$IME_NEW" ] || fail "切输入法没生效(读回 [$G]) ⇒ 不打字" 4
IME_RESTORE="$CUR"
S "rm -f $OUTD" >/dev/null 2>&1
fresh_termux; warm; type_run '/system/bin/su%s-c%s/data/local/tmp/w450_close.sh'; sleep 6
echo "  收尾腿的回执($OUTD)：" | tee -a "$OUT"
S "cat $OUTD 2>&1" | tee -a "$OUT"
for w in 'umount_rc=0' 'rm_allow_rc=0' 'DONE'; do
    S "grep -ac '$w' $OUTD 2>/dev/null" | grep -qa '^[1-9]' || fail "收尾腿缺证人 [$w] ⇒ 先不 reboot(那会把没做完的收尾留在重启前)" 5
done

echo "=== ④ shell 侧把我方件删净(拿不掉的**如实记下**，不谎报) ==="
PATS="$T/kd $T/shd $T/ksud $T/w450_close.sh $T/ksu_stage.log $T/ksu_nosuw $T/ksu_args.txt $T/ksu_race_fd $T/kernelsu.ko $T/ksuctl $T/shd.log $T/dmesg.live $T/dmesg2.log $T/zzsh $T/ksu_slots.dump.txt $T/ksu_dom $T/ksu_dom_map $T/ksu_shbin $T/ksu_ap_key $T/ksu_quiet_after_insmod $T/ksu_quiet_fixcfi $T/ksu_two_profiles $T/ksu_allow_shell $T/ksu_skip_insmod $T/ksu_ring_end"
S "rm -f $PATS 2>/dev/null; for f in $PATS; do [ -e \"\$f\" ] && echo LEFT \"\$f\"; done | head -20; echo ---; ls -A $T | tr '\n' ' '" | tee -a "$OUT"
restore_ime; trap - EXIT

echo "=== ⑤ reboot 前的最后一组读数(记进存证，重启后拿它对账) ==="
S "getenforce; grep -ac '^kernelsu ' /proc/modules; cat /proc/uptime" | tee -a "$OUT"
echo "  >>> 现在 reboot(整机重启：内核才会清掉 ko；这是用户长期授权的动作)" | tee -a "$OUT"
adb -s $SER reboot 2>&1 | tail -1 | tee -a "$OUT"
for i in $(seq 1 60); do
    if adb -s $SER get-state >/dev/null 2>&1; then
        B=$(adb -s $SER shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | tr -dc '0-9')
        [ "$B" = "1" ] && { echo "  第 $i 次轮询：设备在线且 boot_completed=1" | tee -a "$OUT"; break; }
    fi
    sleep 5
done
sleep 15
echo "=== ⑥ 重启后复核(只读)：MAC 回来了、ko 没了、我方件没了 ==="
S "getenforce; grep -ac '^kernelsu ' /proc/modules; cat /proc/uptime; ls $T/kd $T/shd $T/w450_close.sh /product/bin/su 2>&1 | tail -4; ls -A $T | tr '\n' ' '; echo; ls -d /data/adb/* 2>&1 | head -3" | tee -a "$OUT"
ENF=$(S "getenforce"); MOD=$(S "grep -ac '^kernelsu ' /proc/modules"); UP=$(S "cat /proc/uptime" | cut -d. -f1)
echo "  对账：getenforce=[$ENF](应 Enforcing) kernelsu 行数=[$MOD](应 0) uptime=[$UP 秒](应是个位/几十秒＝内核真重启了，不是软重启)" | tee -a "$OUT"
[ "$ENF" = "Enforcing" ] || echo "  [!] 执法态没回来 ⇒ 这条要单独查(不是本腿能修的)" | tee -a "$OUT"
[ "$MOD" = "0" ] || echo "  [!] ko 还在(mod=$MOD) ⇒ 记录异常" | tee -a "$OUT"
echo "=== 完成：一手存证 $EV/w503_teardown.txt 与 w503_pre_* ===" | tee -a "$OUT"
