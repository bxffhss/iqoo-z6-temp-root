#!/bin/bash
# w1151 #238 部件①(核内解码)的 0 枪验证，两件事一条龙：
#   第 2~4 步＝宿主 gcc 跑 w1151_host_selftest，并拿四处**变异**回头查这把尺本身会不会放过坏件
#              (§293/§237 那一手：判据自己也会骗自己)；
#   第 6~7 步＝把**同一份**核心(直接 cp，不重写)用出货同款工具链编成 aarch64 探针 z6sepdec.ko，过七把尺。
# ★"上机那份＝刚验过那份"是靠第 6 步那句 md5 相等钉住的，不是靠我记得它们一样。
set -u
D=/home/lucy/w1151_sepd
LOG=$D/host_build.log
rm -rf "$D"; mkdir -p "$D"

echo "BEGIN $(date)"
echo "CC=$($(command -v gcc) -v 2>&1 | head -1)"
echo "MACHINE=$(uname -m)"

echo; echo "=== 1) 两份输入件各报 md5，缺一份就不跑 ==="
for f in w1151_sepolicy_core.h w1151_host_selftest.c; do
  if [ ! -s /home/lucy/$f ]; then
    echo "!! /home/lucy/$f 不在或是空的 ⇒ 停(先跑 kmod/w1151_run.sh，远端不留陈件)"
    exit 1
  fi
  cp /home/lucy/$f "$D/$f" || { echo "!! 拷 $f 失败"; exit 1; }
  echo "MD5_$f=$(md5sum "$D/$f" | cut -d' ' -f1)"
done
ls -la "$D" | sed -n '1,10p'

echo; echo "=== 2) 编译(原样两份，不许改) ==="
cd "$D"
gcc -std=gnu11 -O2 -Wall -Wextra -o w1151_host_selftest w1151_host_selftest.c > "$LOG" 2>&1
RC=$?
echo "HOST_MAKE_RC=$RC"
ERRN=$(grep -cE ': error: ' "$LOG")
WARNN=$(grep -cE ': warning: ' "$LOG")
echo "DIAG_ERR=$ERRN DIAG_WARN=$WARNN   (判据：两个都必须=0)"
grep -E ': (error|warning): ' "$LOG" | sed 's/^.*: \(error\|warning\): /  \1: /' | sort -u | head -25
[ "$RC" -eq 0 ] && [ "$ERRN" -eq 0 ] && [ "$WARNN" -eq 0 ] || { echo "!! 编译这关就没过 ⇒ 判负"; cat "$LOG"; exit 1; }

echo; echo "=== 3) 跑正件：必须 VERDICT=w1151_pass 且 rc=0 且 [BAD]=0 ==="
./w1151_host_selftest > "$D/run_good.txt" 2>&1
RR=$?
echo "RUN_RC=$RR"
grep -aE 'W1151 begin|TYPES|F1 encoder|F3 argc|F7 in_max|SELF_TOOTH|SUM asserts|VERDICT' "$D/run_good.txt" | sed 's/^/  /'
# ★"不许有 [BAD]"这条尺**必须**把反夹具自己那一行排除出去：那行是设计里就该出现的。
#   第一版我拿总数当判据 ⇒ 正件永远绿不了(仪器拦仪器)。改成"恰=1 行且那行带 SELFTOOTH_MARK"。
BADN=$(grep -a '^\[BAD\]' "$D/run_good.txt" | wc -l)
MARKN=$(grep -ac 'SELFTOOTH_MARK' "$D/run_good.txt")
echo "BADN=$BADN MARKN=$MARKN  (判据：BADN=1 且那一行就是反夹具)"
F=$(sed -n 's/^SUM asserts=[0-9]* fails=\([0-9]*\)$/\1/p' "$D/run_good.txt" | head -1)
echo "SUM_FAILS=${F:-空}"
GOOD_OK=0
if [ "$RR" -eq 0 ] && grep -aq '^VERDICT=w1151_pass$' "$D/run_good.txt" \
   && [ "$BADN" -eq 1 ] && [ "$MARKN" -eq 1 ] && [ "${F:-1}" -eq 0 ]; then GOOD_OK=1; fi
