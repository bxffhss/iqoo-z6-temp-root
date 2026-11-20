#!/usr/bin/env bash
# w419_handover_smoke.sh —— 把 `kmod/DELIVERY.md` 第 0 节"接手只要 N 条命令"**当接口来验**：
#   每条命令逐字跑一遍 ⇒ 三道：①rc=0；②它**自己该产出的证人**在输出里(不是"我看到有输出")；
#   ③这条命令的**锚点串**在台账里还在(文档一改、脚本这边锚不上就红 ⇒ 防"清单与脚本各说各话")。
#   ★值得做的理由：接手的人第一步就抄这几条；它们坏了不是"少一步"，是第一分钟就把人带偏(例 109：宣称要紧跟读回)。
#
# 用法：
#   bash kmod/w419_handover_smoke.sh          # 真跑 ⓪~⑤(只读；不开窗、不打 punch；⓪约 2 分钟)
#   bash kmod/w419_handover_smoke.sh --self   # 离线双向自测(锚点漂移＋形状＋证人正则能否拒坏读数)
#   W419_DOC=路径   指台账(默认 kmod/DELIVERY.md)
#   W419_SKIP0=1    跳过 ⓪(它会跑整轮总闸)
set -u
cd "$(dirname "$0")/.." || exit 1
DOC=${W419_DOC:-kmod/DELIVERY.md}
nchk=0; fail=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }

cmd0() { bash kmod/w413_selftest_sweep.sh; }
cmd1() { cat analysis/CONTINUE_HERE.md | head -40; }
cmd2() { tail -40 kmod/W345_RC68_WINDOW.md; }
cmd3() { adb shell 'cd /data/local/tmp; echo up=$(cat /proc/uptime|head -1|cut -d" " -f1) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce)'; }
cmd4() { adb shell 'pm list packages -U' | grep -a -w package:com.suw.manager; }
cmd5() { adb shell 'ls -l /data/local/tmp/ | grep -aE "ksu_ftrace|ksu_kallsyms|ksu_tainted|ksu_mod_|ksu_ui_track|ksu_race_fd|ksu_redirect"'; }

# 表：id <TAB> 台账里的锚点串(逐字，不含 TAB) <TAB> 证人正则(NOTHING＝"输出必须为空")
rows() {
    printf '0\tbash kmod/w413_selftest_sweep.sh\t离线自检闸 全绿\n'
    printf '1\tcat analysis/CONTINUE_HERE.md\t新会话继续指南\n'
    printf '2\ttail -40 kmod/W345_RC68_WINDOW.md\t## §\n'
    printf '3\tmod=$(grep -c kernelsu /proc/modules)\tup=[0-9.]+ mod=[0-9]+ enf=[A-Za-z]+\n'
    printf '4\tgrep -a -w package:com.suw.manager\tpackage:com.suw.manager uid:[0-9]+\n'
    printf '5\tls -l /data/local/tmp/\tNOTHING\n'
}

run_real() { # $1=id $2=anchor $3=witness
    local id=$1 anchor=$2 wit=$3 out rc n dhit fname="cmd$1"
    if [ "$id" = 0 ] && [ "${W419_SKIP0:-0}" = 1 ]; then echo "  [没跑] ⓪ 被 W419_SKIP0=1 跳过(没测到≠通过)"; return; fi
    out=$("$fname" 2>&1 < /dev/null); rc=$?   # ★垫 /dev/null：子件(bash w413／adb shell)会吃掉调用者的 stdin
    if [ "$wit" = NOTHING ]; then
        n=$(printf '%s\n' "$out" | grep -ac . | tr -d ' ')
        # ⑤是**探测器**：`grep` 没匹配到东西＝"没有残留"＝该返回 1。所以 rc 只许 0/1，
        #   255(adb 连不上)之类才算坏。(第一版我拿 rc=0 当判据，把"干净"判成了失败。)
        chk "$id) rc 是 0 或 1(探测器：1＝无残留)——实得 rc=$rc" "$({ [ "$rc" = 0 ] || [ "$rc" = 1 ]; } && echo 1 || echo 0)"
        chk "$id) 残留行数为 0(数到 $n)；非空就是 §6.343③ 的处置" "$([ "$n" = 0 ] && echo 1 || echo 0)"
    else
        chk "$id) rc=0" "$([ "$rc" = 0 ] && echo 1 || echo 0)"
        n=$(printf '%s\n' "$out" | grep -acE "$wit")
        chk "$id) 证人出现在自己的输出里(数到 $n)" "$([ "$n" -ge 1 ] && echo 1 || echo 0)"
    fi
    dhit=$(grep -acF -- "$anchor" "$DOC")
    echo "  ── $id ── rc=$rc 证人/残留=$n 锚点=$dhit 一手读数(尾 2 行)：$(printf '%s\n' "$out" | tail -2 | tr '\n' ' ' | cut -c1-140)"
    chk "$id) 台账里还有这条锚点 [$anchor]" "$([ "$dhit" -ge 1 ] && echo 1 || echo 0)"
}

