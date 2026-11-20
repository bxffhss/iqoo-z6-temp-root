#!/bin/bash
# 装上 ① (运行时符号解析层) 然后重编，判据 = check_ko.py 的"未定义引用"从 19 个降到 3 个。
LOG=/home/lucy/ksu_devsyms.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
echo "START $(date)"

echo "=== 1) 放文件: infra/dev_syms.c ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  ok ($(wc -l < "$M/infra/dev_syms.c") 行)"

echo; echo "=== 2) Kbuild 追加 dev_syms.o(幂等) ==="
grep -q 'infra/dev_syms.o' "$M/Kbuild" || printf '\nkernelsu-objs += infra/dev_syms.o\n' >> "$M/Kbuild"
grep -n 'dev_syms.o' "$M/Kbuild"

echo; echo "=== 3) 注入点: core/init.c 的 apply_kernelsu_rules(); 之前 ==="
python3 - <<'PY'
import re
p = "/root/k/ksu/kernel/core/init.c"
s = open(p, encoding="utf-8", errors="replace").read()
if "ksu_dev_syms_init()" in s:
    print("  已注入")
else:
    n = len(re.findall(r"^[ \t]*apply_kernelsu_rules\(\);", s, re.M))
    if n == 1:
        s = re.sub(r"^([ \t]*)apply_kernelsu_rules\(\);",
                   r"\1ksu_dev_syms_init();   /* 未导出符号必须先解析(md §6.11) */\n\1apply_kernelsu_rules();",
                   s, count=1, flags=re.M)
        open(p, "w", encoding="utf-8", newline="\n").write(s)
        print("  已注入 ksu_dev_syms_init()")
    else:
        print(f"  !! 锚点命中 {n} 次, 不动")
PY
grep -n 'ksu_dev_syms_init' "$M/core/init.c" | head -3

echo; echo "=== 4) selinux_state 没做别名(tag 同名), 三处显式改写 ==="
python3 - <<'PY'
import re
p = "/root/k/ksu/kernel/selinux/selinux.c"
s = open(p, encoding="utf-8", errors="replace").read()
before = s.count("selinux_state.")
s = s.replace("selinux_state.enforcing", "ksu_p_selinux_state->enforcing")
s = s.replace("selinux_state.disabled", "ksu_p_selinux_state->disabled")
open(p, "w", encoding="utf-8", newline="\n").write(s)
print(f"  改写前 selinux_state. 出现 {before} 次, 现在剩 {s.count('selinux_state.')} 次")
PY
grep -n 'ksu_p_selinux_state' "$M/selinux/selinux.c" | head -5

echo; echo "=== 5) 重编 ==="
cd "$M" || exit 1
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  modules -j32
echo "RC=$?"
echo "--- 前 12 条 error:"
grep -E ' error: ' "$LOG" | sed 's/.* error: /ERR: /' | sort -u | head -12
ls -l "$M"/kernelsu.ko 2>/dev/null
echo "--- 现在还剩哪些未定义(U)符号属于那 19 个:"
llvm-nm "$M/kernelsu.ko" 2>/dev/null | awk '$1=="U"{print $2}' | sort -u > /tmp/und2.txt
comm -12 /tmp/n19.txt /tmp/und2.txt
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc6.ko 2>/dev/null && md5sum /home/lucy/kernelsu_rc6.ko
echo "END $(date)"
