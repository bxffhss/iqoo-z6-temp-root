#!/usr/bin/env bash
# w1105_build_delta_tool.sh — 离线（远程 Linux 构建机）编 w1104_delta.c 并跑 V1..V6，产出判决文件。
# 可重复跑。不碰手机、不碰 /sys/fs/selinux/load、不动任何 .ko。
#
# 需要的文件（先 put 到远端家目录，本脚本再搬进工作目录）：
#   w1104_delta.c  rules.txt  pol.live_1027  [w1100_deathboot_w1093_pol.pre 作为备胎]
#   w1105_build_delta_tool.sh
# 用法（远端）：W1105_IN=~ bash w1105_build_delta_tool.sh
set -u

IN=${W1105_IN:-$HOME}
BASE=${W1105_BASE:-$HOME/w1105}
SRC=${SEPOLSRC:-/home/lucy/sepolsrc/libsepol-3.4}
LIBSEPOL=${LIBSEPOL_A:-$SRC/src/libsepol.a}
HOSTDIR=${W1105_HOSTLIB:-$HOME/w1105_hostlib}
ORIG_LIBSEPOL=$LIBSEPOL
EXPECT_MD5=282a68611a2f36321a153fc0102f9ca0
EXPECT_SIZE=1356948

rm -rf "$BASE"
mkdir -p "$BASE" || exit 9
cd "$BASE" || exit 9
V=verdict.txt
: > "$V"
say() { printf '%s\n' "$*" >> "$V"; }
FAIL=0
fail() { say "FAIL_WHY: $*"; FAIL=$((FAIL + 1)); }

for f in w1104_delta.c rules.txt w1105_build_delta_tool.sh; do
	[ -f "$IN/$f" ] || { echo "missing input $IN/$f" >&2; exit 8; }
	cp -f "$IN/$f" "$BASE/$f"
done
say "== w1105 delta-tool offline verdict  $(date -u '+%Y-%m-%dT%H:%M:%SZ') host=$(hostname) =="
say "IN=$IN BASE=$BASE LIBSEPOL=$LIBSEPOL"
say "gcc=$(gcc --version | head -1)"

# ---------------- 输入凭据 ----------------
POL=pol.live
if [ -f "$IN/pol.live_1027" ]; then cp -f "$IN/pol.live_1027" "$POL"
elif [ -f "$IN/w1100_deathboot_w1093_pol.pre" ]; then cp -f "$IN/w1100_deathboot_w1093_pol.pre" "$POL"
else echo "no policy input" >&2; exit 8; fi
ACT_MD5=$(md5sum "$POL" | cut -d' ' -f1)
ACT_SIZE=$(stat -c %s "$POL")
say "POLFILE $POL size=$ACT_SIZE md5=$ACT_MD5 (expect size=$EXPECT_SIZE md5=$EXPECT_MD5)"
if [ "$ACT_MD5" != "$EXPECT_MD5" ] || [ "$ACT_SIZE" != "$EXPECT_SIZE" ]; then
	fail "vendor policy identity mismatch — the differential dump would prove nothing"
fi

