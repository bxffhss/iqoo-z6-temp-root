#!/bin/bash
# w1163_verify.sh —— 构建机侧(0 编译、0 枪、不碰设备)：把 w1162 已经编好的那两枚 ko **重新量一遍**，
#   只修三把我自己写坏的尺(都不涉及被测)。为什么不重跑 w1162：编译是 10 分钟的事，量是 5 秒的事，
#   而"候选件"就是那枚字节，换了尺不该重新定义被测(#240 那次同样的处置：判据在 w1158_verify_v3)。
# 尺① `Module.symvers` 的格式是 `<CRC>\t<符号>\t<模块>\t<类型>` ⇒ `grep "^$s"` **永远命不中**(符号不在行首)。
#     w1158 的注释里就写着这条，我这次却从 w1156 那版抄了旧尺 ⇒ 九条内核导出的进口符号被判成"没导出"。
#     ⇒ 按第二字段等值查；先印一条**一定在的**(vfree)当正对照、一条**一定不在的**当反夹具。
# 尺② `module_param_cb(sp_arm)` 在这台机的 modinfo 里**两类条目都不写**(w1158 一手) ⇒ "≥14 条 parmtype=sp_"
#     是一条会恒红的错期望(13 才是对的)；改成了"逐条点名 13＋18，cb 那一支另走信道"。
# 尺③ "认不出来源的新符号"必须先把**新增的未定义引用**(ADD)从 NEW 里摘掉，且前缀表要认得出这一版新加的
#     `ld_*` / `__param_str_ld_*` / `__UNIQUE_ID_ld_*`；上一版没摘 ADD 又漏了 ld 前缀 ⇒ 27 条假红。
set -u
A=/home/lucy/kernelsu_rc74c.ko
B=/home/lucy/w1162_kernelsu_rc76_candidate.ko
KDIR=/root/k/nothing_sm7325_v_mr
# ★两个参照值都是**这一跑现读**的(不是记忆)：A 来自 w1162_run.sh 跑前对出货 ko 的 md5sum，
#   B 来自 w1162_rc76_v2.txt 里那行 MD5_B(远端算的)，包装两端对过表并取回了本地同值。
A_WANT=324eda4dcb5d41ecb6763a5192ea9c31
B_WANT=6b59fc859290a826921db6a014478a15
NM=/usr/bin/llvm-nm
RE=/usr/bin/llvm-readelf
OD=/usr/bin/llvm-objdump

