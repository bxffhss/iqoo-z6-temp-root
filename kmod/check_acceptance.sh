#!/bin/bash
# check_acceptance.sh —— 合并验收(ATT=26)的**一条命令**总闸：三个判据源串起来，退出码=FAIL 数。
#   用法：ATT=26 I_KNOW=1 bash kmod/w103_su.sh > kmod/w103_att26.log 2>&1
#         bash kmod/check_acceptance.sh kmod/w103_att26.log
# 三块各自独立、各自的假阳性历史都修过，所以这里**不重复判**，只做串联 + 一处新证据：
#   A. 挂载路线三态   → kmod/check_mount_su.sh     (§6.124⑤：errno=2 / uid=0 / not-allowed 互斥)
#   B. 域的正负对照   → kmod/check_dom_su.sh       (§6.134：不存在的域不切、shell 域真的切、Seccomp 2→0)
#   C. 残留回读       → 本文件自己判(§6.130：shell 侧 `Permission denied` 完全不带信息量，
#                       必须在 root 侧同一上下文里读，且要能看到"不存在"这种形状的回执)
# ★为什么 C 要单独判：这是唯一一条**只能靠 root 窗口**证的判据，而窗口一关就再没机会读。
LOG=${1:-kmod/w103_att26.log}
E=${E:-kmod/w103_evidence}
fail=0
SKIPPED=0   # ★SKIP≠PASS：三块里缺任何一块，最后都不许说"全绿"(第 51 发的现场就是我差点这么说了)
export LC_ALL=C
echo "=== 合并验收总闸  日志=$LOG ==="
[ -f "$LOG" ] || { echo "[x] 找不到驱动日志 ⇒ 三块都无从判"; exit 2; }

echo "--- A. 挂载路线三态 ---"
bash kmod/check_mount_su.sh "$LOG" | tail -6
a=$(bash kmod/check_mount_su.sh "$LOG" >/dev/null 2>&1; echo $?)
[ "$a" = 0 ] && echo "  [ok] A 全绿" || { echo "  [FAIL] A 有 $a 条"; fail=$((fail+a)); }

echo "--- B. SELinux 域的正负对照 ---"
bash kmod/check_dom_su.sh "$LOG" | tail -6
b=$(bash kmod/check_dom_su.sh "$LOG" >/dev/null 2>&1; echo $?)
[ "$b" = 0 ] && echo "  [ok] B 全绿" || { echo "  [FAIL] B 有 $b 条"; fail=$((fail+b)); }

echo "--- C. root 侧残留回读(w29_residue) ---"
# ★★**存证也会跨发残留**(第 50 发一手)：这一发的 punch 是空枪、根本没跑到最后一段，
#   但 `$E/w29_residue` 还是上一发留下的那份(`up=1259.99`)，于是总闸把"上一发的残留"当"这一发的结论"读，
#   报了个 `FAIL /data/adb 还在`——看起来非常有证据，其实读的是历史文件。
#   ⇒ 只判**本发日志里真的承认拉回来过**的证据：驱动每拉一份就打印一行 `存证 w29_xxx`，
#     没有这行 = 这一发没测到 = 不参与判定(而不是拿旧文件判)。
if ! grep -aq "存证 w29_residue" "$LOG"; then
    echo "  [SKIP] 本发日志里没有『存证 w29_residue』这一行 ⇒ 这一份没拉回来(旧文件不算证据；C 的主判据是 w29_sweep，这一格不影响它)"
    C_SKIP=1
fi
# ★优先信 **w29_sweep**：它是"同一个 root 上下文里 rm 完立刻回读"，正是 §6.130 要的形状；
#   w29_residue 只是窗口内独立复核的一份(有更好，没有也不该判"没证到")。
if [ -s "$E/w29_sweep" ] && grep -aq "存证 w29_sweep" "$LOG"; then
    R=$(tr -d '' < "$E/w29_sweep")
    # ★★"拉回来了"和"拉回完整一份"是两件事(第 53 发一手)：载荷都是 `{ … } >"$L"` 的形状，
    #   文件在第一行就建好 ⇒ 旧的 WAITFOR"等文件出现"2 秒就满足，PULL 回来的是**半截**
    #   (w29_sweep 只到三行 rm，[3] 段整个没有)，总闸照着它报"没有回读行"——看着像结论，其实是截断。
    #   ⇒ 存证必须自带完成标记(`DONE up=`)才参与判定；没有就明确报"截断"，不去逐条判内容。
    if ! echo "$R" | grep -aq "DONE up="; then
        echo "  [FAIL] 这份 w29_sweep 里没有完成标记(DONE up=)⇒ 拉回的是半截文件，这一格按**没测到**算(不逐条判)"
        fail=$((fail+1))
    else
    echo "$R" | grep -a "SWEEP up=" | head -1 | cut -c1-120 | sed 's/^/    /'
    for d in /data/adb /metadata/watchdog/ksu /data/local/tmp/pbin; do
        line=$(echo "$R" | sed -n '/\[3\]/,$p' | grep -aF "$d" | head -1)
        case "$line" in
          *"No such file"*) echo "  [ok] $d 清完之后 root 侧回读=不存在(同上下文 rm+ls，带信息量)";;
          "") echo "  [FAIL] [3] 段里没有 $d 的回读行"; fail=$((fail+1));;
          *)  echo "  [FAIL] $d 还在：[${line}]"; fail=$((fail+1));;
        esac
    done
    # ★这条的措辞要说实话：`投放物残留数=0` 是**新加的清单行**才有的信息；
    #   拿旧存证重判时那行根本不存在，报"不是 0"就等于把"没这个字段"读成"没清干净"。
    if echo "$R" | grep -aqE "投放物残留数=0"; then
        echo "  [ok] 投放物清零"
    elif echo "$R" | grep -aqE "投放物残留数="; then
        echo "  [!] 投放物没清零：[$(echo "$R" | grep -aE '投放物残留数=|残留清单=' | tr '\n' ' ' | cut -c1-160)]"
    else
        echo "  [!] 这份存证里没有『投放物残留数』这一行(早于该判据) ⇒ 只判不清，不当失败"
    fi
    fi
