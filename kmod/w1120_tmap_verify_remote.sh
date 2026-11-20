#!/bin/bash
# w1120_tmap_verify_remote.sh —— 在构建机上验**往返前后那张"按位置对的属性映射表"逐条相同**（#232 的前置闸，0 枪）。
#   为什么单独验这一张表：内核读符号表时每条类型**自带 value**(`type_read` 里 `typdatum->value = buf[1]`)，
#     但紧随其后的 `type_attr_map[i]` 段是**按位置**对的（5.4.281 ss/policydb.c:2510 那个 `for i<nprim` 循环）；
#     libsepol 写的时候也按位置（write.c）。⇒ 一旦"符号表写出的次序"不等于 value 升序，整张表就会**集体错位**，
#     而这种错位**不会**出现在 avtab 三元组差分里（93/94 两发的判据全是三元组差分 ⇒ 它们没有这一格的牙），
#     却会让执法态下"谁属于哪个域/文件类型"全乱。所以往 type 表插新类型之前，必须先证往返对这张表是**恒等**的。
#   用法：w1120_tmap_verify_remote.sh <已 put 的源码名> <本机源码 md5> <已 put 的 pol.orig 名>
#   输出一行一键；任何一键取不到 ⇒ TMAP_VERDICT=fail。**不碰设备、不碰 /sys/fs/selinux/load。**
set -u
cd /home/lucy || exit 9
SRCPUT=${1:?源码文件名}; SRCMD5=${2:?源码 md5}; POL=${3:-pol.orig}
SRC=/home/lucy/w1104_tmap_src.c
BIN=/home/lucy/w1104_v3                      # ★新件，不覆盖 w1104_host（93/94 的链还在用它）
OLD=/home/lucy/w1104_host
LIB=/home/lucy/sepolsrc_host/src/libsepol.a  # x86 那份（树里 /home/lucy/sepolsrc/libsepol-3.4 的是 aarch64）

# --- 0) 源码两端一致：先落位再比 md5，比不中就拒 ---
cp "$SRCPUT" "$SRC" 2>/dev/null || { echo "SRC_CP=失败(put 的东西不在: $SRCPUT)"; echo "TMAP_VERDICT=fail"; exit 7; }
REMOTE_MD5=$(md5sum "$SRC" | cut -d' ' -f1)
echo "SRC_MD5_LOCAL=$SRCMD5 SRC_MD5_REMOTE=$REMOTE_MD5"
[ "$REMOTE_MD5" = "$SRCMD5" ] || { echo "[x] 远端这份源码不是本机那份 ⇒ 编出来的件不算数"; echo "TMAP_VERDICT=fail"; exit 7; }
# ★`file` 对 .a 本身不说明架构，抽一个成员看（拿错 aarch64 那份会在这里就红，而不是等链接报 EM:183）
MB=$(ar t "$LIB" 2>/dev/null | head -1)
ar p "$LIB" "$MB" > _m.o 2>/dev/null
echo "LIB_MEMBER=$MB $(file _m.o 2>&1 | cut -d: -f2- | cut -c1-40)"
file _m.o 2>/dev/null | grep -q 'x86-64' || { echo "[x] $LIB 的成员不是 x86-64 ⇒ 拿错库"; echo "TMAP_VERDICT=fail"; exit 7; }
# --- 1) 现场编 x86 件；编译失败就是**结论**（新代码写坏了），不是环境问题 ---
rm -f "$BIN"
gcc -O2 -I/home/lucy/sepolsrc/libsepol-3.4/include -I/home/lucy/sepolsrc/libsepol-3.4 \
     -o "$BIN" "$SRC" "$LIB" 2>tmap_build.err || { echo "BUILD=失败"; tail -6 tmap_build.err | sed 's/^/  /'; echo "TMAP_VERDICT=fail"; exit 7; }
file "$BIN" | cut -c1-58 | sed 's/^/BIN /'
file "$BIN" | grep -q 'x86-64' || { echo "[x] BIN 不是 x86-64 ⇒ 不许拿 arm64 件当主机件"; echo "TMAP_VERDICT=fail"; exit 7; }
echo "BUILD=ok"
# --- 2) 加模式没把老路径改坏：同一份 pol.orig，新旧两件各 dump 一次，逐行比 ---
"$BIN" dump "$POL" D_new.txt >/dev/null 2>&1 || { echo "[x] 新件 dump 跑不通 ⇒ 未测"; echo "TMAP_VERDICT=fail"; exit 7; }
if [ -x "$OLD" ]; then
    "$OLD" dump "$POL" D_old.txt >/dev/null 2>&1
    echo "OLD_DUMP_VS_NEW=$(diff D_old.txt D_new.txt | grep -ac '^[<>]') (期望=0)"
    echo "TRAILER_OLD=$(grep '^DUMP_NODES' D_old.txt | tr -d '\n') TRAILER_NEW=$(grep '^DUMP_NODES' D_new.txt | tr -d '\n')"
