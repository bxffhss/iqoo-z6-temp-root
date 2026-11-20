#!/bin/bash
# #216-B 第一格（0 枪，纯主机构建）：能不能把「构建树自己的 SELinux SS 源码」当模块编出来。
# 为什么走这条路而不是移植 libsepol：这些 .c 本来就是内核态代码(kmalloc/pr_err)，
#   编进我们模块后**结构体由我们自己定义、自洽即可** —— 与设备唯一相接的只有「序列化字节流」，
#   解析与装载都由设备自己那份 policydb_read 完成 ⇒ 不需要知道设备上 struct 的真实布局。
# 判据：①编译过 ②产物是 aarch64 ③llvm-nm -u 的未解析表里**只有**内核导出的通用 API
#   （若出现 policydb_*/avtab_* ⇒ 说明子集取少了，链接期会去找 vmlinux 那份，insmod 必失败）
set -u
KDIR=/root/k/nothing_sm7325_v_mr          # ★与我们出货 ko 同一棵树(remote_ksu_rc74c.sh 里的 KDIR)
SRC=$KDIR/security/selinux
D=/home/lucy/w985_ssport
LOG=$D/build.log
echo "BEGIN $(date)"
echo "KDIR=$KDIR"; ls -d "$SRC" || { echo "!! 没有 $SRC"; exit 1; }

echo; echo "=== 0) 两棵树的 SS 形状是否一致（我们编的是 nothing 这份）==="
for T in "$KDIR" /root/k/linux-5.4.281; do
  echo "-- $T"
  sed -n '/^struct avtab_key {/,/^};/p' "$T/security/selinux/ss/avtab.h" 2>/dev/null | grep -E 'u16|u8|u32'
  sed -n '/^struct avtab {/,/^};/p' "$T/security/selinux/ss/avtab.h" 2>/dev/null | grep -E 'htable|u32|struct'
  grep -n -A9 '^struct selinux_ss {' "$T/security/selinux/ss/services.h" 2>/dev/null | sed -n 2,9p
done

echo; echo "=== 1) 建目录 + 拷源码（拷进来的文件逐个记 md5，出处可追）==="
rm -rf "$D"; mkdir -p "$D/ss" "$D/include"
# ★一手实测(第一版)：这棵树里**没有** ss/context.c(只有 context.h，里面是 static inline)也没有 mls_types.c
#   (那是 mls.c)。上一版我按主线 5.4 的文件名照抄 ⇒ cp 失败(硬闸退了，没编出半成品)。
FILES="policydb.c avtab.c ebitmap.c hashtab.c symtab.c conditional.c mls.c sidtab.c"
for f in $FILES; do
  cp "$SRC/ss/$f" "$D/ss/$f" || { echo "!! 拷 ss/$f 失败"; exit 1; }
done
# ★第三版新增：ss/sidtab.c(policydb.c 引用 sidtab_init/search/set_initial/destroy，不编它就得去
#   vmlinux 找那份，而那四条**都不在 Module.symvers 里**⇒ insmod 会以"未知符号"失败)
#   ＋我们自己的响亮的桩 w987_ss_glue.c(context_add_hash / services_compute_xperms_{drivers,decision})
if [ ! -f /home/lucy/w987_ss_glue.c ]; then
  echo "!! /home/lucy/w987_ss_glue.c 不在 ⇒ 先 put 再编(别用一份说不出来源的桩)"
  exit 1
