#!/bin/bash
# 砍掉 feature/selinux_hide.o(6.x SELinux 状态内部结构)，换成 5 个空函数的桩。
# 依据(一手)：feature/selinux_hide.h 只声明 5 个 void；调用点 5 处
#   core/init.c:141/215、runtime/boot_event.c:33/70、runtime/ksud_integration.c:163。
# 该特性是"对检测隐藏 root"，与"按白名单给 root"无关 ⇒ 砍它不损伤路线 B 的唯一硬收益。
LOG=/home/lucy/ksu_round8.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
SH=/home/lucy/kshim
T="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip"

echo "=== 1) 生成桩文件"
cat > "$M/feature/selinux_hide_stub.c" <<'EOF'
// SPDX-License-Identifier: GPL-2.0
/* 路线 B 的降级桩：原实现(feature/selinux_hide.c)依赖 6.x 的 SELinux 状态/策略内部结构
 * (selinux_state.policy / selinux_stat.status_page / status_lock / struct selinux_policy)，
 * 本树 5.4 没有这些 ⇒ 见 kmod/ROUTE-B-OFFSET-INVERSION.md §6.6/§6.7。
 * 这个特性只做"对检测隐藏 root"，不参与授权路径，所以空实现不影响 su 给 root。 */
#include <linux/types.h>

void ksu_selinux_hide_init(void) {}
void ksu_selinux_hide_exit(void) {}
void ksu_selinux_hide_drop_backup_if_unused(void) {}
void ksu_selinux_hide_handle_second_stage(void) {}
void ksu_selinux_hide_handle_post_fs_data(void) {}
EOF
echo "  写了 $M/feature/selinux_hide_stub.c"

echo; echo "=== 2) Kbuild 换对象(唯一锚点，幂等)"
python3 - <<'PY'
import re
p = "/root/k/ksu/kernel/Kbuild"
s = open(p, encoding="utf-8", errors="replace").read()
new = "# kernelsu-objs += feature/selinux_hide.o   # 剔除: 6.x SELinux 内部结构, 5.4 无 (md §6.7)\nkernelsu-objs += feature/selinux_hide_stub.o"
if "selinux_hide_stub.o" in s:
    print("  跳过(已换过)")
else:
    n = len(re.findall(r"^kernelsu-objs \+= feature/selinux_hide\.o$", s, re.M))
    if n == 1:
        s = re.sub(r"^kernelsu-objs \+= feature/selinux_hide\.o$", new, s, count=1, flags=re.M)
        open(p, "w", encoding="utf-8", newline="\n").write(s)
        print("  已换 selinux_hide.o -> selinux_hide_stub.o")
    else:
        print(f"  !! 锚点命中 {n} 次, 不动")
PY

echo; echo "=== 3) 顺便用生成出来的真 flask.h 顶掉最小 shim(类编号与本树一致)"
for f in flask.h av_permissions.h; do
  G=$(find "$KDIR/security/selinux" -name "$f" | head -1)
  if [ -n "$G" ]; then cp "$G" "$SH/$f"; cp "$G" "$SH/security/$f"; echo "  shim: $f <- $G"; fi
done

echo; echo "=== 4) 重编"
cd "$M" || exit 1
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m $T \
  KCFLAGS="-I$SH -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
echo "=== 剩余 error(按种类):"
grep -E ' error: ' "$LOG" | sed 's/.* error: //' | sort | uniq -c | sort -rn | head -12
echo "=== 产物:"; ls -l "$M"/kernelsu.ko 2>/dev/null || echo "(还没有 kernelsu.ko)"
echo "END $(date)"