for f in "$A" "$B" "$KDIR/Module.symvers"; do
  [ -s "$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
MA=$(md5sum "$A" | cut -d' ' -f1); MB=$(md5sum "$B" | cut -d' ' -f1)
echo "MD5_A=$MA"
echo "MD5_B=$MB"
BAD=0
[ "$MA" = "$A_WANT" ] || { echo "[BAD] A 不是出货那枚(期望 $A_WANT) ⇒ 环境漂了，B 不能叫候选"; BAD=1; }
[ "$MB" = "$B_WANT" ] || { echo "[BAD] B 不是这一跑编出来的候选件(期望 $B_WANT) ⇒ 量的不是被测"; BAD=1; }
[ "$MA" != "$MB" ] || { echo "[BAD] A＝B ⇒ 这条流水线根本没产出新东西"; BAD=1; }

echo; echo "=== 尺①：未定义增量逐条查 Module.symvers(按**第二字段**，不是行首) ==="
$NM "$A" | awk '$1=="U"{print $2}' | sort -u > /tmp/w1163_vA.txt
$NM "$B" | awk '$1=="U"{print $2}' | sort -u > /tmp/w1163_vB.txt
awk '{print $2}' "$KDIR/Module.symvers" | sort -u > /tmp/w1163_sym.txt
NSYM=$(wc -l < /tmp/w1163_sym.txt)
echo "  SYMVERS_NAMES=$NSYM"
[ "$NSYM" -gt 7000 ] || { echo "[BAD] symvers 只读出 $NSYM 个名字 ⇒ 读法坏(全表该有七千以上)，不是数据坏"; BAD=1; }
awk 'BEGIN{f=0} $1=="vfree"{f=1} END{exit !f}' /tmp/w1163_sym.txt \
  && echo "  [ok] 正对照：vfree 查得到(这把尺通)" || { echo "[BAD] 正对照失守：连 vfree 都查不到 ⇒ 读法坏"; BAD=1; }
# ★这条自己就是新的一条仪器红(11-07 现量)：反夹具我写成 `END{exit f}` —— 查不到时 f=0 ⇒ awk **返回 0(真)**
#   ⇒ 打印"反夹具失守"。awk 的退出码与布尔"找到了"是反的，正对照那行写了 `exit !f` 才对，抄漏了 `!`。
#   ⇒ 规矩：**夹具与正对照必须成对同形**(同一个 `exit !f`)，否则恒红的是尺不是被测。
awk 'BEGIN{f=0} $1=="w1163_bogus_sym"{f=1} END{exit !f}' /tmp/w1163_sym.txt \
  && { echo "[BAD] 反夹具失守：不存在的符号被查到"; BAD=1; } || echo "  [ok] 反夹具：w1163_bogus_sym 查不到"
# ★给这把"反夹具"本身再配一条正对照：把夹具换成**一定在**的 vfree，同一个 awk 必须报红。
#   它不报红 ⇒ 这条判据是恒绿的空枪(就是刚才那个 `!` 的形状)，比缺判据更坏＝例 231③。
if awk 'BEGIN{f=0} $1=="vfree"{f=1} END{exit !f}' /tmp/w1163_sym.txt; then
  echo "  [ok] 反夹具的夹具自证：把词换成 vfree，同一把尺会报红 ⇒ 它真有牙"
else
  echo "[BAD] 反夹具本身是空的(真符号也不报红) ⇒ 它那条'查不到'不算证据"; BAD=1
fi
ADD=$(comm -13 /tmp/w1163_vA.txt /tmp/w1163_vB.txt)
DEL=$(comm -23 /tmp/w1163_vA.txt /tmp/w1163_vB.txt)
echo "  未定义增量 $(echo "$ADD" | grep -ac .) 条：[$(echo "$ADD" | tr '\n' ' ')]"
echo "  未定义少了  $(echo "$DEL" | grep -ac .) 条(必须 0)"
[ -z "$DEL" ] || { echo "[BAD] 候选比出货少了 A 里就有的未定义符号 ⇒ 不止加了代码：[$(echo "$DEL" | tr '\n' ' ')]"; BAD=1; }
MISS=0
for s in $ADD; do
  if grep -qxF "$s" /tmp/w1163_sym.txt; then echo "    [ok] $s 已导出"; else echo "    [x] $s **不在** symvers ⇒ 装载期会缺符号"; MISS=1; fi
done
[ "$MISS" = 0 ] || { echo "[BAD] 有新增未定义符号没导出"; BAD=1; }
# ★正对照( tied to code，不是 tied to 一个我记的条数)：这一版**新引进**的两个进口符号必须出现在 ADD 里——
#   `simple_read_from_buffer`＝交图口那次读回、`kstrtoull`＝命令口的解析。它们不在 ⇒ 新代码没被链进来。
for s in simple_read_from_buffer kstrtoull; do
  echo "$ADD" | grep -qxF "$s" && echo "  [ok] 新代码的进口符号 [$s] 确实新增" || { echo "[BAD] ADD 里没有 [$s] ⇒ 装载面没被链进来"; BAD=1; }
done

echo; echo "=== 装载面那一半的接线形状：三个内核名字**不该**是链接期引用 ==="
SSEX=$(echo "$ADD" | grep -acE '^(security_|selinux_|policydb|avc_|ss_|services_)')
echo "  SS/security_* 外流=$SSEX(必须 0)"
[ "$SSEX" = 0 ] || { echo "[BAD] 有 SS 符号外流 ⇒ 装载面改成链接期引用了(kallsyms 那条路被绕开)"; BAD=1; }
for s in security_load_policy security_read_policy selinux_state; do
  grep -qxF "$s" /tmp/w1163_vB.txt && { echo "[BAD] [$s] 在未定义表里 ⇒ 它绕过了 ld_sym_addr"; BAD=1; } || echo "  [ok] [$s] 不在未定义表(走 kallsyms/kprobe)"
done

echo; echo "=== 尺②：参数进 .modinfo 的逐条点名(cb 那一支按一手形状另算) ==="
MI=/tmp/w1163_mi.txt
$RE --string-dump=.modinfo "$B" | sed -E 's/^\[[ ]*[0-9a-f]+\] //' | tail -n +2 | sort > "$MI"
echo "  MODINFO_LINES=$(wc -l < "$MI")(必须 >0 ⇒ 先证读段这条路通)"
[ "$(wc -l < "$MI")" -gt 0 ] || { echo "[BAD] .modinfo 读出来是空的 ⇒ 读法坏"; BAD=1; }
NLD=0
for p in ld_key:uint ld_cap:uint ld_seq:uint ld_sym_rc:int ld_proc:int ld_armed:int ld_arm_want:ulong \
         ld_arm_live:ulong ld_img_len:long ld_img_sum:ulong ld_writes:int ld_fault:int ld_why:int \
         ld_load_rc:int ld_pre_len:long ld_pre_sum:ulong ld_post_len:long ld_post_sum:ulong; do
  if grep -qxF "parmtype=$p" "$MI"; then NLD=$((NLD+1)); else echo "    [x] 少了 parmtype=$p"; BAD=1; fi
done
echo "  装载面点名 18 条：命中 $NLD"
[ "$NLD" = 18 ] || BAD=1
NSP=0
for p in sp_verbose:uint sp_calls:uint sp_seq:uint sp_why:int sp_n:int sp_bytes:long sp_bad_at:long \
         sp_max_arg:uint sp_rc:int sp_lenmatch:int sp_rec_bytes:int sp_rec_trunc:int sp_sum:ulong; do
  grep -qxF "parmtype=$p" "$MI" && NSP=$((NSP+1)) || { echo "    [x] 少了 parmtype=$p"; BAD=1; }
done
echo "  解码面点名 13 条：命中 $NSP"
[ "$NSP" = 13 ] || BAD=1
for k in parmtype=ld_bogus:uint parmtype=sp_bogus:uint; do
  grep -qxF "$k" "$MI" && { echo "[BAD] 反夹具失守：$k 被数出来了"; BAD=1; } || echo "  [ok] 反夹具：$k 查不到"
done
if grep -q '^parm=sp_arm' "$MI" || grep -q 'parmtype=sp_arm' "$MI"; then
  echo "  [note] sp_arm 在 modinfo 里有条目(比 w1158 那次一手读数多，仍算通)"
else
  echo "  [ok] sp_arm 走 module_param_cb ⇒ 这台机的 modinfo 不写它的条目(w1158 一手)；它的真证人＝代码里那句 module_param_cb＋运行期 /proc/ksu_sepol 在不在，不在这把尺上"
fi

echo; echo "=== 尺③：新符号(先把 ADD 摘掉，再用前缀认来源) ==="
$NM "$A" | awk '{print $NF}' | sort -u > /tmp/w1163_sA.txt
$NM "$B" | awk '{print $NF}' | sort -u > /tmp/w1163_sB.txt
GONE=$(comm -23 /tmp/w1163_sA.txt /tmp/w1163_sB.txt)
[ -z "$GONE" ] || { echo "[BAD] 候选比出货少了符号：[$(echo "$GONE" | tr '\n' ' ')]"; BAD=1; }
echo "  少了 $(echo "$GONE" | grep -ac .) 条(必须 0)"
echo "$ADD" | grep -a . > /tmp/w1163_add.txt
NEW=$(comm -13 /tmp/w1163_sA.txt /tmp/w1163_sB.txt)
NNEW=$(echo "$NEW" | grep -ac .)
STRLIST=$(comm -23 <(echo "$NEW" | grep -a . | sort) /tmp/w1163_add.txt)
PAT='^(sp_|ld_|p_ld_|p_kln|w1161_|w1155_|w1151_|ksu_sepol|handle_sepolicy|apply_kernelsu_rules|__param_(sp|str_sp|ld|str_ld)|__UNIQUE_ID_(sp|str_sp|ld|str_ld)|__cfi_jt_.*|.*dropped_stub.*)'
STRAY=$(echo "$STRLIST" | grep -avE "$PAT" | grep -ac .)
echo "  新符号 $NNEW 条；其中进口(ADD) $(grep -ac . /tmp/w1163_add.txt) 条；认不出来源的 $STRAY(必须 0)"
[ "$STRAY" = 0 ] || { echo "[BAD] 新符号里有对不上这份新代码的东西："; echo "$STRLIST" | grep -avE "$PAT" | head -10 | sed 's/^/      /'; BAD=1; }
echo "  信息(不当判据，static 会被内联，拿名字当闸就是错的期望)：新表里 ld_ 前缀的符号条数=$(echo "$NEW" | grep -acE '^ld_')"
grep -qxF 'ksu_sepol_put' /tmp/w1163_sB.txt && echo "  [ok] 收尾符号 ksu_sepol_put 在表里(它是非 static，被 main.c 引用)" || { echo "[BAD] 收尾符号不在表里"; BAD=1; }

echo; echo "=== 其余与 A 对比的几把 ==="
CFI=$($NM "$B" | grep -ac '__cfi_check'); echo "  __cfi_check=$CFI(必须 1)"; [ "$CFI" = 1 ] || { echo "[BAD] cfi 桩形状变了"; BAD=1; }
PVA=$($OD -h "$A" | awk '$2=="__param"{print $3}'); PVB=$($OD -h "$B" | awk '$2=="__param"{print $3}')
echo "  __param A=$((16#$PVA)) B=$((16#$PVB))(必须严格变大)"
[ "$((16#$PVB))" -gt "$((16#$PVA))" ] || { echo "[BAD] __param 没长大 ⇒ 新参数没进产物"; BAD=1; }
# ★词元表按**源文件里的字符串字面量**逐条对过(现读)：`SELINUX_MAGIC` 是**宏名**，不在任何字面量里
#   ⇒ 它不可能出现在 rodata，拿它当"链进来了"的证据就是一把恒红的尺(读法坏＝例 227 一族)。
for t in ksu_sepol "REC seq=" "STMT " "TRUNC cap=" "<empty>" ksu_sepol_img ksu_sepol_ctl "ARM " RESET; do
  C=$(strings -a "$B" | grep -ac -- "$t"); echo "  串 [$t]=$C"
  [ "$C" -ge 1 ] || { echo "[BAD] 少串 [$t] ⇒ 那段代码没被链进来"; BAD=1; }
done
VA=$(strings -a "$A" | grep -am1 '^vermagic='); VB=$(strings -a "$B" | grep -am1 '^vermagic=')
echo "  vermagic A=[$VA] B=[$VB]"
[ "$VA" = "$VB" ] || { echo "[BAD] vermagic 变了 ⇒ 不是同一棵树"; BAD=1; }
HA=$(strings -a "$A" | grep -am1 '^name=kernelsu'); HB=$(strings -a "$B" | grep -am1 '^name=kernelsu')
[ "$HA" = "$HB" ] || { echo "[BAD] MODNAME 变了"; BAD=1; }
SA=$(wc -c < "$A" | tr -dc '0-9'); SB=$(wc -c < "$B" | tr -dc '0-9')
echo "  SIZE A=$SA B=$SB 差=$((SB-SA))"

echo; echo "=== 树侧(这跑的还原是否真还原)：现读，不读证件 ==="
M=/root/k/ksu/kernel
echo "  现役桩 md5=$(md5sum "$M/selinux/dropped_stub.c" 2>/dev/null | cut -d' ' -f1)(期望 8795ceb4e73e8344e07dd5be30b4e0fa＝出货那份)"
echo "  三个头的残留=$(ls "$M/selinux/" 2>/dev/null | grep -cE 'w1151_|w1155_|w1161_')(必须 0)"
echo "  core/init.c 里 ksu_sepol_put 计数=$(grep -ac 'ksu_sepol_put' "$M/core/init.c" 2>/dev/null | tr -dc '0-9')(必须 0)"

if [ "$BAD" = 0 ]; then
  echo "VERDICT=ok rc76 候选件过尺：三把读法坏已按 w1158 的一手修正(列号／cb 信道／ADD 先摘)，装载面的两个新进口符号逐条点名"
else
  echo "VERDICT=bad 见 [BAD]"
fi
exit 0
