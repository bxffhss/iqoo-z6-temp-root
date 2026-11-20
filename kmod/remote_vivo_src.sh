#!/bin/bash
# vivo 公开源码(5.4.86 那份镜像) vs QC qgki 树 的**结构体头文件 diff**。
# 目的：把"厂商私有开关到底往 task_struct/thread_info/module/cred 里加了什么字段"从推测变成一手文本。
# 跑法(远端，脱管)：setsid nohup bash /home/lucy/remote_vivo_src.sh </dev/null >/dev/null 2>&1 &
LOG=/home/lucy/vivo_src.log
exec > "$LOG" 2>&1
echo "START $(date)"
R=/root/k/vivo_T1
QT=/root/k/nothing_sm7325_v_mr
if [ ! -d "$R/.git" ]; then
  git clone --depth 1 https://github.com/vivo-source-mirror/T1_IQOO_Z6_5G "$R" 2>&1 | tail -3
fi
cd "$R" || { echo CLONE_FAIL; exit 1; }
echo "=== vivo 镜像 Makefile 版本:"; grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION)' Makefile
echo "=== 顶层有没有 vendor/ 或 vivo 目录:"; ls -d */ | head -30

echo; echo "=== 关键头文件是否存在:"
for f in include/linux/sched.h include/linux/cred.h include/linux/module.h \
         include/linux/thread_info.h arch/arm64/include/asm/thread_info.h \
         include/linux/sched/rt.h include/linux/nsproxy.h; do
  printf '%-46s %s\n' "$f" "$(test -f "$f" && wc -l < "$f")"
done

echo; echo "=== 那 179 个[厂商私有]开关里, 有哪些真的出现在 vivo 源码的结构体头文件里:"
VPRIV=$(sed -n 's/^      \([A-Z0-9_]*\)$/\1/p' /tmp/vpriv_nothing_sm7325_v_mr.txt 2>/dev/null | head -200)
HDRS="include/linux/sched.h include/linux/cred.h include/linux/module.h include/linux/thread_info.h arch/arm64/include/asm/thread_info.h include/linux/sched/rt.h include/linux/fs.h include/linux/mm_types.h"
for S in $VPRIV; do
  HITS=$(grep -l "$S" $HDRS 2>/dev/null | tr '\n' ' ')
  [ -n "$HITS" ] && echo "  $S  -> $HITS"
done | tee /home/lucy/vivo_in_headers.txt

echo; echo "=== 这些开关在全树的命中文件数(前 25 名):"
grep -rhoE 'CONFIG_(RSC[A-Z_0-9]*|SLA[A-Z_0-9]*|EZRAM[A-Z_0-9]*|VFCS[A-Z_0-9]*|VIVO[A-Z_0-9]*|APP_LINK|MOBILEEVENT|TSHELL|PROCESS_MLOCK|PAGECACHE_STAT|SHRINKER_PROXY)' \
  --include='*.c' --include='*.h' . 2>/dev/null | sort | uniq -c | sort -rn | head -25

for f in include/linux/sched.h arch/arm64/include/asm/thread_info.h include/linux/module.h include/linux/cred.h; do
  O=/home/lucy/diff_$(basename $f).txt
  diff -u "$QT/$f" "$R/$f" > "$O" 2>&1
  echo; echo "=== diff $f  (QC 树 → vivo 镜像): $(grep -c '^[+-]' "$O") 行变更, 其中结构体内新增/删除:"
  grep -nE '^[+-].*(struct|u64|unsigned|long|int |void|\*|CONFIG_)' "$O" | head -30
done
echo "END $(date)"
