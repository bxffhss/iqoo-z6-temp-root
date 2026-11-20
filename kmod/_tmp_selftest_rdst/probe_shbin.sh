#!/system/bin/sh
# probe_shbin.sh —— 在**设备上**(mksh)双向验收 shim v4 的 exec 目标解析(0 枪：不 insmod、不开窗)。
#   为什么必须在设备上跑：被测对象是 aarch64 静态二进制，离线切片测不到"它到底能不能加载、
#   解析出来是哪个串"。这一支拿的是**仪器级**回执(目标解析)，不是 #117 那一格的结论。
#   ★每格都要"我现算的期望串"去 grep 整行，不去解析它打印的文案取数。
#   用法：adb push 本件与 cm57/sustatic_v4 到 /data/local/tmp，然后 sh /data/local/tmp/probe_shbin.sh
BIN=${BIN:-/data/local/tmp/sustatic_v4}
SW=/data/local/tmp/ksu_shbin
DEF=/system/bin/sh
ALT1=/data/data/com.termux/files/usr/bin/bash
ALT2=/data/local/tmp/zz_other
n=0; bad=0
chk() {
    n=$((n+1))
    if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; bad=$((bad+1)); fi
}
runit() { # 跑一次，stderr 落到 $TMP；另跑一次不解析的分支当"这支能加载"的证人
    "$BIN" --suw-dump >"$TMP0" 2>&1
    # v6(#210)：shbin 那行诊断默认**不打**(真 su 不往 stderr 吐常规信息)，仪器要它就明说
    if [ -n "$1" ]; then SU_SHBIN="$1" SUW_SHBIN_WITNESS=1 "$BIN" -c id >/dev/null 2>"$TMP"; else SUW_SHBIN_WITNESS=1 "$BIN" -c id >/dev/null 2>"$TMP"; fi
}
[ -x "$BIN" ] || { echo "[x] 设备上没有可执行的 $BIN"; exit 1; }

echo "=== 格子 1：两个开关都不给 ⇒ 目标逐字＝$DEF 且来源=默认"
rm -f "$SW"; TMP=/data/local/tmp/probe1.txt; TMP0=/data/local/tmp/probe0.txt; runit ""
cat "$TMP0"
chk "①加载证人：--suw-dump 那行真打出来了(这支在设备上跑得起来，不是 CANNOT LINK)" "$(grep -qa 'su(suw) uid=' "$TMP0" && echo 1 || echo 0)"
cat "$TMP"
chk "①无开关：shbin=[$DEF] 来源=默认" "$(grep -qa "shbin=\[$DEF\] 来源=默认" "$TMP" && echo 1 || echo 0)"

echo "=== 格子 2：设备侧开关文件 ⇒ 覆盖成传入串"
printf '%s\n' "$ALT1" > "$SW"; TMP=/data/local/tmp/probe2.txt; runit ""
cat "$TMP"
chk "②铺了文件：shbin=[$ALT1] 且来源写着那个文件" "$(grep -qa "shbin=\[$ALT1\]" "$TMP" && echo 1 || echo 0)"

echo "=== 格子 3：只有 env ⇒ 覆盖"
rm -f "$SW"; TMP=/data/local/tmp/probe3.txt; runit "$ALT2"
cat "$TMP"
chk "③只有 env：shbin=[$ALT2] 来源=env SU_SHBIN" "$(grep -qa "shbin=\[$ALT2\] 来源=env SU_SHBIN" "$TMP" && echo 1 || echo 0)"

echo "=== 格子 4：env 与文件同时给 ⇒ env 赢(优先级有定稿)"
printf '%s\n' "$ALT1" > "$SW"; TMP=/data/local/tmp/probe4.txt; runit "$ALT2"
cat "$TMP"
chk "④两个都给：shbin=[$ALT2](env 赢)" "$(grep -qa "shbin=\[$ALT2\] 来源=env" "$TMP" && echo 1 || echo 0)"

echo "=== 格子 5：开关里是带空格的串 ⇒ 必须明说被拒并退回默认"
printf '%s\n' "/bin/sh id" > "$SW"; TMP=/data/local/tmp/probe5.txt; runit ""
cat "$TMP"
chk "⑤非法开关：打出『不合格…退回默认 /system/bin/sh』" "$(grep -qa '不合格' "$TMP" && echo 1 || echo 0)"
chk "⑤非法开关：最终 shbin=[$DEF] 来源=退回默认(开关被拒)" "$(grep -qa "shbin=\[$DEF\] 来源=退回默认" "$TMP" && echo 1 || echo 0)"

echo "=== 格子 6：开关文件存在但 0 字节 ⇒ 不许让来源写着文件而目标是默认"
: > "$SW"; TMP=/data/local/tmp/probe6.txt; runit ""
cat "$TMP"
chk "⑥空开关：shbin=[$DEF]" "$(grep -qa "shbin=\[$DEF\]" "$TMP" && echo 1 || echo 0)"
chk "⑥空开关：来源=开关为空⇒退回默认" "$(grep -qa '来源=开关为空' "$TMP" && echo 1 || echo 0)"

rm -f "$SW" /data/local/tmp/probe*.txt
echo
if [ "$bad" = 0 ]; then echo "=== probe_shbin PASS(共 $n 项，条数由 chk 自数；设备侧残留已清) ==="; else echo "=== probe_shbin FAIL($n 项里 $bad 项红) ==="; fi
[ "$bad" = 0 ]
