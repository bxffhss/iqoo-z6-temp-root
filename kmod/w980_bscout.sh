#!/bin/bash
# 只读侦察：为 #216（把 sepolicy 补丁做进 ko）确定 5.4 侧可用的形状。
# 不写任何东西、不碰设备。
set -u
echo "=== who / where ==="
id -un; pwd
echo
echo "=== k tree layout ==="
ls -d /root/k/* 2>/dev/null | head -20
echo
KSU=/root/k/ksu/kernel/selinux
K=/root/k/linux-5.4.281
echo "=== 1) upstream ksu sepolicy: 它调用了哪些 SS 外部函数 ==="
if [ -d "$KSU" ]; then
  grep -n -E '\b(security_load_policy|policydb_read|policydb_write|policydb_destroy|policydb_init|avtab_[a-z_]+|sidtab_[a-z_]+|ebitmap_[a-z_]+|hashtab_[a-z_]+|symtab_[a-z_]+|context_[a-z_]+|mls_[a-z_]+|security_get_user_sids|security_compute_av|string_to_security_class|selinux_state|security_policycap)\b' \
    "$KSU"/sepolicy.c "$KSU"/rules.c "$KSU"/selinux.c 2>/dev/null \
    | sed 's/^.*\///' | awk -F: '{print $1" L"$2}' | sort | uniq -c | sort -rn | head -40
  echo "--- upstream: 装载策略那一段（原样打印，含 12 行上下文）"
  grep -n -B4 -A16 'security_load_policy' "$KSU"/selinux.c 2>/dev/null | head -60
  echo "--- upstream: 它怎么拿到 policydb（找 selinux_state / policy）"
  grep -n -E 'selinux_state|->policy\b|policydb \*|extern ' "$KSU"/selinux.c "$KSU"/sepolicy.c 2>/dev/null | head -40
else
  echo "MISSING $KSU"; ls /root/k/ 2>/dev/null
fi
echo
echo "=== 2) 5.4 树：policy_file / security_read_policy / avtab 插入点 ==="
grep -n -A12 'struct policy_file {' "$K/security/selinux/include/security.h" 2>/dev/null
echo "--- selinux_state struct ---"
grep -n -A30 '^struct selinux_state {' "$K/security/selinux/include/security.h" 2>/dev/null
echo "--- security_read_policy 定义 ---"
grep -n -A26 'int security_read_policy' "$K/security/selinux/ss/services.c" 2>/dev/null | head -40
echo "--- avtab 头（struct avtab / 函数声明） ---"
sed -n '1,200p' "$K/security/selinux/ss/avtab.h" 2>/dev/null | grep -n -E 'struct avtab|avtab_[a-z_]+\(|u32 nslots|MASK' | head -40
echo "--- avtab.c 里的插入函数是否 static ---"
grep -n -E '^(static )?[a-z_].*avtab_[a-z_]+\(' "$K/security/selinux/ss/avtab.c" 2>/dev/null | head -30
echo
echo "=== 3) 5.4 树：policydb_read/init 的可见性 + 类型表属性 ebitmap ==="
grep -n -E '^(int|static int|void|static void) (policydb_read|policydb_init|policydb_write|policydb_destroy|typeattribute_set)\(' "$K/security/selinux/ss/policydb.c" 2>/dev/null
grep -n -E 'CONFIG_SECURITY_SELINUX_(AUDITALREADY|SS|MLS)' "$K/security/selinux/Kconfig" 2>/dev/null | head
echo "--- type_datum / 属性 ebitmap ---"
grep -n -A8 'struct type_datum {' "$K/security/selinux/ss/policydb.h" 2>/dev/null
echo "--- 设备 config 里的 MLS ---"
ls /root/k/*/.config 2>/dev/null | head -3
grep -E 'CONFIG_SECURITY_SELINUX' /root/k/linux-5.4.281/.config 2>/dev/null | head
echo DONE
