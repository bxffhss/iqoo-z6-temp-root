#!/bin/bash
# 第四波：① flask.h 用 **vivo 自己那份**(编号必须跟厂商一致) ② 取回两处待改源码原文
# ③ 重编看计数。判据: kernelsu.ko 存在 && check_ko.py 过。
LOG=/home/lucy/ksu_round4.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
SH=/home/lucy/kshim
mkdir -p "$SH/linux" "$SH/security"

echo "=== 1) vivo 公开源码里的 flask.h ==="
V=$(find /root/k/vivo_T1 -name 'flask.h' 2>/dev/null | head -1)
echo "  找到: ${V:-没有}"
if [ -n "$V" ]; then
  cp "$V" "$SH/flask.h"; cp "$V" "$SH/security/flask.h"
  echo "  行数 $(wc -l < "$SH/flask.h"); 里面有没有 SECINITSID_/security_class:"
  grep -cE 'SECINITSID_|security_class' "$SH/flask.h"
  echo "  厂商自定义的类(前 12 个 SECCLASS_):"; grep -oE 'SECCLASS_[A-Z_]+' "$SH/flask.h" | sort -u | head -12
else
  echo "  ⇒ 退回最小 shim(只补类型);若 classmap.h 已给 SECINITSID_* 就够用"
  cat > "$SH/flask.h" <<'EOF'
#ifndef _KSU_SHIM_FLASK_H
#define _KSU_SHIM_FLASK_H
#include <linux/types.h>
typedef u32 ssid_t;
struct security_class { char *name; ssid_t num; };
#endif
EOF
  cp "$SH/flask.h" "$SH/security/flask.h"
fi
echo "--- 对照: vivo 的 classmap.h 与本树的是否同源"
diff -q /root/k/vivo_T1/security/selinux/include/classmap.h "$KDIR/security/selinux/include/classmap.h" 2>&1 | head -2

echo; echo "=== 2) 待改源码原文 ==="
echo "--- manager/pkg_observer.c:1..95"
sed -n '1,95p' "$M/manager/pkg_observer.c"
echo "--- policy/app_profile.c:78..126 (含 filter_count 那个函数)"
sed -n '78,126p' "$M/policy/app_profile.c"

echo; echo "=== 3) 重编 ==="
cd "$M" || exit 1
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I$SH -I$KDIR/security/selinux/include -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
echo "=== 剩余 error(按种类):"
grep -E ' error: ' "$LOG" | sed 's/.* error: //' | sort | uniq -c | sort -rn | head -14
echo "=== 产物:"; ls -l "$M"/kernelsu.ko 2>/dev/null || echo "(还没有 kernelsu.ko)"
echo "END $(date)"
