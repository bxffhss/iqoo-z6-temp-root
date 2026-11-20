#!/usr/bin/env bash
# run_fdkeepalive.sh —— stage 里 §FDKA"常驻补装驱动 fd"那段循环的专属双向自测(0 枪、全程桩，绝不碰设备)。
#   ★三条设计决定(都是刚才踩出来的)：
#   ①自测**从 stage 抽字节**跑，不抄第二份实现(抄的两份会分叉，例 120/153)；用的 sed 与 stage 运行期
#     生成 helper 时是**同一条**(带 `BE[GIN]`/`EN[D]` 转义，否则模式自我匹配会一路吞到文件末尾)。
#   ②循环一律**前台跑**，靠它自己的两个出口(删开关⇒退 0 / 连续失败到上限⇒退 3)结束 ⇒
#     没有后台残留、不会跨格共写同一份日志(上一版用 `&` 起循环，后面的读数被上一格污染)。
#   ③节拍=桩 sleep，每迭代恰好推一个 tick ⇒ "装了几次/跑到第几轮"可以精确断言，不靠真睡觉碰运气。
set -u
cd "$(dirname "$0")/../.." || exit 1
W=kmod/_tmp_selftest_rdst/.fdk_work
STAGE=kmod/ksu_one_stage.sh
REAL_SLEEP="$(command -v sleep)"
rm -rf "$W"; mkdir -p "$W/bin" "$W/fx"
export W REAL_SLEEP
N=0; RN=0; fail=0
chk() { N=$((N+1)); if [ "$2" = 0 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

cat > "$W/bin/pidof" <<'P'
#!/bin/sh
case "$1" in
  zygote64)            [ -s "$W/fx/fz" ] && cat "$W/fx/fz" ;;
  me.weishu.kernelsu)  [ -s "$W/fx/fm" ] && cat "$W/fx/fm" ;;
esac
exit 0
P
cat > "$W/bin/sleep" <<'S'
#!/bin/sh
T=$(cat "$W/fx/tick" 2>/dev/null || echo 0); T=$((T + 1)); echo "$T" > "$W/fx/tick"
[ -f "$W/fx/case_$T" ] && . "$W/fx/case_$T"
"$REAL_SLEEP" 0.02
exit 0
S
chmod 755 "$W/bin/pidof" "$W/bin/sleep" 2>/dev/null

sed -n '/# FDKA-BE[GIN]/,/# FDKA-EN[D]/p' "$STAGE" > "$W/loop.sh"   # ← 与 stage 同一条(转义防自我匹配)
BYTES=$(wc -c < "$W/loop.sh" | tr -dc '0-9')
echo "=== 抽取：$W/loop.sh 字节=$BYTES ==="
{ [ "${BYTES:-0}" -gt 600 ] && [ "${BYTES:-0}" -lt 4000 ]; } 2>/dev/null; rc=$?
chk "抽到的字节数在 600..4000(＝只有函数本体，没把 if 块/整个文件吞进来；实得 $BYTES)" $rc
grep -c '# FDKA-BEGIN' "$STAGE" | grep -qx 1; chk "静态牙：FDKA-BEGIN 标记恰好 1 个" $?
grep -c '# FDKA-END'   "$STAGE" | grep -qx 1; chk "静态牙：FDKA-END 标记恰好 1 个" $?
grep -aq 'if \[ -e /data/local/tmp/ksu_fd_keepalive \]' "$STAGE"; chk "静态牙：整块在默认关的开关分支后面(交付形状一字不动)" $?
grep -aq 'FDKA-BE.GIN.*FDKA-EN.D./p' "$STAGE"; chk "静态牙：stage 确实用同一条(转义过的) sed 自我抽取" $?
grep -aq '种进 zygote64' "$STAGE"; chk "静态牙：stage 在起循环前先把 fd 种进 zygote64(不留 5 秒空窗)" $?
grep -aq "sh -c '. /data/local/tmp/ksu_one_stage.sh" "$STAGE"; rc=$?
[ "$rc" != 0 ] && r=0 || r=1; chk "反夹具(致命)：stage 里不许出现自我 source 整条 stage＝会重放 insmod/漏洞" $r

reset_fx() { rm -f "$W/fx/fz" "$W/fx/fm" "$W/fx/tick" "$W/fx/case_"* "$W/trig" "$W/log" "$W/sw" 2>/dev/null; rm -rf "$W/proc"; mkdir -p "$W/proc"; echo 0 > "$W/fx/tick"; }
#   ★给夹具造 /proc/<pid>/stat(字段 4=ppid；comm 写成 (main) 与真机 zygote 一致)，这样"挑 ppid=1 那个"这条判据能被真跑
mkstat() { mkdir -p "$W/proc/$1"; printf '%s (main) S %s %s %s\n' "$1" "$2" "$1" "$1" > "$W/proc/$1/stat"; }
TICK() { cat "$W/fx/tick" 2>/dev/null || echo 0; }
run_case() {   # $1=开关 $2=触发口 $3=FAIL_MAX —— 前台跑，返回循环自己的退出码
    RN=$((RN + 1)); RF="$W/run_$RN.sh"
    { cat "$W/loop.sh"
      printf '%s\n' "fd_keepalive_loop \"$1\" \"$2\" zygote64 me.weishu.kernelsu 1 \"$3\" \"$W/log\" \"$W/proc\"" 'exit $?'
    } > "$RF"
    PATH="$W/bin:$PATH" sh "$RF"; }

