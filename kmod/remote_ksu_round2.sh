#!/bin/bash
# 三件事一次做完：① 找到 flask.h 的真实位置并放进 shim 目录 ② 取回两条要改的源码现场原文
# ③ 重编 KSU 看错误怎么变。★不盲改：filter_count / fsnotify 的表达式必须先看到原文再动锚点。
LOG=/home/lucy/ksu_round2.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
SH=/home/lucy/kshim
ML=/root/k/linux-5.4.281

echo "=== 1) flask.h 到底在哪(两棵树都找) ==="
find "$ML" -name 'flask.h' 2>/dev/null | head -3
find "$KDIR" -name 'flask.h' 2>/dev/null | head -3
echo "--- mainline 5.4 的 selinux/include 里有什么(找最像的):"
ls "$ML/security/selinux/include" 2>/dev/null | head -14
echo "--- 谁 include 了 flask.h:"
grep -rn '"flask.h"' "$KDIR/security/selinux/include" 2>/dev/null | head -4

echo; echo "=== 2) 两条待改源码的现场原文 ==="
echo "--- app_profile.c 里 filter_count 所在行(带行号):"
grep -n 'filter_count' "$M/policy/app_profile.c"
grep -n -B4 -A4 'filter_count' "$M/policy/app_profile.c" | head -24
echo "--- 本树里 seccomp_filter 有没有 count 字段:"
sed -n '/^struct seccomp_filter {/,/^};/p' "$KDIR/include/linux/seccomp.h" | head -14
echo "--- pkg_observer.c 的 handler 与 ops 表:"
grep -n -B2 -A14 'fsnotify_ops\|handle_inode_event\|handle_event' "$M/manager/pkg_observer.c" | head -46
echo "--- 本树 fsnotify_ops 的真实定义:"
sed -n '/^struct fsnotify_ops {/,/^};/p' "$KDIR/include/linux/fsnotify.h"

echo; echo "=== 3) 重编(带 shim/-include) ==="
cd "$M" || exit 1
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I$SH -I$KDIR/security/selinux/include -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
echo "=== 剩余 error(按种类):"
grep -E ' error: ' "$LOG" | sed 's/.* error: //' | sort | uniq -c | sort -rn | head -14
echo "=== 产物:"; ls -l "$M"/*.ko 2>/dev/null
echo "END $(date)"
