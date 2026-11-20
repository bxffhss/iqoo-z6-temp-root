#!/bin/bash
# w1050_asan_probe.sh —— 0 枪（纯主机）：量「把同一份 SS 子集在 x86_64 上开 ASAN 跑真实导出」要垫多少东西。
#   为什么先量再写：上一版这一格我按**猜的三个目录**去 ls 头文件，于是给每个本地头都印了「★缺」——
#   而它明明编得过。那是一手教训(先证明对照组存在，再比较／先证控件会在红的时候红)。本版把
#   「找头」换成 **find 整棵树**，并且 ASAN 那一条**自己带双向对照**：坏件必须报、好件必须不报，两臂同形＝仪器坏。
#   本脚本只读：不碰设备、不碰 /sys/fs/selinux/load、不改出货包。
set -u
D=/home/lucy/w985_ssport
KDIR=/root/k/nothing_sm7325_v_mr
SRC=$KDIR/security/selinux

echo "BEGIN $(date)"
echo "HOST_IDENTITY host=$(hostname) user=$(id -un) uname=$(uname -m) kernel=$(uname -r)"
echo "PWD_IDENTITY pwd=$(pwd)"

echo
echo "=== 1) 子集在不在(不在就报'未测'，不去猜) ==="
if [ -d "$D/ss" ]; then
  echo "PORT_PRESENT=1 dir=$D files=$(find "$D" -maxdepth 2 -type f | wc -l)"
else
  echo "PORT_PRESENT=0 dir=$D ⇒ 本发未建；改用原树 $SRC 量同一批事(下面 SRC 有则继续)"
fi
if [ -d "$SRC/ss" ]; then
  echo "SRCTREE_PRESENT=1 $SRC/ss .c=$(ls "$SRC"/ss/*.c 2>/dev/null | wc -l) .h=$(ls "$SRC"/ss/*.h 2>/dev/null | wc -l)"
else
  echo "SRCTREE_PRESENT=0 ⇒ 两把尺都不在场，判未测退出"; exit 1
fi
BASE=$D
[ -d "$D/ss" ] || BASE=$SRC

