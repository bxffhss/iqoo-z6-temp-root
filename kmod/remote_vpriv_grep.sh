#!/bin/bash
# v2 里 VPRIV 取错了(从带缩进的 OUT 文件 sed，结果是空) ⇒ 直接读 /tmp/vpriv_*.txt。
# 目的：在 vivo 公开镜像里找出"那 179 个开关"的实现到底把 per-task 数据放在哪
#       (sched.h 里没有 ⇒ 要么别处结构体、要么独立 slab ⇒ 决定我们该 pad 哪里)。
LOG=/home/lucy/vpriv_grep.log
exec > "$LOG" 2>&1
R=/root/k/vivo_T1
cd "$R" || exit 1
V=/tmp/vpriv_nothing_sm7325_v_mr.txt
echo "vivo 镜像 Makefile: $(grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL)' Makefile | tr '\n' ' ')"
echo "厂商私有符号数: $(grep -c . $V)"

echo; echo "=== 1) 这些符号在 vivo 镜像里有没有实现(一次性建索引，别做 179 次 grep) ==="
grep -rhoE 'CONFIG_[A-Z0-9_]+' --include='*.c' --include='*.h' --include='Kconfig*' . 2>/dev/null \
  | sed 's/^CONFIG_/CONFIG_/' | sort -u > /tmp/vivo_syms.txt
sort -u /tmp/vpriv_nothing_sm7325_v_mr.txt > /tmp/want.txt     # 文件里已带 CONFIG_ 前缀
comm -12 /tmp/want.txt /tmp/vivo_syms.txt > /home/lucy/vpriv_present.txt
comm -23 /tmp/want.txt /tmp/vivo_syms.txt > /home/lucy/vpriv_absent.txt
echo "  vivo 镜像里也有: $(grep -c . /home/lucy/vpriv_present.txt) 个 / 没有(=86 之后新增): $(grep -c . /home/lucy/vpriv_absent.txt) 个"
echo "  有的这些(前 60):"; head -60 /home/lucy/vpriv_present.txt

echo; echo "=== 2) per-task 数据放哪：RSC/SLA 族在 include/ 下的字段定义 ==="
grep -rnE 'CONFIG_(RSC|SLA)[A-Z_0-9]*' include/ kernel/sched/ fs/proc/ 2>/dev/null | head -30

echo; echo "=== 3) 结构体头文件里出现这些开关的地方(全 include/) ==="
while read -r S; do
  grep -rn "$S" include/ 2>/dev/null | head -2
done < /home/lucy/vpriv_present.txt | grep -E '\.h:' | head -40

echo; echo "=== 4) asm/thread_info.h 与 linux/thread_info.h 的 vivo 版 vs QC 版 ==="
for f in include/linux/thread_info.h arch/arm64/include/asm/thread_info.h include/linux/sched/config.h; do
  echo "--- diff $f"; diff -u "/root/k/nothing_sm7325_v_mr/$f" "$f" | head -40
done

echo; echo "=== 5) ANDROID_VENDOR_DATA/KABI_RESERVE 的用量(vivo 是否动了保留区) ==="
grep -rnE 'ANDROID_(VENDOR_DATA|KABI_RESERVE)' include/linux/sched.h | head -12
echo "END $(date)"