# ---------------- 归档架构 ----------------
# 构建机是 x86-64，而源码树里预编好的 src/libsepol.a 其实是 **aarch64**（ld 报 "Relocations in generic ELF (EM: 183)"）。
# 所以要把同一份 3.4 源码在**副本**里重编一份 host 归档来跑差分（原树一个字节都不动，那份 arm64 归档留给手机侧用）。
arch_of() {
	local a="$1" m
	m=$(ar t "$a" 2>/dev/null | head -1)
	[ -n "$m" ] || { echo unknown; return; }
	ar p "$a" "$m" > "$BASE/_probe.o" 2>/dev/null || { echo unknown; return; }
	file -b "$BASE/_probe.o" | grep -o 'aarch64\|x86-64' | head -1
	rm -f "$BASE/_probe.o"
}
HOSTARCH=$(uname -m)
[ "$HOSTARCH" = x86_64 ] && HOSTARCH=x86-64
ORIG_ARCH=$(arch_of "$ORIG_LIBSEPOL")
say "ARCHLIB tree_archive=$ORIG_LIBSEPOL arch=$ORIG_ARCH host_wants=$HOSTARCH"
if [ "$ORIG_ARCH" != "$HOSTARCH" ]; then
	say "HOST_BUILD: tree archive is $ORIG_ARCH, rebuilding the same 3.4 source for the host inside a copy ($HOSTDIR)"
	mkdir -p "$HOSTDIR"
	rm -rf "$HOSTDIR/libsepol-3.4"
	cp -a "$SRC" "$HOSTDIR/" || fail "copy of libsepol source failed"
	( cd "$HOSTDIR/libsepol-3.4" && make clean >/dev/null 2>&1 && make -j2 >"$HOSTDIR/hostbuild.log" 2>&1 )
	HB=$?
	if [ ! -f "$HOSTDIR/libsepol-3.4/src/libsepol.a" ]; then
		say "HOST_BUILD failed rc=$HB"
		tail -10 "$HOSTDIR/hostbuild.log" >> "$V"
		exit 7
	fi
	LIBSEPOL="$HOSTDIR/libsepol-3.4/src/libsepol.a"
	SRC="$HOSTDIR/libsepol-3.4"
	say "HOST_BUILD rc=$HB host_archive=$LIBSEPOL arch=$(arch_of "$LIBSEPOL") tree_untouched=yes"
fi

# ---------------- 编译 ----------------
CERR=compile.err
gcc -O2 -Wall -Wextra -Wno-unused-parameter -I"$SRC/include" -o w1104_delta \
	w1104_delta.c "$LIBSEPOL" > "$CERR" 2>&1
CRC=$?
say "COMPILE rc=$CRC warnings=$(grep -c 'warning:' "$CERR") errors=$(grep -c 'error:' "$CERR")"
if [ $CRC -ne 0 ]; then
	say "--- compile output (first 40 lines) ---"
	head -40 "$CERR" >> "$V"
	exit 7
fi
say "SRC_MD5 w1104_delta.c=$(md5sum w1104_delta.c | cut -d' ' -f1) rules.txt=$(md5sum rules.txt | cut -d' ' -f1) this_script=$(md5sum w1105_build_delta_tool.sh | cut -d' ' -f1)"
say "TOOL_MD5=$(md5sum w1104_delta | cut -d' ' -f1) TOOL_ARCH=$(file -b w1104_delta | cut -c1-40)"
T=./w1104_delta

# 去掉 dump 尾部计数行，只留规则行，供 diff 用
only_rules() { grep -v -E '^(DUMP_|UNNAMED_)' "$1" > "$2"; }

# ---------------- V1: dump 厂商策略 ----------------
say ""
say "== V1 dump vendor =="
$T dump "$POL" A.txt > v1.out 2>&1
R1=$?
say "V1 rc=$R1"
if [ $R1 -ne 0 ]; then sed -n '1,20p' v1.out >> "$V"; fail "V1 dump of vendor policy failed"; exit 6; fi
grep -E '^(READ|DUMP) ' v1.out >> "$V"
DUMP_NODES=$(sed -n 's/^.*DUMP_NODES=\([0-9]*\).*$/\1/p' v1.out | head -1)
only_rules A.txt A.r
say "V1 DUMP_NODES=$DUMP_NODES  rule_lines=$(wc -l < A.r)"
if [ "${DUMP_NODES:-0}" -lt 10000 ]; then fail "V1 DUMP_NODES=$DUMP_NODES is not the expected tens of thousands — traversal is suspect"; fi