echo
echo "=== 1b) ★先把【被测对象】落成一份显式文件表(上一格吃过『两臂其实没换对象』的亏，这里让它自证) ==="
FILES=""
for f in "$BASE"/ss/*.c "$BASE"/ss/*.h; do [ -f "$f" ] && FILES="$FILES $f"; done
if [ -d "$D/ss" ]; then
  for f in "$D"/*.c "$D"/*.h; do [ -f "$f" ] && FILES="$FILES $f"; done
  echo "输入面＝port 树(SS 子集＋主源＋桩) FILES_N=$(printf '%s\n' $FILES | grep -c .)"
else
  echo "输入面＝原树 ss/ 子集(没有主源/桩) FILES_N=$(printf '%s\n' $FILES | grep -c .)"
  echo "  ★注意：这一臂量的是【原树 ss/】，不是【我们编进 ko 的那份子集】——两者若不同，结论要标【外推】"
fi
echo "文件清单："; printf '%s\n' $FILES | sed 's|^|   |'

echo
echo "=== 2) ★找头＝find 整棵树(上一版的错就是只 ls 三个猜的目录) ==="
# 被 include 的本地头＝引号形式；对每一个 find 出它的所有落点，找不到才算缺。
HDRS=$(grep -hoE '#include[[:space:]]+"[^"]+"' $FILES 2>/dev/null \
        | sed -E 's/.*"(.*)"/\1/' | sort -u)
echo "quote-include 去重条数=$(printf '%s\n' "$HDRS" | grep -c .)"
for h in $HDRS; do
  bn=$(basename "$h")
  hits=$(find "$D" "$SRC" -name "$bn" -type f 2>/dev/null | sed 's|^| |' | tr -d '\n')
  n=$(find "$D" "$SRC" -name "$bn" -type f 2>/dev/null | wc -l)
  if [ "$n" = "0" ]; then echo "  [缺] $bn"; else echo "  [在 $n 处] $bn ->$hits"; fi
done

echo
echo "=== 3) 尖括号 include 面(＝要垫的假头清单，输入面＝第 1b 节那张表) ==="
grep -hoE '#include[[:space:]]*<[^>]+>' $FILES 2>/dev/null \
  | sed -E 's/.*<(.*)>/\1/' | sort | uniq -c | sort -rn

echo
echo "=== 4) 内核 API 面(固定词表＋逐条计数；0 命中要能区分'没用到'和'grep 坏了') ==="
PAT='kmalloc|kzalloc|kcalloc|kmalloc_array|kmem_cache_[a-z_]+|kvfree|kvmalloc[a-z_]*|vzalloc|kstrdup|kfree|GFP_KERNEL|pr_(info|err|warn|notice|debug)|rcu_read_(lock|unlock)|spin_lock_irqsave|spin_unlock_irqrestore|mutex_|BUG_ON|WARN_ON|scnprintf|find_next_bit|smp_[a-z_]+|READ_ONCE|WRITE_ONCE'
tot=$(cat "$BASE"/ss/*.c 2>/dev/null | wc -l)
echo "ss/*.c 文件数=$(ls "$BASE"/ss/*.c 2>/dev/null | wc -l) 总行数=$tot (不为 0 才说明第 4 节的 grep 有输入面)"
for p in $PAT; do
  c=$(grep -hoE "$p" "$BASE"/ss/*.c 2>/dev/null | wc -l)
  printf '  %-26s %s\n' "$p" "$c"
done

echo
echo "=== 5) 工具链 + ★ASAN 通道有没有牙(两臂必须翻面) ==="
echo "gcc=$(gcc --version 2>/dev/null | head -1)"
echo "clang=$(command -v clang >/dev/null 2>&1 && clang --version | head -1 || echo 无)"
T=$(mktemp -d)
cat > "$T/bad.c" <<'EOF'
#include <stdlib.h>
#include <stdio.h>
int main(void){ char *p=(char*)malloc(16); p[16]=(char)'x'; printf("wrote %d\n",(int)p[16]); free(p); return 0; }
EOF
cat > "$T/good.c" <<'EOF'
#include <stdlib.h>
#include <stdio.h>
int main(void){ char *p=(char*)malloc(16); p[15]=(char)'x'; printf("wrote %d\n",(int)p[15]); free(p); return 0; }
EOF
gcc -fsanitize=address -g -O0 "$T/bad.c" -o "$T/bad" 2>"$T/bad.build"; BADB=$?
gcc -fsanitize=address -g -O0 "$T/good.c" -o "$T/good" 2>"$T/good.build"; GOODB=$?
BADOUT="none"; GOODOUT="none"
if [ "$BADB" = "0" ]; then
  o=$(ASAN_OPTIONS=detect_leaks=0 "$T/bad" 2>&1); r=$?
  if printf '%s' "$o" | grep -q 'ERROR: AddressSanitizer'; then BADOUT="REPORT rc=$r"; else BADOUT="NOREPORT rc=$r"; fi
else
  BADOUT="BUILDFAIL rc=$BADB $(head -2 "$T/bad.build" | tr '\n' ' ')"
fi
if [ "$GOODB" = "0" ]; then
  o=$(ASAN_OPTIONS=detect_leaks=0 "$T/good" 2>&1); r=$?
  if printf '%s' "$o" | grep -q 'ERROR: AddressSanitizer'; then GOODOUT="REPORT rc=$r"; else GOODOUT="NOREPORT rc=$r"; fi
else
  GOODOUT="BUILDFAIL rc=$GOODB"
fi
echo "ARM_bad(越界 1 字节)  =$BADOUT"
echo "ARM_good(合法下标)    =$GOODOUT"
if [ "$BADOUT" != "$GOODOUT" ]; then echo "ASAN_TEETH=1(两臂翻面＝这把尺有判别力)"; else echo "ASAN_TEETH=0(★两臂同形＝仪器坏，别拿它的读数下结论)"; fi

echo
echo "=== 6) 真实导出在主机的哪一份(喂料) ==="
for f in /root/k/pol.live_1027 /home/lucy/pol.live_1027 "$D/pol.live_1027"; do
  [ -f "$f" ] && echo "  [在] $f bytes=$(wc -c < "$f") md5=$(md5sum "$f" | cut -d' ' -f1)"
done
echo "  (本机 PC 侧另有一份 kmod/w103_evidence/w1042_pol.pre = 282a6861…/1356948B，需要时 put 上来)"
echo "END $(date)"
