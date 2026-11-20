#!/usr/bin/env bash
# run_shbin.sh —— #117 第二把生产者的离线双向自测：`kmod/go.sh` 的 §1.69(SHBIN 开关＋选哪支二进制)
#   与第 5 步"推上去的那支必须两端 md5 一致"那道硬闸。
#   ★被测的是**切片**：两段都从出货的 go.sh 按"两头有牙"的锚切；锚漂了就 exit 1，不许静默空跑(例 127)。
#   ★v4 那支二进制自己的目标解析(env/文件/退回默认/被拒)在**设备上**才有意义 ⇒ 那半边由
#     kmod/_tmp_selftest_rdst/probe_shbin.sh 拿真机九格(一手：kmod/w103_evidence/w424_probe_shbin.txt)。
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
W=$(mktemp -d); DEV=$W/dev; mkdir -p "$DEV" "$W/cm57"
SW=$DEV/ksu_shbin
nchk=0; fail=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

# ---------- 切片 1：§1.69 那段 ----------
awk 'index($0,"=== 1.69)"){f=1} index($0,"=== 1.7)"){f=0} f' kmod/go.sh > "$W/switch.sh"
grep -qF '=== 1.69)' "$W/switch.sh" || { echo "[x] 没切到 1.69(起点锚失效)"; exit 1; }
grep -qF '官方 Manager 要能用' "$W/switch.sh" && { echo "[x] 把 1.7 段也吞进来了(终点锚失效)"; exit 1; }
grep -qF 'SHIM_SRC=cm57/sustatic_v4' "$W/switch.sh" || { echo "[x] 切片里没有「换二进制」那半 ⇒ 只测了一半"; exit 1; }
grep -qF 'rm -f /data/local/tmp/ksu_shbin' "$W/switch.sh" || { echo "[x] 切片里没有「不给时清开关」那半"; exit 1; }
sed "s|/data/local/tmp|$DEV|g" "$W/switch.sh" > "$W/switch_run.sh"
[ "$(grep -c '/data/local/tmp' "$W/switch_run.sh")" = 0 ] || { echo "[x] 设备路径没替换干净 ⇒ 格子会写真设备路径"; exit 1; }

# ---------- 切片 2：第 5 步那半道两端 md5 硬闸 ----------
#   ★终点锚从 `adb push kmod/w135_fix.sh` 改成 §1.69b 之后的**分支起点**(#145 把派发放进了 else 支)：
#     旧终点在新形状下会一路吃进 if/else 主体，把 WAITFOR 也算进"md5 闸"这一块 ⇒ 这条守卫本来就该红。
awk 'index($0,"=== 5) bind su"){f=1} index($0,"if [ \"${NOSUW_ON:-0}\" = 1 ]"){f=0} f' kmod/go.sh > "$W/step5.sh"
grep -qF '=== 5) bind su' "$W/step5.sh" || { echo "[x] 没切到第 5 步(起点锚失效)"; exit 1; }
#   ★守卫要看**下游那条腿**在不在，不能看 `w135_fix.sh` 这个字符串——chmod 那一行本来就该含它(第一版就在这红的)。
grep -qF 'WAITFOR' "$W/step5.sh" && { echo "[x] 终点锚没生效，把等 DONE 那条腿也吞进来了"; exit 1; }
grep -qF 'fire "@sushd:' "$W/step5.sh" && { echo "[x] 终点锚没生效，把派单腿也吞进来了"; exit 1; }
grep -qF '[ "$LS" = "$RS" ]' "$W/step5.sh" || { echo "[x] 切片里没有那道两端 md5 硬闸"; exit 1; }
echo "切片行数：switch=$(wc -l < "$W/switch.sh")  step5=$(wc -l < "$W/step5.sh")"

