#!/bin/bash
# #237(B′) 的 0 枪构建：把 kmod/w1140_polload.c 编成 z6polload.ko，一次过七把尺。
# ★与 w985_ssport_build.sh 的差别是故意的：这一件**不编任何 SS 源码**(没有 ss/ 目录、没有 avtab 补丁)，
#   只借设备自己的四个入口＋selinux_state，全部走运行期 kallsyms 解析。⇒ 尺查的是另一件事：
#   ★★那五个名字**绝不该**出现在产物的未解析表里(出现＝链接期去找 vmlinux 那份 ⇒ insmod 必以未知符号失败)。
#   正对照(§293 那一手：空的读数必须有"它能非空"的证明)：`register_kprobe` 是真引用，它**必须**在表里。
set -u
KDIR=/root/k/nothing_sm7325_v_mr
SRC=$KDIR/security/selinux
D=/home/lucy/w1141_polload
LOG=$D/build.log
NM=/usr/bin/llvm-nm

echo "BEGIN $(date)"
echo "KDIR=$KDIR  编译器侧一手：$($NM --version 2>/dev/null | head -1)"
ls -d "$SRC/include" >/dev/null || { echo "!! 没有 $SRC/include ⇒ 停"; exit 1; }
rm -rf "$D"; mkdir -p "$D"

echo; echo "=== 1) 三个输入件各报 md5，缺一个就不编(不许编一份说不出来历的件) ==="
if [ ! -f /home/lucy/w1141_main.c ]; then
  echo "!! /home/lucy/w1141_main.c 不在 ⇒ 先跑 kmod/w1141_run.sh(主源由本地 put 进来，远端不留陈件)"
  exit 1
fi
cp /home/lucy/w1141_main.c "$D/z6polload_main.c" || { echo "!! 拷主源失败"; exit 1; }
echo "MAIN_MD5=$(md5sum "$D/z6polload_main.c" | cut -d' ' -f1)"
if [ ! -s /root/k/ksu/kernel/cfi_stub.c ]; then
  echo "!! /root/k/ksu/kernel/cfi_stub.c 不在或是空的 ⇒ 停(没桩的件不许上机：§6.484，那条不在判据里时我们花了三枪)"
  exit 1
fi
cp /root/k/ksu/kernel/cfi_stub.c "$D/cfi_stub.c" || { echo "!! 拷桩失败"; exit 1; }
echo "STUB_MD5=$(md5sum "$D/cfi_stub.c" | cut -d' ' -f1)"
echo "HDR_SECURITY_MD5=$(md5sum "$SRC/include/security.h" | cut -d' ' -f1)"
echo "HDR_FLASK_MD5=$(md5sum "$SRC/flask.h" | cut -d' ' -f1)"

cat > "$D/Makefile" <<'MK'
# B′ 探针：只一个主源＋CFI 桩；不链任何 SS 对象(设计上就不解析)
obj-m += z6polload.o
z6polload-y := z6polload_main.o cfi_stub.o
MK
ls -la "$D" | sed -n '1,12p'

echo; echo "=== 2) 编(与出货脚本同一条 make 行的编译器设置；-I 指原树头，不拷副本) ==="
# ★只给两个 -I：$SRC/include 让 #include "security.h" 命中，$SRC 让它里面的 #include "flask.h" 命中。
#   故意**不**加 -I$SRC/ss：主源不 include ss/*.h(那条链在 w985 撞过两个 conditional.h 共用 guard 的坑)。
cd "$D" && make -C "$KDIR" M="$D" \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I$SRC/include -I$SRC -Wno-unused-function" \
  modules > "$LOG" 2>&1
