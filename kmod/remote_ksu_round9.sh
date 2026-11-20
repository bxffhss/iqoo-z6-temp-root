#!/bin/bash
# 收掉两条安全的，并把 patch_memory.c 的现场取回来(那两处不猜)。
LOG=/home/lucy/ksu_round9.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel

echo "=== 0) patch_memory.c 现场(先读再动)"
echo "--- 1..70 (页表walk/__p4d_to_phys 用法):"; sed -n '1,70p' "$M/hook/arm64/patch_memory.c"
echo "--- 120..170 (copy_to_kernel_nofault 用法):"; sed -n '120,170p' "$M/hook/arm64/patch_memory.c"

echo; echo "=== 1) 兼容头补 security_inode_init_security_anon(5.4 无此钩子, 6.x 用于给匿名 inode 打标)"
printf '%s\n' \
 '/* 6.x 才有的匿名 inode 标注钩子; 5.4 无 ⇒ 提供"什么都不做=允许"的空实现。' \
 ' * 语义: 该调用只在 KSU 自己创建匿名 inode 时问一次, 返回 0 = 放行, 不影响授权判定。 */' \
 '#ifndef ksu_have_inode_init_security_anon' \
 'static inline int security_inode_init_security_anon(struct inode *inode,' \
 '\t\t\t\t\tconst struct qstr *name, const struct inode *dir)' \
 '{ return 0; }' \
 '#define security_inode_init_security_anon security_inode_init_security_anon' \
 '#endif' >> /home/lucy/ksu_compat54_extra.h
cp /home/lucy/ksu_compat54.h /home/lucy/ksu_compat54.h.bak 2>/dev/null
grep -q init_security_anon /home/lucy/ksu_compat54.h || \
  sed -i '/^#endif \/\* _KSU_COMPAT54_H/d' /home/lucy/ksu_compat54.h
grep -q init_security_anon /home/lucy/ksu_compat54.h || \
  cat /home/lucy/ksu_compat54_extra.h >> /home/lucy/ksu_compat54.h
echo '#endif /* _KSU_COMPAT54_H */' >> /home/lucy/ksu_compat54.h
tail -12 /home/lucy/ksu_compat54.h

echo; echo "=== 2) pkg_observer.c 去掉多余的 dir 参数(本树 handle_event 是 8 参数)"
python3 - <<'PY'
import re
p = "/root/k/ksu/kernel/manager/pkg_observer.c"
s = open(p, encoding="utf-8", errors="replace").read()
pat = r"struct inode \*dir, const struct qstr \*file_name"
n = len(re.findall(pat, s))
if "u32 mask, const void *data, int data_type,\n\t\t\t  const struct qstr *file_name" in s:
    print("  跳过(已去掉 dir)")
elif n == 1:
    s = s.replace("struct inode *dir, const struct qstr *file_name", "const struct qstr *file_name")
    open(p, "w", encoding="utf-8", newline="\n").write(s)
    print("  已去掉 dir")
else:
    print(f"  !! 锚点命中 {n} 次, 不动")
PY

echo; echo "=== 3) 重编"
cd "$M" || exit 1
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
echo "=== 剩余 error(按种类):"
grep -E ' error: ' "$LOG" | sed 's/.* error: //' | sort | uniq -c | sort -rn | head -10
echo "=== 产物:"; ls -l "$M"/kernelsu.ko 2>/dev/null || echo "(还没有 kernelsu.ko)"
echo "END $(date)"