A=$(sed -n 's/^SUM asserts=\([0-9]*\) fails=[0-9]*$/\1/p' "$D/run_good.txt" | head -1)
echo "ASSERTS=$A  (判据：>=60，太小说明这一轮没真跑)"
[ "${A:-0}" -ge 60 ] || GOOD_OK=0
grep -aq '^SELF_TOOTH fail_delta=1 ' "$D/run_good.txt" || { echo "!! 反夹具那条没让 [BAD] 计数恰好 +1 ⇒ 尺本身可疑"; GOOD_OK=0; }
echo "GOOD_OK=$GOOD_OK"
[ "$GOOD_OK" -eq 1 ] || { echo "---- 正件全文 ----"; cat "$D/run_good.txt"; echo "!! 正件判负 ⇒ 停"; exit 1; }

echo; echo "=== 4) 变异回查：三处各拆一把尺，编得出来但**必须**跑红 ==="
#   每条变异都是"少一把尺"，不是"多一个坏字节"：正件应当照样过(说明这一把尺本来没在护着绿)，
#   而变异体必须被指定的那条 CASE 抓到 ⇒ 这证明那条 CASE 真在查这一把尺。
mut() {
  local name="$1" from="$2" to="$3"
  rm -rf "$D/mut_$name"; mkdir -p "$D/mut_$name"
  cp "$D/w1151_host_selftest.c" "$D/mut_$name/"
  sed "s|$from|$to|" "$D/w1151_sepolicy_core.h" > "$D/mut_$name/w1151_sepolicy_core.h"
  if cmp -s "$D/w1151_sepolicy_core.h" "$D/mut_$name/w1151_sepolicy_core.h"; then
    echo "  MUT[$name] sed 没改动任何东西 ⇒ 这条变异是空跑，判负"
    echo "MUT_$name=NOOP"
    return 1
  fi
  if ! ( cd "$D/mut_$name" && gcc -std=gnu11 -O2 -o t w1151_host_selftest.c >build.log 2>&1 ); then
    echo "  MUT[$name] 编译失败(变异不该改变编译结果) ⇒ 这条不算抓到"; echo "MUT_$name=BUILDFAIL"; return 1
  fi
  ( cd "$D/mut_$name" && ./t >run.txt 2>&1 )
  local rc=$?
  local badn first
  # ★同样要把反夹具那一行摘出去：它每轮都在，拿总行数当"被抓到"＝恒真尺。
  badn=$(grep -a '^\[BAD\]' "$D/mut_$name/run.txt" 2>/dev/null | grep -vc 'SELFTOOTH_MARK')
  first=$(grep -a '^\[BAD\]' "$D/mut_$name/run.txt" 2>/dev/null | grep -av 'SELFTOOTH_MARK' | head -3 | cut -c1-110 | tr '\n' ';')
  echo "  MUT[$name] rc=$rc BAD行数=${badn:-0}"
  echo "    首条: $first"
  if [ "$rc" -ne 0 ] && [ "${badn:-0}" -ge 1 ]; then
    echo "MUT_$name=CAUGHT"
    return 0
  fi
  echo "MUT_$name=ESCAPED"
  return 1
}

MFAIL=0
#   变异一：subcmd 取值域那把尺拆掉 ⇒ M4/F4_cmd1_sub5 必须红
mut subcmd 'if (!w1151_subcmd_ok(cmd, sub)) {' 'if (0) {' || MFAIL=1
#   变异二：单参数上限那把尺拆掉 ⇒ F5_arg_300_reject / M6_arglen_ffff 必须红
mut argmax  'if (alen > W1151_ARG_MAX) {' 'if (0) {' || MFAIL=1
#   变异三：收尾 NUL 那把尺拆掉 ⇒ M8_no_nul 必须红(只改判断不删行，偏移推进保持原样)
mut laternul 'if (buf\[pos + alen\] != 0) {' 'if (0) {' || MFAIL=1
#   变异四：cmd 表把 ATTR(6) 的 argc 从 1 改成 2 ⇒ F3 的表比对＋F6/F7 的 cmd6 夹具必须红
mut argc6   'case 6: /\* ATTR' 'case 6: return 2; /\* ATTR' || MFAIL=1

echo; echo "=== 5) 判读(宿主侧) ==="
echo "GOOD_OK=$GOOD_OK MUTFAIL=$MFAIL"
if [ "$MFAIL" -ne 0 ]; then
  echo "VERDICT=mut_escaped  (有变异没被抓 ⇒ 上面那些 CASE 护不住对应的尺)"
  exit 1
