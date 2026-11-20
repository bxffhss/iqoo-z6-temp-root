#!/bin/bash
# w1162_precheck2_remote.sh —— 只读第二遍：把"接线要用的四个名字到底在树里哪儿"数出来。
# 第一遍有两处空手而归(SELINUX_MAGIC / POLICYDB_STRING)，那要么是**我 grep 的范围错了**，
# 要么是**这台机的树里根本没有 ss/ 那层**——两种解释对代码写法的影响完全不同，必须分开。
K=/root/k/nothing_sm7325_v_mr
S=$K/security/selinux
echo "=== [A] ss/ 这一层在不在 ==="
ls -d $S/ss 2>/dev/null && echo "  SS_DIR=有" || echo "  SS_DIR=无(这棵树把 SS 源码平铺在 security/selinux 下)"
echo "=== [B] SELINUX_MAGIC 全树定义处(不带 2>/dev/null，让'找不到'本身可见) ==="
grep -rn "define SELINUX_MAGIC" $K/include $K/security 2>/dev/null | head -6
echo "=== [C] POLICYDB_STRING 定义处 ==="
grep -rn "define POLICYDB_STRING" $K/security $K/include 2>/dev/null | head -6
echo "=== [D] 四个原型的声明点(逐个点名，数得到才算) ==="
for n in security_load_policy security_read_policy security_policydb_len security_context_to_sid; do
  c=$(grep -rn "^int $n(" $S 2>/dev/null | wc -l | tr -dc '0-9')
  echo "  DECL $n 头文件命中=$c"
  grep -rn "^int $n(" $S 2>/dev/null | head -2 | sed 's/^/    /'
done
echo "=== [E] security.h 自己 include 了谁(魔数是不是顺这条路进来的) ==="
grep -n '#include' $S/include/security.h | head -14
echo "=== [F] 这四个是否真的没导出(为'必须走 kallsyms'再补一次) ==="
for n in security_load_policy security_read_policy security_policydb_len; do
  echo "  SYMVERS $n=$(grep -ac "	$n	" $K/Module.symvers)"
done
echo "PRECHECK2_DONE=1"
