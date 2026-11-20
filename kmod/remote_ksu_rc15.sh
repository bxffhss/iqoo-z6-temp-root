#!/bin/bash
# rc15 = rc14 + hook 层自检(KSUBEAT A 读回比对 / B 调度器进入一次)
# 内核日志尾"定位到具体哪一句，而不是只定位到子系统。见 md §6.28/§6.29。
LOG=/home/lucy/ksu_rc15.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
DEVS=/home/lucy/Module.symvers_dev
echo "START $(date)"

echo "=== 1) 打脚印(幂等) ==="
cp /home/lucy/patch_ksu_steps.py /home/lucy/steps.py
python3 /home/lucy/steps.py "$M"
cp /home/lucy/patch_ksu_diag.py /home/lucy/diag.py
python3 /home/lucy/diag.py "$M"
echo "--- 校验: 每个文件里的 KSUBEAT 行数"
grep -rc 'KSUBEAT' "$M/hook/syscall_hook_manager.c" "$M/feature/kernel_umount.c" "$M/feature/sucompat.c" \
     "$M/supercall/supercall.c" "$M/hook/arm64/syscall_hook.c" "$M/core/init.c" 2>/dev/null
echo "--- core/init.c 晚加载区间的脚印顺序(应当 L0..L10):"
grep -n 'KSUBEAT L' "$M/core/init.c" | sed 's/pr_info(//; s/\\n");//' | head -14

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

echo; echo "=== 3) 闸门自查 ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc15.txt
echo "U 总数 $(wc -l < /tmp/und_rc15.txt)"
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || echo "  未导出: $s"
done < /tmp/und_rc15.txt
echo -n "KSUBEAT 串条数: "; strings "$M/kernelsu.ko" | grep -c 'KSUBEAT'
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc15.ko && md5sum /home/lucy/kernelsu_rc15.ko
echo "END $(date)"
