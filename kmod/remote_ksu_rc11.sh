#!/bin/bash
# rc11 = rc10 + 两件事：
#   A) infra/seccomp_cache.c 整文件换成**空操作**(上游那份按"有 action cache 的 struct seccomp_filter"
#      布局写位图，本机内核这个结构根本没有 cache ⇒ 一发 allowlisted setuid 就是堆越界写)。
#   B) dev_syms 里加 `apfmt:` 尺寸回执(与 cm57/ksuctl 打的同一组数字对表)。
LOG=/home/lucy/ksu_rc11.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
DEVS=/home/lucy/Module.symvers_dev
echo "START $(date)"

echo "=== 0) 判据前提：本机树里到底有没有 seccomp action cache ==="
echo -n "全树 action_cache/allow_native/SECCOMP_ARCH_NATIVE_NR 命中数: "
grep -rc 'action_cache\|allow_native\|SECCOMP_ARCH_NATIVE_NR' "$KDIR/kernel/seccomp.c" "$KDIR/include/linux/seccomp.h" 2>/dev/null | tr '\n' ' '
echo; echo "--- 真 struct seccomp_filter(逐字):"
grep -n 'struct seccomp_filter {' -A 10 "$KDIR/kernel/seccomp.c"
echo "--- 上游 KSU 那份手写布局(要被打掉的东西):"
grep -n 'struct action_cache {' -A 8 "$M/infra/seccomp_cache.c"
grep -n 'refcount_t refs\|refcount_t users\|struct action_cache cache' "$M/infra/seccomp_cache.c"
echo "--- 调用点(只有 setuid_hook 两处):"
grep -rn 'ksu_seccomp_allow_cache\|ksu_seccomp_clear_cache' "$M" --include=*.c | grep -v seccomp_cache.c

echo; echo "=== 1) 整文件替换 seccomp_cache.c + 装 dev_syms(本地为准) ==="
cp /home/lucy/ksu_seccomp_cache_noop.c "$M/infra/seccomp_cache.c" && echo "  seccomp_cache.c <- noop ($(wc -l < "$M/infra/seccomp_cache.c") 行)"
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c <- $(wc -l < "$M/infra/dev_syms.c") 行"
grep -c 'set_bit\|clear_bit' "$M/infra/seccomp_cache.c" | sed 's/^/  现在位图操作条数: /'

echo; echo "=== 2) 全量重编 ==="
cd "$M" || exit 1
find "$M" -name '*.o' -delete
rm -f "$M"/kernelsu.ko 2>/dev/null
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
grep -E ' error: ' "$LOG" | sed 's/.* error: /ERR: /' | sort -u | head -10
ls -l "$M"/kernelsu.ko 2>/dev/null || { echo "!! 没产物"; echo "END $(date)"; exit 1; }

echo; echo "=== 3) 未定义引用里还有没有没导出的 ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc11.txt
echo "U 总数 $(wc -l < /tmp/und_rc11.txt)"
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || echo "  未导出: $s"
done < /tmp/und_rc11.txt
echo "--- 三个转发函数应当是本模块的 T:"
/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -E ' T __(set_fixmap|arm64_sys_close|arm64_sys_setns)$'
echo "--- apfmt 那条打印在不在(拿不到=回执没编进去):"
/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -c 'dev_syms' 
strings "$M/kernelsu.ko" | grep -c 'apfmt:'
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc11.ko && md5sum /home/lucy/kernelsu_rc11.ko
echo "END $(date)"
