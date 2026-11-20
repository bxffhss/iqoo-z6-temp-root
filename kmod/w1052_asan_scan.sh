#!/bin/bash
# w1052_asan_scan.sh —— 0 枪（纯主机）：给「主机 ASAN 复现台」精确量出要垫哪些 shim，并复核要照抄的调用形状。
#   两条自我更正(都是这次探针里现抓的)：
#     ①上一版(w1050)第 4 节的词表 PAT 写成**一整串**(没有空格)，`for p in $PAT` 只循环了一次 ⇒
#        印出一行「总数 292」，我想要的**逐项计数一格都没拿到**。本版用换行表＋while read，并自证行数。
#     ②上一版第 3 节的"输入面"把**生成的 w985_probe.mod.c** 和**我们自己的 main/桩/cfi_stub** 一起算了进去
#        ⇒ 那份「尖括号假头清单」混进了 kprobes/proc_fs/seq_file/vermagic 这些**根本不属于 SS 子集**的项。
#        本版把尺收窄到 8 个 SS 的 .c＋它们自己的头，另起一节单独列"我们自己的件"。
#   只读：不改任何文件、不碰设备。
set -u
D=/home/lucy/w985_ssport
SRC=/root/k/nothing_sm7325_v_mr/security/selinux
[ -d "$D/ss" ] || { echo "PORT_ABSENT=1 dir=$D ⇒ 判未测退出(先跑 w985_ssport_build.sh)"; exit 1; }

echo "BEGIN $(date)"
echo "HOST_IDENTITY host=$(hostname) user=$(id -un) uname=$(uname -m)"

echo
echo "=== A) 被测对象＝SS 子集那 8 个 .c ＋它们看到的头(自证数量) ==="
SSC="$D/ss/avtab.c $D/ss/conditional.c $D/ss/ebitmap.c $D/ss/hashtab.c $D/ss/mls.c $D/ss/policydb.c $D/ss/sidtab.c $D/ss/symtab.c"
SSH="$D/ss/*.h $D/include/*.h $D/flask.h $D/av_permissions.h"
echo "SS .c 数=$(echo $SSC | wc -w) 行数=$(cat $SSC | wc -l)   ← 0 就说明下面的 grep 没有输入面"
echo "头文件落点：ss/*.h=$(ls "$D"/ss/*.h | wc -l) include/*.h=$(ls "$D"/include/*.h 2>/dev/null | wc -l) 根上=$(ls "$D"/*.h 2>/dev/null | wc -l)"

echo
echo "=== B) 尖括号 include 面(收窄后＝真正要垫的假头) ==="
grep -hoE '#include[[:space:]]*<[^>]+>' $SSC $SSH 2>/dev/null | sed -E 's/.*<(.*)>/\1/' | sort | uniq -c | sort -rn
echo "-- 对比：我们自己的件(main/桩/cfi_stub，不算 SS 子集)用到的是--"
grep -hoE '#include[[:space:]]*<[^>]+>' "$D"/w987_ss_glue.c "$D"/cfi_stub.c 2>/dev/null | sed -E 's/.*<(.*)>/\1/' | sort -u | tr '\n' ' '
echo

echo
echo "=== C) ★逐项计数(换行表＋while read；上一版这里静默退化成一行的总数) ==="
cat > /tmp/w1052_tokens.txt <<'EOF'
kmalloc
kzalloc
kcalloc
kmalloc_array
kmem_cache_create
kmem_cache_alloc
kmem_cache_free
kfree
kvmalloc
kvzalloc
vzalloc
vmalloc
vfree
kstrdup
kvasprintf
kasprintf
scnprintf
sprintf
snprintf
vsprintf
pr_info
pr_err
pr_warn
pr_cont
GFP_KERNEL
GFP_ATOMIC
rcu_read_lock
rcu_read_unlock
rcu_assign_pointer
rcu_dereference
spin_lock
spin_unlock
spinlock_t
mutex_lock
mutex_init
DECLARE_HASHTABLE
hash_add
hash_for_each
hash_for_each_possible
hlist_add_head
hlist_del
hlist_entry
hlist_nulls
INIT_HLIST_NODE
smp_load_acquire
smp_store_release
smp_mb
read_barrier_depends
READ_ONCE
WRITE_ONCE
ACCESS_ONCE
BUG_ON
WARN_ON
IS_ERR
ERR_PTR
PTR_ERR
ARRAY_SIZE
sizeof_field
offsetof
__ro_after_init
____cacheline_aligned
__aligned
__weak
__init
EXPORT_SYMBOL
netlbl_
security_get_bools
sidtab_
avtab_cache_init
EOF
TN=$(grep -c . /tmp/w1052_tokens.txt)
echo "词表行数=$TN (★不写死期望值，由产生者现数；=0 就是词表没落地) 逐项命中如下(只数 SS 子集那 8 个 .c)"
[ "$TN" -gt 0 ] || { echo "!! 词表空 ⇒ 本发未测"; exit 1; }
ZERO=""
while read -r tok; do
  [ -n "$tok" ] || continue
  c=$(grep -hoE "\b${tok}[a-z_]*" $SSC 2>/dev/null | wc -l)
  if [ "$c" = "0" ]; then ZERO="$ZERO $tok"; else printf '  %-24s %s\n' "$tok" "$c"; fi
done < /tmp/w1052_tokens.txt
echo "零命中(＝不用垫)：$ZERO"

echo
echo "=== D) 要照抄的调用形状(现读头文件，不凭印象) ==="
echo "-- policydb_read 原型 --"
grep -n -A3 'int policydb_read' "$D/ss/policydb.h" | head -8
echo "-- struct policy_file --"
grep -n -A6 'struct policy_file {' "$D/ss/policydb.h" | head -10
echo "-- policydb_read 里是否自己调 policydb_init(决定主机侧要不要先 init) --"
awk '/^int policydb_read/{f=1} f&&/policydb_init/{print NR": "$0; c++} /^}/&&f{f=0} END{print "policydb_init_in_read_hits="c+0}' "$D/ss/policydb.c" | head -6
echo "-- file_read_* 游标用的哪个类型 --"
grep -n -E 'static inline int file_read_(uint32|aux)\(' "$D/ss/policydb.c" | head -4
grep -n -E '#define file_read' "$D/ss/policydb.c" | head -6
echo "-- policydb 里 te_avtab/policyvers/mls_enabled 三个成员在不在(判据要读它们) --"
grep -n -E 'struct avtab te_avtab;|policyvers;|mls_enabled;' "$D/ss/policydb.h" | head -6

echo
echo "=== E) 喂料文件在场复证(两把读法) ==="
F=/home/lucy/pol.live_1027
if [ -f "$F" ]; then
  echo "  ls: $(ls -l "$F" | awk '{print $5" "$9}')"
  echo "  wc -c=$(wc -c < "$F") md5=$(md5sum "$F" | cut -d' ' -f1)"
  echo "  头 16 字节 od -c:"; od -An -c -N16 "$F" | sed 's|^|    |'
else
  echo "  [缺] $F ⇒ 从本地 put w1042_pol.pre 上来再用"
fi
echo "END $(date)"
