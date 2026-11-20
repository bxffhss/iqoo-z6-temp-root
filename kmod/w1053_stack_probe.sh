#!/bin/bash
# w1053_stack_probe.sh —— 0 枪（纯主机）：用**出货同一条 make 行**量出这个模块每个函数的内核栈帧，
#   再拿"内核栈到底有多大"去夹它 ⇒ 判「stage3 死在 insmod 里」这一格的第一个候选机制：
#   **模块装载路径的内核栈溢出**(insmod 的栈已经比 boot 期加载策略浅得多，而 VMAP_STACK 会把越界直接变成 fault)。
# 为什么先打这一格而不是先搭 ASAN 台：这一格用的是**同一份源＋同一个编译器＋同一套 KCFLAGS**，
#   读数不掺"我的 shim 是不是骗我"这一层(搭 ASAN 台时那一层是洗不掉的)；而且它便宜。
# ★判据形状(不靠"最深链"那种我还没仪器去算的东西，先用一个**上界**把假设打死或打活)：
#   任一执行链的栈用量 ≤ 「本次参与编译的所有函数帧之和」⇒
#     和 < 16384 ⇒ ★假设**判死**(连上界都够不着，不必再算图)
#     和 ≥ 16384 ⇒ 假设**仍活着**，但这一格还说不清有没有一条真链够得到 ⇒ 下一格才是要不要建调用图 DFS。
#   仪器牙=selftest：①`policydb_read` 必须在表里(它在 policydb.c 里定义；缺了＝-fstack-usage 没生效，全表作废)
#                    ②行数/文件数现印；③被量的那份 main 的 md5 现印(证明量的是哪一个件，别跨件借读数)。
# 只读设备无关；不动原目录(/home/lucy/w985_ssport)——在副本里编，出货件的字节不变。
set -u
KDIR=/root/k/nothing_sm7325_v_mr
SRC=$KDIR/security/selinux
S=/home/lucy/w985_ssport
D=/home/lucy/w1053_su
LOG=$D/build.log

echo "BEGIN $(date)"
echo "HOST_IDENTITY host=$(hostname) user=$(id -un) uname=$(uname -m)"
[ -d "$S/ss" ] || { echo "PORT_ABSENT dir=$S ⇒ 判未测退出(先跑 w985_ssport_build.sh)"; exit 1; }

