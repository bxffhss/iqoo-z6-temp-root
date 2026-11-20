#!/bin/bash
# w1162_remote.sh —— 构建机侧(0 枪，不碰设备)：把 **rc76 候选桩(解码＋账＋装载门)** 编进出货同一条流水线，
#   并证明"这次只动了那几个变量"。
# 为什么仍要 stage A：候选件必须与**出货那份**可比，而"我记得树现在是 rc74c 状态"不是证人(§296/§297)。
#   先原样跑 `ksu_rc74c.sh`，把它的产物 md5 与本地包装送上来的**出货 ko 现读值**对表；不等就停手。
# stage B 动的东西(逐条带回执，全部可数)：
#   (1) `kernel/selinux/dropped_stub.c` ← rc76 候选；三个头放进同目录(引号 include 就近解析)
#   (2) `kernel/main.c`(按内容找 module_exit)函数体首行插 `extern void ksu_sepol_put(void); ksu_sepol_put();`
#   ★这一版的**新风险**是"就近 include 撞名"：桩里 `#include "security.h"` 必须命中**树里 SS 那份**
#     (security/selinux/include/security.h，11-06 现读：原型 :198/:200、struct selinux_state :100)，
#     而不是 kernel/selinux/ 下的同名件(现读＝不存在)。所以 B 之前先把这条前提再数一次。
# 判据全部以 A 为参照(未定义符号增量、新符号来源、__param 段、cfi、modinfo、rodata 串)。
set -u
KSU=/root/k/ksu
M=$KSU/kernel
KDIR=/root/k/nothing_sm7325_v_mr
LOGA=/home/lucy/w1162_A.log
LOGB=/home/lucy/w1162_B.log
SHIPPED_MD5_WANT=$(tr -d '\r\n' < /home/lucy/w1162_shipmd5.txt 2>/dev/null)
cd /home/lucy || exit 1

