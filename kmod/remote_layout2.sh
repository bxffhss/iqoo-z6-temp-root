#!/bin/bash
# 第二轮：把"夹逼洞"要用的**嵌套类型**也一次性 dump 出来（pahole 默认不展开嵌套 struct）。
# 用法：bash /home/lucy/remote_layout2.sh
LOG=/home/lucy/layout2.log
exec > "$LOG" 2>&1
echo "START $(date)"
TYPES="task_struct dl_task_struct sched_entity cred module module_kobject module_layout kprobe nsproxy thread_info signal_struct fs_struct files_struct pt_regs rt_mutex wait_queue_head list_head linux_binfmt audit_context"
for T in linux-5.4.281 ack nothing_sm7325_v_mr nothing_sm7325_u_mr; do
  D=/root/k/layout_$T
  OBJ=""
  for c in dw.lto.o dw.o; do [ -f "$D/$c" ] && OBJ="$D/$c" && break; done
  [ -z "$OBJ" ] && { echo "SKIP $T (没有 dw.o)"; continue; }
  OUT=/home/lucy/layout2_$T.txt
  : > "$OUT"
  echo "$T 用 $OBJ"
  for S in $TYPES; do
    echo "===== $S ($T)" >> "$OUT"
    pahole -C "$S" "$OBJ" >> "$OUT" 2>&1
  done
  echo "OK $T -> $OUT $(wc -l < "$OUT") 行"
done
echo "END $(date)"
