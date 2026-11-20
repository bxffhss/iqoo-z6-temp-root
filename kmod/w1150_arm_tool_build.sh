#!/bin/bash
# #216-A 的那半格（0 枪，只在构建机上）：把离线算图工具 `w1104_delta.c` **交叉编成设备能直接跑的
# aarch64 静态件**，并过一把"这枚件真的能自足运行"的审计。
# ★为什么要这一步：#238 的两条形状（(2) 我们的 agent 开机算图＋ko 装载 / (3) SET_SEPOLICY 只当投递口）
#   都需要"在设备上把规则算成整图"这一能力；离线那份 x86 件已经判正过两次(#232/#233/#234 的底料)，
#   但 x86 件上不了机。
# ★这一支**不声明**"行为等价已证"：构建机上没有 qemu-user(`command -v qemu-aarch64` 空、binfmt 空)⇒
#   同输入产不产出同一张图，只能在设备上跑一次才知道 ⇒ 那一格记**未测**，挂在"下一扇窗顺带跑"
#   （它是纯读写文件：读厂商图＋规则、写一张新图，**不装载、不碰策略** ⇒ 与开枪解耦，不额外烧枪）。
set -u
SRC=${SEPOLSRC:-/home/lucy/sepolsrc/libsepol-3.4}      # 这份是**为 aarch64 预编好**的那棵(libsepol.a arch=aarch64)
ARMCC=$(command -v aarch64-linux-gnu-gcc || echo "")
MAIN=${MAIN:-/home/lucy/w1150_main.c}                  # 主源＝仓库 kmod/w1104_delta.c，由本地包装 put 进来
D=${OUTD:-/home/lucy/w1150_arm}
LOG=$D/build.log
say() { printf '%s\n' "$*"; }
fail() { say "VERDICT=红：$*"; exit 1; }

say "BEGIN $(date)"
say "SRC=$SRC ARMCC=${ARMCC:-ABSENT} MAIN=$MAIN"
[ -n "$ARMCC" ] || fail "没有 aarch64-linux-gnu-gcc ⇒ 交叉编译无从谈起(别拿 x86 件冒充)"
[ -f "$MAIN" ] || fail "主源不在 $MAIN ⇒ 先跑本地包装(别编一份说不出来历的件)"
[ -f "$SRC/src/libsepol.a" ] || fail "没有 $SRC/src/libsepol.a"

# 机器类型用 `readelf -h` 的 Machine 字段。★第一版我用 `file -b | grep -o 'aarch64\|x86-64\|ARM'`
#   ⇒ "ARM aarch64" 里 'ARM' 先命中，把一枚**本来就是 aarch64** 的库判成了红(例 227 那一族，又犯一次)。
#   正对照＝同时读那枚**host(x86-64)** 库：同一把尺必须给出两个不同的值，否则"AArch64"这个读数不值钱。
arch_of_a() {
	local p="$1" m
	m=$(ar p "$p" "$(ar t "$p" 2>/dev/null | head -1)" 2>/dev/null > /tmp/w1150_mem.o; readelf -h /tmp/w1150_mem.o 2>/dev/null | sed -n 's/^ *Machine: *//p')
	[ -n "$m" ] || m=UNKNOWN
	printf '%s' "$m"
}
echo; echo "=== 1) 输入清点（三份各报现值；库的机器类型必须真是 aarch64） ==="
say "MAIN_MD5=$(md5sum "$MAIN" | cut -d' ' -f1)"
say "LIBSEPOL_MD5=$(md5sum "$SRC/src/libsepol.a" | cut -d' ' -f1)  LIBSEPOL_BYTES=$(stat -c %s "$SRC/src/libsepol.a")"
M=$(ar t "$SRC/src/libsepol.a" 2>/dev/null | head -1)
[ -n "$M" ] || fail "ar 打不开 libsepol.a ⇒ 机器类型这格未测，不许过"
ARCH=$(arch_of_a "$SRC/src/libsepol.a")
HOSTLIB=${HOSTLIB:-/home/lucy/w1105_hostlib/libsepol-3.4/src/libsepol.a}
HOSTARCH=ABSENT-HOSTLIB
[ -f "$HOSTLIB" ] && HOSTARCH=$(arch_of_a "$HOSTLIB")
say "TARGET_MEMBER=$M  TARGET_MACHINE=[$ARCH]"
say "CONTROL_HOSTLIB=$HOSTLIB  CONTROL_MACHINE=[$HOSTARCH]  (正对照：必须与目标不同，且不是 UNKNOWN)"
case "$HOSTARCH" in
  UNKNOWN|"ABSENT-HOSTLIB") fail "读不出 host 库的机器类型 ⇒ 这把尺未经正对照，目标的 AArch64 不算证(先把 HOSTLIB 指对)" ;;
esac
[ "$HOSTARCH" != "$ARCH" ] || fail "两枚库读出一个机器类型 ⇒ 尺坏了(或被 put 串了件)，不许继续"
say "ARCH_VERDICT=目标=$ARCH 对照=$HOSTARCH ⇒ 尺有牙"
[ "$ARCH" = AArch64 ] || fail "libsepol.a 不是 AArch64(=$ARCH) ⇒ 链出来的件上不了机"
# 静态 libc：`-static` 需要 aarch64 的 libc.a；缺了就是"看着编过、其实留着动态依赖"
LIBC_A=$(ls /usr/lib/gcc-cross/*/*/libgcc.a /usr/aarch64-linux-gnu/lib/libc.a 2>/dev/null | head -1)
say "LIBC_A=${LIBC_A:-ABSENT}  (判据：ABSENT 就不许用 -static，只能改成'设备侧运行时再解动态库'那条更差的路)"

