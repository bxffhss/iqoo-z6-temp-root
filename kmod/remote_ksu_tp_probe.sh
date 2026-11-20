#!/bin/bash
# 只读侦察：把"运行时取真 tracepoint"这条路需要的每一个前提核清楚，不动任何文件。
LOG=/home/lucy/ksu_tp_probe.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
SV=$KDIR/Module.symvers
DEVS=/home/lucy/Module.symvers_dev
KS=/home/lucy/kallsyms_dev.txt

echo "START $(date)"
echo "=== 0) 参照文件在不在 ==="
ls -l "$DEVS" "$KS" 2>&1 | head -4
[ -f "$DEVS" ] || { echo "(把 analysis/Module.symvers_dev 传上来)"; }

echo; echo "=== 1) 本树 include/linux/tracepoint.h 里 prio 注册的真实原型 ==="
grep -n 'register_trace_prio_##name\|register_trace_##name\|tracepoint_probe_register_prio\|tracepoint_probe_register(\|tracepoint_probe_unregister(\|for_each_kernel_tracepoint\|tracepoint_synchronize_unregister' \
  "$KDIR/include/linux/tracepoint.h" | head -30
echo "--- struct tracepoint 定义(字段顺序决定 name 的偏移):"
sed -n '/^struct tracepoint {/,/^};/p' "$KDIR/include/linux/tracepoint-defs.h"

echo; echo "=== 2) 这棵树有没有 prio 版(4 参) —— 决定我怎么调 ==="
grep -n 'int tracepoint_probe_register_prio' "$KDIR/include/linux/tracepoint.h" "$KDIR/kernel/tracepoint.c" | head

echo; echo "=== 3) 设备侧：这几个符号导出没导出 / 存在没存在 ==="
for s in for_each_kernel_tracepoint tracepoint_probe_register tracepoint_probe_register_prio \
         tracepoint_probe_unregister tracepoint_synchronize_unregister __tracepoint_sys_enter \
         sys_enter; do
  ex=$(awk -F'\t' -v s="$s" '$2==s{print $1" "$4}' "$DEVS" 2>/dev/null | head -1)
  ka=$(grep -E "[[:space:]](T|t|D|B|R|W)[[:space:]]$s\$" "$KS" 2>/dev/null | head -2 | tr '\n' ' ')
  printf '%-38s symvers=[%-28s] kallsyms=[%s]\n' "$s" "${ex:-未导出}" "${ka:-不存在}"
done

echo; echo "=== 4) 还有谁在用 tracepoint(KSU 全树) ==="
grep -rn 'register_trace_\|__tracepoint_\|for_each_kernel_tracepoint\|tracepoint_synchronize' "$M" --include=*.c --include=*.h | grep -v '^.*Binary' | head -20

echo; echo "=== 5) sys_enter 这个 tracepoint 在本树是不是内核内置(能被发现) ==="
grep -rn 'CREATE_TRACE_POINTS' "$KDIR/kernel/sys.c" "$KDIR/kernel/trace/" 2>/dev/null | grep -i syscall | head
grep -rn 'TRACE_EVENT_FN(sys_enter' "$KDIR/include/trace/events/syscalls.h" | head -3
grep -rn 'EXPORT_TRACEPOINT' "$KDIR/kernel/tracepoint.c" "$KDIR/include/linux/export.h" | head -8

echo; echo "=== 6) rc9 现在的未定义引用全表(逐个查 symvers) ==="
KO=$M/kernelsu.ko
ls -l "$KO" 2>/dev/null
/usr/bin/llvm-nm "$KO" 2>/dev/null | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc9.txt
echo "U 共 $(wc -l < /tmp/und_rc9.txt) 个"
while read -r s; do
  if awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS"; then :; else echo "  未导出: $s"; fi
done < /tmp/und_rc9.txt
echo "END $(date)"