elif [ "${C_SKIP:-0}" = 1 ]; then
    echo "  [SKIP] 本发既没拉回 w29_sweep 也没拉回 w29_residue ⇒ C 段整体没测到(不算全绿)"
    SKIPPED=$((SKIPPED+1))
elif [ ! -s "$E/w29_residue" ]; then
    echo "  [FAIL] 没有 w29_residue ⇒ 这一格根本没测到(不能当阴性)"
    fail=$((fail+1))
elif ! tr -d '\000' < "$E/w29_residue" | grep -aq "DONE up="; then
    echo "  [FAIL] w29_residue 里没有完成标记(DONE up=)⇒ 拉回的是半截文件，按没测到算"
    fail=$((fail+1))
else
    R=$(tr -d '\000' < "$E/w29_residue")
    echo "$R" | grep -a "RESIDUE up=" | head -1 | cut -c1-120 | sed 's/^/    /'
    for d in /data/adb /metadata/watchdog/ksu /data/local/tmp/pbin; do
        # ★判据形态：必须是 root 侧读回来的 `No such file or directory`；
        #   读到 `Permission denied` 说明这条不是在 root 上下文里读的 ⇒ 无效，不算通过。
        line=$(echo "$R" | grep -aF "$d" | head -1)
        case "$line" in
          *"No such file"*|*"无法访问"*|*"cannot access"*) echo "  [ok] $d 不存在(root 侧回读)";;
          *"Permission denied"*) echo "  [FAIL] $d 读回来的是 Permission denied ⇒ 不是 root 上下文，这句不带信息量"; fail=$((fail+1));;
          "") echo "  [FAIL] $d 没有对应回执行"; fail=$((fail+1));;
          *)  echo "  [FAIL] $d **还在**：[${line}]"; fail=$((fail+1));;
        esac
    done
    echo "$R" | grep -aqE "pbin 挂载行=0" && echo "  [ok] 没有残留挂载" || { echo "  [FAIL] 挂载没读到 0"; fail=$((fail+1)); }
    echo "$R" | grep -aqE "/product/bin 条目数=3" && echo "  [ok] /product/bin 回到出厂 3 项" \
        || echo "  [!] /product/bin 条目数不是 3(自己看一眼那行，别默认它没事)"
fi

echo "--- D. 授权链 G1..G7(同一枪里跑的第二套判据) ---"
RG=kmod/w103_evidence/w29_regress.txt
if ! grep -aq "存证 w29_regress" "$LOG"; then
    echo "  [SKIP] 本发日志没有『存证 w29_regress』⇒ 驱动没跑到 D 块(旧存证不算)"
    SKIPPED=$((SKIPPED+1))
elif [ ! -s "$RG" ]; then
    echo "  [FAIL] 没有 w29_regress ⇒ D 块没测到"
    fail=$((fail+1))
else
    R=$(tr -d '\000' < "$RG")
    echo "$R" | grep -aE "^  \[G[0-9]\]" | sed 's/^/    /'
    echo "$R" | grep -aqE "汇总：FAIL=0" && echo "  [ok] G1..G7 全绿(第二套独立判据)" \
        || { echo "  [FAIL] 授权链有 FAIL：[$(echo "$R" | grep -aE '汇总：FAIL' | head -1)]"; fail=$((fail+1)); }
fi

echo
echo "--- E. 挂载存活取样(w29_mw，信息位：不进'四块都测到'的计数) ---"
# ★为什么要这一格：Z5 教程正文里那句"绑定环境被系统自愈弄坏 ⇒ 只能重启恢复"是**二手**故事，
#   我们自己的 bind /product/bin 到底能不能扛满一个长窗口，只有真机上按 up 采出来才知道。
#   它不改 A/B/C/D 的验收语义(那一格挂了才叫交付退化)，但**只要采到过一次掉挂载就报 FAIL**。
MW=$E/w29_mw
if [ ! -s "$MW" ] || ! grep -aq "存证 w29_mw" "$LOG"; then
    echo "  [--] 本发没采到挂载取样(不影响 A/B/C/D 的结论，只是 #58 那一格还空着)"