fi
if [ "$GOOD_OK" -ne 1 ]; then
  echo "VERDICT=red(正件没过)"
  exit 1
fi
echo "HOST_VERDICT=ok  (正件绿＋四条变异全被抓)"

echo; echo "=== 6) 同一份核心，换出货同款工具链编成 aarch64 探针模块 z6sepdec.ko ==="
# ★这一格查的是"上机那份＝刚验过的那份"：核心文件与第 1 步用的是**同一个 inode**(直接 cp，不重写)，
#   探针主源只负责喂字节与印读数。这个件不解析策略图、不碰 security_*，风险比 B′ 低一档。
KDIR=/root/k/nothing_sm7325_v_mr
NM=/usr/bin/llvm-nm
KD=$D/ko
rm -rf "$KD"; mkdir -p "$KD"
[ -s /home/lucy/w1151_sepd_probe.c ] || { echo "!! /home/lucy/w1151_sepd_probe.c 不在 ⇒ 停"; exit 1; }
cp /home/lucy/w1151_sepd_probe.c "$KD/z6sepdec_main.c"
cp "$D/w1151_sepolicy_core.h" "$KD/"          # ← 同一份，不是抄第二遍
cp /root/k/ksu/kernel/cfi_stub.c "$KD/cfi_stub.c"
echo "PROBE_MD5=$(md5sum "$KD/z6sepdec_main.c" | cut -d' ' -f1)"
echo "CORE_MD5_KO_SIDE=$(md5sum "$KD/w1151_sepolicy_core.h" | cut -d ' ' -f1)"
echo "STUB_MD5=$(md5sum "$KD/cfi_stub.c" | cut -d' ' -f1)"
if [ "$(md5sum "$KD/w1151_sepolicy_core.h" | cut -d' ' -f1)" != "$(md5sum "$D/w1151_sepolicy_core.h" | cut -d' ' -f1)" ]; then
  echo "!! 上机那份核心≠刚验过那份 ⇒ 停(这正是'两份实现互不相干'那一族)"; exit 1
fi
cat > "$KD/Makefile" <<'MK'
obj-m += z6sepdec.o
z6sepdec-y := z6sepdec_main.o cfi_stub.o
MK
cd "$KD" && make -C "$KDIR" M="$KD" \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip KCFLAGS="-Wno-unused-function" \
  modules > "$D/ko_build.log" 2>&1
KRC=$?
echo "KO_MAKE_RC=$KRC"
KERR=$(grep -cE ': error: ' "$D/ko_build.log")
KWARN=$(grep -cE ': warning: ' "$D/ko_build.log")
KIMP=$(grep -cE 'implicit declaration' "$D/ko_build.log")
echo "KDIAG_ERR=$KERR KDIAG_WARN=$KWARN KDIAG_IMPLICIT=$KIMP   (判据：三个都=0)"
grep -E ': (error|warning): ' "$D/ko_build.log" | sed 's/^.*: \(error\|warning\): /  \1: /' | sort -u | head -20
[ "$KRC" -eq 0 ] && [ "$KERR" -eq 0 ] && [ "$KWARN" -eq 0 ] && [ "$KIMP" -eq 0 ] || {
  echo "!! aarch64 这关没过 ⇒ 判负"; tail -30 "$D/ko_build.log"; exit 1; }

echo; echo "=== 7) 尺：CFI 桩／未解析表／SS 与 security_* 外流=0／参数齐／件名与 vermagic ==="
KO="$KD/z6sepdec.ko"
[ -f "$KO" ] || { echo "!! 没有 z6sepdec.ko ⇒ 判负"; tail -30 "$D/ko_build.log"; exit 1; }
ls -l "$KO"; md5sum "$KO"; file "$KO" | sed 's/^/  /'
BAD=0
CFIN=$($NM "$KO" 2>/dev/null | grep -cw __cfi_check)
echo "  CFI_STUB=$CFIN  (判据：恰=1，=0 时内核经 do_one_initcall 间接调用本件会当场 panic，§6.484)"
[ "$CFIN" = 1 ] || BAD=1
$NM -u "$KO" | awk '{print $2}' | sort > /tmp/w1151_u.txt
NU=$(wc -l < /tmp/w1151_u.txt)
echo "  UNRESOLVED_TOTAL=$NU  (必须 >0，否则'不在表里'这类判断全没判别力)"
[ "$NU" -gt 0 ] || BAD=1
head -30 /tmp/w1151_u.txt | tr '\n' ' '; echo
if grep -qx vmalloc /tmp/w1151_u.txt; then
  echo "  [ok] 正对照：vmalloc 在未解析表里(这把尺有牙)"
