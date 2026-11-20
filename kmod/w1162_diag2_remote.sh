#!/bin/bash
# w1162_diag2_remote.sh —— 只读：把"哪一份 security.h 赢了"量出来，不看旗标表猜。
#   事实待答：SS 的 include/security.h:198 明明声明了 security_load_policy(刚才 sed 打出来了)，
#   可真编译却说 undeclared ⇒ 它引到的**不是**这一份。用 cc 自己的 -H 层级打印当证人。
K=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
CMD=$M/selinux/.dropped_stub.o.cmd
echo "=== [1] 上一次真编译这份桩用的 -I / -include 全序(现读 .cmd，不是我记) ==="
tr ' ' '\n' < "$CMD" | grep -n '^-I\|^-include\|^security\.h$\|^\-D__KERNEL__' | head -30
echo "=== [2] 同一条命令里有没有把 selinux/include 排在别的东西后面 ==="
tr ' ' '\n' < "$CMD" | grep -c 'selinux/include'
echo "=== [3] 用同一组旗标 + -H 只跑语法检查，打印 security.h 命中哪份(产物全进 /tmp) ==="
FLAGS=$(sed -n 's/^cmd_kernel\/selinux\/dropped_stub.o := //p' "$CMD" | head -1)
echo "  CMD_FOUND=$([ -n "$FLAGS" ] && echo 1 || echo 0)"
cd /root/k/ksu || exit 1
# 把真正的源换成我们上传的候选桩，旗标沿用 .cmd，只加 -H 与 -fsyntax-only
eval "${FLAGS% *}" -H -fsyntax-only -Wno-error /home/lucy/w1162_stub.c 2>/tmp/w1162_h.txt
echo "  cc rc=$?"
echo "  -H 层级里出现过的 security.h："
grep -ao '/[^ ]*security\.h' /tmp/w1162_h.txt | sort -u | sed 's/^/    HIT /'
echo "  前 8 行层级(看清是谁引谁)："
grep -a '^ ' /tmp/w1162_h.txt | head -8 | sed 's/^/    /'
echo "  error 摘录："
grep -a ' error: ' /tmp/w1162_h.txt | head -6 | sed 's/^/    /'
echo "=== [4] 假如 SS 那份被 KSU 的 -include 链挡住了：直接问预处理选中的第一个 security.h ==="
echo '#include "security.h"' > /tmp/w1162_p4.c
echo 'int zzz(void){ return SELINUX_MAGIC; }' >> /tmp/w1162_p4.c
clang -fsyntax-only -H -D__KERNEL__ $(tr ' ' '\n' < "$CMD" | grep '^-I' | tr '\n' ' ') /tmp/w1162_p4.c 2>/tmp/w1162_h4.txt
echo "  rc=$? 命中：$(grep -ao '/[^ ]*security\.h' /tmp/w1162_h4.txt | sort -u | tr '\n' ' ')"
head -6 /tmp/w1162_h4.txt | sed 's/^/    /'
echo "=== [5] KSU 自己的 kernel/selinux 下现在有没有 security.h(撞名前提复现读) ==="
ls $M/selinux/security.h 2>/dev/null || echo "  没有(与预期一致)"
DIAG2_DONE=1
