#!/bin/bash
# rc19 = rc18 + hook_mask 逐位开关 + ksu_mass_mark(禁止大面积打标) + 调度器进入打印
LOG=/home/lucy/ksu_rc19.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
DEVS=/home/lucy/Module.symvers_dev
echo "START $(date)"

echo "=== 1) 装文件 ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
grep -n 'ksu_hook_mask\|ksu_mass_mark' "$M/infra/dev_syms.c" | head

echo; echo "=== 2) 三个补丁(都幂等) ==="
cp /home/lucy/patch_ksu_hookmask.py /home/lucy/hm.py;  python3 /home/lucy/hm.py "$M"
cp /home/lucy/patch_ksu_massmark.py /home/lucy/mm.py;  python3 /home/lucy/mm.py "$M"
cp /home/lucy/patch_ksu_diag3.py /home/lucy/d3.py;    python3 /home/lucy/d3.py "$M"
echo "--- 校验:"
grep -n 'ksu_hook_mask & ' "$M/hook/syscall_hook_manager.c" | head -6
grep -n 'ksu_mass_mark' "$M/hook/tp_marker.c" "$M/infra/dev_syms.c" | head -6
grep -n 'KSUBEAT E' "$M/hook/arm64/syscall_hook.c" | head -4

echo; echo "=== 3) 全量重编 ==="
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

echo; echo "=== 4) 闸门自查 ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc19.txt
echo "U 总数 $(wc -l < /tmp/und_rc19.txt)"
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || echo "  未导出: $s"
done < /tmp/und_rc19.txt
echo -n "参数表: "; strings "$M/kernelsu.ko" | grep -E '^(ksu_stage|ksu_hook_mask|ksu_mass_mark|allow_shell)$' | sort | tr '\n' ' '; echo
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc19.ko && md5sum /home/lucy/kernelsu_rc19.ko
echo "END $(date)"
