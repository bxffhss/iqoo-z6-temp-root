#!/bin/bash
# rc10：把最后一个"存在但未导出"的链接期引用(__tracepoint_sys_enter)改成运行时发现，
# 同时修 dev_syms 里"数据符号用 kprobe 取地址必然失败"的坑(md §6.24)。
LOG=/home/lucy/ksu_rc10.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
DEVS=/home/lucy/Module.symvers_dev
echo "START $(date)"

echo "=== 0) 前提核对：本树的 prio 注册宏到底是什么 ==="
grep -n 'define register_trace_prio_##name' -A2 "$KDIR/include/linux/tracepoint.h"
grep -n 'int tracepoint_probe_register_prio' "$KDIR/include/linux/tracepoint.h"
grep -n 'void for_each_kernel_tracepoint' "$KDIR/include/linux/tracepoint.h"
echo "--- struct tracepoint 前 3 个字段(name 必须存在):"
sed -n '/^struct tracepoint {/,/key;/p' "$KDIR/include/linux/tracepoint-defs.h"
echo "--- tracepoint_synchronize_unregister 在本树是不是内联(它没导出，若真是外部符号就是下一个坑):"
grep -n 'tracepoint_synchronize_unregister' "$KDIR/include/linux/tracepoint.h" | head -4
echo "--- KSU 全树还有谁直接吃 __tracepoint_*(除我们已改的这一处):"
grep -rn '__tracepoint_\|register_trace_' "$M" --include=*.c --include=*.h | head -10

echo; echo "=== 1) 上传文件就位检查(本地为准，已 put) ==="
ls -l /home/lucy/ksu_compat54.h /home/lucy/ksu_dev_syms.c
grep -c 'ksu_sys_enter_tp_register' /home/lucy/ksu_compat54.h /home/lucy/ksu_dev_syms.c
tail -3 /home/lucy/ksu_compat54.h

echo; echo "=== 2) 装 dev_syms(整文件覆盖，不做 sed) ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
cp /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h 2>/dev/null
grep -n 'dev_syms.o' "$M/Kbuild"

echo; echo "=== 3) 幂等打补丁：hook/syscall_hook_manager.c 换两处调用 ==="
python3 - <<'PY'
import re
p = "/root/k/ksu/kernel/hook/syscall_hook_manager.c"
s = open(p, encoding="utf-8", errors="replace").read()
if "ksu_sys_enter_tp_register" in s:
    print("  已打过，不动")
else:
    a1 = "    ret = register_trace_prio_sys_enter(ksu_sys_enter_handler, NULL, INT_MIN);"
    a2 = "    unregister_trace_sys_enter(ksu_sys_enter_handler, NULL);"
    n1 = "    ret = ksu_sys_enter_tp_register(ksu_sys_enter_handler);"
    n2 = "    ksu_sys_enter_tp_unregister(ksu_sys_enter_handler);"
    for a, n in ((a1, n1), (a2, n2)):
        c = s.count(a)
        if c != 1:
            raise SystemExit("!! 锚点命中 %d 次, 不动: %r" % (c, a))
        s = s.replace(a, n)
    open(p, "w", encoding="utf-8", newline="\n").write(s)
    print("  两处已替换")
PY
grep -n 'ksu_sys_enter_tp_' "$M/hook/syscall_hook_manager.c"

echo; echo "=== 4) 全量重编(删掉所有 .o 强制重编，兼容头是 -include 不进依赖) ==="
cd "$M" || exit 1
find "$M" -name '*.o' -delete
rm -f "$M"/kernelsu.ko "$M"/*.mod "$M"/.kernelsu.mod* 2>/dev/null
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
echo "--- 前 12 类 error:"
grep -E ' error: ' "$LOG" | sed 's/.* error: //' | sort | uniq -c | sort -rn | head -12
ls -l "$M"/kernelsu.ko 2>/dev/null || { echo "!! 没产物"; echo "END $(date)"; exit 1; }

echo; echo "=== 5) 离线闸门自查：未定义引用里还有没有'没导出'的(这次含 __ 前缀) ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc10.txt
echo "U 总数 $(wc -l < /tmp/und_rc10.txt)"
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || echo "  未导出: $s"
done < /tmp/und_rc10.txt
echo "--- 那 4 个符号现在应当是 T(本模块定义)或被消掉:"
/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -E '__set_fixmap|__arm64_sys_close|__arm64_sys_setns|__tracepoint_sys_enter' | head

cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc10.ko && md5sum /home/lucy/kernelsu_rc10.ko
echo "END $(date)"