for f in ksu_rc74c.sh w1162_stub.c w1162_core.h w1162_record.h w1162_gate.h w1162_shipmd5.txt w1162_stubmd5.txt; do
  [ -s "/home/lucy/$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
[ -n "$SHIPPED_MD5_WANT" ] || { echo "!! 没给出货 ko 的现读 md5 ⇒ 没法证明可比性，停"; exit 1; }
for f in ksu_rc74c.sh w1162_stub.c w1162_core.h w1162_record.h w1162_gate.h w1162_shipmd5.txt w1162_stubmd5.txt; do
  echo "MD5_$f=$(md5sum /home/lucy/$f | cut -d' ' -f1)"
done
echo "SHIPPED_MD5_WANT=$SHIPPED_MD5_WANT"
[ -d "$KDIR" ] || { echo "!! 内核树不在：$KDIR"; exit 1; }
[ -f "$M/selinux/dropped_stub.c" ] || { echo "!! 现役桩不在预期路径 ⇒ 停(别猜树的结构)"; exit 1; }

echo "=== A-0) 撞名前提：kernel/selinux/ 下不许有 security.h(否则 'security.h' 命中的不是 SS 那份) ==="
if [ -e "$M/selinux/security.h" ]; then
  echo "!! [BAD] $M/selinux/security.h 存在 ⇒ 引号 include 会命中它而不是 SS 的 include/security.h，停"
  exit 1
fi
echo "  [ok] kernel/selinux 下没有 security.h"
[ -f "$KDIR/security/selinux/include/security.h" ] || { echo "!! SS 那份 security.h 不在 ⇒ 停"; exit 1; }
echo "  [ok] 要用的是 $(grep -c '' "$KDIR/security/selinux/include/security.h") 行那份"
echo "  DECL_CHECK security_load_policy=$(grep -ac '^int security_load_policy(' "$KDIR/security/selinux/include/security.h")(必须 1)"
echo "  DECL_CHECK security_read_policy=$(grep -ac '^int security_read_policy(' "$KDIR/security/selinux/include/security.h")(必须 1)"

STUB_WANT=$(tr -d '\r\n' < /home/lucy/w1162_stubmd5.txt 2>/dev/null)
NOWSTUB=$(md5sum "$M/selinux/dropped_stub.c" | cut -d' ' -f1)
echo "  树里现役桩=$NOWSTUB 期望=$STUB_WANT"
if [ -n "$STUB_WANT" ] && [ "$NOWSTUB" != "$STUB_WANT" ]; then
  BKP=$(md5sum /home/lucy/w1162_stub_pristine.c 2>/dev/null | cut -d' ' -f1)
  if [ "$BKP" = "$STUB_WANT" ]; then
    cp /home/lucy/w1162_stub_pristine.c "$M/selinux/dropped_stub.c"
    echo "  [ok] 树里那枚是上一次中途留下的 ⇒ 已用备份还原成出货那份"
    NOWSTUB=$(md5sum "$M/selinux/dropped_stub.c" | cut -d' ' -f1)
  else
    echo "!! 现役桩与出货那份不符，备份也不符(备份=${BKP:-无}) ⇒ 停：树的来源不可知"; exit 1
  fi
fi
cp "$M/selinux/dropped_stub.c" /home/lucy/w1162_stub_pristine.c
echo "  现役桩(出货那份)md5=$(md5sum "$M/selinux/dropped_stub.c" | cut -d' ' -f1)"

echo; echo "=== A1) 前置清点：流水线读的参照件在不在(不在就别烧一轮编译) ==="
REQ="/home/lucy/kernelsu_rc73.ko /home/lucy/ksu_dev_syms_rc73.c /home/lucy/sh_hook_w372.c /home/lucy/shm_rc73.c /home/lucy/ksu_compat54.h /home/lucy/kshim /root/k/nothing_sm7325_v_mr/Module.symvers /home/lucy/w1162_stubmd5.txt"
MISSCNT=0
for f in $REQ; do
  if [ -d "$f" ]; then echo "  [ok] $f (目录，条目 $(ls "$f" 2>/dev/null | grep -c . ))";
  elif [ -e "$f" ]; then echo "  [ok] $f ($(wc -c <"$f" | tr -dc '0-9') B)";
  else echo "  [x] 缺参照件：$f"; MISSCNT=$((MISSCNT+1)); fi
done
for f in /home/lucy/patch_ksu_*.py; do [ -e "$f" ] || { echo "  [x] 缺补丁件：$f"; MISSCNT=$((MISSCNT+1)); }; done
echo "  REQUIRED_MISSING=$MISSCNT(必须 0)"
[ "$MISSCNT" = 0 ] || { echo "!! 环境不齐 ⇒ 停"; exit 1; }

echo; echo "=== A) 原样重跑出货流水线(全量重编) ==="
bash /home/lucy/ksu_rc74c.sh > "$LOGA" 2>&1; RCA=$?
echo "RC74C_RC=$RCA (0=流水线本身跑完；产物对表才是真证人)"
A_KO=/home/lucy/kernelsu_rc74c.ko
[ -s "$A_KO" ] || { echo "!! A 阶段没产出 $A_KO ⇒ 停"; tail -20 "$LOGA"; exit 1; }
A_MD5=$(md5sum "$A_KO" | cut -d' ' -f1)
echo "MD5_A=$A_MD5"
[ "$A_MD5" = "$SHIPPED_MD5_WANT" ] || { echo "!! 红灯：A 阶段产物 ≠ 出货那份 ⇒ 环境漂了，B 出来的不能叫候选，停"; exit 1; }
echo "  ★可比性成立：A＝出货那份逐字节相同 ⇒ 下面只动桩与收尾那一行"
AWARN=$(grep -ac 'warning:' "$LOGA"); AERR=$(grep -ac ' error: ' "$LOGA")
echo "A_LOG warn=$AWARN err=$AERR"
/usr/bin/llvm-nm "$A_KO" | awk '$1=="U"{print $2}' | sort -u > /tmp/undA.txt
/usr/bin/llvm-nm "$A_KO" | awk '{print $NF}' | sort -u > /tmp/symA.txt
echo "A_UND=$(wc -l < /tmp/undA.txt)"
PVH_A=$( /usr/bin/llvm-objdump -h "$A_KO" | awk '$2=="__param"{print $3}' )
echo "A_PARAM_HEX=$PVH_A"

MC=""
PATCHED_MC=0
restore_tree() {
  [ -n "${RESTORED:-}" ] && return 0
  RESTORED=1
  [ -s /home/lucy/w1162_stub_pristine.c ] && cp /home/lucy/w1162_stub_pristine.c "$M/selinux/dropped_stub.c" 2>/dev/null
  rm -f "$M/selinux/w1151_sepolicy_core.h" "$M/selinux/w1155_sepol_record.h" "$M/selinux/w1161_polgate.h" 2>/dev/null
  [ "$PATCHED_MC" = 1 ] && [ -n "$MC" ] && sed -i '/extern void ksu_sepol_put(void); ksu_sepol_put();/d' "$MC" 2>/dev/null
}
# ★"还原"与"证明还原"必须同源(#139 那条纪律)：三条回执只有这一个生产者，成功路径和失败路径都调它。
#   上一版的红就是这么来的：B 编译不过 ⇒ 那三行**根本没打印** ⇒ 包装把"没有那行"读成三条 [BAD]，
#   把一次编译失败说成了"树没还原"。而现查证明树是干净的。
report_tree() {
  echo "  桩还原 md5=$(md5sum "$M/selinux/dropped_stub.c" 2>/dev/null | cut -d' ' -f1)(期望 $STUB_WANT)"
  if [ -n "$MC" ]; then
    echo "  main.c 里 ksu_sepol_put 计数还原后=$(grep -ac 'ksu_sepol_put' "$MC")(必须 0)"
  else
    echo "  main.c 里 ksu_sepol_put 计数还原后=未到达(改动没走到那一步，不是 0)"
  fi
  echo "  头的残留计数=$(ls "$M/selinux/" 2>/dev/null | grep -cE 'w1151_|w1155_|w1161_')(必须 0)"
}
trap restore_tree EXIT

echo; echo "=== B) 换上 rc76 候选桩 ==="
cp /home/lucy/w1162_stub.c "$M/selinux/dropped_stub.c"
cp /home/lucy/w1162_core.h "$M/selinux/w1151_sepolicy_core.h"
cp /home/lucy/w1162_record.h "$M/selinux/w1155_sepol_record.h"
cp /home/lucy/w1162_gate.h "$M/selinux/w1161_polgate.h"
echo "  桩落盘 md5=$(md5sum "$M/selinux/dropped_stub.c" | cut -d' ' -f1)"
# ★回执必须**锚在代码行首**，不是 `grep -qF` 数文本：上一版那句撞上文件头注释里那句散文就放行了，
#   而代码里根本没有那行 ⇒ 真相反到 B 阶段编译才说(11-07)。这里先数，编都不用编。
INCNT=0
for ere in '^#include "selinux\.h"' '^#include "security\.h"' '^#include "w1151_sepolicy_core\.h"' \
           '^#include "w1155_sepol_record\.h"' '^#include "w1161_polgate\.h"'; do
  n=$(grep -acE "$ere" "$M/selinux/dropped_stub.c")
  echo "  回执 $ere 代码行=$n(必须 1)"
  [ "$n" = 1 ] || { echo "!! [$ere] 没在代码里(注释里说过不算) ⇒ 停，别烧编译"; INCNT=$((INCNT+1)); }
done
[ "$INCNT" = 0 ] || exit 1
for h in w1151_sepolicy_core.h:w1162_core.h w1155_sepol_record.h:w1162_record.h w1161_polgate.h:w1162_gate.h; do
  d=${h%%:*}; s=${h##*:}
  [ "$(md5sum "$M/selinux/$d" | cut -d' ' -f1)" = "$(md5sum /home/lucy/$s | cut -d' ' -f1)" ] || { echo "!! 头 $d 没忠实落到树里(源=$s)"; exit 1; }
  echo "  [ok] 落盘头 $d ← $s"
done

MAP=( $(grep -rl 'module_exit(' "$M" --include='*.c' 2>/dev/null) )
[ "${#MAP[@]}" = 1 ] || { echo "!! module_exit 出现在 ${#MAP[@]} 处(应为 1) ⇒ 停：[${MAP[*]}]"; exit 1; }
MC=${MAP[0]}
echo "  收尾文件=$MC"
EXF=$(grep -o 'module_exit([A-Za-z_0-9]*)' "$MC" | head -1 | sed 's/module_exit(\(.*\))/\1/')
[ -n "$EXF" ] || { echo "!! 找不到 module_exit 的函数名 ⇒ 停(不接收尾＝泄漏)"; exit 1; }
echo "  退出函数=$EXF"
occ() { grep -ao 'ksu_sepol_put' "$1" 2>/dev/null | wc -l | tr -dc '0-9'; }
BEFORE=$(occ "$MC")
awk -v fn="$EXF" 'BEGIN{ins=0}
  { print }
  ins==0 && $0 ~ ("__exit " fn "\\(") { gotfn=1 }
  ins==0 && gotfn==1 && $0 ~ /^\{/ { print "\textern void ksu_sepol_put(void); ksu_sepol_put();"; ins=1 }
' "$MC" > /tmp/main_new.c
grep -q 'ksu_sepol_put();' /tmp/main_new.c || { echo "!! 插入没落地(函数体形状与预期不符) ⇒ 停"; exit 1; }
cp /tmp/main_new.c "$MC"
PATCHED_MC=1
AFTER=$(occ "$MC")
echo "  收尾文件里 ksu_sepol_put 出现次数：$BEFORE→$AFTER(必须 0→2)"
[ "$BEFORE" = 0 ] && [ "$AFTER" = 2 ] || { echo "!! 计数不对 ⇒ 这条改动没被证明，停"; exit 1; }

find "$M" -name '*.o' -delete
rm -f "$M/kernelsu.ko" 2>/dev/null
cd "$M" || exit 1
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  KSU_EXPECTED_SIZE2=0x2c1 \
  KSU_EXPECTED_HASH2=11c42292f3cce107eb5499002948c689b19493b47032d4532e29a618395d4063 \
  KSU_VERSION_OVERRIDE=32601 \
  modules -j32 > "$LOGB" 2>&1
RCB=$?
echo "MAKE_B_RC=$RCB"
BERR=$(grep -ac ' error: ' "$LOGB"); BWARN=$(grep -ac 'warning:' "$LOGB")
echo "B_LOG err=$BERR warn=$BWARN (A 是 warn=$AWARN)"
grep -E ' error: ' "$LOGB" | head -14 | sed 's/^/  cc: /'
grep -E 'warning: ' "$LOGB" | head -8 | sed 's/^/  W: /'
[ "$RCB" = 0 ] || { echo "!! B 没编出来 ⇒ **这就是答案**(装载面在这棵树的头下编不过)。判据那一段没跑，不许拿「没有那一行」当失败 ⇒ 三条还原回执现在打出来："; restore_tree; report_tree; echo "VERDICT=nocompile 编译未过：尺未测(未装设备、未进包)，树已还原"; exit 0; }
[ "$BERR" = 0 ] || { echo "!! rc=0 却有 error 计数 ⇒ 读法不一致，停"; exit 1; }
B_KO="$M/kernelsu.ko"
[ -s "$B_KO" ] || { echo "!! 没产物"; exit 1; }

echo; echo "=== 判据(全部以 A 为参照) ==="
BAD=0
[ "$BWARN" -le "$AWARN" ] && echo "[ok] warning 没比 A 多(A=$AWARN B=$BWARN)" || { echo "[BAD] B 多了 warning"; BAD=1; }
/usr/bin/llvm-nm "$B_KO" | awk '$1=="U"{print $2}' | sort -u > /tmp/undB.txt
ADD=$(comm -13 /tmp/undA.txt /tmp/undB.txt); DEL=$(comm -23 /tmp/undA.txt /tmp/undB.txt)
echo "  未定义增量(只许多不许少)：[$(echo "$ADD" | tr '\n' ' ')]  少了：[$(echo "$DEL" | tr '\n' ' ')]"
[ -z "$DEL" ] || { echo "[BAD] 候选比出货少了未定义符号 ⇒ 不是单变量"; BAD=1; }
MISS=0
# ★尺①(11-07 修)：`Module.symvers` 的格式是 `<CRC>\t<符号>\t<模块>\t<类型>` ⇒ 上一版的 `grep "^$s"`
#   永远命不中(符号不在行首)。这是 w1158 就已经记过的一次"读法坏被读成数据坏"，我从 w1156 抄尺时又抄回来了。
awk '{print $2}' "$KDIR/Module.symvers" | sort -u > /tmp/w1162_sym.txt
NSYM=$(wc -l < /tmp/w1162_sym.txt)
echo "  SYMVERS_NAMES=$NSYM(必须 >7000 才像一份全表)"
[ "$NSYM" -gt 7000 ] || { echo "[BAD] symvers 只读出 $NSYM 个名字 ⇒ 读法坏(不是数据坏)"; BAD=1; }
# 正对照：`vfree` 一定在这份表里；查不到就是这把尺坏了，不是候选坏了。
awk 'BEGIN{f=0} $1=="vfree"{f=1} END{exit !f}' /tmp/w1162_sym.txt \
  && echo "  [ok] 正对照：vfree 查得到(这把尺通)" || { echo "[BAD] 正对照失守：连 vfree 都查不到 ⇒ 读法坏"; BAD=1; }
# 反夹具 + 夹具自证：三条必须同形(同一个 `exit !f`)，缺 `!` 会让它恒红(w1163 一手)。
awk 'BEGIN{f=0} $1=="w1162_bogus_sym"{f=1} END{exit !f}' /tmp/w1162_sym.txt \
  && { echo "[BAD] 反夹具失守：不存在的符号被查到"; BAD=1; } || echo "  [ok] 反夹具：w1162_bogus_sym 查不到"
awk 'BEGIN{f=0} $1=="vfree"{f=1} END{exit !f}' /tmp/w1162_sym.txt \
  || { echo "[BAD] 反夹具本身是空的(真符号也不报红) ⇒ 它那条'查不到'不算证据"; BAD=1; }
for s in $ADD; do
  grep -qxF "$s" /tmp/w1162_sym.txt || { echo "  [x] 新增未定义符号 [$s] **不在** Module.symvers ⇒ 装载期会缺符号"; MISS=1; }
done
[ "$MISS" = 0 ] && echo "[ok] 新增未定义符号逐条已在 Module.symvers 里导出(不靠 kallsyms)" || { echo "[BAD] 有新增符号没导出"; BAD=1; }
# ★正对照( tied to 代码，不 tied to 我记的条数)：新代码必然引进这两个进口符号，不在 ⇒ 装载面没链进来
for s in simple_read_from_buffer kstrtoull; do
  echo "$ADD" | grep -qxF "$s" && echo "  [ok] 新代码的进口符号 [$s] 确实新增" || { echo "[BAD] ADD 里没有 [$s] ⇒ 装载面没被链进来"; BAD=1; }
done
SS=$(echo "$ADD" | grep -cE '^(security_|selinux_|policydb|avc_|ss_)')
[ "$SS" = 0 ] && echo "[ok] SS/security_* 外流=0(装载面是靠 kallsyms 找函数，不是靠链接期引用)" || { echo "[BAD] SS 符号外流=$SS"; BAD=1; }
# ★这一版新加的牙：装载那三个名字必须**只**出现在 kallsyms 路线上，链接期一个都不许要
KLBAD=0
for s in security_load_policy security_read_policy selinux_state; do
  grep -qxF "$s" /tmp/undB.txt && { echo "[BAD] 产物在链接期就要 [$s] ⇒ 我写成了直接引用，KCFI/导出两面都会翻"; KLBAD=1; BAD=1; }
done
[ "$KLBAD" = 0 ] && echo "[ok] 装载面三个名字都没进未定义表(都走 ld_sym_addr)"
/usr/bin/llvm-nm "$B_KO" | grep -ac '__cfi_check' > /tmp/x.txt
CFI=$(/usr/bin/llvm-nm "$B_KO" | grep -ac '__cfi_check')
echo "  __cfi_check=$CFI(必须 1)"; [ "$CFI" = 1 ] || { echo "[BAD] cfi 桩形状变了"; BAD=1; }
MI2=/tmp/w1162_mi.txt
/usr/bin/llvm-readelf --string-dump=.modinfo "$B_KO" 2>/dev/null | sed -E "s/^\[[ ]*[0-9a-f]+\] //" |
  tail -n +2 | sort > "$MI2"
TOTAL_LINES=$(wc -l < "$MI2")
echo "  MODINFO_LINES=$TOTAL_LINES(必须 >0 ⇒ 先证读段这条路是通的)"
[ "$TOTAL_LINES" -gt 0 ] || { echo "[BAD] .modinfo 读出来是空的 ⇒ 读法坏，不是数据坏"; BAD=1; }
MODI=$(cat "$MI2")
PSp=$(grep -ac '^parmtype=sp_' <<<"$MODI")
PLd=$(grep -ac '^parmtype=ld_' <<<"$MODI")
# ★尺②(11-07 修)：`module_param_cb(sp_arm,…)` 在这台机的 modinfo 里**两类条目都不写**(w1158 一手：
#   parmtype=sp_ 13 条、parm=sp_ 0 条)。上一版写"≥14"是把 `sp_arm` 也算进来了 ⇒ 恒红的一把我自己写坏的尺。
#   `sp_arm` 的真证人不在 modinfo：代码里那句 `module_param_cb` ＋ 运行期 `/proc/ksu_sepol` 在不在。
echo "  parmtype=sp_* 条数=$PSp(按 w1158 一手＝13，逐条点名在下面)  parmtype=ld_* 条数=$PLd(必须 ≥18)"
NSP=0
for p in sp_verbose:uint sp_calls:uint sp_seq:uint sp_why:int sp_n:int sp_bytes:long sp_bad_at:long \
         sp_max_arg:uint sp_rc:int sp_lenmatch:int sp_rec_bytes:int sp_rec_trunc:int sp_sum:ulong; do
  grep -qxF "parmtype=$p" <<<"$MODI" && NSP=$((NSP+1)) || { echo "[BAD] .modinfo 少了 parmtype=$p"; BAD=1; }
done
echo "  解码面逐条点名 13 条：命中 $NSP"
[ "$NSP" = 13 ] || BAD=1
[ "$PLd" -ge 18 ] || { echo "[BAD] 装载面的 18 个读数参数没全进 .modinfo ⇒ 上机就没有读回口"; BAD=1; }
for k in parmtype=ld_key:uint parmtype=ld_cap:uint parmtype=ld_why:int parmtype=ld_load_rc:int parmtype=ld_armed:int parmtype=ld_arm_live:ulong parmtype=ld_pre_sum:ulong parmtype=ld_post_len:long; do
  grep -qxF "$k" <<<"$MODI" || { echo "[BAD] .modinfo 少了 [$k]"; BAD=1; }
done
grep -qxF "parmtype=ld_bogus:uint" <<<"$MODI" && { echo "[BAD] 反夹具失守：不存在的参数被数出来了"; BAD=1; } || echo "  [ok] 反夹具：parmtype=ld_bogus:uint 查不到"
grep -qxF "parmtype=sp_bogus:uint" <<<"$MODI" && { echo "[BAD] 反夹具失守：不存在的参数被数出来了"; BAD=1; } || echo "  [ok] 反夹具：parmtype=sp_bogus:uint 查不到"
if grep -q '^parm=sp_arm' <<<"$MODI" || grep -q 'parmtype=sp_arm' <<<"$MODI"; then
  echo "  [note] sp_arm 在 modinfo 里有条目(比 w1158 那次一手读数多，仍算通)"
else
  echo "  [ok] sp_arm 走 module_param_cb ⇒ 这台机的 modinfo 不写它的条目(w1158 一手)，不在这把尺上"
fi
CBN=$(grep -ac 'module_param_cb(sp_arm' "$M/selinux/dropped_stub.c" 2>/dev/null)
echo "  代码侧证人(还原前现读)：树里那句 module_param_cb(sp_arm…) 计数=$CBN(必须 1)"
[ "$CBN" = 1 ] || { echo "[BAD] 代码里没有那句 cb ⇒ sp_arm 的参数口不成立"; BAD=1; }
strings -a "$B_KO" > /tmp/strB.txt
for s in ksu_sepol "REC seq=" "STMT " "ksu_sepol_img" "ksu_sepol_ctl" "RESET" "ARM " "kallsyms_lookup_name" "selinux_state" "security_load_policy" "security_read_policy"; do
  C=$(grep -ac -- "$s" /tmp/strB.txt); echo "  串 [$s]=$C(必须 ≥1)"; [ "$C" -ge 1 ] || { echo "[BAD] 少串 [$s] ⇒ 那段代码没被链进来"; BAD=1; }
done
PVH_B=$( /usr/bin/llvm-objdump -h "$B_KO" | awk '$2=="__param"{print $3}' )
echo "  __param 段 A=$PVH_A B=$PVH_B(必须严格变大)"
[ "$((16#$PVH_B))" -gt "$((16#$PVH_A))" ] || { echo "[BAD] __param 没长大 ⇒ 新参数没进产物"; BAD=1; }
/usr/bin/llvm-nm "$B_KO" | awk '{print $NF}' | sort -u > /tmp/symB.txt
NEW=$(comm -13 /tmp/symA.txt /tmp/symB.txt); GONE=$(comm -23 /tmp/symA.txt /tmp/symB.txt)
echo "  新符号 $(echo "$NEW" | grep -ac .) 条；少了 $(echo "$GONE" | grep -ac .) 条(必须 0)"
[ -z "$GONE" ] || { echo "[BAD] 候选比出货少了符号 ⇒ 不止加了代码"; BAD=1; }
# ★尺③(11-07 修，两半)：① 先把**新增的未定义进口符号**(ADD)摘掉——它们当然在"新符号"里(A 没用到
#   vmalloc，表里自然没有)，拿"我自己的前缀"去过滤它们必然漏 ⇒ 上一版那 9 条被判成"认不出来源"。
#   ② `module_param(ld_key,…)` 展开出的键名是 `__param_str_ld_key`／`__UNIQUE_ID_ld_key17`，
#   上一版的 `__param_(sp|str_sp|ld)` 少了 `str_ld` 那一支 ⇒ 27 条假红。
echo "$ADD" | grep -a . | sort > /tmp/w1162_add.txt
STRLIST=$(comm -23 <(echo "$NEW" | grep -a . | sort) /tmp/w1162_add.txt)
PAT='^(sp_|ld_|p_ld_|p_kln|w1161_|w1155_|w1151_|ksu_sepol|handle_sepolicy|apply_kernelsu_rules|__param_(sp|str_sp|ld|str_ld)|__UNIQUE_ID_(sp|str_sp|ld|str_ld)|__cfi_jt_.*|.*dropped_stub.*)'
STRAY=$(echo "$STRLIST" | grep -avE "$PAT" | grep -ac .)
echo "  新符号 $(echo "$NEW" | grep -ac .) 条；其中进口(ADD) $(grep -ac . /tmp/w1162_add.txt) 条；认不出来源的 $STRAY(必须 0)"
[ "$STRAY" = 0 ] || { echo "[BAD] 新符号里有对不上这份新代码的东西"; echo "$STRLIST" | grep -avE "$PAT" | head -8 | sed 's/^/      /'; BAD=1; }
VM_A=$(strings -a "$A_KO" | grep -am1 '^vermagic='); VM_B=$(strings -a "$B_KO" | grep -am1 '^vermagic=')
echo "  vermagic A=[$VM_A] B=[$VM_B]"; [ "$VM_A" = "$VM_B" ] || { echo "[BAD] vermagic 变了 ⇒ 不是同一棵树"; BAD=1; }
MH_A=$(strings -a "$A_KO" | grep -am1 '^name=kernelsu'); MH_B=$(strings -a "$B_KO" | grep -am1 '^name=kernelsu')
[ "$MH_A" = "$MH_B" ] || { echo "[BAD] MODNAME 变了"; BAD=1; }

cp "$B_KO" /home/lucy/w1162_kernelsu_rc76_candidate.ko
echo "MD5_B=$(md5sum /home/lucy/w1162_kernelsu_rc76_candidate.ko | cut -d' ' -f1)"
echo "SIZE_B=$(wc -c < /home/lucy/w1162_kernelsu_rc76_candidate.ko | tr -dc '0-9')"
echo "SIZE_A=$(wc -c < "$A_KO" | tr -dc '0-9')"
echo "B_LOG_PATH=$LOGB"

echo; echo "=== 还原现场 ==="
restore_tree
report_tree

if [ "$BAD" = 0 ]; then
  echo "VERDICT=ok rc76 候选件与出货那份只差『换桩＋接一行收尾』，尺全过(未装设备、未进包)"
else
  echo "VERDICT=bad 见上面 [BAD] 行"
fi
exit 0
