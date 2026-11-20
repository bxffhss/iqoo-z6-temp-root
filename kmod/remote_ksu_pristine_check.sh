#!/usr/bin/env bash
# 任务 #97 / §6.248 留的那格：**从 git pristine 把链跑一遍，能不能得到"我出货的那棵树"**。
# 只做到源码层比较(不编译)：先回答"差在哪些文件、差多少"，再决定值不值得花一次编译。
# ★全程在 /home/lucy/pristine 里做，交付树 /root/k/ksu 只读。
set -u
REPO=/root/k/ksu
P=/home/lucy/pristine
LOG=/home/lucy/pristine_check.log
: > "$LOG"
say(){ echo "$@" | tee -a "$LOG"; }

say "START $(date)"
rm -rf "$P"; mkdir -p "$P" || { say "!! 建不了副本目录 ⇒ 停"; exit 1; }
git -C "$REPO" rev-parse HEAD >"$LOG.head" 2>&1
say "  pristine 锚点 = $(cat "$LOG.head")  ($(cut -c1-12 "$LOG.head"))"
git -C "$REPO" archive HEAD | tar -x -C "$P" || { say "!! git archive 没跑成 ⇒ 停"; exit 1; }
[ -d "$P/kernel/feature" ] || { say "!! 解出来的树里没有 kernel/feature ⇒ 停(结构和我以为的不一样)"; exit 1; }
say "  解出来：.c/.h 共 $(find "$P" -type f \( -name '*.c' -o -name '*.h' \) | wc -l) 个"

M="$P/kernel"; U="$P/uapi"
# --- step 1(装文件) ---
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && say "  1) dev_syms.c 装上(它是 git 里的未跟踪资产，链不负责生成它)"
# --- step 2(链) ---
for f in diag4 sucompat_gates escape_steps decline killscan unlimit visible fdinstall setprof_gate sucompat_steps ksudpath sucompat_gates2 ksudpath2 tracequiet statprobe_steps capclamp; do
    python3 "/home/lucy/patch_ksu_$f.py" "$M" >>"$LOG" 2>&1 || say "    (注意) patch_ksu_$f.py 退出码非 0"
done
python3 /home/lucy/patch_ksu_domainfallback.py "$M/selinux/selinux.c" >>"$LOG" 2>&1 || say "    (注意) domainfallback 退出码非 0"
python3 /home/lucy/patch_ksu_selfexec.py "$M" >>"$LOG" 2>&1 && say "  2c) selfexec 直接打在 pristine+链 上(**不做 2c 的还原**——那正是这一格要问的)" || say "    !! selfexec 没打成"
# --- step 3(版本/uapi 对齐，与构建脚本同形) ---
KB="$M/Kbuild"
OLD='ccflags-y += -DKSU_VERSION=$(KSU_VERSION)'
if grep -qF "$OLD" "$KB"; then
    python3 - "$KB" "$OLD" <<'PY' >>"$LOG" 2>&1
import io, sys
p, old = sys.argv[1], sys.argv[2]
s = io.open(p, encoding="utf-8", errors="replace").read()
assert s.count(old) == 1, "anchor=%d" % s.count(old)
new = ("ccflags-y += -DKSU_VERSION=$(if $(KSU_VERSION_OVERRIDE),$(KSU_VERSION_OVERRIDE),$(KSU_VERSION))\n"
       "$(info -- RC60 effective KSU_VERSION = $(if $(KSU_VERSION_OVERRIDE),$(KSU_VERSION_OVERRIDE),$(KSU_VERSION)))")
io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old, new))
print("  3) Kbuild 已改")
PY
else
    say "  3) Kbuild 那行没找到(与构建脚本的分支不同，记下来)"
fi
sed -i "s/^static const __u32 KERNEL_SU_UAPI_VERSION = .*/static const __u32 KERNEL_SU_UAPI_VERSION = 2;/" "$U/supercall.h" 2>/dev/null || say "  3) 没有 uapi/supercall.h 可改"

# --- 比较：pristine+链一遍  vs  交付树 ---
say ""
say "=== 比较(只看两边都有的 .c/.h) ==="
( cd "$P" && find . -type f \( -name '*.c' -o -name '*.h' \) -print | sort ) > /tmp/pl.txt
( cd "$REPO" && find kernel uapi -type f \( -name '*.c' -o -name '*.h' \) 2>/dev/null -print | grep -v '\.bak\|\.pristine\|\.orig' | sort ) > /tmp/dl.txt
SAME=0; DIFF=0; ONLYP=0; ONLYD=0
for rel in $(cat /tmp/pl.txt); do
    d="/root/k/ksu/${rel#./}"
    if [ ! -f "$d" ]; then say "  只在 pristine 侧: $rel"; ONLYP=$((ONLYP+1)); continue; fi
    a=$(md5sum "$P/$rel" | cut -d' ' -f1); b=$(md5sum "$d" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then SAME=$((SAME+1)); else
        DIFF=$((DIFF+1))
        say "  ★不等: $rel   pristine+链=$(wc -c <"$P/$rel") B  交付树=$(wc -c <"$d") B  差=$(( $(wc -c <"$P/$rel") - $(wc -c <"$d") ))"
    fi
done
for rel in $(cat /tmp/dl.txt); do
    [ -f "$P/$rel" ] || { say "  只在交付树侧(链不生成它)：$rel"; ONLYD=$((ONLYD+1)); }
done
say "小计：相等=$SAME 不等=$DIFF 只在 pristine=$ONLYP 只在交付树=$ONLYD"

# --- 把"不等"那格讲成人话：数三份已知的积累 ---
SC_P="$M/feature/sucompat.c"; SC_D="$REPO/kernel/feature/sucompat.c"
say ""
say "=== sucompat.c 里那三处积累，两边各几份 ==="
for pat in 'path\[0\] = 0;' 'if (ksu_stat_off)' 'pr_info("KSUBEAT FS0' 'KSUBEAT SD-INIT'; do
    printf '  %-26s pristine+链=%-4s 交付树=%s\n' "$pat" "$(grep -c "$pat" "$SC_P" 2>/dev/null)" "$(grep -c "$pat" "$SC_D" 2>/dev/null)"
done
say "  selfexec 标记：pristine+链=$(grep -c 'rc68(#125) selfexec' "$SC_P" 2>/dev/null) 交付树=$(grep -c 'rc68(#125) selfexec' "$SC_D" 2>/dev/null)"
say "  交付树 sucompat.c md5=$(md5sum "$SC_D" | cut -d' ' -f1) (应当=7b147e97ad235f2d654fdc167b30f03c)"
say "END $(date)"