echo "=== ① 开关不存在 ⇒ 第一轮就自退(退 0)，触发口一个字节都不许有＝默认形状没被动过 ==="
reset_fx; echo 100 > "$W/fx/fz"
run_case "$W/no_such_sw" "$W/trig" 3; rc=$?
[ "$rc" = 0 ] && r=0 || r=1; chk "①循环返回 0(是它自己判开关退的，不是崩；实得 rc=$rc)" $r
[ ! -e "$W/trig" ] && r=0 || r=1; chk "①触发口没被创建(实得 $(wc -c < $W/trig 2>/dev/null | tr -dc '0-9') 字节)" $r
grep -aq 'STOP 开关没了' "$W/log"; chk "①日志明写 STOP 原因" $?

echo "=== ② 开关在但一个 pid 都读不到 ⇒ 一轮里不许写触发口(读不到≠乱写) ==="
reset_fx; : > "$W/sw"
echo 'rm -f "$W/sw"' > "$W/fx/case_1"
run_case "$W/sw" "$W/trig" 3; rc=$?
[ "$rc" = 0 ] && r=0 || r=1; chk "②退 0(走删开关这个出口，不是失败上限；实得 $rc)" $r
[ ! -e "$W/trig" ] && r=0 || r=1; chk "②触发口仍未被创建(实得 [$(cat $W/trig 2>/dev/null)])" $r

echo "=== ③④⑤⑥ 确定性剧本：装 100/300 → 不重复刷 → 换 pid 重装 → 删开关自停 ==="
reset_fx; : > "$W/sw"       # ★先 reset 再铺 case：reset 会 rm case_*，写在前头等于没写
echo 'echo 100 > "$W/fx/fz"; echo 300 > "$W/fx/fm"' > "$W/fx/case_1"
echo 'echo 200 > "$W/fx/fz"' > "$W/fx/case_2"
echo 'echo 400 > "$W/fx/fm"' > "$W/fx/case_3"
echo 'rm -f "$W/sw"' > "$W/fx/case_4"
run_case "$W/sw" "$W/trig" 9; rc=$?
[ "$rc" = 0 ] && r=0 || r=1; chk "③整局按 kill switch 收(退 0；实得 $rc)" $r
grep -aq 'INST Z pid=100' "$W/log"; chk "③zygote=100 装上(这才是\"之后每个 app 出生就带着\"的那一步)" $?
grep -aq 'INST M pid=300' "$W/log"; chk "③Manager=300 也装上(两个宿主各记各的 last，互不顶掉)" $?
c=$(grep -ac 'FDKA INST' "$W/log" 2>/dev/null | tr -dc '0-9')
[ "${c:-0}" = 4 ] && r=0 || r=1; chk "④幂等：INST 恰好 4 次(100/300/200/400，不是每轮刷一次；实得 $c)" $r
t=$(tr -d '[:space:]' < "$W/trig" 2>/dev/null)
[ "$t" = 400 ] && r=0 || r=1; chk "④b 触发口是命令口(每写一次覆一次) ⇒ 最后一笔=最新 pid(实得 [$t])" $r
grep -aq 'INST Z pid=200' "$W/log"; chk "⑤pid 真变了必须重装 200(只认第一次＝假守护)" $?
grep -aq 'INST M pid=400' "$W/log"; chk "⑤Manager 换 pid(400)同样重装" $?
[ "$(TICK)" = 4 ] && r=0 || r=1; chk "⑥删开关后即停、没多跑：tick=$(TICK)(应恰好 4)" $r

echo "=== ⑦ 反夹具：触发口不可写 ⇒ 退 3 且明写 WRITEFAIL/GIVEUP(不能闷头装好在跑) ==="
reset_fx; : > "$W/sw"; echo 100 > "$W/fx/fz"; echo 300 > "$W/fx/fm"
run_case "$W/sw" "$W/nope/deep/trig" 3; rc=$?
[ "$rc" = 3 ] && r=0 || r=1; chk "⑦退出码必须是 3(GIVEUP 出口；实得 rc=$rc)" $r
grep -aq 'WRITEFAIL' "$W/log"; chk "⑦写不进时报 WRITEFAIL(带次数)" $?
grep -aq 'GIVEUP' "$W/log"; chk "⑦连续失败到上限 ⇒ 明写 GIVEUP 并退" $?

