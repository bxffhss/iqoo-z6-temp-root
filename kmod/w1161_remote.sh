#!/bin/bash
# w1161_remote.sh —— 构建机侧(0 枪)：把 #238 部件③「装载门」的纯判定在 x86 宿主编出来、
#   拿**第 96 发那两张真设备策略图**跑自测，再用五条变异证明这把尺有牙。
# ★为什么证人用真图而不是我造的字节：这道门的四条数(长度/指纹)是那一发**设备自己印出来**的
#   (`pl_pre_len/pl_pre_sum/pl_post_len/pl_post_sum`)——只有它们能回答"我这把尺量的还是那张图吗"。
# 输入(全部由本地包装 put 上来，名字固定)：
#   w1161_gate.h w1159_wire.h w1151_core.h w1155_record.h w1161_supercall.h w1161_app_profile.h
#   w1161_main.c w1161_img.tar(两张真图) w1143_leg_shot96.out(第 96 发腿证件)
set -u
cd /home/lucy || exit 1
IN="w1161_gate.h w1159_wire.h w1151_core.h w1155_record.h w1161_supercall.h w1161_app_profile.h w1161_main.c w1161_img.tar w1143_leg_shot96.out"
for f in $IN; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
for f in $IN; do
  echo "MD5_$f=$(md5sum "$f" | cut -d' ' -f1)"
done
echo "MAIN_BYTES=$(wc -c <w1161_main.c | tr -dc '0-9')"

rm -rf w1161d && mkdir -p w1161d/uapi w1161d/img
cp w1151_core.h   w1161d/w1151_sepolicy_core.h
cp w1155_record.h w1161d/w1155_sepol_record.h
cp w1159_wire.h   w1161d/w1159_sepol_wire.h
cp w1161_gate.h   w1161d/w1161_polgate.h
cp w1161_supercall.h  w1161d/uapi/supercall.h
cp w1161_app_profile.h w1161d/uapi/app_profile.h
tar -xf w1161_img.tar -C w1161d/img || { echo "!! 图解不开"; exit 1; }
echo "IMG_FILES=$(ls w1161d/img/ 2>/dev/null | wc -l | tr -dc '0-9')"
for p in pol.before pol.after; do
  echo "IMG $p bytes=$(wc -c <w1161d/img/$p | tr -dc '0-9') md5=$(md5sum w1161d/img/$p | cut -d' ' -f1)"
done
# ★腿证件的形状闸：证件里没有那四个键，自测就是在拿空数对表 ⇒ 先数出来
for k in post_pre_len post_pre_sum post_post_len post_post_sum; do
  echo "LEG_$k=$(grep -ac "$k=" w1143_leg_shot96.out | tr -dc '0-9')"
done

# -Wno-unused-function：这个 TU 只向 w1159 借那**一把已经三方对过表的 FNV**，
#   它带的读文件/预解/填载荷四支在本自测里用不到 ⇒ 报"没用到"不是缺陷；
#   那四支的牙在 w1159 自己的 229 断言里(§350)，不在这里重复。
CFLAGS="-std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-const-variable -Wno-unused-function -Iw1161d"
gcc $CFLAGS -o w1161_st w1161_main.c 2>w1161_err.txt; RC=$?
echo "HOST_MAKE_RC=$RC"
echo "DIAG_ERR=$(grep -c 'error:' w1161_err.txt) DIAG_WARN=$(grep -c 'warning:' w1161_err.txt)"
[ "$RC" = 0 ] || { sed 's/^/  cc: /' w1161_err.txt | head -30; echo "!! 宿主编译没过 ⇒ 停"; exit 1; }

./w1161_st w1161d/img w1143_leg_shot96.out >w1161_run.txt; RUN=$?
echo "RUN_RC=$RUN"
grep -acE '^\[OK\]' w1161_run.txt | sed 's/^/OK_LINES=/'
grep -aE '^\[OK\] T[16]' w1161_run.txt | sed 's/^/  okline: /'
grep -aE '^\[BAD\]' w1161_run.txt | head -14 | sed 's/^/  /'
grep -aE '^SUM |^VERDICT=' w1161_run.txt | sed 's/^/  /'
[ "$RUN" = 0 ] || { echo "!! 正跑没绿 ⇒ 门本身就是错的，变异不用看"; exit 1; }

# ===== 五条变异：每次只拆一把闸或改一次次序，改完必须被**指定的那一格**抓到 =====
cp w1161d/w1161_polgate.h w1161_base.h
mut() { # <名字> <sed 程序> <期望红在哪一格的固定串>
  local tag="$1" prog="$2" want="$3"
  cp w1161_base.h w1161d/w1161_polgate.h
  sed -i "$prog" w1161d/w1161_polgate.h
  cmp -s w1161_base.h w1161d/w1161_polgate.h && { echo "MUT_$tag=NO_OP(sed 没改动任何字节 ⇒ 这条变异是空枪)"; return 1; }
  gcc $CFLAGS -o w1161_m w1161_main.c 2>w1161_merr.txt || {
    echo "MUT_$tag=BUILD_FAIL(抓到，但要看是不是编不出来才红：$(head -c 160 w1161_merr.txt | tr -d '\n'))"
    return 0; }
  ./w1161_m w1161d/img w1143_leg_shot96.out >w1161_m.txt 2>&1
  local r=$?
  if [ "$r" != 0 ] && grep -qF "$want" w1161_m.txt; then
    echo "MUT_$tag=CAUGHT rc=$r 首红=[$(grep -am1 -F "$want" w1161_m.txt | cut -c1-78)]"
    return 0
  fi
  echo "MUT_$tag=MISSED rc=$r (期望非 0 且出现 [$want]) ⇒ 那把尺没牙"
  return 1
}
BAD=0
# ★五条都"编得过、只在行为上错"——§6.548 那一栏刚为这条栽过两次。
mut orderless  's/if (r->len < W1161_HDR_MIN)/if (0)/'                 "T4 头不够"   || BAD=1
mut smallbound 's/if (r->len < W1161_HDR_MIN)/if (r->len <= W1161_HDR_MIN)/' "T5 恰好 32" || BAD=1
mut capbound   's/if (r->len > r->cap)/if (r->len >= r->cap)/'         "T7 恰好等于上限" || BAD=1
mut armdrop    's/if (r->armed_sum != r->live_sum)/if (0)/'             "T3 武装值与当下不符" || BAD=1
# ★最后这条是把**我自己犯过的错**原样塞回去：凭记忆写 `0x3000012`(那是老古董值)，
#   而设备的图第一字是 `0xf97cff8c` ⇒ 必须被"全条件都好"那一格抓到。
mut magicmem   's/if (w1161_magic(r) != r->magic_want)/if (w1161_magic(r) != 0x3000012u)/' "T2 全条件都好" || BAD=1
cp w1161_base.h w1161d/w1161_polgate.h
gcc $CFLAGS -o w1161_b w1161_main.c 2>/dev/null && ./w1161_b w1161d/img w1143_leg_shot96.out >/dev/null 2>&1
REVERT_RC=$?
echo "REVERT_RC=$REVERT_RC (必须 0 ⇒ 五条变异只是把件拆开看过，没留在件里)"
if [ "$BAD" = 0 ] && [ "$RUN" = 0 ] && [ "$REVERT_RC" = 0 ]; then
  echo "VERDICT=ok 装载门：宿主正跑绿＋五条变异全被抓＋还原后仍绿"
else
  echo "VERDICT=bad 变异没全被抓(BAD=$BAD) 或正跑/还原没绿(RUN=$RUN REVERT=$REVERT_RC)"
fi
exit 0