fi
cp /home/lucy/w987_ss_glue.c "$D/w987_ss_glue.c" || { echo "!! 拷桩失败"; exit 1; }
GLUE_MD5=$(md5sum "$D/w987_ss_glue.c" | cut -d' ' -f1)
echo "GLUE_MD5=$GLUE_MD5"        # ★由本地包装脚本 kmod/w985_run.sh 与仓库里那份现值比，不写死在脚本里
# ★一手实测(第二版)：树里有**两个** conditional.h(ss/ 与 include/)且**共用同一个 include guard**
#   `_CONDITIONAL_H_`。我原来只加 -I 指原树，`#include "conditional.h"` 先命中 include/ 那份
#   ⇒ 真身 ss/conditional.h 被 guard 吃掉 ⇒ 7 个 cond_* 报"隐式声明"(policydb.c 编不过)。
#   修法＝**镜像原树的目录结构**，让"同目录优先"这条 C 规则替我做对：.c/.h 放 ss/，include/ 放头，
#   ss/conditional.h 里那句 "../include/conditional.h" 也照样解析得到。
cp "$SRC"/ss/*.h "$D/ss/" || { echo "!! 拷 ss/*.h 失败"; exit 1; }
cp "$SRC"/include/*.h "$D/include/" || { echo "!! 拷 include 那批头失败"; exit 1; }
cp "$SRC"/*.h "$D/" 2>/dev/null || true           # flask.h / av_permissions.h / objsec.h 在根上

# 主源由本地包装 kmod/w985_run.sh put 进来(仓库里的原件＝kmod/w985_probe.c 或 kmod/w986_polround.c)
# ★一手实测：仓库那份 kmod/w985_probe.c 与远端这次编出 w985_probe.ko 的 probe.c **md5 逐字节相同**
#   (5da76744…)，所以"仓库=产物出处"这条链是核过的，不是我说了算。
if [ ! -f /home/lucy/w985_main.c ]; then
  echo "!! /home/lucy/w985_main.c 不在 ⇒ 先跑 kmod/w985_run.sh(别编一份说不出主源来历的件)"
  exit 1
fi
cp /home/lucy/w985_main.c "$D/w985_main.c" || { echo "!! 拷主源失败"; exit 1; }
MAIN_MD5=$(md5sum "$D/w985_main.c" | cut -d' ' -f1)
echo "MAIN_MD5=$MAIN_MD5"

echo; echo "=== 1b) ★安全补丁：我们这份 avtab.c 副本**不能带 SLAB_PANIC、也不能与内核自己那两份 slab 重名** ==="
# 一手依据(现读树)：`avtab_cache_init()` 用 `kmem_cache_create("avtab_node", …, SLAB_PANIC, NULL)`；
# 而这台机的 5.4 `kmem_cache_sanity_check()` **根本不查重名**(只查 name/null/in_interrupt/size)。
# ⇒ 模块里再调一次＝同参数时被 SLUB 的 __kmem_cache_alias **复用内核那个 cache**(共享，靠 object_size/align 相同)
#   或造出第二个同名 cache(撞 /sys/kernel/slab 的名字)；而 **SLAB_PANIC 在量产机上＝任何一次创建失败就是硬复位**。
#   这两条都不是"理论风险"，是"我们没必要替别人的内核冒的险"。⇒ 改名＋去掉 PANIC＋改成 int 返回让我们能判空。
cat > /tmp/w985_avtab_patch.py <<'PYP'
import io, sys
p = "/home/lucy/w985_ssport/ss/avtab.c"
s = io.open(p, encoding="utf-8", errors="replace").read()

# 1) 整段替换 avtab_cache_init()：改名＋去 SLAB_PANIC＋返回 int＋判空
start = s.find("void __init avtab_cache_init(void)")
if start < 0:
    print("[x] 找不到 avtab_cache_init 的定义 ⇒ 停"); sys.exit(1)
end = s.index("\n}", start) + 2          # 到该函数自己的收尾 }
old_body = s[start:end]
if old_body.count("SLAB_PANIC") != 2 or old_body.count("kmem_cache_create") != 2:
    print("[x] 函数体形状与预期不符(PANIC=%d create=%d) ⇒ 停\n%s"
          % (old_body.count("SLAB_PANIC"), old_body.count("kmem_cache_create"), old_body))
    sys.exit(1)
new_body = (
    "void __init avtab_cache_init(void)\n"
    "{\n"
    "\t/* w985 硬化：唯一名(不与内核自己的 avtab_node/avtab_extended_perms 抢)＋去掉 panic 旗标\n"
    "\t *      ⇒ 创建失败不再把量产机打进硬复位。签名保持原样(它由 include/security.h:411 声明为\n"
    "\t *      `extern void avtab_cache_init(void);`——我一度以为「没有任何头声明它」，那是**我只在 ss 目录那批头里 grep**、\n"
    "\t *      没 grep include/ 造成的错判，被自家编译器以 conflicting types 当场驳掉)。\n"
    "\t *      创建结果改由下面那个 z6ss_avtab_caches_ok() 交回调用方判。 */\n"
    "\tavtab_node_cachep = kmem_cache_create(\"z6ss_avtab_node\",\n"
    "\t\t\t\t\t      sizeof(struct avtab_node),\n"
    "\t\t\t\t\t      0, 0, NULL);\n"
    "\tavtab_xperms_cachep = kmem_cache_create(\"z6ss_avtab_xperms\",\n"
    "\t\t\t\t\t      sizeof(struct avtab_extended_perms),\n"
    "\t\t\t\t\t      0, 0, NULL);\n"
    "}\n"
    "\n"
    "/* 我们自己的访问器(不与任何内核符号重名)：0＝两份 cache 都在手上 */\n"
    "int z6ss_avtab_caches_ok(void)\n"
    "{\n"
    "\treturn (avtab_node_cachep && avtab_xperms_cachep) ? 0 : -ENOMEM;\n"
    "}\n")
