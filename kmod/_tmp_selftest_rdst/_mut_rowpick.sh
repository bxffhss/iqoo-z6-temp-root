#!/usr/bin/env bash
# _mut_rowpick.sh —— 变异测试(一次性)：把 run_rowpick.sh 守的那几条闸**逐一拆掉**，看自测是否变红。
#   拆掉还全绿 ⇒ 那道闸没牙(例 141：每条"计数=0/必须拒"的断言都要配一格"该红时真红")。
#   ★变异只打在 **临时副本** 上，绝不动出货件；跑完就删本文件。
set -u
cd "$(dirname "$0")"/"../.." || exit 1
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
T=$(mktemp -d)
nred=0
mut() { # $1=标签 $2=被改的原件 $3=环境里的变量名 $4=旧串 $5=新串 $6=必须变红的断言前缀
    local tag=$1 src=$2 var=$3 old=$4 new=$5 want=$6
    local dst="$T/x.py"
    [ "${src##*.}" = sh ] && dst="$T/x.sh"
    cp "$src" "$dst" || { echo "### 变异 $tag ⇒ 复制失败，本条不算数(红在这上面)"; nred=$((nred+1)); return; }
    python - "$dst" "$old" "$new" <<'PY'
import io, sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding='utf-8', newline='').read()
n = s.count(old)
if n != 1:
    sys.stderr.write('MUT-ANCHOR %d 处(须恰好 1)\n' % n)
    sys.exit(2)
io.open(p, 'w', encoding='utf-8', newline='').write(s.replace(old, new))
PY
    if [ $? -ne 0 ]; then echo "### 变异 $tag ⇒ 锚失效，本条不算数(红在这上面)"; nred=$((nred+1)); echo; return; fi
    echo "### 变异 $tag"
    local out
    out=$(env "$var=$dst" bash kmod/_tmp_selftest_rdst/run_rowpick.sh 2>&1 | grep -aE '^  \[BAD\]|^=== run_rowpick')
    printf '%s\n' "$out" | sed 's/^/    /'
    if printf '%s' "$out" | grep -qa "$want"; then
        echo "    ⇒ 这道闸**有牙**(变红的那格正是：$want)"
    else
        echo "    ⇒ ★这道闸**没牙**：拆了它 $want 照样绿"
        nred=$((nred+1))
    fi
    echo
}

echo "=== 变异驱动：五条，每条都必须把指名的那一格打红 ==="
mut "A(退回旧身份闸：ident 还要包名)" kmod/prof_gate.py PG \
    'ident = 1 if (ok_ap and ok_uid) else 0' 'ident = 1 if (ok_ap and ok_uid and ok_pkg) else 0' \
    '⑤真 Profile 树'
mut "B(身份闸恒过：不核 UID)" kmod/prof_gate.py PG \
    'ident = 1 if (ok_ap and ok_uid) else 0' 'ident = 1' \
    '⑦uid 不符'
mut "C(拒点时不删输出文件＝留残留坐标)" kmod/row_pick.py RP \
    '        os.remove(outf)                                # ★残留坐标绝不能被下一轮 read 拿去点' \
    '        pass                                # 变异C：不删' \
    '③拒点后输出文件'
mut "D(不做最小化：整屏滚动容器也当卡)" kmod/row_pick.py RP \
    '    return [g for g in cs if not any(wraps(g, o) and not same(g, o) for o in cs)]' '    return cs' \
    '①整屏滚动容器'
mut "E(出货件不再把过滤词传给 row_pick)" kmod/ui_grant.sh UG \
    'build_ug_row.txt "$TERM"; ROWRC=$?' 'build_ug_row.txt; ROWRC=$?' \
    '⑧ui_grant.sh 里 row_pick 的调用'

rm -rf "$T"
echo "=== 汇总：没牙的变异 $nred 条(0=五条都有牙) ==="
[ "$nred" = 0 ] && echo "=== _mut_rowpick PASS ===" || echo "=== _mut_rowpick FAIL($nred 条拆了不红) ==="
[ "$nred" = 0 ]