# ---------------- V2: 空 delta 往返 ----------------
say ""
say "== V2 rt (read+write, no delta) =="
$T rt "$POL" rt.pol > v2.out 2>&1
R2=$?
say "V2 rc=$R2 $(grep -E '^WROTE' v2.out)"
if [ $R2 -ne 0 ]; then sed -n '1,20p' v2.out >> "$V"; fail "V2 rt failed"; exit 6; fi
RT_SIZE=$(stat -c %s rt.pol)
DIFFB=$(cmp -l "$POL" rt.pol 2>/dev/null | wc -l)
CMPLINE=$(cmp "$POL" rt.pol 2>&1 | head -1)
say "V2 cmp size vendor=$ACT_SIZE rt=$RT_SIZE differing_bytes=$DIFFB first_diff='$CMPLINE' (byte-identity not expected)"
$T dump rt.pol B.txt > v2b.out 2>&1
R2B=$?
if [ $R2B -ne 0 ]; then sed -n '1,20p' v2b.out >> "$V"; fail "V2 dump of rt.pol failed"; exit 6; fi
only_rules B.txt B.r
RT_ADDED=$(comm -13 A.r B.r | wc -l)
RT_REMOVED=$(comm -23 A.r B.r | wc -l)
say "V2 RT_ADDED=$RT_ADDED RT_REMOVED=$RT_REMOVED  (A md5=$(md5sum A.r | cut -c1-32) B md5=$(md5sum B.r | cut -c1-32))"
if [ "$RT_ADDED" != 0 ] || [ "$RT_REMOVED" != 0 ]; then
	fail "V2 round-trip is not semantically empty"
	say "--- first 10 diff lines (A vs B) ---"
	diff A.r B.r | head -10 >> "$V"
fi

# ---------------- V2b: 权限编码的独立复算（解码规则不能靠猜） ----------------
say ""
say "== V2b perm-encoding cross-check =="
# capability(7)/classmap 的公开序号表（内核 uapi capability.h 的 CAP_* 索引，0 起）
CAPIDX="chown dac_override dac_read_search fowner fsetid kill setgid setuid setpcap linux_immutable net_bind_service net_broadcast net_admin net_raw ipc_lock ipc_owner sys_module sys_rawio sys_chroot sys_ptrace sys_pacct sys_admin sys_boot sys_nice sys_resource sys_time sys_tty_config mknod lease audit_write audit_control setfcap"
$T perms "$POL" capability > permcap.txt 2>&1 || fail "V2b perms probe failed"
ORD_BAD=$(awk -v list="$CAPIDX" '
	BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) { want[i-1] = a[i]; got[i-1] = "?" } }
	/^PERM/ { split($4, kv, "="); b = kv[2] - 1; got[b] = $3 }
	END { bad = 0; for (i = 0; i < 32; i++) if (got[i] != want[i]) { printf("bit%d: file=%s public=%s\n", i, got[i], want[i]); bad++ }
	      printf("ORDCHECK_MISMATCH=%d CHECKED=32\n", bad) }' permcap.txt | head -8)
say "V2b capability ordinal->bit table vs public CAP index list: $ORD_BAD"
echo "$ORD_BAD" | grep -q "MISMATCH=0" || fail "V2b capability ordinal table does not line up with the public CAP index order"

# 独立复算 RULE 1 的位掩码：直接从 rules.txt 取权限名，用上面那张公开表算，不借工具的解码
P1=$(sed -n 's/^allow shell self:capability {\(.*\)};$/\1/p' rules.txt | tr -s ' ')
EXPBITS=$(awk -v list="$CAPIDX" -v perms="$P1" '
	BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) idx[a[i]] = i - 1;
	        m = split(perms, p, " "); s = 0;
	        for (j = 1; j <= m; j++) {
	                if (!(p[j] in idx)) { print "NOPERM:" p[j]; bad = 1; exit 1 }
	                v = 1; for (k = 0; k < idx[p[j]]; k++) v *= 2;
	                s += v
	        }
	        if (bad) exit 1; printf("0x%08x\n", s) }')