else
    M=$(tr -d '\000' < "$MW")
    N=$(printf '%s\n' "$M" | grep -ac "^MW up=")
    LAST=$(printf '%s\n' "$M" | grep -a "^MW up=" | tail -1)
    FIRST=$(printf '%s\n' "$M" | grep -a "^MW up=" | head -1)
    echo "    样本 $N 行：首[$FIRST] 末[$LAST]"
    if [ "$N" -lt 5 ]; then
        echo "  [FAIL] 只采到 $N 行 ⇒ 取样器没真跑起来(派发被队列吃了/循环死了)，这一格不算测到"
        fail=$((fail+1))
    else
        BADUID=$(printf '%s\n' "$M" | grep -ac "^MW up=[0-9.]* uid=[^0]")
        [ "$BADUID" = 0 ] && echo "  [ok] 取样全在 uid=0 上下文里读(不是 shell 侧的假阴性)" \
                          || { echo "  [FAIL] 有 $BADUID 行不是 root 读的 ⇒ mountinfo 视角不可信"; fail=$((fail+1)); }
        # umount 之后掉挂载是**预期**，不能算坏。umount 的时刻从同一发的 w135_off 存证里拿。
        # ★`=== up=993.17` 这种串按 `=` 切，前三个空字段都在 `===` 里 ⇒ 要**先只捞 `up=[0-9]+`** 再 cut，
        #   否则 `cut -d= -f2` 拿到的是空串(夹具第一跑就是这么把 UOFF 弄没的)。
        UOFF=$(tr -d '\000' < "$E/w29_w135_off.out" 2>/dev/null | grep -aoE "up=[0-9]+" | head -1 | cut -d= -f2)
        LOSS=$(printf '%s\n' "$M" | awk -v u="${UOFF:-999999}" '/^MW up=/{split($2,a,"="); if (a[2]+0 < u+0 && ($0 ~ /mount=0/ || $0 ~ /su=MISS/)) print}')
        # ★**正对照**：计划内的卸载必须被这个取样器看见(至少一行 `up>=卸载时刻` 且 `mount=0`)。
        #   看不见就只有两种解释——它死了，或者它根本分辨不出"没了"；这两种情况下"一直没掉"都不带信息量。
        POS=$(printf '%s\n' "$M" | awk -v u="${UOFF:-0}" '/^MW up=/{split($2,a,"="); if (a[2]+0 >= u+0 && $0 ~ /mount=0/) print}')
        UP0=$(printf '%s\n' "$FIRST" | grep -aoE 'up=[0-9]+' | head -1 | cut -d= -f2 | cut -d. -f1)
        UP1=$(printf '%s\n' "$LAST"  | grep -aoE 'up=[0-9]+' | head -1 | cut -d= -f2 | cut -d. -f1)
        if [ -z "$UOFF" ]; then
            echo "  [FAIL] 对不上卸载时刻($E/w29_w135_off.out 里取不到数字的 up= 行)⇒ E 的分母没定义，'没掉过'这句无从判(显式失败，不静默降级)"
            fail=$((fail+1))
        elif [ -n "$LOSS" ]; then
            echo "  [FAIL] 卸载前就掉过挂载/丢 su(第一行：$(echo "$LOSS" | head -1)) ⇒ Z5 那一手在本机是真的，要加重挂看门狗"
            fail=$((fail+1))
        elif [ -z "$POS" ]; then
            echo "  [FAIL] 取样器没记到计划内的卸载(up>=$UOFF 里没有一行 mount=0) ⇒ '一直没掉'缺正对照，不许当通过"
            fail=$((fail+1))
        else
            echo "  [ok] ★卸载前 $N 行全 mount=1/su=OK，卸载后立刻记到 mount=0 [$(echo "$POS" | head -1)] ⇒ 检测有效"
            echo "  [ok] ⇒ 本机这一段(UP $UP0→$UP1，约 $((UP1-UP0))s)扛住了，**不需要**重挂看门狗"
        fi
    fi
fi


# ★四块里少任何一块都不许说"全绿"。第 51 发的现场：C 被 SKIP，旧措辞照样打印"合并验收全绿"——
#   这正是我这两天在别的判据上反复防的那一族(把"没测到"读成"通过")，这次轮到自己新写的总闸。
if [ "$fail" = 0 ] && [ "$SKIPPED" = 0 ]; then
    echo "=== 合并验收全绿：挂载三态 + 域可控 + 机器无残留 + 授权链 7 闸(A/B/C/D 四块都真测到) ==="
    exit 0
elif [ "$fail" = 0 ]; then
    echo "=== 验收不完整：三块里只测到 $((4-SKIPPED)) 块(全绿)，但有 $SKIPPED 块**根本没测到**(旧存证不算) ==="
    exit 90
fi
echo "=== 合计 $fail 条 FAIL(A=$a B=$b SKIP=$SKIPPED)，见上 ==="
[ "$fail" -gt 125 ] && exit 125
exit "$fail"
