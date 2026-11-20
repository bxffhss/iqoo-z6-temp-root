#!/bin/bash
# w1162_diag_remote.sh —— 只读诊断：①`security.h` 到底命中哪一份 ②SS 那份头的声明是否被 #ifdef 关着
#   ③构建失败之后**树有没有还原**(这是我自己欠的一手读数：包装那 20 条 [BAD] 里有一半只是"读不到行")。
K=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
echo "=== [1] kshim 里那个 security 是什么(目录?里面有 security.h 吗) ==="
ls -la /home/lucy/kshim/ | sed 's/^/  /'
echo "--- kshim/security 里面:"
find /home/lucy/kshim/security -maxdepth 2 2>/dev/null | sed 's/^/    /'
echo "=== [2] 全仓所有叫 security.h 的文件(谁在 -I 更前面) ==="
for d in /home/lucy/kshim $M $K/include $K/security/selinux; do
  find "$d" -maxdepth 3 -name 'security.h' 2>/dev/null | sed 's/^/  HIT /'
done
echo "=== [3] SS 那份 include/security.h：198~201 行的上下文有没有 #ifdef ==="
sed -n '185,205p' $K/security/selinux/include/security.h | cat -n
echo "  GUARD_198_to_201=$(awk 'NR>=150 && NR<=201 && /^#if/ {print NR": "$0}' $K/security/selinux/include/security.h | tr '\n' ';')"
echo "=== [4] 编译期实际解析到哪一份：用 -H 只跑 cc1 的预处理(不产任何文件、不改树) ==="
cd /tmp || exit 1
cat > /tmp/w1162_probe.c <<'EOF'
#include "security.h"
int w1162_probe_magic(void) { return SELINUX_MAGIC; }
EOF
clang -print-file-name=include 2>/dev/null | sed 's/^/  clang-incdir=/'
arm64_linux_gnu_gcc() { :; }
# 用与流水线同款的 -I 次序(先 kshim，再 selinux/include，再 selinux)，只问预处理，不链
clang -E -nostdinc \
  -I$K/include -I$K/include/uapi -I$K/arch/arm64/include -I$K/arch/arm64/include/uapi \
  -I$K/include/generated/uapi -I$K/scripts/gcc/include \
  -I/home/lucy/kshim -I$K/security/selinux/include -I$K/security/selinux \
  /tmp/w1162_probe.c -o /tmp/w1162_probe.i 2>/tmp/w1162_probe.err
echo "  预处理 rc=$?  产物行数=$(grep -c '' /tmp/w1162_probe.i 2>/dev/null | tr -dc '0-9')"
echo "  命中的 security.h 路径=$(grep -ao '/[^ "]*security\.h' /tmp/w1162_probe.i 2>/dev/null | sort -u | tr '\n' ' ')"
echo "  第一行报错=$(head -2 /tmp/w1162_probe.err | tr '\n' ' ')"
echo "=== [5] 树现在到底什么状态(还原有没有发生) ==="
echo "  桩 md5=$(md5sum $M/selinux/dropped_stub.c 2>/dev/null | cut -d' ' -f1)(出货那份应是 8795ceb4e73e8344e07dd5be30b4e0fa)"
echo "  桩字节=$(wc -c <$M/selinux/dropped_stub.c 2>/dev/null | tr -dc '0-9')"
echo "  备份件=$(md5sum /home/lucy/w1162_stub_pristine.c 2>/dev/null | cut -d' ' -f1)"
echo "  树里的头残留=$(ls $M/selinux/ 2>/dev/null | grep -cE 'w1151_|w1155_|w1161_')(必须 0)"
ls $M/selinux/ 2>/dev/null | grep -E 'w11' | sed 's/^/    还在:/'
MC=$(grep -rl 'module_exit(' $M --include='*.c' 2>/dev/null | head -1)
echo "  收尾文件=$MC  ksu_sepol_put 计数=$(grep -ac 'ksu_sepol_put' "$MC" 2>/dev/null)(必须 0)"
echo "=== [6] 现役出货件仍在那儿吗(货没动的第三只手) ==="
md5sum /home/lucy/kernelsu_rc74c.ko 2>/dev/null
DIAG_DONE=1
