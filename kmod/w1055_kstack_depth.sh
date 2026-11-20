#!/bin/bash
# w1055_kstack_depth.sh —— 0 枪（纯主机）：把 w1054 剩的那半答掉。
#   上一格的读数：我们模块自己最坏链＝9632 B，THREAD_SIZE＝16384 B。但这**不等于**判死：
#   insmod 那条路在我们 init 之前已经吃掉的内核栈(系统调用入口→finit_module→load_module→do_one_initcall)
#   我还没量。9632 + 那一段 > 16384 才会溢出 ⇒ 本格量那一段。
# ★顺带把"上界"这个论证的两条前提各查一遍(论证是我自己写的，前提不能靠我说)：
#   前提甲：.su 里没有 dynamic(＝没有 alloca/VLA)，否则"帧之和＝上界"根本不成立 ⇒ 现数。
#   前提乙：调用图无环(上一格已印"环=无")，否则同一条链可把同一帧加多次。
set -u
KDIR=/root/k/nothing_sm7325_v_mr
D=/home/lucy/w1053_su
VML=$KDIR/vmlinux

echo "BEGIN $(date)"
echo "HOST_IDENTITY host=$(hostname) user=$(id -un) uname=$(uname -m)"

echo
echo "=== 0) 前提甲：.su 里有没有 dynamic(alloca/VLA)——有则【帧之和当上界】作废 ==="
DN=$(find "$D" -name '*.su' -exec grep -h dynamic {} + 2>/dev/null | grep -c .)
echo "dynamic 行数=$DN (判据：=0 ⇒ 前提甲成立，帧之和才是上界)"
find "$D" -name '*.su' -exec grep -h dynamic {} + 2>/dev/null | head -10 | sed 's|^|  RAW: |'

echo
echo "=== 1) 有没有带符号的 vmlinux(分母的另一半要在它身上量) ==="
if [ -f "$VML" ]; then
  echo "VMLINUX=在 bytes=$(wc -c < "$VML") md5=$(md5sum "$VML" | cut -d' ' -f1)"
  file "$VML" | sed 's|^|  |'
else
  echo "VMLINUX=无 ⇒ 这一格未测(不拿 System.map+裸 Image 硬凑：那条路要自己定函数边界，误差正好落在判据要的位数上)"
fi
if [ ! -s "$KDIR/System.map" ]; then
  echo "System.map=无"
else
  echo "System.map=有 行数=$(wc -l < "$KDIR/System.map")"
  for s in __arm64_sys_finit_module load_module do_one_initcall security_load_policy policydb_read; do
    echo "  $(grep -m1 -E " (t|T) $s\$" "$KDIR/System.map" || echo "  [查无] $s")"
  done
fi

echo
echo "=== 2) insmod 那条路上每个函数的栈帧(现读反汇编的 prologue，不背主线) ==="
if [ -f "$VML" ]; then
  for s in __arm64_sys_finit_module finit_module load_module do_one_initcall do_init_module \
           selinux_init security_load_policy policydb_read; do
    llvm-objdump -d --disassemble="$s" "$VML" > /tmp/w1055_one.txt 2>/dev/null
    if [ ! -s /tmp/w1055_one.txt ]; then echo "  $s = [反汇编取不到，未测]"; continue; fi
    # arm64 帧＝prologue 里第一条把 sp 减下去的指令：`sub sp, sp, #N` 或 `stp x29, x30, [sp, #-N]!`
    # ★解析器不许独吞读数：数字旁边一定把原始那几行也印出来，我自己用眼睛复核(见 §5 的教训)。
    FR=$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /^-?#/) { t = $i; gsub(/[^0-9]/, "", t)
                if (t != "" && t + 0 < 65536) { print t; exit } } }' /tmp/w1055_one.txt)
    echo "  $s frame=${FR:-未识别} 反汇编条数=$(grep -c . /tmp/w1055_one.txt)"
    grep -m4 -E '(sub[[:space:]]+sp, sp|stp[[:space:]]+x29|str[[:space:]]+x30)' /tmp/w1055_one.txt | sed 's|^|      RAW: |'
  done
  echo "-- 交叉核对：vmlinux 的 policydb_read 帧 应当与 w1054 里我们那份(policydb.c)同一数量级 --"
  grep -h 'policydb_read' "$D"/ss/policydb.su 2>/dev/null | sed 's|^|  我们那份: |'
else
  echo "  (没有 vmlinux，跳过)"
fi

echo
echo "=== 3) 算式(把两半摆在一起，结论留给人判，不让脚本替我圆) ==="
echo "  我们模块最坏链(w1054) = 9632 B      THREAD_SIZE(w1053 现读 page.h) = 16384 B"
echo "  ⇒ 留给内核 insmod 那条路的余量 = 16384 - 9632 = 6752 B"
echo "  第 2 节把那条路的每格帧印出来；若它们之和(再加系统调用入口的固定开销) < 6752 ⇒ 栈溢出这一候选**判死**"
echo "  ★注意口径：第 2 节量的是 boot 期加载策略也要走的那半(selinux_init→security_load_policy 与我们的链同深度)，"
echo "    所以真正区分【厂商活／我们炸】的只有 系统调用+finit_module+load_module 这几格的新增深度。"
echo "END $(date)"
