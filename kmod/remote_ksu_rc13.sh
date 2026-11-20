#!/bin/bash
# rc13 = rc11 + **分级闸门 ksu_stage**(为了在"取不到崩溃后日志"的机器上定位上一发的重启)
LOG=/home/lucy/ksu_rc13.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
DEVS=/home/lucy/Module.symvers_dev
echo "START $(date)"

echo "=== 1) 装本地为准的文件 ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
cp /home/lucy/ksu_seccomp_cache_noop.c "$M/infra/seccomp_cache.c" && echo "  seccomp_cache.c 已换空操作"
cp /home/lucy/ksu_compat54.h /home/lucy/ksu_compat54.h.bak 2>/dev/null; echo "  兼容头由 -include 直接吃 /home/lucy/ksu_compat54.h"

echo; echo "=== 2) 打分级闸门(幂等锚点补丁) ==="
cp /home/lucy/patch_ksu_stage.py /home/lucy/ps.py
python3 /home/lucy/ps.py "$M"
echo "--- 校验：每道闸门都在，且函数体第一行就是它:"
for f in hook/arm64/syscall_hook.c supercall/supercall.c hook/syscall_hook_manager.c manager/throne_tracker.c manager/pkg_observer.c selinux/selinux.c; do
  echo "[$f]"; grep -n 'ksu_stage_ok' "$M/$f" || echo "  !! 没有闸门"
done

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
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc13.txt
echo "U 总数 $(wc -l < /tmp/und_rc13.txt)"
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || echo "  未导出: $s"
done < /tmp/und_rc13.txt
echo "--- 参数表(__param 里应有 ksu_stage/allow_shell/norc/bundled):"
strings "$M/kernelsu.ko" | grep -E '^ksu_stage$|^allow_shell$|^norc$|^bundled$' | sort
echo "--- exit 闸门计数(应为 4)::"
strings "$M/kernelsu.ko" | grep -c 'KSUSTEP'
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc13.ko && md5sum /home/lucy/kernelsu_rc13.ko
echo "END $(date)"
