#!/bin/bash
# 量 C 堆的爆炸半径：① Kbuild 里全部对象 ② 哪些 .c 因 SELinux 内部结构编不过 ③ 别的文件引用了它们的哪些符号
# 目的: 决定"从构建里剔除哪些 + 要补哪些桩"，不靠猜。
LOG=/home/lucy/ksu_blast.log
exec > "$LOG" 2>&1
M=/root/k/ksu/kernel
KDIR=/root/k/nothing_sm7325_v_mr

echo "=== 1) Kbuild 全对象列表 ==="
grep -nE 'kernelsu-objs' "$M/Kbuild"

echo; echo "=== 2) 逐文件单独编译(只编不链), 标出哪些属于 C 堆 ==="
for o in $(grep -oE '[a-zA-Z0-9_/]+\.o' "$M/Kbuild" | sort -u); do
  c="${o%.o}.c"
  [ -f "$M/$c" ] || c=$(find "$M" -name "$(basename $o)" -printf '%h/%f' 2>/dev/null | head -1)
  src="${c%.o}.c"
  [ -f "$M/$src" ] || { echo "  SKIP 找不到源: $o"; continue; }
  e=$(make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
        CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy \
        KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -include /home/lucy/ksu_compat54.h" \
        "$M/$o" 2>&1 | grep -cE ' error: ')
  if [ "$e" = "0" ]; then echo "  OK   $o"; else echo "  FAIL $o  (error $e 条)"; fi
done

echo; echo "=== 3) SELinux 内部结构类的错误分布在哪些文件 ==="
grep -E ' error: ' /home/lucy/ksu_round4.log | sed -E 's#^/root/k/ksu/kernel/##; s#^./security#<KDIR>/security#' | awk -F: '{print $1}' | sort | uniq -c | sort -rn | head -12

echo; echo "=== 4) 非 selinux 文件里对 sepolicy/selinux_hide 的引用(=要补的桩) ==="
grep -rnE '\bsepolicy_|selinux_hide|policydb_|filename_trans|security_context_to_sid|security_sid_to_context' "$M" \
  --include=*.c --include=*.h | grep -vE '^(.*sepolicy\.c|.*selinux_hide\.c|.*selinux/)' | head -20
echo "--- selinux/ 目录对外导出的函数:"
grep -rhoE '^[a-z_].*\b(sepolicy|ksu_selinux)[a-z_0-9]*\(' "$M/selinux" 2>/dev/null | head -12
echo "END $(date)"
