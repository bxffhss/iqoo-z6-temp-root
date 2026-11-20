#!/bin/bash
# rc33 = rc28(=rc27+killscan/killsoft) + **把 suw.apk 加进第二个 Manager 身份**(§6.74⑤)：
#   Kbuild 本来就支持 KSU_EXPECTED_SIZE2/HASH2 ⇒ 不用改源码，只要把 suw.keystore 的证书 DER
#   (705 字节=0x2c1, sha256=11c42292…d4063) 传进去。判据：dmesg 里出现
#   `Crowning manager: com.suw.manager(uid=10284)`，之后 SET_APP_PROFILE 才对我们开放。
# rc28 = rc27 + **killscan**(§6.69：扫厂商模块里所有 bl->force_sig，默认只打印不写；参数 scanmod/scanall/scannop)
#   原 rc27 = rc20 + (a) 修好我自己写错的 copy_to_kernel_nofault 地址闸门(sys_call_table 那笔写的真根因)
#              + (b) patch_memory 写前比对/逐步回执(P1..P4)
#              + (c) 调度器 E3 不再返回 -ENOSYS(改成回落原实现) —— 灭掉"adbd 全局 ENOSYS"这一类自伤
#              + (d) ksu_mass_mark=0 时连 mark-running 也一并拦掉 ⇒ 存量进程一个都不打标
#              + (e) F/F2/G 三行回执：tracepoint 到底有没有跑、改道有没有生效、标有没有进 ti->flags
#   动机：官方 KernelSU 管理器 v2.0.0 拿 fd 的方式是 scan_driver_fd()(只扫 /proc/self/fd)，
#   native 层没有任何 reboot 超级调用；我们晚加载 + 不挂 syscall hook ⇒ 它没 fd，才会显示
#   "版本 -1 过低"并锁死列表页。加了这条之后，官方 apk **一行不改**也可能直接可用。
#   判据：insmod 后 `echo <pid> > /sys/module/kernelsu/parameters/install_fd_pid`，dmesg 应出
#   `KSUFDINST 已排队给 pid=N` + 随后 `KSUFDINST 回调跑在 pid=N comm=[...] => fd=M`。
# rc33 = rc32 + suw.apk 作为第二个 Manager 身份(§6.74⑤)：
LOG=/home/lucy/ksu_rc50.log
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
cp /home/lucy/patch_ksu_killscan.py /home/lucy/ks.py; python3 /home/lucy/ks.py "$M"
cp /home/lucy/patch_ksu_unlimit.py /home/lucy/unl.py; python3 /home/lucy/unl.py "$M"
cp /home/lucy/patch_ksu_visible.py /home/lucy/vis.py; python3 /home/lucy/vis.py "$M"
cp /home/lucy/patch_ksu_fdinstall.py /home/lucy/fd.py; python3 /home/lucy/fd.py "$M"
echo "--- 校验(每处都应当=1):"
for pat in 'KSUBEAT BN' '没资格拿 su' 'pr_info_ratelimited("KSUBEAT' 'KSUBEAT SD0' 'KSUBEAT SD5' 'id == __NR_execve' 'KSUBEAT X0' 'KSUBEAT X8' 'KSUBEAT XC' 'KSUBEAT SU0' 'KSUBEAT SU3' 'ksu_no_escape' 'ksu_no_cred_override' 'KSUBEAT P1' 'KSUBEAT P2' 'KSUBEAT P4' 'patch_rc' '回落原实现' 'KSUBEAT F sys_enter' 'KSUBEAT F2' 'KSUBEAT G mark' 'mark-running' 'ksu_fd_install_run' 'ksu_install_fd' 'SLOTTBL' 'LSMHOOK' 'security_hook_heads' 'PCODE' 'KPROBEWALK' 'CFI ' 'OPENPROBE' 'CFIFIX' 'CFIGUARD'; do
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
  KSU_EXPECTED_SIZE2=0x2c1 \
  KSU_EXPECTED_HASH2=11c42292f3cce107eb5499002948c689b19493b47032d4532e29a618395d4063 \
  modules -j32
echo "RC=$?"
grep -E ' error: ' "$LOG" | sed 's/.* error: /ERR: /' | sort -u | head -12
ls -l "$M"/kernelsu.ko 2>/dev/null || { echo "!! 没产物"; echo "END $(date)"; exit 1; }

echo; echo "=== 4) 闸门自查 ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc50.txt
echo "U 总数 $(wc -l < /tmp/und_rc50.txt)"
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || echo "  未导出: $s"
done < /tmp/und_rc50.txt
echo -n "参数表: "; strings "$M/kernelsu.ko" | grep -E '^(ksu_stage|ksu_hook_mask|ksu_mass_mark|allow_shell|scanmod|scanall|scannop)$' | sort | tr '\n' ' '; echo
strings "$M/kernelsu.ko" | grep -c 'KILLSCAN' | sed 's/^/KILLSCAN 串数: /'
grep -c 'ksu_killscan_run' "$M/core/init.c" | sed 's/^/init.c 挂点: /'
strings "$M/kernelsu.ko" | grep -c 'KSUBEAT' | sed 's/^/KSUBEAT 串数: /'
echo "rc50chk opt3=$(grep -c "do_slot = (c" $M/infra/dev_syms.c) guard=$(grep -c CFIGUARD $M/infra/dev_syms.c) fixproc=$(grep -c ksu_fixcfi_write $M/infra/dev_syms.c) cfifix=$(grep -c ksu_cfi_fix_one $M/infra/dev_syms.c) taskstate=$(grep -c "task ti_flags=" $M/infra/dev_syms.c) cfi2=$(grep -c "CFI %s w%d" $M/infra/dev_syms.c) openprobe=$(grep -c ksu_open_probe_run $M/infra/dev_syms.c) kpbwalk=$(grep -c ksu_kprobe_walk $M/infra/dev_syms.c) cfi=$(grep -c ksu_cfi_check $M/infra/dev_syms.c) pcode=$(grep -c ksu_pcode_report $M/infra/dev_syms.c) lsmhook=$(grep -c ksu_lsmhook_report $M/infra/dev_syms.c) namebuf=$(grep -c 'KSYM_NAME_LEN + 16' $M/infra/dev_syms.c) snapshot=$(strings $M/kernelsu.ko | grep -c 'SLOTTBL done')"
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc50.ko && md5sum /home/lucy/kernelsu_rc50.ko
echo "END $(date)"