RC=$?
echo "MAKE_RC=$RC  (★这一步之后才取 RC，别在管道末端取)"
echo "-- error 行(去重)"; grep -E ' error: ' "$LOG" | sed 's/^.* error: /ERR: /' | sort -u | head -20
echo "-- warning 行(去重)"; grep -E ': warning: ' "$LOG" | sed 's/^.* warning: /WARN: /' | sort -u | head -20
ERRN=$(grep -cE ': error: ' "$LOG")
WARNN=$(grep -cE ': warning: ' "$LOG")
IMPN=$(grep -cE 'implicit declaration' "$LOG")
echo "DIAG_ERR=$ERRN DIAG_WARN=$WARNN DIAG_IMPLICIT=$IMPN   (判据：三个都必须=0)"
if [ "$ERRN" -ne 0 ] || [ "$WARNN" -ne 0 ] || [ "$IMPN" -ne 0 ]; then
  echo "!! 诊断非零 ⇒ 判负(带 warning 的件不许当上机件)"; tail -30 "$LOG"; exit 1
fi

echo; echo "=== 3) 产物 ==="
KO="$D/z6polload.ko"
if [ ! -f "$KO" ]; then
  echo "!! 没有 .ko ⇒ 本格判负"; tail -40 "$LOG"; exit 1
fi
ls -l "$KO"; md5sum "$KO"; file "$KO" | sed 's/^/  /'
echo "KO_MD5=$(md5sum "$KO" | cut -d' ' -f1)"

echo; echo "=== 4) 尺①：__cfi_check 必须恰=1(§6.484：=0 时内核经 do_one_initcall 间接调用本件会当场 panic) ==="
CFIN=$($NM "$KO" 2>/dev/null | grep -cw __cfi_check)
echo "  CFI_STUB=$CFIN"
[ "$CFIN" = 1 ] || { echo "!! CFI 桩数量≠1 ⇒ 这个件不许派上机"; exit 1; }

echo; echo "=== 5) 尺②：未解析表(必须非空＝表是真的；里面出现 SS 名字或那五个运行期名字都是坏事) ==="
$NM -u "$KO" | awk '{print $2}' | sort > /tmp/w1141_u.txt
NU=$(wc -l < /tmp/w1141_u.txt)
echo "  UNRESOLVED_TOTAL=$NU"
[ "$NU" -gt 0 ] || { echo "  !! 未解析表是空的 ⇒ 这个读数没有判别力(先怀疑 nm 没跑成)，不许当通过"; exit 1; }
head -40 /tmp/w1141_u.txt | tr '\n' ' '; echo
BAD=0
# 正对照：真引用的东西必须在表里，否则说明"查表"这把尺本身是坏的
if grep -qx register_kprobe /tmp/w1141_u.txt; then
  echo "  [ok] 正对照：register_kprobe 在未解析表里(尺有牙)"
else
  echo "  !! register_kprobe 不在表里 ⇒ 尺不可信，后面那五条的'不在'也不许信"; BAD=1
fi
for n in security_load_policy security_read_policy security_policydb_len security_context_to_sid selinux_state; do
  if grep -qx "$n" /tmp/w1141_u.txt; then
    echo "  !! $n 被当成链接期引用 ⇒ insmod 会以未知符号失败(这四个函数＋那个数据符号都只许按名字运行期取)"
    BAD=1
  else
    echo "  [ok] $n 不在未解析表(只在代码里当字符串传给 kallsyms)"
  fi
done
LEAK=$(grep -E 'policydb|avtab|ebitmap|hashtab|symtab|context_|mls_|cond_' /tmp/w1141_u.txt | tr '\n' ' ')
if [ -n "$LEAK" ]; then
  echo "  !! SS 内部符号外流(这一件设计上就该是 0)：$LEAK"; BAD=1
else
  echo "  SS 内部符号外流=0"
fi

echo; echo "=== 6) 尺③：模块参数在产物里真存在(腿要按名字写值，参数丢了就是空枪)＋件名/vermagic ==="
# ★★这一格第一版用的是 `strings -a | grep '^param='` ⇒ 数到 0。不是 strings 坏了：本机 5.4 的 modpost
#   写进 .modinfo 的是 **`parmtype=<名>:<类型>`**，压根没有 `param=` 这个前缀(我用 python 直接数原始字节
#   `b"param="` 复证＝0 次，与 strings 同向 ⇒ 是"读法错被读成数据坏"，例 227 的第七次犯)。
#   ⇒ 改成读 .modinfo 那一段，并**先印它自己解析了多少行**(TOTAL_LINES)，再点名查参数。
MI=/tmp/w1141_mi.txt
/usr/bin/llvm-readelf --string-dump=.modinfo "$KO" \
  | sed -E 's/^\[[ ]*[0-9a-f]+\] //' | tail -n +2 | sort > "$MI"
