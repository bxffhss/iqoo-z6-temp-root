#!/bin/bash
# 只读侦察 3：#216-B 的两个决定性未知数
#   ① 内核 policydb_read 对 policyvers/policy_type 的硬约束（我们喂 libsepol 写出的件，内核读不读得进）
#   ② 这棵树里 ss->policydb 通路上的真实结构体与常量
# 另外把我们 ko 的构建面(源码树布局/构建脚本/已 vendor 的头)摸清楚。
set -u
K=/root/k/linux-5.4.281
echo "=== 0) ksu 树布局（我们自己的端口放在哪、有哪些 vendored 头）==="
ls /root/k/ksu/ 2>/dev/null
echo "--- kernel/ ---"; ls /root/k/ksu/kernel/ 2>/dev/null
echo "--- kernel/selinux/ ---"; ls -la /root/k/ksu/kernel/selinux/ 2>/dev/null
echo "--- 我们 vendor 的 selinux 结构体头（找 selinux_ss/policydb 的自定义定义）---"
grep -rln -E 'struct selinux_ss|struct policydb|selinux_state' /root/k/ksu/kernel/ /root/k/ksu/include/ 2>/dev/null | head -20
echo
echo "=== 1) policydb_compat_info 表（内核能读哪些版本/种类）==="
grep -n -B4 -A48 'static struct policydb_compat_info policydb_compat' "$K/security/selinux/ss/policydb.c" | head -80
echo
echo "=== 2) policydb_read 里 policy_type / policyvers 的判据 ==="
sed -n '2254,2420p' "$K/security/selinux/ss/policydb.c" | grep -n -E 'policy_type|policyvers|POLICYDB_VERSION|compat|goto bad|return|pr_err' | head -50
echo
echo "=== 3) 常量与结构体 ==="
grep -rn -E '#define POLICYDB_MAGIC|#define POLICYDB_STRING|#define POLICYDB_VERSION_(BASE|AVTAB|MAX|MIN)' "$K/security/selinux/include/"*.h "$K/security/selinux/ss/"*.h "$K/security/selinux/ss/policydb.c" 2>/dev/null | head -20
echo "--- struct avtab 全文 ---"
sed -n '20,95p' "$K/security/selinux/ss/avtab.h"
echo "--- struct selinux_ss 在哪 ---"
grep -rn 'struct selinux_ss {' "$K/security/selinux/" 2>/dev/null
grep -rn -A24 'struct selinux_ss {' "$K/security/selinux/" 2>/dev/null | head -40
echo "--- struct policydb 前 40 行（看 te_avtab 的偏移深浅）---"
grep -n -A46 '^struct policydb {' "$K/security/selinux/ss/policydb.h"
echo
echo "=== 4) security_load_policy 的「已初始化」分支（我们真正会走的那条）==="
awk '/^int security_load_policy/,/^}/' "$K/security/selinux/ss/services.c" | sed -n '60,160p'
echo DONE