echo "=== ⑧ 反夹具的二分：同样写不进，但 FMAX=999 ⇒ 只能因删开关退 0、不许出现 GIVEUP ==="
reset_fx; : > "$W/sw"; echo 100 > "$W/fx/fz"; echo 300 > "$W/fx/fm"
echo 'rm -f "$W/sw"' > "$W/fx/case_2"
run_case "$W/sw" "$W/nope/deep/trig" 999; rc=$?
[ "$rc" = 0 ] && r=0 || r=1; chk "⑧退 0(实得 $rc) ⇒ 证明 ⑦ 那个 3 真的是失败上限给的" $r
if grep -aq 'GIVEUP' "$W/log"; then r=1; else r=0; fi; chk "⑧这一局没有 GIVEUP 行(两个出口分得清)" $r
grep -acq 'WRITEFAIL' "$W/log"; chk "⑧但 WRITEFAIL 有在记(失败不静默)" $?

echo "=== ⑨ 多候选时必须挑 ppid=1 那个(第 38 发真机一手：pidof zygote64 在这台机上不唯一，readdir 序把瞬时子进程排在前面) ==="
reset_fx; : > "$W/sw"
echo '20567 1028' > "$W/fx/fz"          # ← 顺序故意把错的放前面
mkstat 20567 1028                        # 瞬时子进程：父亲是 zygote
mkstat 1028 1                            # 真 zygote：父亲是 init
echo 'rm -f "$W/sw"' > "$W/fx/case_1"
run_case "$W/sw" "$W/trig" 3 >/dev/null 2>&1; rc=$?
grep -aq 'INST Z pid=1028' "$W/log"; chk "⑨装上的是 ppid=1 的 1028，不是排在前面那个 20567(实得 [$(grep -a 'INST Z' $W/log | head -1 | cut -c1-40)])" $?
[ "$(cat "$W/trig" 2>/dev/null)" = 1028 ] && r=0 || r=1; chk "⑨b 触发口最后一笔=1028(实得 [$(cat $W/trig 2>/dev/null)])" $r
if grep -aq 'ZG_FALLBACK' "$W/log"; then r=1; else r=0; fi; chk "⑨c 这一局不许打 FALLBACK(有一个 ppid=1 就该选它；实得 $(grep -ac ZG_FALLBACK $W/log 2>/dev/null | tr -dc '0-9') 行)" $r

echo "=== ⑩ 反夹具：一个 ppid=1 都没有 ⇒ 必须明打 FALLBACK(证明 ⑨ 真在比 ppid，不是空判据) ==="
reset_fx; : > "$W/sw"
echo '20567 1028' > "$W/fx/fz"
mkstat 20567 1028; mkstat 1028 1028      # 两个的父亲都不是 init
echo 'rm -f "$W/sw"' > "$W/fx/case_1"
run_case "$W/sw" "$W/trig" 3 >/dev/null 2>&1; rc=$?
grep -aq 'ZG_FALLBACK pid=20567 候选数=2' "$W/log"; chk "⑩打了 FALLBACK(带第一个候选与候选数；实得 [$(grep -a ZG_FALLBACK $W/log | head -1 | cut -c1-60)])" $?
[ "$rc" = 0 ] && r=0 || r=1; chk "⑩b 兜底之后仍按 kill switch 收(退 0；实得 $rc)" $r
grep -acq '^FDKA ZG_FALLBACK' "$W/log"; rc=$?
[ $(( $(grep -ac '^FDKA ZG_FALLBACK' "$W/log" | tr -dc '0-9') )) = 1 ] && r=0 || r=1
chk "⑩c FALLBACK 只打一次，不每轮刷日志(实得 $(grep -ac '^FDKA ZG_FALLBACK' "$W/log" | tr -dc '0-9') 行)" $r

echo "=== ⑪ 静态牙：当场那次种子也走同一把 pick_zygote；调用行带第 8 参数；pick 在循环外面 ==="
grep -aq 'ZP0=$(pick_zygote zygote64)' "$STAGE"; chk "⑪当场种 zygote 那行不再是 pidof 取第一个(同一颗雷不能只拆一半)" $?
grep -aq 'FDKA_PROC:-/proc}' "$STAGE"; chk "⑪b helper 的调用行传了第 8 个参数(自测才能把 /proc 指到夹具)" $?
grep -an 'pick_zygote()' "$STAGE" | head -1 | cut -d: -f1 | { read PL; grep -an 'fd_keepalive_loop()' "$STAGE" | head -1 | cut -d: -f1 | { read FL; [ "${PL:-0}" -lt "${FL:-0}" ] && exit 0 || exit 1; }; }
chk "⑪c pick_zygote 定义在 fd_keepalive_loop **外面**(函数体只在被调用时展开，里面定义＝当场那次用不到)" $?

echo "=== 全绿：$N 项 PASS(条数由本脚本自己现数) ==="
[ "$fail" = 0 ] || { echo "有红项 ⇒ 整体非零"; exit 1; }
