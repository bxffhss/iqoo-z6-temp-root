#!/bin/bash
# w1159_remote.sh —— 构建机侧(0 枪)：把 #241 的**用户态那一头**在 x86 宿主上编出来、跑自测，
#   再用五条变异证明这把尺有牙。件不碰 ioctl、不碰设备，纯 C＋那份 uapi 头。
# ★为什么这段要在构建机上跑：本机(Windows)没有 C 编译器，而 ksuctl.c 编出来是 aarch64 静态二进制，
#   在这台 PC 上连"跑一下"都做不到 ⇒ 纯逻辑只有搬进宿主自测才有读数(§345/§348 立的规矩)。
# 输入(全部由本地包装 put 上来，名字固定)：
#   w1159_wire.h w1151_core.h w1155_record.h w1159_supercall.h w1159_app_profile.h
#   w1159_main.c w1159_fix.tar(11 件夹具＋expect.txt) w1159_rec.tar(第 97 发 12 份设备证件)
set -u
cd /home/lucy || exit 1
IN="w1159_wire.h w1151_core.h w1155_record.h w1159_supercall.h w1159_app_profile.h w1159_main.c w1159_fix.tar w1159_rec.tar"
for f in $IN; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
for f in $IN; do
  echo "MD5_$f=$(md5sum "$f" | cut -d' ' -f1)"
done
echo "MAIN_BYTES=$(wc -c <w1159_main.c | tr -dc '0-9')"

rm -rf w1159d w1159r && mkdir -p w1159d/uapi w1159d/fixtures w1159r
cp w1151_core.h   w1159d/w1151_sepolicy_core.h
cp w1155_record.h w1159d/w1155_sepol_record.h
cp w1159_wire.h   w1159d/w1159_sepol_wire.h
cp w1159_supercall.h  w1159d/uapi/supercall.h
cp w1159_app_profile.h w1159d/uapi/app_profile.h
tar -xf w1159_fix.tar -C w1159d/fixtures || { echo "!! 夹具解不开"; exit 1; }
tar -xf w1159_rec.tar -C w1159r || { echo "!! 设备证件解不开"; exit 1; }
echo "FIXTURES_BINS=$(ls w1159d/fixtures/*.bin 2>/dev/null | wc -l | tr -dc '0-9')"
echo "TBL_LINES=$(grep -vc '^#' w1159d/fixtures/expect.txt)"
echo "REC_FILES=$(ls w1159r/rec_* 2>/dev/null | wc -l | tr -dc '0-9')"
# ★证件的形状闸：每份 rec_* 第一行都该是内核 scnprintf 出来的 "PD v1 "，不是就整批发不出言
echo "REC_PDV1=$(grep -l '^PD v1 ' w1159r/rec_* 2>/dev/null | wc -l | tr -dc '0-9')"

# -Wno-unused-const-variable：uapi 头里那些 `static const __u32 KSU_IOCTL_*` 本自测用不到全部，
#   带着 -Werror 会把"没用到"读成编译失败——那是**头的形状**不是被测的红，不能算在被测头上。
CFLAGS="-std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-const-variable -Iw1159d"
gcc $CFLAGS -o w1159_st w1159_main.c 2>w1159_err.txt; RC=$?
echo "HOST_MAKE_RC=$RC"
echo "DIAG_ERR=$(grep -c 'error:' w1159_err.txt) DIAG_WARN=$(grep -c 'warning:' w1159_err.txt)"
[ "$RC" = 0 ] || { sed 's/^/  cc: /' w1159_err.txt | head -30; echo "!! 宿主编译没过 ⇒ 停"; exit 1; }

./w1159_st w1159d/fixtures w1159d/fixtures/expect.txt w1159r >w1159_run.txt; RUN=$?
echo "RUN_RC=$RUN"
grep -acE '^\[OK\]' w1159_run.txt | sed 's/^/OK_LINES=/'
# ★把"对表跑了多少格、红了几格"那两句原文抄进证件：只有 OK 行数与 SUM 的话，
#   日后看不出 S4 那 12 格到底是"对过且全等"还是"根本没进到那一格"(例 231：输出非空≠来自对端)。
grep -aE '^\[OK\] S[1357]' w1159_run.txt | sed 's/^/  okline: /'
grep -aE '^\[BAD\]' w1159_run.txt | head -14 | sed 's/^/  /'
grep -aE '^SUM |^VERDICT=' w1159_run.txt | sed 's/^/  /'
[ "$RUN" = 0 ] || { echo "!! 正跑没绿 ⇒ 用户态那一头本身就是错的，变异不用看"; exit 1; }