s = s[:start] + new_body + s[end:]

# 2) 全文件复核：PANIC 清零、旧名清零、新名各 1、返回值 1
for tok, want in [("SLAB_PANIC", 0), ('"avtab_node"', 0), ('"avtab_extended_perms"', 0),
                  ('"z6ss_avtab_node"', 1), ('"z6ss_avtab_xperms"', 1),
                  ("void __init avtab_cache_init(void)", 1),
                  ("int z6ss_avtab_caches_ok(void)", 1),
                  ("return (avtab_node_cachep && avtab_xperms_cachep)", 1)]:
    got = s.count(tok)
    if got != want:
        print("[x] 复核 [%s] 命中 %d，期望 %d ⇒ 停" % (tok, got, want)); sys.exit(1)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print("[ok] avtab 补丁：整段替换＋7 项复核全过")
PYP
python3 /tmp/w985_avtab_patch.py
PATCH_RC=$?
echo "PATCH_RC=$PATCH_RC"
[ "$PATCH_RC" -eq 0 ] || { echo "!! avtab 补丁失败 ⇒ 停(不编未硬化的件)"; exit 1; }
echo "-- 打完读回(原样打印，给人核句子对不对，不只核字节)："
# ★这一行的模式原来是 `/int __init avtab_cache_init/`，而补丁写进去的是 `void __init ...`
#   ⇒ 一条**永远打印不出东西**的读回＝没有牙的证人(读回为空会被读成"没问题")。改成两个函数各自精确匹配。
sed -n '/^void __init avtab_cache_init/,/^}/p;/^int z6ss_avtab_caches_ok/,/^}/p' "$D/ss/avtab.c" | sed 's/^/    /'
RB=$(sed -n '/^void __init avtab_cache_init/,/^}/p' "$D/ss/avtab.c" | wc -l)
echo "  READBACK_LINES=$RB  (判据：读回必须非空，0 行＝这条腿自己坏了，不是补丁没问题)"
[ "$RB" -gt 0 ] || { echo "!! 读回为空 ⇒ 停(不许用一条没有输出的读回给自己作证)"; exit 1; }
ls "$D/ss" | wc -l | sed 's/^/  ss 里文件数=/'
ls "$D/include" | wc -l | sed 's/^/  include 里文件数=/'


