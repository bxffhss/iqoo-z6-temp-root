#!/bin/bash
# 收掉 check_ko 的三条: __cfi_check / vermagic 的尾部 '+' / 两个漏掉的桩。
LOG=/home/lucy/ksu_round11.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
echo "START $(date)"

echo "=== 0) 桩的签名必须照声明写(先取原文，别猜) ==="
grep -rn 'apply_kernelsu_rules\|handle_sepolicy' "$M"/selinux/*.h "$M"/include/*.h 2>/dev/null | head -6
echo "--- 调用点原文:"
grep -rn 'handle_sepolicy(' "$M/supercall/dispatch.c" | head -3

echo; echo "=== 1) 写桩文件 selinux/dropped_stub.c ==="
cat > "$M/selinux/dropped_stub.c" <<'EOF'
// SPDX-License-Identifier: GPL-2.0
/* 路线 B 的降级桩: 原实现.selinux/sepolicy.c/rules.c 依赖 6.x 的 SELinux SS 内部结构
 * (filename_trans_key / datum.stypes / sidtab / selinux_state.policy)，本树 5.4 没有。
 * 见 kmod/ROUTE-B-OFFSET-INVERSION.md §6.6/§6.7。
 * ★保守返回: 注入类不谎报成功(-EOPNOTSUPP)，规则应用类什么都不做。 */
#include <linux/err.h>
#include <linux/types.h>

void apply_kernelsu_rules(void) {}

int handle_sepolicy(unsigned long arg3[3], void __user *buf, int *response)
{
	return -EOPNOTSUPP;
}
EOF
echo "  写了 $M/selinux/dropped_stub.c"

echo; echo "=== 2) Kbuild 加 cfi_stub.o + dropped_stub.o(锚点 = 第一行 ':=' 那条) ==="
cp /home/lucy/cfi_stub.c "$M/cfi_stub.c"
python3 - <<'PY'
import re
p = "/root/k/ksu/kernel/Kbuild"
s = open(p, encoding="utf-8", errors="replace").read()
add = ("kernelsu-objs += cfi_stub.o      # 自带 accept-all __cfi_check(本机 CFI 非 permissive)\n"
       "kernelsu-objs += selinux/dropped_stub.o  # 剔除 6.x sepolicy 层的保守桩(md §6.7)")
if "cfi_stub.o" in s:
    print("  已加过")
else:
    for pat in (r"^kernelsu-objs := core/init\.o$", r"^kernelsu-objs \+= core/init\.o$"):
        n = len(re.findall(pat, s, re.M))
        if n == 1:
            s = re.sub(pat, "\\1\n" + add.replace("\\", "\\\\"), s, count=1, flags=re.M)
            open(p, "w", encoding="utf-8", newline="\n").write(s)
            print("  已加(锚点: %s)" % pat)
            break
        print("  锚点 %s 命中 %d 次" % (pat, n))
PY
grep -nE 'cfi_stub|dropped_stub' "$M/Kbuild"

echo; echo "=== 3) 去掉 vermagic 尾部的 '+'(setlocalversion 因为 .git 存在且树被改过而加 '+') ==="
[ -d "$KDIR/.git" ] && mv "$KDIR/.git" "$KDIR/.git.off" && echo "  .git 暂时改名 -> .git.off"
make -C "$KDIR" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld prepare -j32 >/dev/null 2>&1
echo "  kernel.release = $(cat $KDIR/include/config/kernel.release)"

echo; echo "=== 4) 重编 ==="
cd "$M" || exit 1
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
grep -E ' error: |WARNING' /home/lucy/ksu_round11.log | sed 's/.* error: /ERR: /' | sort -u | head -8
ls -l "$M"/kernelsu.ko 2>/dev/null
/usr/bin/llvm-objcopy --dump-section=.modinfo=/dev/stdout "$M/kernelsu.ko" 2>/dev/null | tr '\0' '\n' | grep vermagic
llvm-nm "$M/kernelsu.ko" 2>/dev/null | grep -E '__cfi_check|handle_sepolicy|apply_kernelsu_rules'
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc3.ko 2>/dev/null && md5sum /home/lucy/kernelsu_rc3.ko
echo "END $(date)"
