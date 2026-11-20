#!/bin/bash
# w1109_verify_remote.sh —— 在构建机上把"设备上刚导出的那份策略"验一遍，产出一个链能读的死数字。
#   为什么要跑在远端：x86 的 libsepol 与 w1104_delta.c 都在那台机上（11-02 那次离线判定就是在那儿出的），
#     本机没有 libsepol；这条脚本只做"读/往返/插/序列化/dump"，**不碰设备、不碰 /sys/fs/selinux/load**。
#   用法：w1109_verify_remote.sh <远端目录里已 put 的 pol.orig 名> <rules 文件名>
#   输出（一行一键，链按这些行取值；任何一项取不到都算"未测"，链就不装载）：
#     ORIG_MD5=  RT_ADDED= RT_REMOVED= DELTA_ADDED= DELTA_REMOVED= NEW_MD5= NEW_BYTES= VERDICT=ok|fail
set -u
cd /home/lucy || exit 9
POL=${1:-pol.orig}; RULES=${2:-delta_rules.txt}
SRC=/home/lucy/w1104_delta.c
BIN=/home/lucy/w1104_host
SEPD=/home/lucy/sepolsrc/libsepol-3.4
# --- 1) 工具来源：优先用**已存在且真能跑**的 x86 件；没有才现场编(★必须先 clean) ---
BIN=/home/lucy/w1104_host
ok_bin() { [ -x "$BIN" ] && "$BIN" dump "$POL" /tmp/_probe.txt >/dev/null 2>&1 && grep -q '^DUMP_NODES=[0-9]' /tmp/_probe.txt; }
LIB=""
for c in $(find /home/lucy -maxdepth 5 -name 'libsepol.a' 2>/dev/null); do
    if file "$c" | grep -q 'x86-64'; then LIB=$c; break; fi
done
if ! ok_bin; then
    echo "HOST_BIN 不可用(不存在或 dump 不出节点) ⇒ 现场编"
    if [ -z "$LIB" ]; then
        echo "BUILD 没找到 x86 的 libsepol.a ⇒ 在副本里从源码重编(★先 clean，否则 .o 还是 aarch64＝EM:183)"
        rm -rf /home/lucy/sepolsrc_host; cp -a $SEPD /home/lucy/sepolsrc_host
        (cd /home/lucy/sepolsrc_host && make -C src clean >/dev/null 2>&1; make -C src libsepol.a CC=gcc >/tmp/sepolbuild.log 2>&1)
        LIB=/home/lucy/sepolsrc_host/src/libsepol.a
        tail -3 /tmp/sepolbuild.log | sed 's/^/  build: /'
    fi
    file "$LIB" | cut -c1-60
    gcc -O2 -I"$SEPD/include" -I"$SEPD" -o "$BIN" "$SRC" "$LIB" 2>build.err || { tail -4 build.err; echo "VERDICT=fail"; exit 7; }
fi
file "$BIN" | grep -q 'x86-64' || { echo "BIN 不是 x86-64：$(file "$BIN" | cut -c1-60) ⇒ 不许拿 arm64 件当主机件"; echo "VERDICT=fail"; exit 7; }
ok_bin || { echo "dump 跑不通 ⇒ 未测"; echo "VERDICT=fail"; exit 7; }
# --- 3) 三道判定 ---
md5sum "$POL" | cut -c1-32 | sed 's/^/ORIG_MD5=/'
"$BIN" dump "$POL" A.txt >/dev/null 2>&1; echo "DUMP_A=$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' A.txt)"
"$BIN" rt "$POL" rt.pol >rt.log 2>&1; "$BIN" dump rt.pol B.txt >/dev/null 2>&1
echo "RT_ADDED=$(comm -13 <(grep -v '^DUMP_' A.txt|sort) <(grep -v '^DUMP_' B.txt|sort) | grep -ac . )"
echo "RT_REMOVED=$(comm -23 <(grep -v '^DUMP_' A.txt|sort) <(grep -v '^DUMP_' B.txt|sort) | grep -ac . )"
"$BIN" delta "$POL" new.pol "$RULES" >delta.log 2>&1 || { tail -3 delta.log; echo "VERDICT=fail"; exit 8; }
grep -aE '^RULE|^INSERTED' delta.log | sed 's/^/  /'
"$BIN" dump new.pol C.txt >/dev/null 2>&1
#   ★diff 只许比**三元组行**：dump 文件尾部的计数行(DUMP_NODES/DUMP_AVTAB_*)每次都会变，
#     把它们算进"增/删"就会得出 DELTA_ADDED=6/REMOVED=3 这种假账(11-02 第 89 发实测被自己的闸挡下)。
#     计数不当判据，但**单独印出来当旁证**：节点数应恰好 +3。
R() { grep -v '^DUMP_' "$1" | sort; }   # 只留三元组行
echo "TRAILER_A=$(grep '^DUMP_NODES' A.txt | tr -d '\n') TRAILER_C=$(grep '^DUMP_NODES' C.txt | tr -d '\n')"
N1=$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' A.txt); N3=$(sed -n 's/^DUMP_NODES=\([0-9]*\).*/\1/p' C.txt)
echo "NODES_DELTA=$((N3 - N1)) (期望=3)"
echo "DELTA_ADDED=$(comm -13 <(R A.txt) <(R C.txt) | grep -ac . )"
echo "DELTA_REMOVED=$(comm -23 <(R A.txt) <(R C.txt) | grep -ac . )"
comm -13 <(R A.txt) <(R C.txt) | head -6 | sed 's/^/  ADD /'
md5sum new.pol | cut -c1-32 | sed 's/^/NEW_MD5=/'; echo "NEW_BYTES=$(wc -c < new.pol)"
A=$(comm -13 <(R A.txt) <(R B.txt) | grep -c .); B=$(comm -23 <(R A.txt) <(R B.txt) | grep -c .)
D=$(comm -13 <(R A.txt) <(R C.txt) | grep -c .); Rm=$(comm -23 <(R A.txt) <(R C.txt) | grep -c .)
[ "$A" = 0 ] && [ "$B" = 0 ] && [ "$D" = 3 ] && [ "$Rm" = 0 ] && [ "$((N3 - N1))" = 3 ] && echo "VERDICT=ok" || echo "VERDICT=fail"