TOTAL_LINES=$(wc -l < "$MI")
PN=$(grep -c '^parmtype=' "$MI")
echo "  MODINFO_LINES=$TOTAL_LINES  PARMTYPE=$PN  (判据：两个都 >0 才有判别力；=0 先怀疑读段这条路没通)"
[ "$TOTAL_LINES" -gt 0 ] && [ "$PN" -gt 0 ] || { echo "  !! modinfo 读出来是空的 ⇒ 这把尺坏了"; BAD=1; }
for p in pl_key pl_cap pl_test_ctx pl_ctrl_ctx pl_abi; do
  if grep -q "^parmtype=$p:" "$MI"; then
    echo "  [ok] $p 在"
  else
    echo "  !! $p 不在产物 modinfo 里 ⇒ 腿传不进去(第 66 发那类空枪的形状)"; BAD=1
  fi
done
# 反向对照：一个我们确实没定义的名字必须查不到，否则上面那五条"在"是假的
if grep -q '^parmtype=pl_zzz_not_defined:' "$MI"; then
  echo "  !! 反向对照失守：不存在的 pl_zzz_not_defined 却查到了 ⇒ 匹配式写坏了"; BAD=1
else
  echo "  [ok] 反向对照：pl_zzz_not_defined 查不到(匹配式有牙)"
fi
# 件名与 vermagic：腿拼 /sys/module/<名>/parameters 的路径、以及"这枚是不是这台机的件"都靠这两行
MODNAME=$(grep '^name=' "$MI" | head -1 | cut -d= -f2)
VERM=$(grep '^vermagic=' "$MI" | head -1 | cut -d= -f2-)
echo "  MODNAME=$MODNAME"
echo "  VERMAGIC=[$VERM]"
[ "$MODNAME" = z6polload ] || { echo "  !! 件名≠z6polload ⇒ 腿里那条 /sys/module/... 路径是假的"; BAD=1; }
case "$VERM" in
  5.4.281-qgki-*aarch64) echo "  [ok] vermagic 与设备同号(5.4.281-qgki- 前缀＋aarch64)";;
  *) echo "  !! vermagic 不是设备那一号 ⇒ insmod 会被 modversions/版本闸拒掉"; BAD=1;;
esac

echo; echo "=== 7) 尺④：未解析的那些名字有多少不在导出表里(>0 就得走 kallsyms，本件全靠它) ==="
if [ -s "$KDIR/Module.symvers" ]; then
  MISSN=$(awk 'NR==FNR{need[$1]=1;next} {have[$2]=1} END{c=0;for(s in need) if(!(s in have)) c++; print c+0}' \
          /tmp/w1141_u.txt "$KDIR/Module.symvers")
  echo "  未导出合计=$MISSN / $NU"
  awk 'NR==FNR{need[$1]=1;next} {have[$2]=1} END{for(s in need) if(!(s in have)) print "    未导出: "s}' \
      /tmp/w1141_u.txt "$KDIR/Module.symvers" | sort | head -20
else
  echo "  !! 本机没有 $KDIR/Module.symvers ⇒ 这一格记「未测」，不记「都导出」"
fi

if [ "$BAD" -ne 0 ]; then
  echo "VERDICT=红(上面有尺没过) ⇒ 这个件不许上机"
  exit 1
fi
cp "$KO" /home/lucy/w1141_z6polload.ko || { echo "!! 复制产物失败 ⇒ 本地取不到件"; exit 1; }
echo "KO_COPY=/home/lucy/w1141_z6polload.ko"
echo "KO_COPY_MD5=$(md5sum /home/lucy/w1141_z6polload.ko | cut -d' ' -f1)"
echo "VERDICT=ok(七把尺全过：诊断 0／CFI=1／运行期五名不外流／SS 外流 0／参数齐／反向对照有牙)"
echo "END $(date)"
