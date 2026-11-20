#!/bin/bash
# 路线 B 偏移反演第一步：在"与设备逐字同 config"的树上，用 DWARF 一次拿到完整 struct 布局。
# 为什么不用问数法(char (*a)[offsetof]=1)：pahole 给的是**全字段 + 洞(padding)**，
# 而问数法一次只能问我们预先点名的字段 —— 夹逼"厂商多出来的 64 字节"要的正是洞的位置。
# 前提(设备 config 已核实)：CONFIG_DEBUG_INFO=y + DWARF4 ⇒ 模块 .o 里有完整 DWARF。
# 用法(在远端)：bash /home/lucy/remote_layout.sh <树名> [<树名>...]
LOG=/home/lucy/layout.log
exec > "$LOG" 2>&1
CL=/root/clangrepo/clang-r383902b/bin/clang
command -v pahole >/dev/null || apt-get install -y -qq dwarves

for T in "$@"; do
  TREE=/root/k/$T
  D=/root/k/layout_$T
  [ -d "$TREE" ] || { echo "#### $T  没有这棵树，跳过"; continue; }
  cd "$TREE" || continue
  echo; echo "########## $T  commit=$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null)"
  grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION)' Makefile | tr -d '\n'; echo
  echo "--- clang: $(clang --version 2>/dev/null | head -1) / $(test -x "$CL" && "$CL" --version | head -1)"
  echo "--- .config 里的布局敏感开关:"
  grep -E '^CONFIG_(DEBUG_INFO|CFI|LTO|THINLTO|SCHEDSTATS|SCHED_DEBUG|MODVERSIONS|KPROBES|RANDSTRUCT|DEBUG_CREDENTIALS|CONFIG_STACKPROTECTOR)' .config 2>/dev/null
  echo "--- kernel.release: $(cat include/config/kernel.release 2>/dev/null)"

  rm -rf "$D"; mkdir -p "$D"
  cat > "$D/dw.c" <<'EOF'
#include <linux/module.h>
#include <linux/sched.h>
#include <linux/sched/clock.h>
#include <linux/cred.h>
#include <linux/kprobes.h>
#include <linux/nsproxy.h>
#include <linux/binfmts.h>
#include <linux/fs.h>
/* 文件作用域的实例 ⇒ 强制这些 struct 的完整 DWARF 落到 .o 里 */
struct task_struct  dw_task;
struct cred         dw_cred;
struct module       dw_mod;
struct kprobe       dw_kp;
struct nsproxy      dw_nsp;
struct linux_binfmt dw_bf;
EOF
  printf 'obj-m += dw.o\n' > "$D/Makefile"
  TOOL="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip RANLIB=llvm-ranlib"
  test -x "$CL" && TOOL="ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- HOSTCC=gcc CC=$CL"
  make $TOOL M="$D" modules 2>&1 | tail -8
  if [ -f "$D/dw.o" ]; then
    OUT=/home/lucy/layout_$T.txt
    : > "$OUT"
    for S in task_struct cred module kprobe nsproxy linux_binfmt thread_info signal_struct fs_struct files_struct; do
      echo "===== $S ($T)" >> "$OUT"
      pahole -C "$S" "$D/dw.o" >> "$OUT" 2>&1
    done
    cp "$D/dw.o" /home/lucy/dw_$T.o
    echo "LAYOUT_OK $T -> $OUT ($(wc -l < "$OUT") 行)"
  else
    echo "LAYOUT_FAIL $T (dw.o 没产出，看上面的 make 输出)"
  fi
  cd /root/k
done
echo "END $(date)"