echo
echo "=== 1) 把被测对象**整份**复制到副本(原目录不动＝出货 ko 的字节不受影响) ==="
rm -rf "$D"; mkdir -p "$D"
cp -a "$S/." "$D/" || { echo "!! cp -a 失败"; exit 1; }
rm -f "$D"/*.o "$D"/*.ko "$D"/*.su "$D"/.*.cmd 2>/dev/null
rm -rf "$D/.tmp_versions" 2>/dev/null
echo "副本=$D 文件数=$(find "$D" -type f | wc -l) (删掉旧产物之后)"
echo "-- 被测源 md5(与登记值对表：主源应=fe5a8d6d… 桩=a769b55e…，SS 八件见下) --"
md5sum "$D"/w985_main.c "$D"/w987_ss_glue.c 2>/dev/null | sed 's|^|  |'
md5sum "$D"/ss/*.c | sed 's|^|  |'
echo "-- 与原件逐字节是否相同(两把尺：md5 表本身＋cmp) --"
DIFFN=0
for f in w985_main.c w987_ss_glue.c ss/avtab.c ss/conditional.c ss/ebitmap.c ss/hashtab.c ss/mls.c ss/policydb.c ss/sidtab.c ss/symtab.c; do
  cmp -s "$S/$f" "$D/$f" || { echo "  [不同] $f"; DIFFN=$((DIFFN+1)); }
done
echo "  副本与原件差异文件数=$DIFFN (判据：=0)"

echo
echo "=== 2) 内核栈到底多大(现读这棵树的 .config，不背主线数字) ==="
C=$KDIR/.config
if [ -f "$C" ]; then
  for k in CONFIG_ARM64_4K_PAGES CONFIG_ARM64_16K_PAGES CONFIG_ARM64_64K_PAGES CONFIG_THREAD_SIZE_ORDER \
           CONFIG_VMAP_STACK CONFIG_FRAME_WARN CONFIG_CC_STACKPROTECTOR CONFIG_CC_STACKPROTECTOR_STRONG \
           CONFIG_SCHED_STACK_END_CHECK CONFIG_KASAN CONFIG_GCC_PLUGIN_STACKLEAK; do
    v=$(grep -m1 -E "^($k=|.*# $k is not set)" "$C" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "  $v" || echo "  [查无此行] $k"
  done
else
  echo "  !! $C 不在 ⇒ 这一格未测(没有分母，帧数再多也判不了)"
fi

echo
echo "=== 3) 用出货同一条 make 行＋-fstack-usage 编(在副本里) ==="
cd "$D" && make -C "$KDIR" M="$D" \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I$D -I$D/include -I$D/ss -Wno-unused-function -Wno-unused-variable -fstack-usage" \
  modules > "$LOG" 2>&1
RC=$?
echo "MAKE_RC=$RC (★这是 make 自己的 rc，不是管道末端)"
echo "DIAG_ERR=$(grep -cE ': error: ' "$LOG")  (非 0 就先修编译，别读表)"

echo
echo "=== 4) .su 表收集 + ★仪器的牙 ==="
NF=$(find "$D" -name '*.su' | wc -l)
NR=$(find "$D" -name '*.su' -exec cat {} + 2>/dev/null | grep -c .)
echo "SU_FILES=$NF SU_ROWS=$NR"
find "$D" -name '*.su' -exec head -2 {} + 2>/dev/null | sed 's|^|  格式样本: |' | head -8
if find "$D" -name '*.su' -exec grep -l 'policydb_read' {} + 2>/dev/null | grep -q .; then
  echo "SU_TEETH=1(policydb_read 在表里＝-fstack-usage 真生效)"
else
  echo "SU_TEETH=0(★表里没有 policydb_read ⇒ 这一格什么都没量到，下面所有数字都不许用)"
fi

echo
echo "=== 5) 读数：全体函数帧之和(＝任一执行链的上界) + 最大的那些 ==="
python3 - "$D" <<'PY'
import os, sys
root = sys.argv[1]
rows, raw = [], []
def fieldval(line):
    f = line.split(":")
    if len(f) < 3:
        return None
    # 不背格式：两种都试。A) file:function:bytes:static:dynamic
    if len(f) >= 4 and f[2].isdigit() and (f[3] in ("static", "dynamic") or f[3].isdigit()):
        return (int(f[2]), f[1], os.path.basename(f[0]))
    # B) file:line:function:bytes:static:dynamic
    if len(f) >= 5 and f[3].isdigit():
        return (int(f[3]), f[2], os.path.basename(f[0]))
    return None
for dp, _, fs in os.walk(root):
    for fn in fs:
        if not fn.endswith(".su"):
            continue
        for ln in open(os.path.join(dp, fn), encoding="utf-8", errors="replace"):
            ln = ln.rstrip("\n")
            if not ln.strip():
                continue
            raw.append(ln)
            v = fieldval(ln)
            if v:
                rows.append(v)
print("总行数=%d 可解析=%d 不可解析=%d" % (len(raw), len(rows), len(raw) - len(rows)))
tot = sum(r[0] for r in rows)
print("★帧之和(任一执行链的上界)=%d 字节   函数条数=%d" % (tot, len(rows)))
print("-- 最大的 25 个 --")
for by, fn, tu in sorted(rows, reverse=True)[:25]:
    print("  %7d  %-44s %s" % (by, fn, tu))
KEY = ("policydb_read", "policydb_write", "policydb_init", "avtab_read", "avtab_init",
       "avtab_cache_init", "ebitmap_read", "ebitmap_init", "mls_read", "mls_range_read",
       "mls_level_read", "symtab_read", "context_read", "cond_read_list", "cond_read_avtab_link",
       "sidtab_init", "sidtab_set_initial", "wr_init", "compute_xperms", "read_isids",
       "type_read", "class_read", "role_read", "user_read", "policydb_load_isids")
print("-- 装载链上那些(按名字挑) --")
hit = 0
for by, fn, tu in sorted(rows, reverse=True):
    if any(k in fn for k in KEY):
        print("  %7d  %-44s %s" % (by, fn, tu)); hit += 1
print("链上命中条数=%d" % hit)
print("-- 原始前 6 行(核对格式用，别信上面的解析器) --")
for ln in raw[:6]:
    print("  RAW:", ln)
PY

echo
echo "=== 6) 分母(把 THREAD_SIZE 现算，不写死) ==="
python3 - "$KDIR/.config" <<'PY'
import re, sys
p = sys.argv[1]
try:
    t = open(p, encoding="utf-8", errors="replace").read()
except Exception as e:
    print("读不到 .config ⇒ 本格未测:", e); sys.exit(0)
def g(k):
    m = re.search(r"^%s=(\S+)$" % k, t, re.M)
    return m.group(1) if m else None
pg = 4096
if g("CONFIG_ARM64_16K_PAGES") == "y": pg = 16384
if g("CONFIG_ARM64_64K_PAGES") == "y": pg = 65536
order = g("CONFIG_THREAD_SIZE_ORDER")
thr = (pg << int(order)) if order is not None else None
print("PAGE=%s THREAD_SIZE_ORDER=%s ⇒ THREAD_SIZE=%s" % (pg, order, thr))
print("VMAP_STACK=%s FRAME_WARN=%s STACKPROTECTOR=%s STRONG=%s SCHED_STACK_END_CHECK=%s KASAN=%s" % (
    g("CONFIG_VMAP_STACK"), g("CONFIG_FRAME_WARN"), g("CONFIG_CC_STACKPROTECTOR"),
    g("CONFIG_CC_STACKPROTECTOR_STRONG"), g("CONFIG_SCHED_STACK_END_CHECK"), g("CONFIG_KASAN")))
print("★判据：第 5 节那个『上界』若 < THREAD_SIZE ⇒ 栈溢出这一候选**判死**；若 >= ⇒ 假设仍活，但要真调用图才敢说有没有一条链够得到")
PY
echo "END $(date)"
