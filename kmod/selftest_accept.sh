#!/bin/bash
# selftest_accept.sh —— **总闸自己**的双向验证(专测 C 块的两道新闸：半截存证 / 跨发旧存证)。
# 用法：bash kmod/selftest_accept.sh
#
# 为什么要有这一份：C 块这两天连着出过两次"看着像结论、其实是信道断了"——
#   第 50 发拿**上一发**的 w29_residue 当本发结论(修法是"日志里必须有『存证 xxx』这一行")；
#   第 53 发拉到**半截**的 w29_sweep(载荷 `{ … } >"$L"` 一开局就建文件，WAITFOR 等"文件存在"
#   2 秒就满足)，于是三条 [3] 段的 FAIL 全是从截断里读出来的(修法是存证必须带完成标记)。
#   两个修法都不验证就等于没有：夹具要**同时**考"该过的过"和"该点名的点名"。
#
# ★A/B/D 在四份夹具里用的是同一份合成日志(故意不含挂载/域的回执 ⇒ 它们恒定地 FAIL)，
#   所以判据是**退出码的差**，不是绝对值。
set -u
export LC_ALL=C
G=kmod/check_acceptance.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/selfacc.XXXXXX")
[ -f "$G" ] || { echo "[x] 找不到 $G(要在仓库根目录跑)"; exit 2; }

# ---- 公共日志骨架：D 的标记给上(读的是真 w29_regress.txt，四份一致)，C 的标记由各自决定 ----
logbase() {   # logbase <夹具名> <是否声明拉到 sweep(1/0)>
    { echo "=== 合成驱动日志(夹具 $1) ==="
      [ "$2" = 1 ] && echo "    存证 w29_sweep"
      echo "  存证 w29_regress"
      [ "${4:-0}" = 1 ] && echo "    存证 w29_mw"
    } > "$T/$1.log"
}

# ---- 三份 w29_sweep 形状 ----
cat > "$T/complete" <<'EOF'
===== SWEEP up=1234.56 uid=0 =====
--- [2] 清 ---
  rm -rf /data/adb rc=0
--- [3] 清完之后同一个上下文回读 ---
  /data/adb                  ls: /data/adb: No such file or directory
  /metadata/watchdog/ksu     ls: /metadata/watchdog/ksu: No such file or directory
  /data/local/tmp/pbin       ls: /data/local/tmp/pbin: No such file or directory
  投放物残留数=0
  残留清单=[]
  /product/bin 条目数=3 (出厂 3)
===== DONE up=1240.00 =====
EOF
cat > "$T/trunc" <<'EOF'
===== SWEEP up=1039.45 uid=0 =====
--- [2] 清(顺序：先挂载后目录) ---
  rm -rf /data/adb rc=0
  rm -rf /metadata/watchdog/ksu rc=0
  rm -rf /data/local/tmp/pbin rc=0
EOF
cat > "$T/still" <<'EOF'
===== SWEEP up=1234.56 uid=0 =====
--- [3] 清完之后同一个上下文回读 ---
  /data/adb                  /data/adb
  /metadata/watchdog/ksu     ls: /metadata/watchdog/ksu: No such file or directory
  /data/local/tmp/pbin       ls: /data/local/tmp/pbin: No such file or directory
  投放物残留数=1
  /product/bin 条目数=3 (出厂 3)
===== DONE up=1240.00 =====
EOF

mkcase() {   # mkcase <夹具> <存证声明 1/0> <存证内容文件名|-> [挂载取样|无] [umount时刻|无]
    logbase "$1" "$2" "$3" "${mwdec:-0}"
    mkdir -p "$T/e_$1"
    # 旧存证**故意留在目录里**：STALE 那一格考的就是"有旧文件也不许读它"
    cp "$T/complete" "$T/e_$1/w29_sweep"
    [ "$3" = "-" ] || cp "$T/$3" "$T/e_$1/w29_sweep"
    cp "$T/complete" "$T/e_$1/w29_residue"     # 上一发的残留，全都不该被采信
    echo "=== up=993.17 uid=0 ===" > "$T/e_$1/w29_w135_off.out"   # 卸载时刻(E 格要拿它分"预期"与"真掉")
    [ -z "${4:-}" ] || cp "$T/$4" "$T/e_$1/w29_mw"
    # 第 5 参给个**不是数字**的时刻(夹具 e_nouoff)⇒ 闸门该报"分母取不到"，而不是静默只报数
    [ -z "${5:-}" ] || echo "=== up=$5 uid=0 ===" > "$T/e_$1/w29_w135_off.out"
}
# ---- E(挂载存活取样)的三份夹具 ----
gen_mw() {   # gen_mw <名字> <行数> <从第几行开始掉(0=不掉)> <umount 时刻>
    n=$2; drop=$3; u=$4
    : > "$T/$1"
    i=1
    while [ $i -le "$n" ]; do
        up=$((700 + i * 20))
        if [ "$up" -ge "$u" ]; then                    # 计划内的卸载：必须看得见"没了"(正对照)
            echo "MW up=$up uid=0 mount=0 su=MISS tgt_n=3" >> "$T/$1"
        elif [ "$drop" != 0 ] && [ $i -ge "$drop" ]; then   # 不该掉的时候掉了：真缺陷
            echo "MW up=$up uid=0 mount=0 su=MISS tgt_n=3" >> "$T/$1"
        else
            echo "MW up=$up uid=0 mount=1 su=OK tgt_n=4" >> "$T/$1"
        fi
        i=$((i+1))
    done
    echo "MW-END up=${u} reason=mount-gone samples=$n" >> "$T/$1"
}
gen_mw mw_clean 20 0 993
gen_mw mw_broke 20 6 993      # 第 6 行(up=820)就掉了，而 umount 在 up=993 ⇒ 真掉挂载
gen_mw mw_few 2 0 993         # 只 2 行 ⇒ 取样器根本没跑起来