echo; echo "=== 2) 编（-static 优先；带 warning 计数，不当隐忍） ==="
rm -rf "$D"; mkdir -p "$D"
CC_STATIC=0
if [ -n "$LIBC_A" ]; then
	CC_STATIC=1
	"$ARMCC" -O2 -Wall -Wextra -Wno-unused-parameter -static -I"$SRC/include" -I"$SRC/src" \
		-o "$D/z6delta" "$MAIN" "$SRC/src/libsepol.a" > "$LOG" 2>&1
else
	"$ARMCC" -O2 -Wall -Wextra -Wno-unused-parameter -I"$SRC/include" -I"$SRC/src" \
		-o "$D/z6delta" "$MAIN" "$SRC/src/libsepol.a" > "$LOG" 2>&1
fi
RC=$?
say "MAKE_RC=$RC CC_STATIC=$CC_STATIC"
say "DIAG_ERR=$(grep -cE ': error: ' "$LOG")  DIAG_WARN=$(grep -cE ': warning: ' "$LOG")"
grep -E ': error: ' "$LOG" | sed 's/^.* error: /ERR: /' | sort -u | head -12
grep -E ': warning: ' "$LOG" | sed 's/^.* warning: /WARN: /' | sort -u | head -8
[ "$RC" = 0 ] || { tail -25 "$LOG"; fail "编译不过"; }
[ "$(grep -cE ': error: ' "$LOG")" = 0 ] || fail "有 error 却 RC=0？读法有问题，别过"
[ -s "$D/z6delta" ] || fail "产物是空的"

echo; echo "=== 3) 审计四把（每一把都配'它能非空出现'的正／反对照） ==="
FILE=$(file -b "$D/z6delta")
say "FILE=[$FILE]"
echo "$FILE" | grep -qi 'ARM aarch64' || fail "产物不是 aarch64 ⇒ 上不了机"
echo "$FILE" | grep -qi 'statically linked' || say "[!] 没有 statically linked 字样 ⇒ 设备上没有 glibc，动态件必跑不起来(这一格记未测/或改 -static 再编)"

NMU=$(nm -u "$D/z6delta" 2>/dev/null | wc -l)
say "UNDEF_STATIC=$NMU  (判据：静态件应=0)"
# ★正对照（没有它，"0 个未定义"可能只是 nm 没跑成）：同一件**去掉 -static 再链一次**，那张表必须非空。
POS=""
if [ "$CC_STATIC" = 1 ]; then
	"$ARMCC" -O2 -w -I"$SRC/include" -I"$SRC/src" -o "$D/z6delta_dyn" "$MAIN" "$SRC/src/libsepol.a" >> "$LOG" 2>&1
	POS=$(nm -u "$D/z6delta_dyn" 2>/dev/null | wc -l)
fi
say "UNDEF_DYNAMIC=$POS  (正对照：>0 才说明'数未定义符'这把尺有牙；=0 或空⇒尺坏了)"
if [ -n "$POS" ] && [ "$POS" = 0 ]; then fail "动态版也未定义=0 ⇒ 这把尺没牙，静态那格的 0 不算数"; fi
if [ "$CC_STATIC" = 1 ] && [ -z "$POS" ]; then fail "没能编出动态对照件 ⇒ 静态那格的 0 不算数(尺未经正对照)"; fi
[ "$NMU" = 0 ] || { nm -u "$D/z6delta" | head -10; fail "静态件仍有未定义符 ⇒ 设备上跑不起来"; }

# ★第三把：件里必须真有主源的形状(有 main、有那句给负对照用的 `ERROR:` 前缀)。
#   (原来我想数 "usage" 字样——但主源本来不打 usage，那会把"链对了"读成"尺没牙"。)
HASMAIN=$(nm "$D/z6delta" 2>/dev/null | grep -cw main)
ERRS=$(strings -a "$D/z6delta" | grep -c 'ERROR:')
say "HAS_MAIN=$HASMAIN  ERR_PREFIX_STRINGS=$ERRS  (判据：两个都 >0；=0 先怀疑 nm/strings 没跑成，不许当通过)"
[ "$HASMAIN" -gt 0 ] || fail "件里没有 main ⇒ 链的不是这份主源(或 nm 坏了)"
[ "$ERRS" -gt 0 ] || fail "件里数不到 ERROR: 前缀 ⇒ 主源没进去或被裁掉了，这一枚不能当设备侧算图工具"

echo; echo "=== 4) 交件（名字带机器类型，供本地 get 用相对名） ==="
cp "$D/z6delta" /home/lucy/z6delta_arm64 || fail "复制产物失败 ⇒ 本地取不到件"
say "KO_COPY=/home/lucy/z6delta_arm64"
say "ARM_TOOL_MD5=$(md5sum /home/lucy/z6delta_arm64 | cut -d' ' -f1)  ARM_TOOL_BYTES=$(stat -c %s /home/lucy/z6delta_arm64)"
say "STILL_UNTESTED=行为等价(同输入产不产出与 x86 件那张 1357091B/md5 7e3c2557… 相同的图)——构建机无 qemu-user，只能等设备上跑一次；那一格现在记**未测**"
say "VERDICT=ok(交叉链通、静态自足、三把尺各有正对照；行为等价仍未证)"
echo "END $(date)"
