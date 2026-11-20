#!/bin/bash
# w1054_stack_chain.sh —— 0 枪（纯主机）：接 w1053 的 .su 表，算「从我们的 init 出发，内核栈最坏要用多少」，
#   拿它跟这棵树真正的 THREAD_SIZE 比 ⇒ 判「第 81 发死在 insmod 里＝模块装载路径栈溢出」这一候选。
# ★两条来自上一格(w1053)的自我更正，先写在这儿免得再犯：
#   ①.clang 的 .su 行是 `路径:行:函数名<TAB>字节<TAB>static`，**不是全冒号**。上一版我的解析器按冒号切，
#     于是 157 行全部"不可解析"、还印出一个「帧之和=0 字节」——那 0 是仪器瞎，不是"帧很小"。
#     救回来的是同一段里"顺便把原始前 6 行印出来"那一手(不许信解析器)。本版按 TAB 解析，并**强制**自证可解析条数>0。
#   ②THREAD_SIZE 在这棵树的 arm64 上**不是 Kconfig 符号**(.config 里查无 CONFIG_THREAD_SIZE_ORDER)，
#     它写在 arch/arm64/include/asm/page.h ⇒ 分母要从源码现读，不能背主线数字，也不能只 grep .config。
# 只读；用 w1053 已经编好的副本(不在就现编一次)。
set -u
KDIR=/root/k/nothing_sm7325_v_mr
D=/home/lucy/w1053_su
KO=$D/w985_probe.ko

echo "BEGIN $(date)"
echo "HOST_IDENTITY host=$(hostname) user=$(id -un) uname=$(uname -m)"
if [ ! -d "$D/ss" ] || [ ! -f "$KO" ]; then
  echo "COPY_ABSENT ⇒ 先跑一次 w1053_stack_probe.sh(它建副本并出 .su)，本脚本不替它建"
  exit 1
fi
NF=$(find "$D" -name '*.su' | wc -l)
echo "SU_FILES=$NF KO=$KO bytes=$(wc -c < "$KO") md5=$(md5sum "$KO" | cut -d' ' -f1)"
echo "被测主源 md5=$(md5sum "$D/w985_main.c" | cut -d' ' -f1) (登记值 fe5a8d6dd7e349e96c284dcc4bdf1e82)"

echo
echo "=== 1) 分母：THREAD_SIZE 从 arm64 的 page.h 现读(不是 .config) ==="
for f in "$KDIR"/arch/arm64/include/asm/page.h "$KDIR"/arch/arm64/include/asm/stacktrace.h "$KDIR"/include/asm-generic/threads.h; do
  [ -f "$f" ] || continue
  echo "-- $f"
  grep -nE 'THREAD_SIZE_ORDER|THREAD_SIZE|THREAD_SHIFT' "$f" | head -8 | sed 's|^|   |'
done
echo "-- VMAP/相关(现读 .config 里有的那几条) --"
grep -E '^CONFIG_(VMAP_STACK|ARM64_4K_PAGES|FRAME_WARN|SCHED_STACK_END_CHECK)=' "$KDIR/.config" | sed 's|^|   |'

echo
echo "=== 2) 帧表(按 TAB 解析) + 调用图 + 最坏链 ==="
# ★图从**设备上真跑的那份 ko**里取($S/w985_probe.ko，md5 现核对 f0e8ee24…)，帧数从副本的 .su 取。
#   为什么分开：加 -fstack-usage 之后产物字节会变；调用关系要用被测那个件，不能拿"我重新编的近似件"顶。
S=/home/lucy/w985_ssport
DEVM=f0e8ee245b231d827665b7aed9f30db7
GKO=$S/w985_probe.ko
GM=$(md5sum "$GKO" | cut -d' ' -f1)
echo "图用件=$GKO md5=$GM 设备登记=$DEVM ⇒ $([ "$GM" = "$DEVM" ] && echo 同一件 || echo '★不是同一件！下面所有读数按"外推"标')"
llvm-objdump -d "$GKO" > /tmp/w1054_dis.txt 2>/dev/null
echo "反汇编行数=$(wc -l < /tmp/w1054_dis.txt) (0 ⇒ 图没料，下面未测)"
python3 - "$D" /tmp/w1054_dis.txt <<'PY'
import os, re, sys
root, dis = sys.argv[1], sys.argv[2]

