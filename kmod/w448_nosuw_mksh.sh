#!/bin/bash
# w448_nosuw_mksh.sh —— 把 ksu_one_stage.sh 里那块 **NOSUW 开关块**原样切片，推到设备上用**设备 mksh**跑 6 种形状。
#   为什么要有这条腿(§6.365)：DELIVERY/台账里那句"设备 mksh 跑同一切片读数一致"以前**没有生产者**
#   (例 116 同族——写在文档里的动作没人实现)；而新契约用的是 `[!a-z0-9._-]` 这种括号取反 + `wc -w`，
#   正是 mksh/dash 最容易和 PC 的 sh 跑出两种结果的地方。这一条不是开枪，不占窗口。
#   判据＝6 形状的 NOSUW/ENT_UID/ENT_KEY 三元组逐个对表(期望值写死在下面，红绿由现读数比出来)。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
fail=0; nchk=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

W=/data/local/tmp/w448_mksh
LW=kmod/_tmp_w448
mkdir -p "$LW" || exit 1
adb shell "mkdir -p $W" >/dev/null 2>&1

# 1) 切片(锚点唯一：起点是那行 ★★ 注释，终点是 T0= 那行之前)
awk '/^# ★★§6\.361\/#145 的仪器开关/{f=1} /^T0=\$\(date/{f=0} f' kmod/ksu_one_stage.sh > "$LW/block.sh"
[ -s "$LW/block.sh" ] || { echo "[x] 没切出开关块 ⇒ 起点锚失效(别当成\"形状没问题\")"; exit 1; }
NBLK=$(grep -ac . "$LW/block.sh")
chk "①切片非空(行数=$NBLK，含 ENT_UID/ENT_KEY/NOSUW 三件)" "$(grep -aq 'ENT_UID' "$LW/block.sh" && grep -aq 'ksu_nosuw' "$LW/block.sh" && [ "$NBLK" -ge 10 ] && echo 1 || echo 0)"

# 2) 包一层可跑的夹具(SUWID/APKEY 照 stage 口径先 seed，否则"空结果"会被读成"形状不对"＝夹具没喂料)
{
    echo 'log() { echo "$*"; }'
    echo 'SUWID=10342'
    echo 'APKEY=com.suw.manager'
    sed "s|/data/local/tmp/ksu_nosuw|$W/switch_file|g" "$LW/block.sh"
    echo 'echo "RESULT NOSUW=$NOSUW ENT_UID=$ENT_UID ENT_KEY=$ENT_KEY"'
} > "$LW/run.sh"
bash -n "$LW/run.sh" || { echo "[x] 夹具本身语法不过 ⇒ 后面全不算测到"; exit 1; }
adb push "$LW/run.sh" "$W/run.sh" >/dev/null 2>&1
LM=$(md5sum "$LW/run.sh" | cut -c1-32); RM=$(A "md5sum $W/run.sh" | cut -c1-32)
LB=$(wc -c < "$LW/run.sh" | tr -dc '0-9'); RB=$(A "wc -c < $W/run.sh" | tr -dc '0-9')
chk "②设备上那份就是本机这份(两端 md5＋字节一致；本机=$LM 设备=$RM)" "$([ "$LM" = "$RM" ] && [ -n "$RB" ] && [ "$LB" = "$RB" ] && echo 1 || echo 0)"
A "chmod 755 $W/run.sh; sh -n $W/run.sh && echo MKSH_SYNTAX_OK || echo MKSH_SYNTAX_BAD" | sed 's/^/  设备 mksh 语法复证：/'
chk "③设备 mksh 认这块语法(那句 OK 必须真出现)" "$([ "$(A "sh -n $W/run.sh >/dev/null 2>&1; echo rc=\$?")" = "rc=0" ] && echo 1 || echo 0)"

# 3) 六形状逐个跑(期望值＝§87 预登记的契约)
run_case() { # $1=标签 $2=开关文件准备命令 $3=期望 RESULT 行
    A "$2" >/dev/null 2>&1
    got=$(A "sh $W/run.sh 2>&1 | grep -a '^RESULT' | head -1")
    if [ "$got" = "$3" ]; then chk "$1 ⇒ $got" 1; else chk "$1 ⇒ 实得[$got] 期望[$3]" 0; fi
}
run_case "④不给开关(交付形状逐字不变)" "rm -f $W/switch_file" "RESULT NOSUW=0 ENT_UID=10342 ENT_KEY=com.suw.manager"
run_case "⑤新契约正例(目标 app)"       "printf '%s\n' '10667 com.termux' > $W/switch_file" "RESULT NOSUW=1 ENT_UID=10667 ENT_KEY=com.termux"
run_case "⑥旧空文件(touch 形状)必须弃权" ": > $W/switch_file" "RESULT NOSUW=0 ENT_UID=10342 ENT_KEY=com.suw.manager"
run_case "⑦uid 段非纯数字要拦"          "printf '%s\n' 'abc com.termux' > $W/switch_file" "RESULT NOSUW=0 ENT_UID=10342 ENT_KEY=com.suw.manager"
run_case "⑧只有一段(词数≠2)要拦"        "printf '%s\n' '10667' > $W/switch_file" "RESULT NOSUW=0 ENT_UID=10342 ENT_KEY=com.suw.manager"
run_case "⑨包名带非法字符要拦"          "printf '%s\n' '10667 Com.Termux!' > $W/switch_file" "RESULT NOSUW=0 ENT_UID=10342 ENT_KEY=com.suw.manager"
#   ★⑩弃权那几格必须**当场打 [!]**：只改数不吭声＝下一发说不清是哪一半没落地
A "printf '%s\n' '10667' > $W/switch_file; sh $W/run.sh 2>&1" | grep -aq '不改形状' \
    && chk "⑩弃权那格当场打了 [!] 那句" 1 || chk "⑩弃权那格没打 [!](静默弃权＝最坏那种)" 0
#   ★⑪反夹具(证明这条腿真的有牙，而不是恒绿)：**换一个没写死的 uid/包名**喂进去 ⇒ 必须照新值生效。
#     如果代码把 10667/com.termux 写死在别处，这一格就会红(它测的是"块真的在读开关文件"这件事)。
got11=$(A "printf '%s\n' '19999 com.qoder.probe' > $W/switch_file; sh $W/run.sh 2>&1 | grep -a '^RESULT' | head -1")
chk "⑪反夹具有效：换个 uid/包名照样照新值生效(证明它读的是开关文件，不是写死的)［实得 $got11］" \
    "$([ "$got11" = "RESULT NOSUW=1 ENT_UID=19999 ENT_KEY=com.qoder.probe" ] && echo 1 || echo 0)"

echo "  设备侧读回原件：$(A "ls -l $W/run.sh | tr -s ' '")"
[ "$fail" = 0 ] && echo "=== w448 设备 mksh 切片 PASS($nchk 项，条数由 chk 自数) ===" || echo "=== w448 FAIL($nchk 项里有红) ==="
adb shell "rm -rf $W" >/dev/null 2>&1
rm -f "$LW/block.sh" "$LW/run.sh"
[ "$fail" = 0 ]
