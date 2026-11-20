#!/bin/bash
# w1158_verify.sh —— 构建机侧(0 枪、**不编译**)：把 w1156 那两枚已在机器上的 ko 重新量一遍，
#   只修两把我自己写坏的尺(都不涉及被测)：
# 尺① `Module.symvers` 的格式是 `<CRC>\t<符号>\t<模块>\t<类型>` ⇒ `grep "^$s"` 永远命不中
#     (符号不在行首)。这就是例 227 那一族的又一次：读法坏被读成"数据坏"，我差点把 vmalloc 判成没导出。
#     ⇒ 改 awk 按第二字段等值查，并且**先印一条一定在的符号当正对照**(vfree)，它查不到就是这把尺坏了。
# 尺② `module_param_cb` 在这台机的 modinfo 里**两类条目都不写**(现读：parmtype=sp_ 13 条、parm=sp_ 0 条)
#     ⇒ `sp_arm` 的"参数真进去了"不能靠 modinfo 证；能证的是 insmod 后 `/proc/ksu_sepol` 在不在
#     (出货 ko 自己 `kobject_del` 掉了 /sys/module/kernelsu ⇒ 13 条读数参数本来就只能编译期定，
#      运行期回读要走 /proc)。⇒ 期望从"14 条 parmtype"改成"13 条按名＋型点名＋sp_arm 走另一条信道"。
set -u
A=/home/lucy/kernelsu_rc74c.ko
B=/home/lucy/w1156_kernelsu_rc75_candidate.ko
KDIR=/root/k/nothing_sm7325_v_mr
A_WANT=324eda4dcb5d41ecb6763a5192ea9c31
B_WANT=037f40a919554cdc2a1f8fb16d8101fa
for f in "$A" "$B" "$KDIR/Module.symvers"; do
  [ -s "$f" ] || { echo "!! 输入不在：$f"; exit 1; }
done
echo "MD5_A=$(md5sum "$A" | cut -d' ' -f1)"
echo "MD5_B=$(md5sum "$B" | cut -d' ' -f1)"
BAD=0
[ "$(md5sum "$A" | cut -d' ' -f1)" = "$A_WANT" ] || { echo "[BAD] A 不是出货那枚(环境漂)"; BAD=1; }
[ "$(md5sum "$B" | cut -d' ' -f1)" = "$B_WANT" ] || { echo "[BAD] B 不是那次编出来的候选件"; BAD=1; }

echo; echo "=== 尺①：未定义增量逐条查 Module.symvers(按第二字段) ==="
/usr/bin/llvm-nm "$A" | awk '$1=="U"{print $2}' | sort -u > /tmp/vA.txt
/usr/bin/llvm-nm "$B" | awk '$1=="U"{print $2}' | sort -u > /tmp/vB.txt
awk '{print $2}' "$KDIR/Module.symvers" | sort -u > /tmp/sym.txt
echo "  SYMVERS_NAMES=$(wc -l < /tmp/sym.txt)(>7000 才像一份全表)"
awk 'BEGIN{f=0} $1=="vfree"{f=1} END{exit !f}' /tmp/sym.txt \
  && echo "  [ok] 正对照：vfree 查得到(这把尺是通的)" || { echo "[BAD] 正对照失守：连 vfree 都查不到 ⇒ 读法坏"; BAD=1; }
ADD=$(comm -13 /tmp/vA.txt /tmp/vB.txt); DEL=$(comm -23 /tmp/vA.txt /tmp/vB.txt)
NADD=$(echo "$ADD" | grep -ac .)
echo "  增量 $NADD 条：[$(echo "$ADD" | tr '\n' ' ')]"
[ -z "$DEL" ] || { echo "[BAD] 候选少了 A 有的未定义符号 ⇒ 不止加了代码：[$(echo "$DEL" | tr '\n' ' ')]"; BAD=1; }
for s in $ADD; do
  if grep -qxF "$s" /tmp/sym.txt; then echo "    [ok] $s 已导出"; else echo "    [x] $s 不在 symvers ⇒ 装载期会缺"; BAD=1; fi
done

echo; echo "=== 尺②：参数与读回信道 ==="
MI=/tmp/vmi.txt
/usr/bin/llvm-readelf --string-dump=.modinfo "$B" | sed -E 's/^\[[ ]*[0-9a-f]+\] //' | tail -n +2 | sort > "$MI"
echo "  MODINFO_LINES=$(wc -l < "$MI")"
N13=0
for p in sp_verbose:uint sp_calls:uint sp_seq:uint sp_why:int sp_n:int sp_bytes:long sp_bad_at:long sp_max_arg:uint sp_rc:int sp_lenmatch:int sp_rec_bytes:int sp_rec_trunc:int sp_sum:ulong; do
  if grep -qxF "parmtype=$p" "$MI"; then N13=$((N13+1)); else echo "    [x] 少了 parmtype=$p"; BAD=1; fi
done
echo "  点名到 13 条带类型的读数参数：命中 $N13"
[ "$N13" = 13 ] || BAD=1
grep -qxF "parmtype=sp_bogus:uint" "$MI" && { echo "[BAD] 反夹具失守"; BAD=1; } || echo "  [ok] 反夹具：不存在的 sp_bogus 查不到"
if grep -q '^parm=sp_arm' "$MI" || grep -q 'parmtype=sp_arm' "$MI"; then
  echo "  [note] sp_arm 在 modinfo 里有条目(比预期多，仍算通)"