selftest() {
    echo "=== w419 自测(离线，不碰设备) ==="
    local cnt=0 bad=0 miss=0 m2=0 T a b c
    while IFS=$'\t' read -r a b c; do
        [ -z "${a:-}" ] && continue
        cnt=$((cnt+1)); [ -n "${b:-}" ] && [ -n "${c:-}" ] || bad=$((bad+1))
    done <<EOF
$(rows)
EOF
    chk "形状：解析到 6 条(实际 $cnt)，字段齐(缺 $bad)" "$([ "$cnt" = 6 ] && [ "$bad" = 0 ] && echo 1 || echo 0)"

    while IFS=$'\t' read -r a b c; do
        [ -z "${a:-}" ] && continue
        grep -aqF -- "$b" "$DOC" || { miss=$((miss+1)); echo "      台账里没这条锚点 ⇒ $b"; }
    done <<EOF
$(rows)
EOF
    chk "正对照：6 条锚点都在 $DOC(缺 $miss)" "$([ "$miss" = 0 ] && echo 1 || echo 0)"

    # ★反对照的粒度：只**替换那一个锚点串**，不是删整行——台账那行极密(⓪~⑤ 全在同一行)，
    #   用 grep -vF 删行会一次抽掉 5 条锚点，看起来"有牙"其实测的是别的形状(第一版就是这样红的)。
    T=$(mktemp -d)/t.txt; sed 's|ls -l /data/local/tmp/|XX被抽掉的锚点XX|g' "$DOC" > "$T"
    while IFS=$'\t' read -r a b c; do
        [ -z "${a:-}" ] && continue
        grep -aqF -- "$b" "$T" || m2=$((m2+1))
    done <<EOF
$(rows)
EOF
    rm -f "$T"
    chk "反对照：从合成台账里抽掉 ⑤ 那一行 ⇒ 必须数到缺 1(实际 $m2)" "$([ "$m2" = 1 ] && echo 1 || echo 0)"

    local g b2
    g=$(printf 'not a device\n' | grep -acE 'up=[0-9.]+ mod=[0-9]+ enf=[A-Za-z]+')
    b2=$(printf 'up=123.45 mod=0 enf=Enforcing\n' | grep -acE 'up=[0-9.]+ mod=[0-9]+ enf=[A-Za-z]+')
    chk "证人正则：坏读数拒(命中 $g＝0)、好读数收(命中 $b2＝1)" "$([ "$g" = 0 ] && [ "$b2" = 1 ] && echo 1 || echo 0)"

    local r1 r2
    r1=$(printf 'a\nb\n' | grep -ac . | tr -d ' ')
    r2=$(printf '' | grep -ac . | tr -d ' ')
    chk "残留腿：两行⇒$r1(非 0＝判不过)、空⇒$r2(0＝判过)" "$([ "$r1" = 2 ] && [ "$r2" = 0 ] && echo 1 || echo 0)"
    # ★探测器 rc 形状的正对照：grep 无匹配返回 1 ⇒ 判据必须收 1(这条就是修掉"把干净当失败"那个错的牙)
    local rprobe
    rprobe=$(printf 'x\n' | grep -acE 'nomatchhere'; echo "rc=$?")
    chk "探测器 rc 形状：无匹配时 grep 给 rc=1($rprobe ⇒ 判据须允许 1)" "$(printf '%s' "$rprobe" | grep -aq 'rc=1' && echo 1 || echo 0)"
    echo
    [ "$fail" = 0 ] && echo "=== w419 自测 PASS(断言 $nchk 条，由 chk 自数) ===" || echo "=== FAIL($nchk 条) ==="
    [ "$fail" = 0 ]
}

if [ "${1:-}" = "--self" ] || [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi
# ★递归保险：总闸(`2)` 那一项)只跑本件的 `--self`。真模式里 ⓪ 会去跑总闸 ⇒ 撞见 W413_SWEEP 就停。
if [ "${W413_SWEEP:-0}" = 1 ]; then
    echo "[x] 不许在总闸里跑 w419 的**真模式**(⓪ 会回头跑总闸＝递归)。要跑：直接在命令行 bash kmod/w419_handover_smoke.sh"
    exit 2
fi

echo "=== 真跑：$DOC 的接手清单，逐条当接口验(0 枪、只读) ==="
# ★这里**不能用 while read ＋ heredoc**：第一版就是那样写的——⓪(bash w413)与 ③④⑤(adb shell)会把
#   喂表的 stdin 读到 EOF ⇒ 后面的格一条都不跑，而循环"正常结束"、**退出码 0、还打印全绿**。
#   改成按 id 逐条从 rows 取行(表走命令替换，谁也不是从 stdin 读)。
for id in 0 1 2 3 4 5; do
    line=$(rows | grep -a "^$id	")
    anchor=$(printf '%s\n' "$line" | cut -f2)
    wit=$(printf '%s\n' "$line" | cut -f3)
    if [ -z "$line" ] || [ -z "$anchor" ] || [ -z "$wit" ]; then
        chk "$id) 表里取得出这一行(锚点＋证人都在)" 0
        continue
    fi
    run_real "$id" "$anchor" "$wit"
done
echo
[ "$fail" = 0 ] && { echo "=== 接手清单 全绿(每条＝rc＋自己的证人＋台账锚点 三道) ==="; exit 0; } || { echo "=== 有红项：先分开判「命令坏了」还是「台账改了没同步」(锚点那道会指名) ==="; exit 1; }
