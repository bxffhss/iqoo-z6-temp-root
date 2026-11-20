#!/bin/bash
# 把"KSU 移植波"需要的一手信息一次抓全：出错位置、flask.h 被用到的符号、树里的真实字段名。
LOG=/home/lucy/ksu_info.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
MDIR=/root/k/ksu/kernel
echo "=== 1) 每条 error 的文件:行 (来自上次构建日志) ==="
grep -E ' error: ' /home/lucy/ksu_build.log | sed -E 's#^/root/k/ksu/kernel/##' | head -20

echo; echo "=== 2) 哪些文件 include flask.h / 用到什么 selinux 符号 ==="
grep -rn 'flask.h' "$MDIR" | head
for f in $(grep -rl 'flask.h' "$MDIR" | head -6); do
  echo "--- $f 里疑似 6.x-only 的符号引用:"
  grep -nE 'security_ssid_to_sid|security_context_to_sid|struct lsm_context|lsm_context|flask_|SECURITY__|cc_.*sid|security_sid_to_context' "$f" | head -12
done

echo; echo "=== 3) 树里 seccomp / fsnotify_ops 的真实字段名(先量再改，别猜) ==="
sed -n '/^struct seccomp {/,/^};/p' "$KDIR/include/linux/seccomp.h"
echo "--- fsnotify_ops 的头两个成员签名:"
sed -n '/^struct fsnotify_ops {/,/^};/p' "$KDIR/include/linux/fsnotify.h" | head -14
echo "--- wake_up_q / TWA_ 在本树存不存在:"
grep -rn 'TWA_RESUME\|typedef struct wake_up_q' "$KDIR/include/linux/" | head -5

echo; echo "=== 4) KSU 用到 TWA_RESUME / handle_inode_event / filter_count 的位置 ==="
grep -rn 'TWA_RESUME' "$MDIR" | head
grep -rn 'handle_inode_event' "$MDIR" | head -4
grep -rn 'filter_count' "$MDIR" | head -4
grep -rn '_nofault\|__p4d_to_phys' "$MDIR" | head -12
echo "END $(date)"