# ★★★CFI 桩（2026-10-28 §6.484）：本机内核是 clang CFI **且非 permissive**，内核对"被间接调用的模块函数"
#   走 `mod->cfi_check`，而它是在 cfi_init() 里**按名字**从模块符号表里找 `__cfi_check`；找不到就
#   handle_cfi_failure() = 当场违规 = panic。⇒ 带 `do_one_initcall` 的任何外部模块**必须**自己提供这个桩，
#   否则连 init 第一句 printk 都打不出来（第 72 发就是这么把机器弄成 PS_HOLD 的）。
#   出货的 kernelsu.ko 一直带着（`/root/k/ksu/kernel/Kbuild:171`，2026-09-30 真机验过）。
cp /root/k/ksu/kernel/cfi_stub.c "$D/cfi_stub.c" || { echo "!! 拿不到 cfi_stub.c ⇒ 停(没桩的件不许上机)"; exit 1; }
[ -s "$D/cfi_stub.c" ] || { echo "!! cfi_stub.c 是空的 ⇒ 停"; exit 1; }
cat > "$D/Makefile" <<'MK'
# 把构建树的 SS 子集编进一个独立探针模块（对象在 ss/ 子目录里，与镜像目录结构一致）
obj-m += w985_probe.o
w985_probe-y := w985_main.o w987_ss_glue.o cfi_stub.o ss/policydb.o ss/avtab.o ss/ebitmap.o ss/hashtab.o ss/symtab.o ss/conditional.o ss/mls.o ss/sidtab.o
MK
ls -la "$D" "$D/ss" | head -30
md5sum "$D"/w985_main.c "$D"/w987_ss_glue.c "$D"/ss/*.c | sed 's/^/  /'

echo; echo "=== 1c) ★段内计数器补丁(第 84 发那一格；开关＝远端那个小纸片 /home/lucy/SUBSTEP 里写的 on/off) ==="
#   为什么用"纸片的内容"而不是"纸片在不在"，也不是环境变量：
#     · `w999_runcap.sh` 走 `cli.py exec --file` ⇒ **环境变量不过去**；
#     · "在＝on、不在＝off"需要一次远端 `rm`——漏删就**静默换形状**＝最坏的那种失效；
#     · 内容式开关永远是"我刚刚写进去的那个值"，读回来就印在证件第一行，两边都不可能猜。
SUBSTATE=$(cat /home/lucy/SUBSTEP 2>/dev/null || echo off)
echo "SUBSTEP=$SUBSTATE(远端纸片现读)"
if [ "$SUBSTATE" = on ]; then
  if [ ! -f /home/lucy/w1085_substep_patch.py ]; then
    echo "!! 纸片写着 on 但打补丁件不在 ⇒ 停(不能编出一份'以为打过补丁其实没打'的件)"
    exit 1
  fi
  python3 /home/lucy/w1085_substep_patch.py --check "$D" || { echo "!! 锚点不齐 ⇒ 停(锚点被我按印象写＝例 190②)"; exit 1; }
  python3 /home/lucy/w1085_substep_patch.py --apply "$D" || { echo "!! 打补丁失败 ⇒ 停"; exit 1; }
  for f in policydb.c avtab.c; do
    echo "PATCHED_MD5_$f=$(md5sum "$D/ss/$f" | cut -d' ' -f1)"
  done
fi

echo; echo "=== 2) 编（与出货脚本同一条 make 行的编译器设置）==="
cd "$D" && make -C "$KDIR" M="$D" \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I$D -I$D/include -I$D/ss -Wno-unused-function -Wno-unused-variable" \
  modules > "$LOG" 2>&1
RC=$?
echo "MAKE_RC=$RC  (注意：这一步之后才取 RC，别在管道末端取)"
echo "-- error 行(去重)"; grep -E ' error: ' "$LOG" | sed 's/^.* error: /ERR: /' | sort -u | head -25
echo "-- 隐式声明(这类会在链接期才爆，必须 0)"; grep -E "implicit declaration" "$LOG" | sort -u | head -15
# ★★这一格原来写的是 `grep -oE '\[(warning|error)\]'`——clang 的诊断行是 `文件:行:列: warning: …`，
#   **方括号形式根本不出现** ⇒ 有 warning 和没 warning 它都打印空 ⇒ 一条没有牙的判据(例：证人放在两种形状都写不进的位置)。
#   改成计数＋硬闸：三个数都必须=0，非零直接判负退出。
ERRN=$(grep -cE ': error: ' "$LOG")
WARNN=$(grep -cE ': warning: ' "$LOG")
IMPN=$(grep -cE 'implicit declaration' "$LOG")
echo "DIAG_ERR=$ERRN DIAG_WARN=$WARNN DIAG_IMPLICIT=$IMPN   (判据：三个都必须=0)"
if [ "$ERRN" -ne 0 ] || [ "$WARNN" -ne 0 ] || [ "$IMPN" -ne 0 ]; then
  echo "!! 诊断非零 ⇒ 判负(不许用带 warning 的件当 B2 底料)"; grep -E ': (warning|error): ' "$LOG" | sort -u | head -20
  exit 1
fi
echo; echo "=== 3) 产物 ==="
if [ -f "$D/w985_probe.ko" ]; then
  ls -l "$D/w985_probe.ko"; md5sum "$D/w985_probe.ko"
  file "$D/w985_probe.ko"
  echo "-- 未解析符号(应只有通用内核 API)："
  /usr/bin/llvm-nm -u "$D/w985_probe.ko" | awk '{print $2}' | sort > /tmp/w985_u.txt
  # ★硬闸：没有 `__cfi_check` 这个符号的件**一律不许上机**（第 72 发的教训：这条不在任何判据里时，
  #   我们花了三枪才发现 init 从没进去过）。
  CFIN=$(/usr/bin/llvm-nm "$D/w985_probe.ko" 2>/dev/null | grep -cw __cfi_check)
  echo "  __cfi_check 符号数=$CFIN  (判据：必须=1；=0 ⇒ 内核经 do_one_initcall 间接调用本件时会 panic)"
  [ "$CFIN" = 1 ] || { echo "!! 缺 CFI 桩 ⇒ 判负，这个件不许派上机(见 §6.484)"; exit 1; }
  NU=$(wc -l < /tmp/w985_u.txt); echo "  未解析条数=$NU"
  [ "$NU" -gt 0 ] || { echo "  !! 未解析表是空的 ⇒ 这个读数没有判别力(先怀疑 nm 没跑成)，别当通过"; exit 1; }
  LEAK=$(grep -E 'policydb|avtab|ebitmap|hashtab|symtab|context_|mls_|cond_' /tmp/w985_u.txt | tr '\n' ' ')
  if [ -n "$LEAK" ]; then
    echo "  !! SS 内部符号外流(链接期会去找 vmlinux 那份 ⇒ insmod 必失败)：$LEAK"
  else
    echo "  SS 内部符号外流=0（子集自洽）"
  fi
  echo "-- 前 30 条未解析："; head -30 /tmp/w985_u.txt | tr '\n' ' '; echo
  echo "-- 这些名字在导出表里吗(缺哪个就得走 kallsyms 兜底)："
  if [ -s "$KDIR/Module.symvers" ]; then
    # symvers 的列：crc  symbol  定义它的.o  导出宏 —— 按第 2 列精确比
    awk 'NR==FNR{need[$1]=1;next} {have[$2]=1} END{for(s in need) if(!(s in have)) print "  未导出: "s}' \
        /tmp/w985_u.txt "$KDIR/Module.symvers" | sort | head -40
    MISSN=$(awk 'NR==FNR{need[$1]=1;next} {have[$2]=1} END{c=0;for(s in need) if(!(s in have)) c++; print c+0}' \
        /tmp/w985_u.txt "$KDIR/Module.symvers")
    echo "  未导出合计=$MISSN / $NU"
  else
    echo "  !! 本机没有 $KDIR/Module.symvers ⇒ 这一格记「未测」，不记「都导出」"
  fi
  # ★把产物按"带没带段内计数器"具名复制一份，供本地 `cli.py get <相对名>` 取回(远端绝对名会把真身留在 mount/ 里＝一手坑)。
  #   名字里带着形状 ⇒ "哪份是哪一格"不靠我记性；两边 md5 由本地包装脚本再比一遍。
  #   ★v7＝`rt_abi=85`：段内计数器之外**多了被测自己记的 `rt_hist` 环＋`/proc/w986_hist` 快照读点**(§6.510)。
  SUBTAG=plain; [ "$SUBSTATE" = on ] && SUBTAG=substep
  KOOUT="/home/lucy/w986_polround_v7_${SUBTAG}.ko"
  cp "$D/w985_probe.ko" "$KOOUT" && echo "KO_COPY=$KOOUT KO_COPY_MD5=$(md5sum "$KOOUT" | cut -d' ' -f1)" \
     || { echo "!! 复制产物失败 ⇒ 本地取不到件"; exit 1; }
else
  echo "!! 没有 .ko ⇒ 本格判负"; echo "-- 尾部 40 行日志"; tail -40 "$LOG"
fi
echo "END $(date)"