say "V2b rule1 perms=[$P1] independent_mask=$EXPBITS (compared against the tool after V3 runs)"

say ""
say "== V3 delta (insert 3 allow rules) =="
$T delta "$POL" new.pol rules.txt > v3.out 2>&1
R3=$?
say "V3 rc=$R3"
sed -n 's/^/V3 /p' v3.out >> "$V"
if [ $R3 -ne 0 ]; then fail "V3 delta failed"; exit 6; fi
TOOLBITS=$(sed -n 's/^RULE 1 .* bits=\(0x[0-9a-f]*\).*$/\1/p' v3.out)
MT=NO
[ "$TOOLBITS" = "$EXPBITS" ] && MT=yes
say "V2b rule1 tool_bits=$TOOLBITS independent_bits=$EXPBITS match=$MT"
[ "$MT" = yes ] || fail "V2b the mask the tool wrote differs from the independently computed one"
NEW_SIZE=$(stat -c %s new.pol)
NEW_MD5=$(md5sum new.pol | cut -d' ' -f1)
say "V3 new.pol size=$NEW_SIZE md5=$NEW_MD5"
$T dump new.pol C.txt > v3b.out 2>&1 || { fail "V3 dump of new.pol failed"; exit 6; }
only_rules C.txt C.r
DELTA_ADDED=$(comm -13 A.r C.r | wc -l)
DELTA_REMOVED=$(comm -23 A.r C.r | wc -l)
say "V3 DELTA_ADDED=$DELTA_ADDED DELTA_REMOVED=$DELTA_REMOVED"
if [ "$DELTA_REMOVED" != 0 ]; then
	fail "V3 delta removed $DELTA_REMOVED lines from the vendor dump"
	say "--- first 10 lines only in A (i.e. lost) ---"
	comm -23 A.r C.r | head -10 >> "$V"
fi
if [ "$DELTA_ADDED" != 3 ]; then fail "V3 DELTA_ADDED=$DELTA_ADDED, expected exactly 3"; fi
say "--- the 3 added lines ---"
comm -13 A.r C.r >> "$V"
# 三条规则的 key 从工具自己的 RULE 行里取，不在脚本里写死名字
KEYS=$(sed -n 's/^RULE [0-9]* src=\([^ ]*\)\/[0-9]* tgt=\([^ ]*\)\/[0-9]* class=\([^ ]*\)\/[0-9]* bits=0x\([0-9a-f]*\) action=\(.*\)$/\1 \2 \3/p' v3.out)
say "V3 keys_from_tool=$(printf '%s' "$KEYS" | tr '\n' '|')"
while IFS= read -r k; do
	[ -n "$k" ] || continue
	say "KEY '$k'"
	grep -F "$k " A.r | sed "s/^/  A: /" >> "$V"
	grep -F "$k " C.r | sed "s/^/  C: /" >> "$V"
done <<< "$KEYS"
say "V3 side_by_side_done (empty A: side means the triple did not exist in the vendor policy at all)"
# 只增不减的第二把尺：权限集必须是超集，且 C 的行数 = A 的行数 + 新增节点数
INS=$(sed -n 's/^INSERTED=\([0-9]*\).*$/\1/p' v3.out)
MRG=$(sed -n 's/^.*MERGED=\([0-9]*\).*$/\1/p' v3.out)
RIF=$(sed -n 's/^.*RULES_IN_FILE=\([0-9]*\).*$/\1/p' v3.out)
LINES_A=$(wc -l < A.r); LINES_C=$(wc -l < C.r)
say "V3 INSERTED=$INS MERGED=$MRG RULES_IN_FILE=$RIF lines_A=$LINES_A lines_C=$LINES_C delta_lines=$((LINES_C - LINES_A))"
if [ "$RIF" != 3 ]; then fail "V3 RULES_IN_FILE=$RIF, expected 3"; fi
if [ "$((LINES_C - LINES_A))" != "$INS" ]; then fail "V3 line delta $((LINES_C - LINES_A)) != INSERTED=$INS"; fi