else
  echo "  !! vmalloc 不在表里 ⇒ 后面那些'不在'都不许信"; BAD=1
fi
# ★这一件的设计承诺是"只解与存，不动策略"⇒ 这些名字一个都不该出现在链接期引用里
for n in security_load_policy security_read_policy security_policydb_len security_context_to_sid selinux_state; do
  if grep -qx "$n" /tmp/w1151_u.txt; then
    echo "  !! $n 被当成链接期引用 ⇒ insmod 必以未知符号失败，而且违背本件的设计承诺"; BAD=1
  fi
done
echo "  security_*/selinux_state 链接期引用＝查完(上面没点名就是 0)"
LEAK=$(grep -E 'policydb|avtab|ebitmap|hashtab|symtab|mls_|cond_' /tmp/w1151_u.txt | tr '\n' ' ')
if [ -n "$LEAK" ]; then echo "  !! SS 内部符号外流(设计上=0)：$LEAK"; BAD=1; else echo "  SS 内部符号外流=0"; fi
MI=/tmp/w1151_mi.txt
/usr/bin/llvm-readelf --string-dump=.modinfo "$KO" | sed -E 's/^\[[ ]*[0-9a-f]+\] //' | tail -n +2 | sort > "$MI"
TOTAL_LINES=$(wc -l < "$MI"); PN=$(grep -c '^parmtype=' "$MI")
echo "  MODINFO_LINES=$TOTAL_LINES PARMTYPE=$PN  (判据：都>0)"
[ "$TOTAL_LINES" -gt 0 ] && [ "$PN" -gt 0 ] || BAD=1
for p in pd_abi pd_slots pd_verbose; do
  if grep -q "^parmtype=$p:" "$MI"; then echo "  [ok] $p 在"; else
    echo "  !! $p 不在产物 modinfo 里 ⇒ 腿传不进去(第 66 发那类空枪)"; BAD=1; fi
done
if grep -q '^parmtype=pd_zzz_not_defined:' "$MI"; then
  echo "  !! 反向对照失守：不存在的 pd_zzz_not_defined 却查到了 ⇒ 匹配式写坏了"; BAD=1
else
  echo "  [ok] 反向对照：pd_zzz_not_defined 查不到(匹配式有牙)"
fi
MODNAME=$(grep '^name=' "$MI" | head -1 | cut -d= -f2)
VERM=$(grep '^vermagic=' "$MI" | head -1 | cut -d= -f2-)
echo "  MODNAME=$MODNAME  VERMAGIC=[$VERM]"
[ "$MODNAME" = z6sepdec ] || { echo "  !! 件名≠z6sepdec"; BAD=1; }
case "$VERM" in
  5.4.281-qgki-*aarch64) echo "  [ok] vermagic 与设备同号";;
  *) echo "  !! vermagic 不是设备那一号 ⇒ 会被版本闸/modversions 拒"; BAD=1;;
esac
if [ -s "$KDIR/Module.symvers" ]; then
  MISSN=$(awk 'NR==FNR{need[$1]=1;next} {have[$2]=1} END{c=0;for(s in need) if(!(s in have)) c++; print c+0}' \
          /tmp/w1151_u.txt "$KDIR/Module.symvers")
  echo "  未导出合计=$MISSN / $NU"
  awk 'NR==FNR{need[$1]=1;next} {have[$2]=1} END{for(s in need) if(!(s in have)) print "    未导出: "s}' \
      /tmp/w1151_u.txt "$KDIR/Module.symvers" | sort | head -10
else
  echo "  !! 本机没有 Module.symvers ⇒ 这一格记「未测」"
fi
[ "$BAD" -eq 0 ] || { echo "VERDICT=red(尺没过) ⇒ 这个件不许上机"; exit 1; }
cp "$KO" /home/lucy/w1151_z6sepdec.ko || { echo "!! 复制产物失败"; exit 1; }
echo "KO_COPY_MD5=$(md5sum /home/lucy/w1151_z6sepdec.ko | cut -d' ' -f1)"
echo "VERDICT=ok  (宿主自测绿＋四条变异被抓＋aarch64 探针七把尺全过)"
echo "END $(date)"
