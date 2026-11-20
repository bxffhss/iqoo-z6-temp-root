#!/usr/bin/env bash
# 变异测试(一次性)：把 w427 的闸逐一拆掉，看专属自测 run_cellprep.sh 是否**变红**。
# 拆掉还全绿 ⇒ 那道闸没牙。跑完就删本文件。
set -u
cd "$(dirname "$0")/../.." || exit 1
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
T=$(mktemp -d)
mut() { # $1=标签  其余=python 语句(逐条 argv)
    local tag=$1; shift
    cp kmod/w427_cell_prep.sh "$T/x.sh"
    python - "$T/x.sh" "$@" <<'PY'
import io, sys
p, stmts = sys.argv[1], sys.argv[2:]
s = io.open(p, encoding='utf-8').read()
orig = s
ns = {'s': s}
exec("\n".join(stmts), ns)
s = ns['s']
assert s != orig, "MUT-ANCHOR-DEAD"
io.open(p, 'w', encoding='utf-8', newline='').write(s)
PY
    if [ $? -ne 0 ]; then echo "### 变异 $tag ⇒ 锚失效，本条不算数"; echo; return; fi
    echo "### 变异 $tag"
    SRC="$T/x.sh" bash kmod/_tmp_selftest_rdst/run_cellprep.sh 2>&1 | grep -E '^  \[BAD\]|^=== run_cellprep|^\[x\]'
    echo
}

# A：整块删掉形状闸(切片守卫就该拦下)
mut "A(整块删掉形状闸)" 'a = s.index("SHAPE_OK=")' 'b = s.index("BAD=$(printf", a)' 's = s[:a] + s[b:]'
# A2：留着 SHAPE_OK 的赋值，只把 if 的条件改成永假 ⇒ 测的是**夹具**有没有牙
mut "A2(形状闸条件改永假)" 's = s.replace(chr(34) + "$SHAPE_OK" + chr(34) + " != 1", chr(34) + "x" + chr(34) + " = " + chr(34) + "y" + chr(34))'
# B：整行精确匹配退回 grep -w(切片守卫拦下)
mut "B(整行匹配退回 grep -w)" 's = s.replace("grep -a " + chr(34) + chr(94) + "package:" + chr(36) + "pkg uid:[0-9]*" + chr(36) + chr(34), "grep -a -w " + chr(34) + "package:" + chr(36) + "pkg" + chr(34))'
# B2：留着整行匹配，只把"匹配到几条必须=1"那道闸改成=9 ⇒ 数腿的夹具要有牙
mut "B2(n=1 那道闸改成永真)" 's = s.replace(chr(34) + "$n" + chr(34) + " = 1", chr(34) + "$n" + chr(34) + " = 9")'
# C：预检文案不看 fail(洞二原样回放)
mut "C(预检文案不看 fail)" 's = s.replace("预检" + chr(36) + "( [ " + chr(34) + "$fail" + chr(34) + " = 0 ] && echo 通过 || echo 未通过 )", "预检通过")'
mut "D(删掉第二条记录的生产者那一块)" "a = s.index(\"TWO_PKG=\${TWO_PKG:-com.termux}\")" "b = s.index(chr(34) + \"  预检\", a)" "s = s[:a] + s[b:]"
