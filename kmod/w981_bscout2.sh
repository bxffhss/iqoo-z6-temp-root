#!/bin/bash
# 只读侦察 2：把上游 KernelSU 的 sepolicy 装载路径原样打出来（决定我们是"改活体"还是"重载镜像"）
set -u
KSU=/root/k/ksu/kernel/selinux
K=/root/k/linux-5.4.281
echo "=== A) 上游 selinux.c 全文（它只有 244 行，是唯一碰装载的入口）==="
cat -n "$KSU/selinux.c"
echo
echo "=== B) 上游 sepolicy.c 的装载/写回相关段 ==="
grep -n -E 'security_load_policy|policydb_write|policydb_read|sel_write_load|ss->policydb|state->policy|policydb \*|ksu_sesearch|apply_rules|avtab_' "$KSU/sepolicy.c" | head -60
echo
echo "=== C) 上游用了哪些 kallsyms 符号（KSU_KSYM 之类宏）==="
grep -rn -E 'KSU_KSYM|kallsyms_lookup_name|KSYM\(' /root/k/ksu/kernel/ 2>/dev/null | head -30
echo
echo "=== D) 5.4 树里这三个签名的原样 ==="
grep -n -E 'int security_load_policy|void \*data|size_t len' "$K/security/selinux/include/security.h" | head -10
echo "--- security_load_policy 函数头 12 行 ---"
awk '/^int security_load_policy/,0' "$K/security/selinux/ss/services.c" | head -60
echo "--- selinux_ss struct ---"
grep -n -A22 '^struct selinux_ss {' "$K/security/selinux/include/security.h"
echo "--- policydb_read 里是否自己调 policydb_init ---"
sed -n '2254,2290p' "$K/security/selinux/ss/policydb.c"
echo "--- policydb_write 头部（魔数/policy_type 怎么写）---"
sed -n '3384,3425p' "$K/security/selinux/ss/policydb.c"
echo "--- 魔数定义 ---"
grep -rn -E 'POLICY_MAGIC|MOD_POLICYDB_VERSION|MAGIC_POLICY' "$K/security/selinux/include/"*.h | head -20
echo DONE
