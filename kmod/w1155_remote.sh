#!/bin/bash
# w1155_remote.sh —— 构建机侧(0 枪)：把 SET_SEPOLICY 的**记录层**在 x86 宿主上编出来、跑自测，
#   再用四条变异证明这把尺有牙。件不解析策略、不引内核符号，纯 C。
# 输入(全部由本地包装 put 上来，名字固定)：
#   w1155_record.h w1151_core.h w1155_main.c w1155_fix.tar(11 件夹具＋expect.txt) w1153_leg_shot97.out
set -u
cd /home/lucy || exit 1
for f in w1155_record.h w1151_core.h w1155_main.c w1155_fix.tar w1153_leg_shot97.out; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
for f in w1155_record.h w1151_core.h w1155_main.c w1155_fix.tar w1153_leg_shot97.out; do
  echo "MD5_$f=$(md5sum "$f" | cut -d' ' -f1)"
done
echo "MAIN_BYTES=$(wc -c <w1155_main.c | tr -dc '0-9')"

# 头文件名必须是被 #include 的那个名字 ⇒ 铺一个 include 目录
rm -rf w1155d && mkdir -p w1155d/fixtures
cp w1151_core.h w1155d/w1151_sepolicy_core.h
cp w1155_record.h w1155d/w1155_sepol_record.h
tar -xf w1155_fix.tar -C w1155d/fixtures || { echo "!! 夹具解不开"; exit 1; }
echo "FIXTURES_BINS=$(ls w1155d/fixtures/*.bin 2>/dev/null | wc -l | tr -dc '0-9')"
echo "TBL_LINES=$(grep -vc '^#' w1155d/fixtures/expect.txt)"
echo "LEG_CASES=$(grep -ac '^CASE ' w1153_leg_shot97.out)"
grep -a '^CASE ' w1153_leg_shot97.out | sed 's/.* rec_stmts=\([0-9]*\).*/STMTWANT \1/' | sort | uniq -c | sed 's/^/  /'

CFLAGS="-std=gnu11 -O2 -Wall -Wextra -Werror -Iw1155d"
gcc $CFLAGS -o w1155_st w1155_main.c 2>w1155_err.txt; RC=$?
echo "HOST_MAKE_RC=$RC"
echo "DIAG_ERR=$(grep -c '[Ee]rror:' w1155_err.txt) DIAG_WARN=$(grep -c 'warning:' w1155_err.txt)"
[ "$RC" = 0 ] || { sed 's/^/  cc: /' w1155_err.txt | head -25; echo "!! 宿主编译没过 ⇒ 停"; exit 1; }
head -3 w1155_err.txt | sed 's/^/  cc-note: /'

./w1155_st w1155d/fixtures w1155d/fixtures/expect.txt w1153_leg_shot97.out > w1155_run.txt; RUN=$?
echo "RUN_RC=$RUN"
grep -acE '^\[OK\]' w1155_run.txt | sed 's/^/OK_LINES=/'
grep -aE '^\[BAD\]' w1155_run.txt | head -12 | sed 's/^/  /'
grep -aE '^SUM |^VERDICT=' w1155_run.txt | sed 's/^/  /'
[ "$RUN" = 0 ] || { echo "!! 正跑没绿 ⇒ 记录层本身就不对，后面的变异不用看"; exit 1; }

# ===== 四条变异：每次只把记录层的一把尺拆掉，改完必须**被对应的 CASE 抓到** =====
# ★尺的次序按代码实际走：C4/C8(拒收件行数) → C3(rc 表) → C7(applied) → C6(参数转写)
cp w1155d/w1155_sepol_record.h w1155_base.h
mut() { # <名字> <sed 程序> <期望红在哪一行前缀>
  local tag="$1" prog="$2" want="$3"
  cp w1155_base.h w1155d/w1155_sepol_record.h
  sed -i "$prog" w1155d/w1155_sepol_record.h
  cmp -s w1155_base.h w1155d/w1155_sepol_record.h && { echo "MUT_$tag=NO_OP(sed 没改动任何字节 ⇒ 这条变异是空枪)"; return 1; }
  gcc $CFLAGS -o w1155_m w1155_main.c 2>/dev/null || { echo "MUT_$tag=BUILD_FAIL(也算抓到，但要看是不是编不出来才红)"; return 0; }
  ./w1155_m w1155d/fixtures w1155d/fixtures/expect.txt w1153_leg_shot97.out > w1155_m.txt 2>&1
  local r=$?
  if [ "$r" != 0 ] && grep -qF "$want" w1155_m.txt; then
    echo "MUT_$tag=CAUGHT rc=$r 首红=[$(grep -am1 -F "$want" w1155_m.txt | cut -c1-70)]"
    return 0
  fi
  echo "MUT_$tag=MISSED rc=$r (期望非 0 且出现 [$want]) ⇒ 那把尺没牙"
  return 1
}
BAD=0
mut whygate 's/if (rep->why == W1151_OK) {/if (1) {/'      "拒收件却印了" || BAD=1
mut rctable 's/return W1155_RC_E2BIG;/return W1155_RC_EINVAL;/' "C3 why=11" || BAD=1
mut applied 's/applied=0 rc=%u/applied=9 rc=%u/'           "没有 applied=0" || BAD=1
mut argmax  's/#define W1155_ARGTXT_MAX 64u/#define W1155_ARGTXT_MAX 256u/' "C6 转写不等于手抄件" || BAD=1
cp w1155_base.h w1155d/w1155_sepol_record.h
gcc $CFLAGS -o w1155_b w1155_main.c 2>/dev/null && ./w1155_b w1155d/fixtures w1155d/fixtures/expect.txt w1153_leg_shot97.out >/dev/null 2>&1
REVERT_RC=$?
# ★上一版这里直接写 `echo "REVERT_RC=$?"` 就往下走，而 `set -u` 下后面 `[ "$REVERT_RC" = 0 ]`
#   立刻炸成 unbound variable ⇒ 远端在总判据前一行就死了(证件上没有 VERDICT 行，只有 stderr)。
#   取到的 $? 要**落到有名有姓的变量里**再往下传，别指望 $? 还活着。
echo "REVERT_RC=$REVERT_RC (必须 0 ⇒ 四条变异只是把件拆开看过，没留在件里)"
if [ "$BAD" = 0 ] && [ "$RUN" = 0 ] && [ "$REVERT_RC" = 0 ]; then
  echo "VERDICT=ok 记录层：宿主正跑绿＋四条变异全被抓＋还原后仍绿"
else
  echo "VERDICT=bad 变异没全被抓(BAD=$BAD) 或正跑/还原没绿(RUN=$RUN REVERT=$REVERT_RC)"
fi
exit 0
