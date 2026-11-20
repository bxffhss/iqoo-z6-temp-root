#!/usr/bin/env bash
set -u
T=/root/k/linux-5.4.281
echo "=== __alloc_fd 本体开头(有没有 !files 的护) ==="
awk '/^static int __alloc_fd\(/,/^}/' $T/fs/file.c | head -28
echo "=== 对照：close_fd / __close_fd 有没有 NULL 护(内核自己知道这条路会踩空) ==="
awk '/^int __close_fd\(|int close_fd\(/,/^}/' $T/fs/file.c | head -30
grep -n -B3 -A8 'if (unlikely(!files))' $T/fs/file.c | head -40
echo "FDINSTALL_AUDIT5_DONE"
