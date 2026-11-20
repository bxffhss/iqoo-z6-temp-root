#!/usr/bin/env bash
# run_rleg.sh —— `w211_ui.sh rleg` 那条"等 DONE"判据的专属双向自测（0 枪，#172 换来的）。
#   为什么要有它：第 37 发我让 `rleg` 派 `w426_enforce.sh`，它**不产 .out**（stdout 归 sushd），
#   而 rleg 空等 12 轮后打印"通道或脚本有问题"⇒ 那是一条**假红**：腿其实跑了(入口证人在 sushd.log，
#   末端证人＝PC 侧读回 enforce 0→1)。教训：**"等不到回执"≠"没发生"；"等回执"这个判据必须先问这条腿有没有生产者**。
#   ★第一跑就抓到一条既存缺陷：成功路径返 rc=1、等满反而返 0——方向是反的(见 ⑤ 最后那格)。
#   ★全部走桩：假 adb＋假 sleep(数次数)，绝不碰设备(例 130：自测要"数腿"——这里数 sleep 次数)。
set -u
cd "$(dirname "$0")/../.." || exit 1
W=kmod/_tmp_selftest_rdst/.rleg_work
rm -rf "$W"; mkdir -p "$W/bin"
export FIX_PROD=0 FIX_DONE=0
N=0; fail=0
chk() { # $1=描述 $2=条件(0=过)
    N=$((N+1))
    if [ "$2" = "0" ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi
}

# 假 adb：只回答 rleg 会问的那两条读数，其余静默成功。输出**带 \r**(像真 adb shell)。
cat > "$W/bin/adb" <<'ADB'
#!/usr/bin/env bash
[ "${1:-}" = "shell" ] || exit 0
c="${2:-}"
case "$c" in
  *"grep -acF '=== DONE'"*) printf '%s\r\n' "$FIX_DONE"; exit 0 ;;
  *"grep -acF '/data/local/tmp/"*) printf '%s\r\n' "$FIX_PROD"; exit 0 ;;
  *) exit 0 ;;
esac
ADB
cat > "$W/bin/sleep" <<'SLP'
#!/usr/bin/env bash
echo x >> "$SLEEPCNT"
exit 0
SLP
chmod 755 "$W/bin/adb" "$W/bin/sleep" 2>/dev/null
export PATH="$W/bin:$PATH"

run_rleg() { # $1=桩里的腿名(只当文件名用)；读数由 FIX_PROD/FIX_DONE 决定
    export SLEEPCNT="$W/sleeps_$1"
    : > "$SLEEPCNT"
    bash kmod/w211_ui.sh rleg "$1.sh" > "$W/out_$1" 2>&1
    RC=$?
    NS=$(wc -l < "$SLEEPCNT" | tr -dc '0-9')
}

echo "=== ① 有生产者(FIX_PROD=1)＋第一次就读到 DONE ⇒ 报'完成(轮=1)'、rc=0 ==="
FIX_PROD=1 FIX_DONE=1 run_rleg with_out
grep -qaE '完成\(轮=1\)' "$W/out_with_out"; chk "①报'完成(轮=1)'" "$?"
chk "①rc=0(实得 $RC)" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
chk "①等待循环真的跑过(数 sleep＝$NS，应≥2：force-stop 那 1 次＋等 DONE)" "$([ "$NS" -ge 2 ] && echo 0 || echo 1)"

echo "=== ② 没有生产者(FIX_PROD=0) ⇒ 走'读不到完成信号'那一支：rc=7＋点名两条替代证人 ==="
FIX_PROD=0 FIX_DONE=1 run_rleg no_out
chk "②rc=7(实得 $RC)" "$([ "$RC" = 7 ] && echo 0 || echo 1)"
grep -qa '状态变化' "$W/out_no_out"; chk "②说了替代证人①(状态变化)" "$?"
grep -qa '入口证人' "$W/out_no_out"; chk "②说了替代证人②(入口证人)" "$?"
grep -qa '不等于腿失败' "$W/out_no_out"; chk "②明写'不等于腿失败'(不把仪器盲区报成事故)" "$?"

echo "=== ③ ②这一跑里不许空等 12 轮，也不许打出那句假红文案 ==="
chk "③sleep 次数＝$NS(只该有 force-stop 那 1 次)" "$([ "$NS" = 1 ] && echo 0 || echo 1)"
if grep -qa '别看旧内容下结论' "$W/out_no_out"; then chk "③没出现'别看旧内容下结论'那条假红" 1; else chk "③没出现假红文案" 0; fi

echo "=== ④ 反夹具：把'有生产者'的读数也改成 0 ⇒ 同一件腿必须翻成 rc=7(证明①不是永绿) ==="
FIX_PROD=0 FIX_DONE=1 run_rleg with_out_flipped
chk "④rc 从 0 翻成 7(实得 $RC)" "$([ "$RC" = 7 ] && echo 0 || echo 1)"

echo "=== ⑤ 有生产者却等满＝真失败(rc=8＋那句假红这时才许出现)；而读到 DONE 时 rc 绝不许非零(方向性) ==="
FIX_PROD=1 FIX_DONE=0 run_rleg no_done
chk "⑤rc=8(实得 $RC)" "$([ "$RC" = 8 ] && echo 0 || echo 1)"
grep -qa '别看旧内容下结论' "$W/out_no_done"; chk "⑤假红文案这时才出现(＝它只该在真失败时出现)" "$?"
chk "⑤等待循环满 12 轮(数 sleep＝$NS，应=13)" "$([ "$NS" = 13 ] && echo 0 || echo 1)"
FIX_PROD=1 FIX_DONE=1 run_rleg again_with_out
chk "⑤方向性反夹具：读到 DONE 时 rc 必须=0(旧版返 1、等满反而返 0＝方向反了；实得 $RC)" "$([ "$RC" = 0 ] && echo 0 || echo 1)"

echo "=== ⑥ 静态牙：出口码 7/8 与产物名变量都在**非注释行**里(不是只在注释中承诺) ==="
if grep -v '^[[:space:]]*#' kmod/w211_ui.sh | grep -qa 'exit 7'; then chk "⑥非注释行里有 exit 7" 0; else chk "⑥非注释行里有 exit 7" 1; fi
if grep -v '^[[:space:]]*#' kmod/w211_ui.sh | grep -qa 'exit 8'; then chk "⑥非注释行里有 exit 8" 0; else chk "⑥非注释行里有 exit 8" 1; fi
if grep -v '^[[:space:]]*#' kmod/w211_ui.sh | grep -qa 'OUTDEV=/data/local/tmp'; then chk "⑥设备侧产物名只算一次(变量，不是散落字符串)" 0; else chk "⑥产物名同源" 1; fi

echo "=== run_rleg 全绿：$N 项 PASS(条数由本脚本自己现数) ==="
[ "$fail" = 0 ] || { echo "有红项 ⇒ 整体非零"; exit 1; }