# ---- .su：`path:line:function\tbytes\tstatic` ----
frame = {}
tot_lines = bad_lines = 0
for dp, _, fs in os.walk(root):
    for fn in fs:
        if not fn.endswith(".su"):
            continue
        for ln in open(os.path.join(dp, fn), encoding="utf-8", errors="replace"):
            ln = ln.rstrip("\n")
            if not ln.strip():
                continue
            tot_lines += 1
            head, sep, rest = ln.partition("\t")
            p = head.split(":")
            w = rest.split()
            if not sep or len(p) < 3 or not w or not w[0].isdigit():
                bad_lines += 1
                continue
            frame[":".join(p[2:])] = int(w[0])
ok = tot_lines - bad_lines
print(".su 总行=%d 可解析=%d 不可解析=%d 唯一函数=%d" % (tot_lines, ok, bad_lines, len(frame)))
if ok == 0:
    print("!! 全不可解析 ⇒ 仪器瞎，本发未测"); sys.exit(1)
for k in ("policydb_read", "avtab_read", "ebitmap_read", "mls_read", "wr_init", "init_module"):
    print("   点名 %s = %s" % (k, frame.get(k, "不在表里")))
print("   全体帧之和(＝任一链的上界)=%d" % sum(frame.values()))

# ---- 调用图：从设备上那份 ko 的反汇编里取函数体内的 bl <符号> ----
cur = None
callee = {}
bl_named = bl_unnamed = 0
fn_re = re.compile(r"^[0-9a-f]+ <([^>]+)>:")
for ln in open(dis, encoding="utf-8", errors="replace"):
    m = fn_re.match(ln)
    if m:
        cur = m.group(1)
        callee.setdefault(cur, [])
        continue
    if cur is None or not re.search(r"\bbl\b", ln):
        continue
    t = re.search(r"<([^>]+)>", ln)
    if not t:
        bl_unnamed += 1          # 外部符号(内核自己的)：当叶子，两边都一样深
        continue
    tgt = t.group(1).split("+")[0]
    bl_named += 1
    if tgt in frame:
        callee[cur].append(tgt)
print("图：函数节=%d 有名 bl 边=%d 无名(外部)边=%d" % (len(callee), bl_named, bl_unnamed))
if callee.get("policydb_read"):
    print("GRAPH_TEETH=1 policydb_read 的内部被调者=%s" % sorted(set(callee["policydb_read"]))[:10])
else:
    print("GRAPH_TEETH=0 ★图里 policydb_read 没有内部边 ⇒ 链读数是仪器产物，别用")

# ---- 最坏链(带路径；环当前路径断开并如实报) ----
memo, cycle = {}, set()
def worst(n, stack):
    if n in stack:
        cycle.add(n)
        return 0, [n + "(环)"]
    if n in memo:
        return memo[n]
    stack.add(n)
    best, bp = 0, []
    for c in set(callee.get(n, [])):
        v, p = worst(c, stack)
        if v > best:
            best, bp = v, p
    stack.discard(n)
    r = (frame.get(n, 0) + best, [n] + bp)
    memo[n] = r
    return r

for start in ("init_module", "policydb_read"):
    if start not in frame and start not in callee:
        print("-- 起点 %s 不在表里，跳过" % start)
        continue
    v, p = worst(start, set())
    print("★最坏链 %s = %d 字节  层数=%d" % (start, v, len(p)))
    print("   路径: %s" % " -> ".join(p[:26]))

print("-- 最大的 20 个帧 --")
for k, v in sorted(frame.items(), key=lambda x: -x[1])[:20]:
    print("   %7d  %s" % (v, k))
print("-- 环(若有，说明上面的最坏链对递归那支是低估)：%s" % (sorted(cycle)[:8] or "无"))
PY

echo
echo "=== 3) insmod 那条路已经吃掉多少(现读树里的真实深度，别背) ==="
echo "-- load_module/do_one_initcall 自己的帧(若有 .su 就现读，没有就说明它不在我们模块里) --"
grep -rl 'load_module' "$D"/*.su 2>/dev/null | head -2
echo "-- 内核侧已开 VMAP_STACK=y ⇒ 栈越界是 fault(＝当场炸，与【装载中就没回来】这一形状相容；若没开，越界是静默踩，形状会不同) --"
grep -m1 '^CONFIG_VMAP_STACK=y' "$KDIR/.config" >/dev/null && echo "  现读复证：本树 CONFIG_VMAP_STACK=y" || echo "  !! 现读不到 VMAP_STACK=y ⇒ 上面那句作废"
echo "END $(date)"