else
    echo "OLD_DUMP_VS_NEW=未测(没有 $OLD 可比)"
fi
# --- 3) 往返：只"读→写→再读"，一条规则都不插 ---
"$BIN" rt "$POL" rt3.pol >rt3.log 2>&1 || { echo "RT=失败"; tail -3 rt3.log | sed 's/^/  /'; echo "TMAP_VERDICT=fail"; exit 7; }
md5sum "$POL" rt3.pol | cut -c1-45 | sed 's/^/MD5 /'
echo "BYTES orig=$(wc -c < $POL) rt=$(wc -c < rt3.pol)"
# ★一手量到的新事实(11-03)：往返后**字节数相同但 md5 不同** ⇒ "空 delta 逐字节相同"这个口径在这份导出上是**不成立**的。
#   所以这里把"差在哪些字节、差多少"打出来，再用**结构证人**(dump 三元组)定"语义有没有变"——别拿 md5 当语义的尺。
NB_DIFF=$(cmp -l "$POL" rt3.pol 2>/dev/null | grep -ac .); FIRST_OFF=$(cmp -l "$POL" rt3.pol 2>/dev/null | head -1 | awk '{print $1}')
echo "BYTE_DIFF=$NB_DIFF 首差偏移=$FIRST_OFF (字节数相同才有这两个数；否则取不到＝记未测)"
"$BIN" dump rt3.pol D_rt.txt >/dev/null 2>&1
echo "RT_VS_ORIG_DUMP=$(diff D_new.txt D_rt.txt | grep -ac '^[<>]') (期望=0；这一格才是「往返语义恒等」的证人)"
echo "TRAILER_RT=$(grep '^DUMP_NODES' D_rt.txt | tr -d '\n')"
"$BIN" tmap "$POL"    tmap_before.txt >tmap_b.err 2>&1 || { echo "TMAP_BEFORE=跑不通"; tail -3 tmap_b.err | sed 's/^/  /'; echo "TMAP_VERDICT=fail"; exit 8; }
"$BIN" tmap rt3.pol   tmap_after.txt  >tmap_a.err 2>&1 || { echo "TMAP_AFTER=跑不通"; tail -3 tmap_a.err | sed 's/^/  /'; echo "TMAP_VERDICT=fail"; exit 8; }
grep -a '^TMAP_TOTAL=' tmap_before.txt | sed 's/^/TRAILER_BEFORE=/'
grep -a '^TMAP_TOTAL=' tmap_after.txt  | sed 's/^/TRAILER_AFTER=/'
echo "TROWS_BEFORE=$(grep -ac '^TMAP ' tmap_before.txt) TROWS_AFTER=$(grep -ac '^TMAP ' tmap_after.txt)"
head -2 tmap_before.txt | sed 's/^/  H /'; tail -2 tmap_before.txt | sed 's/^/  T /'
# --- 4) ★这一格的牙：把同一把尺用在"明知被改过的一份"上，它必须**不为空**（否则"零行差"不算通过）---
sed '5s/$/ ATTR=zz_probe_attr/' tmap_before.txt > tmap_tweak.txt
CTRL=$(diff tmap_before.txt tmap_tweak.txt | grep -ac '^[<>]')
echo "CTRL_TEETH=$CTRL (期望>=1；0 就说明这把尺读不出这张表里的改动，下面的 0 不算数)"
[ "$CTRL" -ge 1 ] || { echo "[x] 正对照没牙"; echo "TMAP_VERDICT=fail"; exit 8; }
# --- 5) 判据：行数相等 ＋ 逐行差 0（牙已在第 4 步单独证过）---
NB=$(grep -ac '^TMAP ' tmap_before.txt); NA=$(grep -ac '^TMAP ' tmap_after.txt)
DIFF=$(diff tmap_before.txt tmap_after.txt | grep -ac '^[<>]')
echo "TMAP_DIFF=$DIFF (期望=0)"
diff tmap_before.txt tmap_after.txt | head -12 | sed 's/^/  D /'
if [ "$NB" = "$NA" ] && [ "$DIFF" = 0 ]; then echo "TMAP_VERDICT=ok"; exit 0; fi
echo "TMAP_VERDICT=fail"
exit 9
