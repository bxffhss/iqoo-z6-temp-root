#!/bin/bash
# w1156_remote.sh —— 构建机侧(0 枪，不碰设备)：把 rc75 候选桩编进**出货同一条流水线**的产物里，
#   并证明"这次只动了那两个变量"。
# 为什么要有 stage A：候选件必须与**出货那份**可比，而"我记得树现在是 rc74c 状态"不是证人(§296/§297
#   迁移那一串教训)。所以先原样跑一遍 `ksu_rc74c.sh`，把它产出的 ko md5 与本地包装送上来的
#   **出货 ko 的现读 md5** 对表；不等就停手 ⇒ 那说明环境漂了，B 阶段做出来的东西不能叫候选。
# stage B 只动两处(全部带回执)：
#   (1) `kernel/selinux/dropped_stub.c` ← rc75 候选；并把两个头文件放进同目录(引号 include 就近解析)
#   (2) `kernel/main.c` 的模块退出函数体首行插 `extern void ksu_sepol_put(void); ksu_sepol_put();`
#       ⇒ 找不到退出函数就**红**，不许"那就先不接"(那样泄漏就成了默认)。
# 判据全部以 A 为参照(未定义符号增量、新符号来源、__param 段、cfi、modinfo、rodata 串)。
set -u
KSU=/root/k/ksu
M=$KSU/kernel
KDIR=/root/k/nothing_sm7325_v_mr
LOGA=/home/lucy/w1156_A.log
LOGB=/home/lucy/w1156_B.log
# ★w999_runcap.sh 只往远端传 脚本/名/超时 三样，**不转发位置参数** ⇒ 上一版这里的 `${1:-}` 恒为空，
#   远端一上来就以"没给出货 md5"停手。参照值改走**文件**交接(包装两端对 md5)。
SHIPPED_MD5_WANT=$(tr -d '\r\n' < /home/lucy/w1156_shipmd5.txt 2>/dev/null)
cd /home/lucy || exit 1

for f in ksu_rc74c.sh w1156_stub.c w1156_core.h w1156_record.h w1156_shipmd5.txt w1156_stubmd5.txt; do
  [ -s "/home/lucy/$f" ] || { echo "!! 输入不在或为空：$f"; exit 1; }
done
[ -n "$SHIPPED_MD5_WANT" ] || { echo "!! 没给出货 ko 的现读 md5 ⇒ 没法证明可比性，停"; exit 1; }
for f in ksu_rc74c.sh w1156_stub.c w1156_core.h w1156_record.h w1156_shipmd5.txt w1156_stubmd5.txt; do
  echo "MD5_$f=$(md5sum /home/lucy/$f | cut -d' ' -f1)"
