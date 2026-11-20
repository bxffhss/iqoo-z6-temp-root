#!/bin/bash
# rc24 = rc24 = rc20 + (a) 修好我自己写错的 copy_to_kernel_nofault 地址闸门(sys_call_table 那笔写的真根因)
#              + (b) patch_memory 写前比对/逐步回执(P1..P4)
#              + (c) 调度器 E3 不再返回 -ENOSYS(改成回落原实现) —— 灭掉"adbd 全局 ENOSYS"这一类自伤
#              + (d) ksu_mass_mark=0 时连 mark-running 也一并拦掉 ⇒ 存量进程一个都不打标
#              + (e) F/F2/G 三行回执：tracepoint 到底有没有跑、改道有没有生效、标有没有进 ti->flags
LOG=/home/lucy/ksu_rc24.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
DEVS=/home/lucy/Module.symvers_dev
echo "START $(date)"

echo "=== 1) 装文件 ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
echo "  compat 头两份都要换(-include 用的是 /home/lucy 那份，kshim 那份防被 #include):"
cp /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h
md5sum /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h
grep -n 'is_vmalloc_addr' /home/lucy/ksu_compat54.h && echo "  !! 旧闸门还在" || echo "  ok: is_vmalloc_addr 闸门已删"

echo; echo "=== 2) 幂等补丁 ==="
cp /home/lucy/patch_ksu_diag4.py /home/lucy/d4.py; python3 /home/lucy/d4.py "$M"
cp /home/lucy/patch_ksu_sucompat_gates.py /home/lucy/sg.py; python3 /home/lucy/sg.py "$M"
cp /home/lucy/patch_ksu_escape_steps.py /home/lucy/es.py; python3 /home/lucy/es.py "$M"
cp /home/lucy/patch_ksu_decline.py /home/lucy/dcl.py; python3 /home/lucy/dcl.py "$M"
echo "--- 校验(每处都应当=1):"
for pat in 'KSUBEAT SD0' 'KSUBEAT SD5' 'id == __NR_execve' 'KSUBEAT X0' 'KSUBEAT X8' 'KSUBEAT XC' 'KSUBEAT SU0' 'KSUBEAT SU3' 'ksu_no_escape' 'ksu_no_cred_override' 'KSUBEAT P1' 'KSUBEAT P2' 'KSUBEAT P4' 'patch_rc' '回落原实现' 'KSUBEAT F sys_enter' 'KSUBEAT F2' 'KSUBEAT G mark' 'mark-running'; do
    printf '  %-16s = %s\n' "$pat" "$(grep -rc "$pat" "$M" --include=*.c | awk -F: '{s+=$2} END{print s}')"
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
grep -E ' error: ' "$LOG" | sed 's/.* error: /ERR: /' | sort -u | head -12
ls -l "$M"/kernelsu.ko 2>/dev/null || { echo "!! 没产物"; echo "END $(date)"; exit 1; }

echo; echo "=== 4) 闸门自查 ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc24.txt
echo "U 总数 $(wc -l < /tmp/und_rc24.txt)"
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || echo "  未导出: $s"
done < /tmp/und_rc24.txt
echo -n "参数表: "; strings "$M/kernelsu.ko" | grep -E '^(ksu_stage|ksu_hook_mask|ksu_mass_mark|allow_shell)$' | sort | tr '\n' ' '; echo
strings "$M/kernelsu.ko" | grep -c 'KSUBEAT' | sed 's/^/KSUBEAT 串数: /'
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc24.ko && md5sum /home/lucy/kernelsu_rc24.ko
echo "END $(date)"
