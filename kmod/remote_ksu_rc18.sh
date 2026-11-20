#!/bin/bash
# rc18 = rc17 + **thread_info v2**(addr_limit 挪到实测的 0x40、preempt_count 0x50) + 布局自证打印
LOG=/home/lucy/ksu_rc18.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
DEVS=/home/lucy/Module.symvers_dev
echo "START $(date)"

echo "=== 1) 装文件 ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
cp /home/lucy/ksu_compat54.h /home/lucy/ksu_compat54.h

echo; echo "=== 2) thread_info v2（整块重写，幂等） ==="
cp /home/lucy/fix_thread_info_v2.py /home/lucy/ti2.py
grep -n 'struct thread_info {' -A 16 "$KDIR/arch/arm64/include/asm/thread_info.h" | head -22
python3 /home/lucy/ti2.py "$KDIR"
echo "--- 重写结果:"
grep -n '__KSU_TI_V2' -A 4 "$KDIR/arch/arm64/include/asm/thread_info.h" | head -8

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
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc18.txt
echo "U 总数 $(wc -l < /tmp/und_rc18.txt)"
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || echo "  未导出: $s"
done < /tmp/und_rc18.txt
echo -n "tilayout/uaccessprobe 串在不在: "; strings "$M/kernelsu.ko" | grep -cE 'tilayout|uaccessprobe'
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc18.ko && md5sum /home/lucy/kernelsu_rc18.ko
echo "END $(date)"