done
echo "SHIPPED_MD5_WANT=$SHIPPED_MD5_WANT"
[ -d "$KDIR" ] || { echo "!! 内核树不在：$KDIR"; exit 1; }
[ -f "$M/selinux/dropped_stub.c" ] || { echo "!! 现役桩不在预期路径 ⇒ 停(别猜树的结构)"; exit 1; }
# ★"备份"这一步本身有个坑：上一次跑到一半死掉时，树里的桩已经是候选那份，再 cp 一次就把**唯一的好备份**覆盖了。
#   ⇒ 备份前先拿"出货那份的 md5"(包装上传)当尺：不对就先用旧备份救回来，救不回来就停，绝不拿脏树当出货状态。
STUB_WANT=$(tr -d '
' < /home/lucy/w1156_stubmd5.txt 2>/dev/null)
NOWSTUB=$(md5sum "$M/selinux/dropped_stub.c" | cut -d' ' -f1)
echo "  树里现役桩=$NOWSTUB 期望=$STUB_WANT"
if [ -n "$STUB_WANT" ] && [ "$NOWSTUB" != "$STUB_WANT" ]; then
  BKP=$(md5sum /home/lucy/w1156_stub_pristine.c 2>/dev/null | cut -d' ' -f1)
  if [ "$BKP" = "$STUB_WANT" ]; then
    cp /home/lucy/w1156_stub_pristine.c "$M/selinux/dropped_stub.c"
    echo "  [ok] 树里那枚是上一次中途留下的 ⇒ 已用备份还原成出货那份"
    NOWSTUB=$(md5sum "$M/selinux/dropped_stub.c" | cut -d' ' -f1)
  else
    echo "!! 现役桩与出货那份不符，备份也不符(备份=${BKP:-无}) ⇒ 停：树的来源不可知，别拿它当可比性基线"; exit 1
  fi
fi
cp "$M/selinux/dropped_stub.c" /home/lucy/w1156_stub_pristine.c
echo "  现役桩(出货那份)md5=$(md5sum "$M/selinux/dropped_stub.c" | cut -d' ' -f1)"

echo; echo "=== A0) 前置清点：这条流水线**读**的参照件在不在(不在就别烧 10 分钟编译) ==="
# ★§296/§297 迁移那条教训的实物化："环境齐不齐"要**量**出来，不是我记得。这一跑第一次就是这么发现的：
#   流水线在"rc74b 闸门"那一步拿 /home/lucy/kernelsu_rc73.ko 当参照，而那枚件在第二台机上从来没铺过
#   ⇒ llvm-nm 报 No such file ⇒ rc73 的未定义表读成空 ⇒ 二百来条符号全算"多出来的" ⇒ 红灯停。
#   那是**环境红**，不是被测红；更关键的是它烧完了一整轮编译才告诉我。
REQ="/home/lucy/kernelsu_rc73.ko /home/lucy/ksu_dev_syms_rc73.c /home/lucy/sh_hook_w372.c /home/lucy/shm_rc73.c /home/lucy/ksu_compat54.h /home/lucy/kshim /root/k/nothing_sm7325_v_mr/Module.symvers /home/lucy/w1156_stubmd5.txt"
MISSCNT=0
for f in $REQ; do
  if [ -d "$f" ]; then echo "  [ok] $f (目录，条目 $(ls "$f" 2>/dev/null | grep -c . ))";
  elif [ -e "$f" ]; then echo "  [ok] $f ($(wc -c <"$f" | tr -dc '0-9') B)";
  else echo "  [x] 缺参照件：$f"; MISSCNT=$((MISSCNT+1)); fi
done
for f in /home/lucy/patch_ksu_*.py; do [ -e "$f" ] || { echo "  [x] 缺补丁件：$f"; MISSCNT=$((MISSCNT+1)); }; done
echo "  REQUIRED_MISSING=$MISSCNT(必须 0；这一格自己就是 set -u 抓出来的：上一版这里写成了另一个拼法)"
[ "$MISSCNT" = 0 ] || { echo "!! 环境不齐 ⇒ 停(先把参照件补上，别拿半套环境当可比性)"; exit 1; }

echo; echo "=== A) 原样重跑出货流水线(全量重编) ==="
bash /home/lucy/ksu_rc74c.sh > "$LOGA" 2>&1; RCA=$?
echo "RC74C_RC=$RCA (0=流水线本身跑完；产物对表才是真证人)"
A_KO=/home/lucy/kernelsu_rc74c.ko
[ -s "$A_KO" ] || { echo "!! A 阶段没产出 $A_KO ⇒ 停"; tail -20 "$LOGA"; exit 1; }
A_MD5=$(md5sum "$A_KO" | cut -d' ' -f1)
echo "MD5_A=$A_MD5"
[ "$A_MD5" = "$SHIPPED_MD5_WANT" ] || { echo "!! 红灯：A 阶段产物 ≠ 出货那份(出货=$SHIPPED_MD5_WANT) ⇒ 环境漂了，B 出来的不能叫候选，停"; exit 1; }
echo "  ★可比性成立：A＝出货那份逐字节相同 ⇒ 下面只动两个变量"
AWARN=$(grep -ac 'warning:' "$LOGA"); AERR=$(grep -ac ' error: ' "$LOGA")
echo "A_LOG warn=$AWARN err=$AERR"
/usr/bin/llvm-nm "$A_KO" | awk '$1=="U"{print $2}' | sort -u > /tmp/undA.txt
/usr/bin/llvm-nm "$A_KO" | awk '{print $NF}' | sort -u > /tmp/symA.txt
echo "A_UND=$(wc -l < /tmp/undA.txt)"
PVH_A=$( /usr/bin/llvm-objdump -h "$A_KO" | awk '$2=="__param"{print $3}' )
echo "A_PARAM_HEX=$PVH_A"

# ★B 阶段一旦动过树，任何提前退出(找不到退出函数、编译失败…)都**必须**把它还原：
#   下一次跑 A 阶段会拿"半改的树"当出货状态，那可比性就成了假的。用 EXIT 陷阱兜住，幂等执行。
MC=""
PATCHED_MC=0
restore_tree() {
  [ -n "${RESTORED:-}" ] && return 0
  RESTORED=1
  [ -s /home/lucy/w1156_stub_pristine.c ] && cp /home/lucy/w1156_stub_pristine.c "$M/selinux/dropped_stub.c" 2>/dev/null
  rm -f "$M/selinux/w1151_sepolicy_core.h" "$M/selinux/w1155_sepol_record.h" 2>/dev/null
  [ "$PATCHED_MC" = 1 ] && [ -n "$MC" ] && sed -i '/extern void ksu_sepol_put(void); ksu_sepol_put();/d' "$MC" 2>/dev/null
  echo "  [restore] 桩 md5=$(md5sum "$M/selinux/dropped_stub.c" 2>/dev/null | cut -d' ' -f1) 头文件残留=$(ls "$M/selinux/" 2>/dev/null | grep -c 'w115[15]') put 调用残留=$([ -n "$MC" ] && occ "$MC" || echo 0)"
}
trap restore_tree EXIT

echo; echo "=== B) 换上 rc75 候选桩(只动两处) ==="
cp /home/lucy/w1156_stub.c "$M/selinux/dropped_stub.c"
cp /home/lucy/w1156_core.h "$M/selinux/w1151_sepolicy_core.h"
cp /home/lucy/w1156_record.h "$M/selinux/w1155_sepol_record.h"
echo "  桩落盘 md5=$(md5sum "$M/selinux/dropped_stub.c" | cut -d' ' -f1)"
grep -q '#include "w1155_sepol_record.h"' "$M/selinux/dropped_stub.c" || { echo "!! 桩里没引记录层头 ⇒ 铺错件了"; exit 1; }
[ "$(md5sum "$M/selinux/w1151_sepolicy_core.h" | cut -d' ' -f1)" = "$(md5sum /home/lucy/w1156_core.h | cut -d' ' -f1)" ] || { echo "!! 核心头没忠实落到树里"; exit 1; }

# main.c 的模块退出函数：先**找**，再插，再回读条数
# ★这棵树的 `module_exit` 不在 kernel/main.c(在 core/init.c) ⇒ 别赌文件名，**按内容找**；
#   找到多处也停(那说明我对树的理解不够，不该猜)。
MAP=( $(grep -rl 'module_exit(' "$M" --include='*.c' 2>/dev/null) )
[ "${#MAP[@]}" = 1 ] || { echo "!! module_exit 出现在 ${#MAP[@]} 处(应为 1) ⇒ 停：[${MAP[*]}]"; exit 1; }
MC=${MAP[0]}
echo "  收尾文件=$MC"
EXF=$(grep -o 'module_exit([A-Za-z_0-9]*)' "$MC" | head -1 | sed 's/module_exit(\(.*\))/\1/')
[ -n "$EXF" ] || { echo "!! 找不到 module_exit 的函数名 ⇒ 停(不接收尾＝泄漏，别默默干)"; exit 1; }
echo "  退出函数=$EXF"
occ() { grep -ao 'ksu_sepol_put' "$1" 2>/dev/null | wc -l | tr -dc '0-9'; }   # 数**出现次数**，不是行数
BEFORE=$(occ "$MC")
awk -v fn="$EXF" 'BEGIN{ins=0}
  { print }
  ins==0 && $0 ~ ("__exit " fn "\\(") { gotfn=1 }
  ins==0 && gotfn==1 && $0 ~ /^\{/ { print "\textern void ksu_sepol_put(void); ksu_sepol_put();"; ins=1 }
' "$MC" > /tmp/main_new.c
grep -q 'ksu_sepol_put();' /tmp/main_new.c || { echo "!! 插入没落地(函数体形状与预期不符：不是 '^static void __exit 名字(' 那一行) ⇒ 停"; grep -n "$EXF" "$MC" | head -4; exit 1; }
cp /tmp/main_new.c "$MC"
PATCHED_MC=1
AFTER=$(occ "$MC")
echo "  收尾文件里 ksu_sepol_put 出现次数：$BEFORE→$AFTER(必须 0→2＝一行里声明＋调用各一次)"
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
grep -E 'warning: .*(implicit declaration|control reaches end)' "$LOGB" | head -8 | sed 's/^/  W: /'
[ "$RCB" = 0 ] || { echo "!! B 没编出来 ⇒ 这就是答案(桩在内核头下编不过)，别继续装样子"; exit 0; }
[ "$BERR" = 0 ] || { echo "!! 有 error 计数非 0 却 rc=0 ⇒ 读法不一致，停"; exit 1; }
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
for s in $ADD; do
  grep -q "^$s" "$KDIR/Module.symvers" || { echo "  [x] 新增未定义符号 [$s] **不在** Module.symvers ⇒ 装载期会缺符号"; MISS=1; }
done
[ "$MISS" = 0 ] && echo "[ok] 新增未定义符号逐条已在 Module.symvers 里导出(不靠 kallsyms)" || { echo "[BAD] 有新增符号没导出"; BAD=1; }
SS=$(echo "$ADD" | grep -cE '^(security_|selinux_|policydb|avc_|ss_)')
[ "$SS" = 0 ] && echo "[ok] SS/security_* 外流=0(这份解码根本不需要 SS——§344 那条形状)" || { echo "[BAD] SS 符号外流=$SS"; BAD=1; }
/usr/bin/llvm-readelf --section-details "$B_KO" 2>/dev/null | awk '{print $2}' | grep -xc '__cfi_check' >/dev/null 2>&1
CFI=$(/usr/bin/llvm-nm "$B_KO" | grep -ac '__cfi_check')
echo "  __cfi_check=$CFI(必须 1)"; [ "$CFI" = 1 ] || { echo "[BAD] cfi 桩形状变了"; BAD=1; }
# ★这条读法照抄 w1141 里已经验过的那把(第一版我用 sed 抠 strings 数到 0 ⇒ 是"读法错被读成数据坏"，例 227)
MI2=/tmp/w1156_mi.txt
/usr/bin/llvm-readelf --string-dump=.modinfo "$B_KO" | sed -E "s/^\[[ ]*[0-9a-f]+\] //" |
  tail -n +2 | sort > "$MI2"
TOTAL_LINES=$(wc -l < "$MI2")
echo "  MODINFO_LINES=$TOTAL_LINES(必须 >0 ⇒ 先证读段这条路是通的)"
[ "$TOTAL_LINES" -gt 0 ] || { echo "[BAD] .modinfo 读出来是空的 ⇒ 读法坏，不是数据坏"; BAD=1; }
MODI=$(cat "$MI2")
PARM=$(grep -ac '^parmtype=sp_' <<<"$MODI")
echo "  parmtype=sp_* 条数=$PARM(本桩有 14 个参数；必须 ≥14)"
[ "$PARM" -ge 14 ] || { echo "[BAD] 参数没进 .modinfo ⇒ 上机就没有读回口"; BAD=1; }
for k in parmtype=sp_arm:uint parmtype=sp_sum:ulong parmtype=sp_rc:int; do
  grep -qxF "$k" <<<"$MODI" || { echo "[BAD] .modinfo 少了 [$k]"; BAD=1; }
done
grep -qxF "parmtype=sp_bogus:uint" <<<"$MODI" && { echo "[BAD] 反夹具失守：不存在的参数被数出来了"; BAD=1; }
strings -a "$B_KO" > /tmp/strB.txt
for s in ksu_sepol "REC seq=" "STMT " "TRUNC cap=" "<empty>"; do
  C=$(grep -ac -- "$s" /tmp/strB.txt); echo "  串 [$s]=$C(必须 ≥1 ⇒ 记录层真被链进来)"; [ "$C" -ge 1 ] || { echo "[BAD] 少串 [$s]"; BAD=1; }
done
PVH_B=$( /usr/bin/llvm-objdump -h "$B_KO" | awk '$2=="__param"{print $3}' )
echo "  __param 段 A=$PVH_A B=$PVH_B(必须严格变大)"
[ "$((16#$PVH_B))" -gt "$((16#$PVH_A))" ] || { echo "[BAD] __param 没长大 ⇒ 新参数没进产物"; BAD=1; }
/usr/bin/llvm-nm "$B_KO" | awk '{print $NF}' | sort -u > /tmp/symB.txt
NEW=$(comm -13 /tmp/symA.txt /tmp/symB.txt); GONE=$(comm -23 /tmp/symA.txt /tmp/symB.txt)
NNEW=$(echo "$NEW" | grep -ac .)
echo "  新符号 $NNEW 条；少了 $(echo "$GONE" | grep -ac .) 条(必须 0)"
[ -z "$GONE" ] || { echo "[BAD] 候选比出货少了符号 ⇒ 不止加了代码"; BAD=1; }
STRAY=$(echo "$NEW" | grep -avE '^(sp_|ksu_sepol|w1155_|w1151_|handle_sepolicy|apply_kernelsu_rules|__param_(sp|str_sp)|__UNIQUE_ID_(sp|str_sp))' | grep -ac .)
echo "  认不出来源的新符号=$STRAY(必须 0)"; [ "$STRAY" = 0 ] || { echo "[BAD] 新符号里有对不上这份新代码的东西"; echo "$NEW" | grep -avE '^(sp_|ksu_sepol|w1155_|w1151_|handle_sepolicy|apply_kernelsu_rules|__param_(sp|str_sp)|__UNIQUE_ID_(sp|str_sp))' | head -8 | sed 's/^/      /'; BAD=1; }
VM_A=$(strings -a "$A_KO" | grep -am1 '^vermagic='); VM_B=$(strings -a "$B_KO" | grep -am1 '^vermagic=')
echo "  vermagic A=[$VM_A] B=[$VM_B]"; [ "$VM_A" = "$VM_B" ] || { echo "[BAD] vermagic 变了 ⇒ 不是同一棵树"; BAD=1; }
MH_A=$(strings -a "$A_KO" | grep -am1 '^name=kernelsu'); MH_B=$(strings -a "$B_KO" | grep -am1 '^name=kernelsu')
[ "$MH_A" = "$MH_B" ] || { echo "[BAD] MODNAME 变了"; BAD=1; }

cp "$B_KO" /home/lucy/w1156_kernelsu_rc75_candidate.ko
echo "MD5_B=$(md5sum /home/lucy/w1156_kernelsu_rc75_candidate.ko | cut -d' ' -f1)"
echo "SIZE_B=$(wc -c < /home/lucy/w1156_kernelsu_rc75_candidate.ko | tr -dc '0-9')"
echo "SIZE_A=$(wc -c < "$A_KO" | tr -dc '0-9')"

echo; echo "=== 还原现场(树里不能留着候选桩：下一次跑出货流水线会拿它当真) ==="
restore_tree
echo "  桩还原 md5=$(md5sum "$M/selinux/dropped_stub.c" | cut -d' ' -f1)(应等于上面打印的现役桩)"
sed -i '/extern void ksu_sepol_put(void); ksu_sepol_put();/d' "$MC"
echo "  main.c 里 ksu_sepol_put 计数还原后=$(grep -ac 'ksu_sepol_put' "$MC")(必须 0)"
rm -f "$M/selinux/w1151_sepolicy_core.h" "$M/selinux/w1155_sepol_record.h"
echo "  两个头已从树里删掉：现读 $(ls "$M/selinux/" 2>/dev/null | grep -c 'w115[15]')(必须 0)"

if [ "$BAD" = 0 ]; then
  echo "VERDICT=ok 候选件与出货那份只差这两个变量，尺全过(未装设备、未进包)"
else
  echo "VERDICT=bad 见上面 [BAD] 行"
fi
exit 0