# ---------------- V4: 头部 16 字节 + 尺寸 ----------------
say ""
say "== V4 headers =="
for f in "$POL" rt.pol new.pol; do
	say "V4 $f size=$(stat -c %s "$f") first16=$(od -An -tx1 -N16 "$f" | tr -s ' ' | sed 's/^ //')"
done

# ---------------- V5: arm64 libsepol.a 有没有 ----------------
say ""
say "== V5 arm64 libsepol.a =="
ARCHIVES=$(for p in "$ORIG_LIBSEPOL" $(find "$HOME" -maxdepth 7 -name 'libsepol.a' 2>/dev/null); do echo "$p"; done | sort -u)
ARMYES=""
for p in $ARCHIVES; do
	a=$(arch_of "$p")
	say "V5 archive=$p arch=$a size=$(stat -c %s "$p" 2>/dev/null)"
	[ "$a" = aarch64 ] && ARMYES="$ARMYES $p"
done
say "V5 ARM64_LIBSEPOL_A=${ARMYES:- NONE}"
say "V5 cross_gcc=$(command -v aarch64-linux-gnu-gcc || echo ABSENT)"
say "V5 note=arm64 archive is PRESENT (that is what the phone-side static link needs); the arm64 tool binary was NOT built in this run — that is the later step"

# ---------------- V6: 两条有牙的负对照 ----------------
say ""
say "== V6 negative controls =="
printf 'allow shell_zzz_bogus self:capability { chown };\n' > neg_bogus_type.txt
printf 'allow shell self:capability { chown_zzz_bogus };\n' > neg_bogus_perm.txt
printf 'dontaudit shell self:capability { chown };\n' > neg_not_allow.txt
for n in neg_bogus_type neg_bogus_perm neg_not_allow; do
	$T delta "$POL" "$n.pol" "$n.txt" > "$n.out" 2>&1
	rc=$?
	why=$(grep -m1 '^ERROR:' "$n.out" | cut -c1-150)
	say "V6 $n rc=$rc reason='$why'"
	if [ $rc -eq 0 ]; then fail "V6 $n exited 0 — the gate has no teeth"; fi
	if [ -z "$why" ]; then fail "V6 $n gave no reason on stderr"; fi
done
# 正对照：合法规则必须过（否则负对照的"红"不值钱）
$T delta "$POL" pos.pol rules.txt > pos.out 2>&1
PRC=$?
say "V6 positive_control rc=$PRC (must be 0)"
[ $PRC -eq 0 ] || fail "V6 positive control failed — the tool rejects the legal rules too"

# ---------------- 结论 ----------------
say ""
if [ $FAIL -eq 0 ]; then
	say "VERDICT=PASS  offline differential dump proves: new.pol = vendor ALLOW set + exactly the 3 rules, nothing removed or weakened"
else
	say "VERDICT=FAIL  failures=$FAIL"
fi
say "COUNTS V1_DUMP_NODES=$DUMP_NODES RT_ADDED=$RT_ADDED RT_REMOVED=$RT_REMOVED DELTA_ADDED=$DELTA_ADDED DELTA_REMOVED=$DELTA_REMOVED INSERTED=$INS MERGED=$MRG RULES_IN_FILE=$RIF"
say "ARTIFACTS pol.live_1027 md5=$ACT_MD5 size=$ACT_SIZE | rt.pol md5=$(md5sum rt.pol | cut -c1-32) size=$RT_SIZE | new.pol md5=$NEW_MD5 size=$NEW_SIZE"
say "ARTIFACT_MD5 A.txt=$(md5sum A.txt | cut -c1-32) B.txt=$(md5sum B.txt | cut -c1-32) C.txt=$(md5sum C.txt | cut -c1-32)"
cat "$V"