# e_noc：从头到尾全 mount=1，**连计划内的卸载都没记到** ⇒ "一直没掉"这句没有正对照，必须报 FAIL
mk_noc() {
    : > "$T/mw_noc"; i=1
    while [ $i -le 8 ]; do
        echo "MW up=$((700 + i * 20)) uid=0 mount=1 su=OK tgt_n=4" >> "$T/mw_noc"
        i=$((i + 1))
    done
}
mk_noc

mkcase good  1 complete
mkcase trunc 1 trunc
mkcase still 1 still
mkcase stale 0 -
mwdec=1
mkcase e_ok  1 complete mw_clean
mkcase e_bad 1 complete mw_broke
mkcase e_few 1 complete mw_few
mkcase e_noc 1 complete mw_noc
mkcase e_nouoff 1 complete mw_clean noff

run() { E="$T/e_$1" bash "$G" "$T/$1.log" > "$T/$1.out" 2>&1; echo $?; }
g=$(run good); t=$(run trunc); s=$(run still); o=$(run stale)
e1=$(run e_ok); e2=$(run e_bad); e3=$(run e_few); e4=$(run e_noc); e5=$(run e_nouoff)

say() { if [ "$1" = 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; bad=$((bad+1)); fi; }
bad=0
sec() { sed -n '/--- C/,/--- D/p' "$T/$1.out"; }
sec2() { sed -n '/--- E/,$p' "$T/$1.out"; }

echo "退出码：good=$g trunc=$t still=$s stale=$o   (A/B 恒为同一批 FAIL，所以只看差)"

[ "$t" = "$((g+1))" ] && say 0 "半截存证(没有 DONE 标记)= 恰好 1 条 FAIL，且不再逐条判 [3]" \
                      || say 1 "半截存证的计数 = $t，期望 $((g+1))(g=$g)"
sec trunc | grep -q '半截文件' && say 0 "半截那一格把**原因**说出来了(截断≠残留)" || say 1 "半截那一格没报'半截文件'"
sec trunc | grep -q '\[3\] 段里没有' && say 1 "半截存证仍然在逐条判 [3](旧病没好)" || say 0 "半截存证不参与逐条判定"

[ "$s" = "$((g+1))" ] && say 0 "真残留(/data/adb 还在)= 恰好 1 条 FAIL" \
                      || say 1 "真残留计数 = $s，期望 $((g+1))"
sec still | grep -q '/data/adb 还在' && say 0 "残留被点名到具体目录" || say 1 "没点名 /data/adb：[$(sec still | tail -3 | tr '\n' ' ')]"

[ "$o" = "$g" ] && say 0 "没有『存证』标记时不新增 FAIL(旧文件不许读)" \
                || say 1 "旧存证还是被读进去了：退出码 $o vs $g"
sec stale | grep -q 'SKIP' && say 0 "STALE 明确报 SKIP" || say 1 "STALE 没报 SKIP"
sec stale | grep -q '\[ok\]' && say 1 "STALE 里居然出了 [ok](旧文件被当真证据判过了)" || say 0 "STALE 不参与通过判定"
grep -q '合并验收全绿' "$T/stale.out" && say 1 "STALE 还敢说全绿" || say 0 "SKIP 不算全绿(退出码之外还有横幅)"

echo "--- E 格(挂载存活取样)的三份夹具 ---"
[ "$e1" = "$g" ] && say 0 "干净取样(10 行全 mount=1)= 不新增 FAIL" \
                 || say 1 "干净取样却新增 FAIL：$e1 vs $g [$(sec2 e_ok)]"
[ "$e2" = "$((g+1))" ] && say 0 "卸载前掉挂载 = 恰好 1 条 FAIL" \
                       || say 1 "掉挂载计数 = $e2，期望 $((g+1))"
sec2 e_bad | grep -q '卸载前就掉过挂载' && say 0 "真掉挂载被点名(带第一行 up)" || say 1 "没点名掉挂载：[$(sec2 e_bad)]"
[ "$e3" = "$((g+1))" ] && say 0 "只 2 行样本 = 按没跑起来算 FAIL" || say 1 "样本过少没报 FAIL：$e3 vs $g"
[ "$e4" = "$((g+1))" ] && say 0 "全 mount=1 却连卸载都没记到 = 缺正对照，必须 FAIL"                        || say 1 "没正对照却放过了：$e4 vs $g"
sec2 e_noc | grep -q '缺正对照' && say 0 "缺正对照的措辞直说原因(不是'没掉就是好')"            || say 1 "缺正对照措辞不对：[$(sec2 e_noc | head -3 | tr '
' ' ')]"
[ "$e5" = "$((g+1))" ] && say 0 "对不上卸载时刻 = 显式 FAIL(不静默降级成 [!])"                        || say 1 "分母缺失却只报了 [!]：$e5 vs $g"
sec2 e_few | grep -q '取样器没真跑起来' && say 0 "少样本的措辞说的是真原因" || say 1 "少样本措辞不对：[$(sec2 e_few)]"
grep -q 'SKIP=0' "$T/good.out" && say 0 "E 没采到只报 [--]，不占用'四块都测到'的 SKIP 计数" \
                               || say 1 "E 缺采被算进了 SKIP(会把 A/B/C/D 的验收语义弄脏)"

echo; [ "$bad" = 0 ] && echo "=== 总闸夹具全绿 ===" || echo "=== 夹具 $bad 条 FAIL ==="
echo "(临时目录留在这台机上供回看：$T)"; exit $bad
