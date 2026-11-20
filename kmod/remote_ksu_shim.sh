#!/bin/bash
# 建 KSU 的 shim 头目录 + 编 KSU 的 LKM。
# 为什么用 shim 目录而不是改 KSU 源码：`linux/pgtable.h`/`linux/minmax.h` 是 5.5 才拆出来的头,
# 而 `security/selinux/include/{security,objsec}.h` 用 `#include "flask.h"` 的相对形式 ——
# 两者都是**纯包含路径**问题, 用 -I 解决比改代码干净, 而且完全可逆。
LOG=/home/lucy/ksu_shim.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
MDIR=/root/k/ksu/kernel
SH=/home/lucy/kshim
rm -rf "$SH"; mkdir -p "$SH/linux" "$SH/security"

echo "=== flask.h 在树里的真实位置:"
find "$KDIR/security" -name 'flask.h' | head
echo "=== pgtable/minmax 在 5.4 的去处:"
ls "$KDIR/include/asm-generic/pgtable.h" "$KDIR/arch/arm64/include/asm/pgtable.h" "$KDIR/include/linux/kernel.h" 2>&1 | head

cat > "$SH/linux/pgtable.h" <<'EOF'
/* shim: 5.4 没有 linux/pgtable.h(5.5 才拆), 用它已有的 */
#ifndef _KSU_SHIM_PGTABLE_H
#define _KSU_SHIM_PGTABLE_H
#include <asm/pgtable.h>
#include <asm-generic/pgtable.h>
#endif
EOF
cat > "$SH/linux/minmax.h" <<'EOF'
/* shim: 5.4 的 min/max/clamp 在 linux/kernel.h 里 */
#ifndef _KSU_SHIM_MINMAX_H
#define _KSU_SHIM_MINMAX_H
#include <linux/kernel.h>
#endif
EOF

# flask.h: 这棵树里**没有**(find 全盘为空)，而 KSU 依赖的 `security/selinux/include/{security,objsec}.h`
# 用 `#include "flask.h"`。从本地那份 mainline 5.4.281 取同代文件当 shim。
# ⚠ 这只解"编不过"，**不保证类/权限编号与厂商一致** —— 上机前必须核对 classmap/class_to_string
#    (vivo 自定义过 SELinux 类的话, 这里会错位)。记在 kmod/ROUTE-B-OFFSET-INVERSION.md 的待办里。
for f in /root/k/linux-5.4.281/security/selinux/include/flask.h /root/k/linux-5.4.281/security/selinux/flask.h; do
  if [ -f "$f" ]; then
    cp "$f" "$SH/flask.h"; cp "$f" "$SH/security/flask.h"
    echo "flask.h shim 来自: $f"; break
  fi
done
ls -l "$SH/flask.h" 2>&1

echo; echo "=== 编 KSU(带 -I shim 与 -include 兼容头)"
cd "$MDIR" || exit 1
make -C "$KDIR" M="$MDIR" src="$MDIR" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I$SH -I$KDIR/security/selinux/include -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
echo "=== 还剩哪些 error(按种类):"
grep -E ' error: ' "$LOG" | sed 's/.* error: //' | sort | uniq -c | sort -rn | head -20
echo "=== 产物:"; ls -l "$MDIR"/*.ko 2>/dev/null
echo "END $(date)"