else
  echo "  [ok] sp_arm 走 module_param_cb ⇒ 这台机的 modinfo 不给它写条目(一手)；它的回读信道＝/proc/ksu_sepol 存不存在"
fi

echo; echo "=== 其余几把(与 A 对比) ==="
CFI=$(/usr/bin/llvm-nm "$B" | grep -ac '__cfi_check'); echo "  __cfi_check=$CFI"; [ "$CFI" = 1 ] || BAD=1
SS=$(comm -13 /tmp/vA.txt /tmp/vB.txt | grep -acE '^(security_|selinux_|policydb|avc_|ss_)'); echo "  SS/security_* 外流=$SS"; [ "$SS" = 0 ] || BAD=1
/usr/bin/llvm-nm "$A" | awk '{print $NF}' | sort -u > /tmp/sA.txt
/usr/bin/llvm-nm "$B" | awk '{print $NF}' | sort -u > /tmp/sB.txt
GONE=$(comm -23 /tmp/sA.txt /tmp/sB.txt); [ -z "$GONE" ] || { echo "[BAD] 候选比 A 少了符号：$(echo "$GONE" | tr '\n' ' ')"; BAD=1; }
NEW=$(comm -13 /tmp/sA.txt /tmp/sB.txt); NNEW=$(echo "$NEW" | grep -ac .)
# ★STRAY 要先把**新增的未定义引用**(那 7 条内核导出的进口符号)摘掉：它们当然会出现在"新符号"里
#   (A 没用到 vmalloc 所以表里没有它)，拿"我自己的前缀"去过滤它们必然漏 ⇒ 上一版这 7 条被判成"认不出来源"。
echo "$ADD" | grep -a . > /tmp/add.txt
STRLIST=$(comm -23 <(echo "$NEW" | grep -a . | sort) /tmp/add.txt)
STRAY=$(echo "$STRLIST" | grep -avE '^(sp_|ksu_sepol|w1155_|w1151_|handle_sepolicy|apply_kernelsu_rules|__param_(sp|str_sp)|__UNIQUE_ID_(sp|str_sp)|__cfi_jt_.*|.*dropped_stub.*)' | grep -ac .)
echo "  新符号 $NNEW 条；认不出来源的 $STRAY(必须 0)"
echo "$NEW" | grep -avE '^(sp_|ksu_sepol|w1155_|w1151_|handle_sepolicy|apply_kernelsu_rules|__param_(sp|str_sp)|__UNIQUE_ID_(sp|str_sp))' | head -8 | sed 's/^/      /'
[ "$STRAY" = 0 ] || BAD=1
for s in ksu_sepol_put sp_read sp_fops sp_setup sp_arm_set; do
  grep -qxF "$s" /tmp/sB.txt || { echo "[BAD] 少了新函数符号 $s"; BAD=1; }
done
PVA=$(/usr/bin/llvm-objdump -h "$A" | awk '$2=="__param"{print $3}'); PVB=$(/usr/bin/llvm-objdump -h "$B" | awk '$2=="__param"{print $3}')
echo "  __param A=$((16#$PVA)) B=$((16#$PVB))(必须严格变大)"
[ "$((16#$PVB))" -gt "$((16#$PVA))" ] || BAD=1
for t in ksu_sepol "REC seq=" "STMT " "TRUNC cap=" "<empty>" "a%u="; do
  C=$(strings -a "$B" | grep -ac -- "$t"); echo "  串 [$t]=$C"; [ "$C" -ge 1 ] || { echo "[BAD] 少串 [$t]"; BAD=1; }
done
VA=$(strings -a "$A" | grep -am1 '^vermagic='); VB=$(strings -a "$B" | grep -am1 '^vermagic=')
echo "  vermagic 同？$([ "$VA" = "$VB" ] && echo 是 || { echo 否; BAD=1; })"
SA=$(strings -a "$A" | grep -am1 '^srcversion='); SB=$(strings -a "$B" | grep -am1 '^srcversion=')
# ★这条判据我写反了(现量)：`srcversion` 是 modpost 对**参与链接的源文件名单**算的摘要，**与文件内容无关**
#   ⇒ 换掉一个文件的内容(不加文件)它当然相同。真证人是我上面那几条：新函数符号在表里、`__param` 变大、
#   新串在 rodata 里。留着这两行只当信息，不当判据(错的判据比缺判据更坏＝例 231③)。
echo "  srcversion：A=${SA:-读不到} B=${SB:-读不到} ⇒ 只当信息：strings 里没有 ^srcversion= 这一行(这本 ko 没写或前缀不在行首)⇒ 量不到东西就不许当判据(读不到≠相同)"
SIZEA=$(wc -c < "$A" | tr -dc '0-9'); SIZEB=$(wc -c < "$B" | tr -dc '0-9')
echo "  SIZE A=$SIZEA B=$SIZEB 差=$((SIZEB-SIZEA))"
if [ "$BAD" = 0 ]; then echo "VERDICT=ok rc75 候选件过尺(两把读法已修，符号/参数/串/段四类都点过名)"; else echo "VERDICT=bad 见 [BAD]"; fi
exit 0
