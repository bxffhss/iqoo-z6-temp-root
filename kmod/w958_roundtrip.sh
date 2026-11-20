#!/bin/bash
# w958_roundtrip.sh — #216 的**可行性判决**（一条命令跑完，网络抖就少来回）：
#   厂商二进制件 →(w957)→ CIL →(secilc，**不加任何 delta**)→ 二进制 →(w953b 三元组双向差)→ 结论
# ★为什么先跑"空 delta"这一版：这是"只加不减"这条路的**前提**——如果连"原样往返"都会丢规则，
#   那这条路本身就不可用，谈不上叠我们的四条；反过来若往返＝0 丢 0 增，则装载风险被这把尺子**当场可证**。
# 硬断言（任何一条不满足就 exit 3，不出结论；这是 §6.455/§6.456 那三条仪器教训写进代码）：
#   A1 gcc 的 rc 由 gcc 自己给（**不许**从 `| head` 取）
#   A2 rt.cil 必须非空且行数 ≥ 10000（否则＝反编译没吐东西）
#   A3 rt.bin 必须非空且能 `sesearch` 读出 ≥ 5 万条 allow
#   A4 差分器 w953b 自己要求解析覆盖率 ≥99.9%，不达标它自己 exit 3
set -u
cd /home/lucy/pol2 || exit 2
LIB=/usr/lib/x86_64-linux-gnu/libsepol.a
V=precompiled_sepolicy
fail() { echo "★FAIL: $1 ⇒ 不出结论"; exit 3; }

echo "T0 date=$(date -Is) 厂商件=$(wc -c < $V) B md5=$(md5sum $V | cut -c1-8)"
gcc -O2 -Wall ../w957_pol2cil.c -o w957 $LIB > T_build.log 2>&1
rc=$?
[ "$rc" = 0 ] || { head -12 T_build.log; fail "A1 编译 rc=$rc"; }
echo "T1 编译 ok（gcc rc=0）"
./w957 $V --info 2>&1 | tail -2

./w957 $V > rt.cil 2> T_cil.err || fail "A2 w957 退出非 0：$(tail -2 T_cil.err)"
lines=$(wc -l < rt.cil)
echo "T2 rt.cil 行数=$lines 字节=$(wc -c < rt.cil)"
[ "$lines" -ge 10000 ] || fail "A2 反编译件只有 $lines 行(<10000) ⇒ 空/半截件"

rm -f rt.bin
secilc -m -M true -G -N -c 30 rt.cil -o rt.bin 2> T_secilc.err
rc=$?
echo "T3 secilc rc=$rc 产物=$(wc -c < rt.bin 2>/dev/null) B（厂商 $(wc -c < $V) B）err 首行: $(head -1 T_secilc.err)"
[ "$rc" = 0 ] && [ -s rt.bin ] || fail "A3 往返编不回来 ⇒ 这条路走不通（不是'待办'，是判负）"

sesearch --allow $V     2>/dev/null | sort > vendor.allow.txt
sesearch --allow rt.bin 2>/dev/null | sort > ours.allow.txt
echo "T4 allow 行数：厂商=$(wc -l < vendor.allow.txt) 往返件=$(wc -l < ours.allow.txt)"
[ "$(wc -l < vendor.allow.txt)" -ge 50000 ] || fail "A3 厂商侧 allow <5 万 ⇒ 读数无效"
[ "$(wc -l < ours.allow.txt)" -ge 50000 ] || fail "A3 往返件 allow <5 万 ⇒ 往返把规则读丢了"

echo "T5 ★空 delta 往返的三元组双向差（这四个数决定 #216 成立与否）:"
python3 ../w953b_rule_diff_probe.py /home/lucy/pol2
rc=$?
[ "$rc" = 0 ] || fail "A4 差分器自己判无效(rc=$rc)"
echo "T6 判决口径：「厂商有、我们完全没有 = 0」且「两边都有但我们权限更少 = 0」⇒ 原样往返保真 ⇒ '只加不减'可证；"
echo "   非零 ⇒ #216 也判负，第 3 档在这台机上没有安全做法（负结果同样是交付）。"
echo "TZ_END date=$(date -Is)"