# ===== 五条变异：每次只拆掉那层里的一把尺，改完必须被对应的格抓到 =====
cp w1159d/w1159_sepol_wire.h w1159_base.h
mut() { # <名字> <sed 程序> <期望红在哪一行的固定串>
  local tag="$1" prog="$2" want="$3"
  cp w1159_base.h w1159d/w1159_sepol_wire.h
  sed -i "$prog" w1159d/w1159_sepol_wire.h
  cmp -s w1159_base.h w1159d/w1159_sepol_wire.h && { echo "MUT_$tag=NO_OP(sed 没改动任何字节 ⇒ 这条变异是空枪)"; return 1; }
  gcc $CFLAGS -o w1159_m w1159_main.c 2>w1159_merr.txt || {
    echo "MUT_$tag=BUILD_FAIL(抓到，但要看是不是编不出来才红：$(head -c 160 w1159_merr.txt | tr -d '\n'))"
    return 0; }
  ./w1159_m w1159d/fixtures w1159d/fixtures/expect.txt w1159r >w1159_m.txt 2>&1
  local r=$?
  if [ "$r" != 0 ] && grep -qF "$want" w1159_m.txt; then
    echo "MUT_$tag=CAUGHT rc=$r 首红=[$(grep -am1 -F "$want" w1159_m.txt | cut -c1-76)]"
    return 0
  fi
  echo "MUT_$tag=MISSED rc=$r (期望非 0 且出现 [$want]) ⇒ 那把尺没牙"
  return 1
}
BAD=0
# ★每条变异都要**编得过、只在行为上错**：上一版我用"把参数扔掉"的写法(s->data=(__u64)len / 去掉 want_send)，
#   -Wextra 的 unused-parameter 直接把它拦在编译期 ⇒ 证件上写的是 BUILD_FAIL，那把尺到底有没有牙**没测到**。
#   所以这两条改成"两个参数都还在用，但算出来的值错了"。
mut fnvprime   's/1099511628211ull/1099511628210ull/'                 "fnv 我="            || BAD=1
mut capbound   's/if (out->want > cap)/if (out->want >= cap)/'        "S5 恰好 cap"        || BAD=1
mut expectone  's/w1151_expect_bytes(st, v->rep.n)/w1151_expect_bytes(st, 1u)/' "lenmatch 我=" || BAD=1
mut fillptr    's/c->data = (__u64)(uintptr_t)data;/c->data = (__u64)(uintptr_t)data + 8ull;/'     "S1 填出来的"  || BAD=1
mut gatealways 's/return want_send ? W1159_FIRE : W1159_DRY;/return (want_send || load_code == W1159_F_OK) ? W1159_FIRE : W1159_DRY;/' "S6 没给 --send" || BAD=1
cp w1159_base.h w1159d/w1159_sepol_wire.h
gcc $CFLAGS -o w1159_b w1159_main.c 2>/dev/null && ./w1159_b w1159d/fixtures w1159d/fixtures/expect.txt w1159r >/dev/null 2>&1
REVERT_RC=$?
echo "REVERT_RC=$REVERT_RC (必须 0 ⇒ 五条变异只是把件拆开看过，没留在件里)"
if [ "$BAD" = 0 ] && [ "$RUN" = 0 ] && [ "$REVERT_RC" = 0 ]; then
  echo "VERDICT=ok 用户态那一头：宿主正跑绿＋五条变异全被抓＋还原后仍绿"
else
  echo "VERDICT=bad 变异没全被抓(BAD=$BAD) 或正跑/还原没绿(RUN=$RUN REVERT=$REVERT_RC)"
fi
exit 0
