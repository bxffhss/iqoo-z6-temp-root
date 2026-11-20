#!/usr/bin/env bash
# §6.247 欠的那格：链里 15 个补丁器**到底幂不幂等**，逐个跑两遍比 md5。
# ★全程在**源码树的副本**上做(/home/lucy/sweep_tree)，交付那棵树一个字节都不碰。
#   (已核对：所有补丁器的 /root/k/ksu 只出现在 argv[1] 的**默认值**里，传参就绕开了)
set -u
SRC=${SRC:-/root/k/ksu/kernel}
TREE=/home/lucy/sweep_tree
LOG=/home/lucy/sweep_idem.log
: > "$LOG"
say(){ echo "$@" | tee -a "$LOG"; }

# ★摘要里**不能带绝对路径**(副本与原件路径天然不同，带着就永远不等——第一跑就是这么停住的)
mani(){ (cd "$1" && find . -type f \( -name '*.c' -o -name '*.h' \) -print0 | sort -z | xargs -0 md5sum | sort | md5sum | cut -d' ' -f1); }
cnt(){ grep -c -a "^  + " "$1" 2>/dev/null || true; }     # 真插入了东西
cntskip(){ grep -c -a "= 已有" "$1" 2>/dev/null || true; } # 被自己的闸挡下
cntref(){ grep -c -a '!!' "$1" 2>/dev/null || true; }      # 锚点没中/拒绝动手

say "START $(date)  SRC=$SRC"
rm -rf "$TREE"
cp -a "$SRC" "$TREE" || { say "!! 副本没做成 ⇒ 停(不许在交付树上做这个实验)"; exit 1; }
N=$(find "$TREE" -type f \( -name '*.c' -o -name '*.h' \) | wc -l)
S0=$(mani "$TREE")
say "副本就绪：.c/.h 共 $N 个，摘要=$S0"
# 副本必须与交付树当前摘要一致，否则"实验对象不是那个产物"
[ "$S0" = "$(mani "$SRC")" ] \
    && say "  ✓ 副本与交付树逐字节同摘要(实验的正是那份产物的源)" || { say "  !! 副本与交付树不等 ⇒ 停"; exit 1; }

CHAIN="diag4 sucompat_gates escape_steps decline killscan unlimit visible fdinstall setprof_gate sucompat_steps ksudpath sucompat_gates2 ksudpath2 tracequiet statprobe_steps capclamp"
EXTRA="domainfallback selfexec"
BAD=0; NOOP=0; OK=0; MISS=0
for f in $CHAIN $EXTRA; do
    P=/home/lucy/patch_ksu_$f.py
    if [ ! -f "$P" ]; then say "  ?? 没有 $P ⇒ 记为'没测'，不算幂等"; MISS=$((MISS+1)); continue; fi
    cp "$P" "/home/lucy/s_$f.py"
    if [ "$f" = domainfallback ]; then TARGET="$TREE/selinux/selinux.c"; else TARGET="$TREE"; fi
    m0=$(mani "$TREE")
    python3 "/home/lucy/s_$f.py" "$TARGET" >"/home/lucy/o1_$f.txt" 2>&1; r1=$?
    m1=$(mani "$TREE")
    python3 "/home/lucy/s_$f.py" "$TARGET" >"/home/lucy/o2_$f.txt" 2>&1; r2=$?
    m2=$(mani "$TREE")
    say "  --- $f: 插入1跑=$(cnt /home/lucy/o1_$f.txt) 插入2跑=$(cnt /home/lucy/o2_$f.txt) 被闸挡=$(cntskip /home/lucy/o2_$f.txt) 拒动=$(cntref /home/lucy/o2_$f.txt) rc=$r1/$r2"
    if [ "$m1" != "$m2" ]; then
        say "      ★★**非幂等**：第二跑又改了树($m1 -> $m2) ⇒ 每次构建都会长东西"
        BAD=$((BAD+1))
    elif [ "$m0" = "$m1" ]; then
        say "      = 这一跑没改任何 .c/.h(被自己的闸挡下，或锚点没中——两种都算'没效果')"
        NOOP=$((NOOP+1))
    else
        say "      ok 幂等：改动了，但第二跑没再动"
        OK=$((OK+1))
    fi
done
say "小计：非幂等=$BAD 没效果=$NOOP 幂等且改动=$OK 没测=$MISS   (链共 $(( $(echo $CHAIN $EXTRA | wc -w) )) 条)"
say "副本终摘要=$(mani "$TREE")   交付树现摘要=$(mani "$SRC")   (实验前=副本初值 $S0，两者当时已对等)"
[ "$S0" = "$(mani "$SRC")" ] \
    && say "  ✓ 复证：实验前后**交付树**摘要相同 ⇒ 这个实验没污染产物来源" || say "  !! 交付树摘要变了 ⇒ 立刻停，别用这棵树出货"
say "END $(date)"
