#!/usr/bin/env bash
# w1026_skel_build.sh —— 变体 A（0 枪）：一支"保留手工符号解析、不含任何 SS 代码"的骨架件。
# 它要分开的就是第 74 发剩下的那条缝：杀手在 `sym_addr(kallsyms_lookup_name)+逐个解析` 这一层，还是在 SS 子集里。
# ★符号表不手写：从 v4 探针件里现取 `llvm-nm -u` 的那批名字 ⇒ 解析次数与名字集合与探针件一致。
set -u
K=/root/k/nothing_sm7325_v_mr
V4=/home/lucy/w985_ssport/w985_probe.ko
D=/home/lucy/w1026
[ -f "$V4" ] || { echo "!! 没有 v4 探针件 ⇒ 停(不许凭记忆造符号表)"; exit 1; }
mkdir -p "$D"
llvm-nm -u "$V4" | awk '{print $NF}' | sort -u > "$D/names.txt"
N=$(wc -l < "$D/names.txt"); echo "从 v4 现取未解析符号=$N"
[ "$N" -gt 5 ] || { echo "!! 符号表太小($N)⇒ 这把对照没有判别力，停"; exit 1; }
{
  echo '/* w1026_skel.c —— 生成自 v4 的未解析符号表；只做"解析地址"这一件事，不调用、不碰策略。 */'
  echo '#include <linux/module.h>'
  echo '#include <linux/kernel.h>'
  echo '#include <linux/init.h>'
  echo '#include <linux/kallsyms.h>'
  echo '#include <linux/export.h>'
  echo 'MODULE_LICENSE("GPL");'
  echo 'static const char *names[] = {'
  while read -r s; do echo "  \"$s\","; done < "$D/names.txt"
  echo '};'
  echo 'static int skel_hits;   module_param(skel_hits, int, 0444);'
  echo 'static int skel_n = '"$N"'; module_param(skel_n, int, 0444);'
  echo 'static int __init skel_init(void)'
  echo '{ unsigned long a; int i, hit = 0; (void)a;'
  echo '  pr_info("W1026 SKEL init begin n=%d\n", (int)skel_n);'
  echo '  for (i = 0; i < skel_n; i++) { if (kallsyms_lookup_name(names[i])) hit++; }'
  echo '  skel_hits = hit;'
  echo '  pr_info("W1026 SKEL resolved hits=%d/%d\n", hit, (int)skel_n);'
  echo '  return 0;'
  echo '}'
  echo 'static void __exit skel_exit(void) { pr_info("W1026 SKEL exit\n"); }'
  echo 'module_init(skel_init); module_exit(skel_exit);'
  echo 'void __cfi_check(unsigned long long id, void *ptr, void *diag) { (void)id; (void)ptr; (void)diag; }'
} > "$D/w1026_skel.c"
printf 'obj-m += w1026_skel.o\n' > "$D/Makefile"
cd "$D" || exit 1
make -C "$K" M="$D" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip KCFLAGS="-Wno-unused-function" > build.log 2>&1
RC=$?; echo "MAKE_RC=$RC"
ERRN=$(grep -cE ': error: ' build.log); WARNN=$(grep -cE ': warning: ' build.log)
echo "DIAG_ERR=$ERRN DIAG_WARN=$WARNN (判据：都=0)"
[ "$RC" = 0 ] || { tail -25 build.log; exit 1; }
[ -f w1026_skel.ko ] || { echo "!! 没有产物"; exit 1; }
[ "$ERRN" = 0 ] && [ "$WARNN" = 0 ] || { grep -E ': (warning|error): ' build.log | sort -u | head; exit 1; }
[ "$(llvm-nm w1026_skel.ko | grep -cw __cfi_check)" = 1 ] || { echo "!! 缺 CFI 桩 ⇒ 不许上机"; exit 1; }
echo "--- 三件形状对照(尺寸/重定位/未解析) ---"
for f in /home/lucy/w1020/w1020_tiny.ko "$D/w1026_skel.ko" "$V4"; do
  printf "%-46s size=%8s reloc=%6s undef=%4s\n" "$(basename $f)" "$(wc -c < $f)" "$(llvm-readelf -r $f 2>/dev/null | grep -c R_AARCH64)" "$(llvm-nm -u $f | wc -l)"; done
md5sum w1026_skel.ko; echo SKEL_BUILD_OK
