#!/bin/bash
# w1162_precheck_remote.sh —— 构建机侧**只读**清点(0 枪，不碰设备)：接线之前把三条"我打算依赖的事实"量出来。
#   ①魔数与串长在内核里叫什么、从哪可达；②四个 SS 原型的家在哪个头；
#   ③我要不要走 link-time 符号(kallsyms_lookup_name / register_kprobe 有没有在 Module.symvers 里导出)——
#     这条直接决定 B 阶段那把 "SS 符号外流=0" 的尺会不会被我踢红。
# 全部 print，不用 `… | tail && echo OK`(那条在 §296 记过：输出会被吞)。
K=/root/k/nothing_sm7325_v_mr
KSU=/root/k/ksu
echo "=== [1] SELINUX_MAGIC 的家 ==="
grep -rn "define SELINUX_MAGIC" $K/include/linux/magic.h $K/security/selinux/include 2>/dev/null
echo "=== [1b] POLICYDB_STRING 的家(串长 8 的出处) ==="
grep -rn "define POLICYDB_STRING" $K/security/selinux/include 2>/dev/null
echo "=== [2] 四个原型在 include/security.h 里吗 ==="
for f in $K/security/selinux/include/security.h $K/security/selinux/include/ss/policydb.h; do
  echo "--- $f"
  grep -n "int security_read_policy\|int security_load_policy\|int security_policydb_len\|int security_context_to_sid" "$f" 2>/dev/null
done
echo "=== [2b] struct selinux_state 定义处 ==="
grep -rn "^struct selinux_state {" $K/security/selinux/include 2>/dev/null
echo "=== [3] 候选 link-time 符号是否在 Module.symvers 里导出 ==="
for s in kallsyms_lookup_name register_kprobe unregister_kprobe simple_read_from_buffer kstrtoull kstrtouint \
         security_load_policy security_read_policy security_policydb_len selinux_state vmalloc vfree proc_create proc_remove mutex_lock; do
  hit=$(grep -ac "	$s	" $K/Module.symvers 2>/dev/null)
  echo "  SYM $s symvers=$hit"
done
echo "=== [4] 现役桩落点与它现在 include 了什么(别猜树) ==="
ls -la $KSU/kernel/selinux/dropped_stub.c
md5sum $KSU/kernel/selinux/dropped_stub.c
grep -n '#include' $KSU/kernel/selinux/dropped_stub.c
echo "=== [5] 树里那几个头是否也能被 -I 命中(KCFLAGS 给了两条 -I) ==="
for h in security.h ss/services.h; do
  echo "  HEAD $h -> $(ls $K/security/selinux/include/$h 2>/dev/null || echo 无)"
done
echo "PRECHECK_DONE=1"