run_switch() { # $1=tag $2=SHBIN 的值(空=不给) $3=本机 v4 在不在(1/0) $4=事先铺的残留内容(空=不铺)
    rm -f "$SW" "$W/cm57/sustatic_v4"
    [ "${3:-1}" = 1 ] && : > "$W/cm57/sustatic_v4"
    [ -n "${4:-}" ] && printf '%s' "$4" > "$SW"
    ( cd "$W" || exit 1
      A() { eval "${1//\/data\/local\/tmp/$DEV}"; }
      if [ -n "${2:-}" ]; then export SHBIN="$2"; else unset SHBIN; fi
      . "$W/switch_run.sh"
      echo "DERIVED_SHIM_SRC=[$SHIM_SRC]"
    ) > "$W/out_$1.txt" 2>&1
    echo $?
}
echo "=== 一) §1.69：铺／校验／不给时的清理／v4 缺件 ==="
OK=/data/data/com.termux/files/usr/bin/bash
RC=$(run_switch s_ok "$OK" 1)
chk "①合法 SHBIN：rc 要 0(实得 $RC)" "$([ "$RC" = 0 ] && echo 1 || echo 0)"
chk "①合法 SHBIN：开关文件真被铺上且逐字等于输入(第一遍真的改了，例 88)" "$([ -f "$SW" ] && [ "$(cat "$SW" 2>/dev/null)" = "$OK" ] && echo 1 || echo 0)"
chk "①合法 SHBIN：读回那行的值＝我算的输入" "$(grep -qF "开关内容读回=[$OK]" "$W/out_s_ok.txt" && echo 1 || echo 0)"
chk "①合法 SHBIN：这一段不许冒出工具自己的报错(第 26 发一手：SHBIN 的值本身就是绝对路径，旧写法把它塞进 sed 的 `s///` 分隔符位 ⇒ `sed: -e expression #1: unknown option to s`)" "$(! grep -aqE "sed: |grep: |awk: |bash: " "$W/out_s_ok.txt" && echo 1 || echo 0)"
chk "①合法 SHBIN：第 5 步的来源被切到 v4(现算期望串去 grep 整行)" "$(grep -qaxF 'DERIVED_SHIM_SRC=[cm57/sustatic_v4]' "$W/out_s_ok.txt" && echo 1 || echo 0)"
RC=$(run_switch s_off '' 1 "$OK")
chk "②不给 SHBIN：rc 要 0(实得 $RC)" "$([ "$RC" = 0 ] && echo 1 || echo 0)"
chk "②不给 SHBIN：上一发残留的开关必须被删掉且有复证行" "$([ ! -e "$SW" ] && grep -qF 'No such file' "$W/out_s_off.txt" && echo 1 || echo 0)"
chk "②不给 SHBIN：来源仍是交付槽 v3，且明打交付形状" "$(grep -qaxF 'DERIVED_SHIM_SRC=[cm57/sustatic]' "$W/out_s_off.txt" && grep -qF '交付形状(shim' "$W/out_s_off.txt" && echo 1 || echo 0)"
rm -f "$SW"
RC=$(run_switch s_inj '/bin/sh; rm -rf /' 1)
chk "③含空格与分号：必须 rc=3(实得 $RC)" "$([ "$RC" = 3 ] && echo 1 || echo 0)"
chk "③含空格与分号：一条都不许铺" "$([ ! -e "$SW" ] && echo 1 || echo 0)"
chk "③含空格与分号：打的是『含非法字符』那条支" "$(grep -qF '含非法字符' "$W/out_s_inj.txt" && echo 1 || echo 0)"
RC=$(run_switch s_rel 'system/bin/sh' 1)
chk "④不是绝对路径：rc=3 且明说(实得 $RC)" "$([ "$RC" = 3 ] && grep -qF '不是绝对路径' "$W/out_s_rel.txt" && echo 1 || echo 0)"
LONG=$(printf '/%s' "$(printf 'a%.0s' $(seq 1 130))")
RC=$(run_switch s_long "$LONG" 1)
chk "⑤超长(>120)：rc=3(实得 $RC 长度=${#LONG})" "$([ "$RC" = 3 ] && grep -qF 'SHBIN 长度' "$W/out_s_long.txt" && echo 1 || echo 0)"
RC=$(run_switch s_nov4 "$OK" 0)
chk "⑥要给 SHBIN 但本机没有 v4：rc=3 且指去跑构建脚本(实得 $RC)" "$([ "$RC" = 3 ] && grep -qF 'build_sustatic.sh' "$W/out_s_nov4.txt" && echo 1 || echo 0)"
chk "⑥本机没有 v4 时也不许铺开关(校验顺序：先查件再铺)" "$([ ! -e "$SW" ] && echo 1 || echo 0)"

echo "=== 二) 第 5 步：两端 md5 那道闸(不一致就别往下推) ==="
: > "$W/binfile"; printf 'fake-shim-bytes' > "$W/binfile"
run_step5() { # $1=tag $2=设备侧 md5 桩返回的串(与本机一致／不一致)
    ( cd "$ROOT" || exit 1
      DEVH="$2"
      adb() { :; }
      A() { echo "$DEVH  /data/local/tmp/sustatic"; }
      SHIM_SRC=$W/binfile
      . "$W/step5.sh"
    ) > "$W/out_$1.txt" 2>&1
    echo $?
}
REAL=$(md5sum "$W/binfile" | cut -c1-32)
RC=$(run_step5 g_ok "$REAL")
chk "⑦两端一致：rc 要 0(实得 $RC)" "$([ "$RC" = 0 ] && echo 1 || echo 0)"
chk "⑦两端一致：把来源与两个 md5 都打进转录(现算值去 grep)" "$(grep -qF "本机 md5=$REAL 设备 md5=$REAL" "$W/out_g_ok.txt" && echo 1 || echo 0)"
RC=$(run_step5 g_bad '00000000000000000000000000000000')
chk "⑧设备侧不是本机这支：必须 rc=3(实得 $RC)" "$([ "$RC" = 3 ] && echo 1 || echo 0)"
chk "⑧判红那句要点名『不是本机』" "$(grep -qF '不是本机' "$W/out_g_bad.txt" && echo 1 || echo 0)"

rm -rf "$W"
echo
[ "$fail" = 0 ] && echo "=== run_shbin 自测 PASS(共 $nchk 项断言，条数由 chk 自数) ===" || echo "=== FAIL($nchk 项里有红) ==="
[ "$fail" = 0 ]
