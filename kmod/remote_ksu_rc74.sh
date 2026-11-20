#!/usr/bin/env bash
# rc74 = **rc73 + 一小块新代码：Manager 出生即装驱动 fd(md §6.413)**
#   要解决的问题(全是一手)：官方 Manager 首页那块「支持/越狱模式」的牌子是**进程启动时一次性查询**
#   (§6.406：libkernelsu.so 扫 /proc/self/fd 找 [ksu_driver])。
#     · fd 晚到刷不亮一个已经在跑的进程 ⇒ §6.406 那发"用户态 1 秒节拍常驻看门狗"判负；
#     · §6.407 只能靠"force-stop→重开→0.1 秒节拍抢在查询前写触发口"把牌子刷回来(那是条要 root 的腿)；
#     · §6.409 用户照着教程连敲那条腿 ⇒ 手机 PS_HOLD 硬复位(#180 已给腿加了三把闸)。
#   ⇒ 唯一比它自己那次查询更早、又不需要用户态节拍的位置，在内核的 sys_enter 上——**而我们本来就注册了那条
#     tracepoint**(hook/syscall_hook_manager.c:186 的 ksu_sys_enter_tp_register)。所以这一版就在它里面认 Manager 的新进程。
#   形状(只加不改，两个文件)：
#     infra/dev_syms.c 末尾追加 ksu_mgr_birth_fd(模块参数，**默认 1=开** ⇒ 出货 ksu_args.txt 一个字都不改)
#       + ksu_mgr_birth_check()：主线程 ∧ uid 命中 ksu_manager_appid ∧ 这个进程(pid+start_time 双键)还没排过
#       ⇒ 走**现成那条 task_work 链**(同一个 ksu_fd_install_tw_func、同一把 !current->files 护栏)；
#     hook/syscall_hook_manager.c 在 "dispatcher 已就绪" 之后加一行谓词调用(带 extern 声明，不动头文件)。
#   ★三条红线：①probe 在 preempt-disabled 下跑 ⇒ 只许 GFP_ATOMIC(GFP_KERNEL 会睡=非法)；
#              ②不许引入新的**未定义**符号(装入门径逐字同 rc73，§6.412 那四条离线核对)；
#              ③!current->files 护栏必须还在(rc73 换默认的全部理由)。
#   ★这一版**故意不碰** printk 密度那条轴(§6.411 排过"降 printk")：出生即装与降 printk 是两个变量，
#     混在一发里红了说不出是谁造成的。降 printk 留给 rc75 单变量。
#   判据(开枪前写死)：①产物里有 KSUBIRTH 串(>=4)与 NULLFILES 串(>=1)；②相对 rc73 **只有这两个文件变**；
#     ③未定义引用条数与 rc73 相同(155)；④__versions 159 条不变；⑤上机后：新起 Manager 时内核出
#     "KSUBIRTH seen Manager pid=… / queued self fd…"，随后 "KSUFDINST 回调跑在…=> fd=N"，
#     而**不重 punch、不跑任何腿**，首页自己就是「工作中／32601-2／越狱模式」。
# ★本脚本是 remote_ksu_rc73.sh 的复制＋两处改动(1/2/2b/2c/2d/3/4 与 rc73 逐字相同，别凭记忆重写 make 行)：
#   改动 1：新增 2e 节——先核 /home/lucy/w685_add_birthfd.py 的 md5，再打补丁，打完结论由 grep 现数；
#   改动 2：5 节闸门换成 rc74 那套(KSUBIRTH>=4 / NULLFILES>=1 / 未定义引用=155 / __versions=159 /
#           符号表"只在 rc74 有"必须**恰好等于**那张名单 / "只在 rc73 有"必须为空)。
LOG=/home/lucy/ksu_rc74.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
U=/root/k/ksu/uapi
DEVS=/home/lucy/Module.symvers_dev
WANT_VER=${WANT_VER:-32601}
WANT_UAPI=${WANT_UAPI:-2}
MD5_DEVSYMS_BASE=5b8d86358419d9429c2c290964b08a60
MD5_DEVSYMS_RC73=e0da5e8c12f32c7110eb74c8538198a0
MD5_ALLOW_RC67=3c479222cc94106c990a9e9a06a83794
MD5_HOOK_RC67=f30801f0bb30687d365bb77b487c42fd
MD5_SHM_RC73=8eb3e5990b3cf0ec85784821ce0b208a      # rc73 树里那份 syscall_hook_manager.c(=快照 /home/lucy/shm_rc73.c)
MD5_BIRTHPY=ec71f5665bf111f75bd47d66914d35a4       # 本地 kmod/w685_add_birthfd.py 上传件
AL="$M/policy/allowlist.c"
SH="$M/hook/arm64/syscall_hook.c"
DS="$M/infra/dev_syms.c"
SHM="$M/hook/syscall_hook_manager.c"
echo "START(rc74) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"

echo "=== 1) 装 rc73 那份 dev_syms.c(cp 前后各核一次 md5；与 rc73 逐字相同) ==="
[ -f /home/lucy/ksu_dev_syms_rc73.c ] || { echo "  !! 没有 /home/lucy/ksu_dev_syms_rc73.c ⇒ 停"; exit 1; }
[ "$(md5sum /home/lucy/ksu_dev_syms_rc73.c | cut -d' ' -f1)" = "$MD5_DEVSYMS_RC73" ] \
    || { echo "  !! 红灯：上传件 md5 不等于 e0da5e8c(不是那份 基线+单护栏) ⇒ 停"; exit 1; }
cp /home/lucy/ksu_dev_syms_rc73.c "$DS" && echo "  dev_syms.c 行数=$(wc -l < "$DS") 字节=$(wc -c < "$DS")"
[ "$(md5sum "$DS" | cut -d' ' -f1)" = "$MD5_DEVSYMS_RC73" ] || { echo "  !! 红灯：cp 之后不等于那份 ⇒ 停"; exit 1; }
echo "  结构自检：护栏=$(grep -c 'if (unlikely(!current->files))' "$DS")(必须 1) NULLFILES 串=$(grep -c 'KSUFDINST NULLFILES skip' "$DS")(必须 1) 旧裸调=$(grep -c 'int nfd = ksu_install_fd();' "$DS")(必须 0)"
[ "$(grep -c 'if (unlikely(!current->files))' "$DS")" = "1" ] || { echo "  !! 红灯：护栏不在或重复 ⇒ 停"; exit 1; }
[ "$(grep -c 'KSUFDINST NULLFILES skip' "$DS")" = "1" ] || { echo "  !! 红灯：ASCII 证人串不在或重复 ⇒ 停"; exit 1; }
[ "$(grep -c 'int nfd = ksu_install_fd();' "$DS")" = "0" ] || { echo "  !! 红灯：旧裸调形状还在 ⇒ 停"; exit 1; }

echo; echo "=== 2) 幂等补丁(与 rc73 逐字相同；sucompat.c 马上会被 2c 整份还原覆盖掉) ==="
for f in diag4 sucompat_gates escape_steps decline killscan unlimit visible fdinstall setprof_gate sucompat_steps ksudpath sucompat_gates2 ksudpath2 tracequiet statprobe_steps capclamp; do
    cp "/home/lucy/patch_ksu_$f.py" "/home/lucy/p_$f.py" 2>/dev/null && python3 "/home/lucy/p_$f.py" "$M" || echo "  !! patch_ksu_$f.py 没跑成"
done

echo; echo "=== 2b) selinux.c 还原 pristine 后**照打域回退补丁**(=rc67 的样子；与 rc73 逐字相同) ==="
SL="$M/selinux/selinux.c"
if [ ! -f "$SL.pristine" ]; then
    cp "$SL" "$SL.pristine" && echo "  已存 pristine 快照：$(md5sum "$SL.pristine" | cut -d' ' -f1)"
else
    echo "  pristine 已存在：$(md5sum "$SL.pristine" | cut -d' ' -f1)"
fi
cp "$SL.pristine" "$SL" && echo "  selinux.c 已还原成 pristine：$(md5sum "$SL" | cut -d' ' -f1)"
cp /home/lucy/patch_ksu_domainfallback.py /home/lucy/p_domainfallback.py || echo "  !! 补丁脚本没拷到"
python3 /home/lucy/p_domainfallback.py "$SL" || { echo "  !! 域回退补丁没跑成 ⇒ 停"; exit 1; }
echo "  打完之后：$(md5sum "$SL" | cut -d' ' -f1) 行数=$(wc -l < "$SL")"
[ "$(grep -c 'ksu_domain_fallback' "$SL")" -ge 1 ] || { echo "  !! 红灯：selinux.c 里没有域回退 ⇒ 与 rc67 的符号表对不上，停"; exit 1; }

echo; echo "=== 2c) sucompat.c 还原成 rc67 快照，**不打 selfexec** ⇒ 这份的底就是 rc67(与 rc73 逐字相同) ==="
SUC="$M/feature/sucompat.c"
RC67_C=/home/lucy/w343_sucompat_rc67.c
MD5_RC67=e8e53b7bd153aa3d54bf72b5ee294b3e
[ -f "$RC67_C" ] || { echo "  !! 没有 rc67 快照 $RC67_C ⇒ 停(宁可不出货，不出说不出来源的货)"; exit 1; }
[ "$(md5sum "$RC67_C" | cut -d' ' -f1)" = "$MD5_RC67" ] || { echo "  !! rc67 快照本身 md5 不对 ⇒ 停"; exit 1; }
cp "$RC67_C" "$SUC" && echo "  已还原 sucompat.c 到 rc67：$(md5sum "$SUC" | cut -d' ' -f1) 字节=$(wc -c < "$SUC")"
[ "$(md5sum "$SUC" | cut -d' ' -f1)" = "$MD5_RC67" ] || { echo "  !! 红灯：还原后的 sucompat.c md5 不等于 rc67 快照 ⇒ 停"; exit 1; }

echo; echo "=== 2d) allowlist.c 与 arm64/syscall_hook.c **都还原成 rc67 快照，一块补丁都不打**(与 rc73 逐字相同) ==="
RC67_A=/home/lucy/allowlist_rc67.c
[ -f "$RC67_A" ] || { echo "  !! 没有 rc67 的 allowlist.c 快照 ⇒ 停"; exit 1; }
echo "  打之前：allow=$(md5sum "$AL" | cut -d' ' -f1)  hook=$(md5sum "$SH" | cut -d' ' -f1)"
cp "$RC67_A" "$AL" && echo "  已把 allowlist.c 还原成 rc67：$(md5sum "$AL" | cut -d' ' -f1)"
[ "$(md5sum "$AL" | cut -d' ' -f1)" = "$MD5_ALLOW_RC67" ] || { echo "  !! 红灯：还原后不等于 rc67 快照 ⇒ 停"; exit 1; }
cp /home/lucy/sh_hook_w372.c "$SH" && echo "  已把 syscall_hook.c 还原成 rc67：$(md5sum "$SH" | cut -d' ' -f1)"
[ "$(md5sum "$SH" | cut -d' ' -f1)" = "$MD5_HOOK_RC67" ] || { echo "  !! 红灯：hook 不是 f30801f0(rc67 那份) ⇒ 停"; exit 1; }
[ "$(grep -c 'ksu_no_allowlist_read' "$AL")" = "0" ] || { echo "  !! 红灯：allowlist 还带着 rc72 的 noread ⇒ 不是单变量"; exit 1; }
[ "$(grep -c 'mgrdomain' "$AL")" -ge 1 ] || { echo "  !! 红灯：allowlist 里没有 mgrdomain ⇒ 这份底不是 rc67 那份"; exit 1; }
[ "$(grep -c 'r72=%d' "$SH")" = "0" ] || { echo "  !! 红灯：hook 还带着 rc72 的正对照行 ⇒ 不是单变量"; exit 1; }
echo "  ★这一发还要钉住「只有那两个文件变」：把 hook/syscall_hook_manager.c 也从快照还原(不还原的话，上一发打过补丁的这份会带着 KSUBIRTH 再被打一次)"
[ -f /home/lucy/shm_rc73.c ] || { echo "  !! 没有 /home/lucy/shm_rc73.c(rc73 那份 manager.c 快照) ⇒ 停"; exit 1; }
[ "$(md5sum /home/lucy/shm_rc73.c | cut -d' ' -f1)" = "$MD5_SHM_RC73" ] \
    || { echo "  !! 红灯：快照本身不等于 8eb3e599 ⇒ 停"; exit 1; }
cp /home/lucy/shm_rc73.c "$SHM" && echo "  已还原 manager.c 到 rc73：$(md5sum "$SHM" | cut -d' ' -f1)"
[ "$(md5sum "$SHM" | cut -d' ' -f1)" = "$MD5_SHM_RC73" ] || { echo "  !! 红灯：还原后不是 8eb3e599 ⇒ 停"; exit 1; }

echo; echo "=== 2e) ★改动 1：打 rc74 的"出生即装"补丁(先核上传件 md5，再打，再现数) ==="
[ -f /home/lucy/w685_add_birthfd.py ] || { echo "  !! 没有 /home/lucy/w685_add_birthfd.py ⇒ 停"; exit 1; }
[ "$(md5sum /home/lucy/w685_add_birthfd.py | cut -d' ' -f1)" = "$MD5_BIRTHPY" ] \
    || { echo "  !! 红灯：w685 上传件 md5 不等于 ec71f566 ⇒ 停(别打一份说不出来源的补丁)"; exit 1; }
python3 /home/lucy/w685_add_birthfd.py "$M" || { echo "  !! 红灯：补丁脚本自己退了非 0 ⇒ 停"; exit 1; }
echo "  打完读回：dev_syms=$(md5sum "$DS" | cut -d' ' -f1)  manager=$(md5sum "$SHM" | cut -d' ' -f1)"
echo "  现数：dev_syms 里 KSUBIRTH=$(grep -ac KSUBIRTH "$DS") GFP_ATOMIC=$(grep -ac GFP_ATOMIC "$DS") 参数定义=$(grep -ac 'module_param(ksu_mgr_birth_fd' "$DS") 谓词函数=$(grep -ac 'void ksu_mgr_birth_check(void)' "$DS")"
echo "  现数：manager.c 里 调用点=$(grep -ac 'ksu_mgr_birth_check();' "$SHM") extern=$(grep -ac 'extern void ksu_mgr_birth_check' "$SHM")"
[ "$(grep -ac 'void ksu_mgr_birth_check(void)' "$DS")" = "1" ] || { echo "  !! 红灯：谓词函数不是恰好 1 个 ⇒ 停"; exit 1; }
[ "$(grep -ac 'module_param(ksu_mgr_birth_fd' "$DS")" = "1" ] || { echo "  !! 红灯：模块参数不是恰好 1 个 ⇒ 停"; exit 1; }
[ "$(grep -ac 'ksu_mgr_birth_check();' "$SHM")" = "1" ] || { echo "  !! 红灯：sys_enter 里的调用点不是恰好 1 行 ⇒ 停"; exit 1; }
[ "$(grep -ac 'GFP_ATOMIC' "$DS")" -ge 1 ] || { echo "  !! 红灯：出生即装那条分配不是 GFP_ATOMIC(probe 里睡=非法) ⇒ 停"; exit 1; }
# ★这条是"别在 probe 里睡"的正闸：新增那一段里不许出现 GFP_KERNEL
BN=$(sed -n '/rc74(md 6.413)/,$p' "$DS" | grep -ac 'GFP_KERNEL')
echo "  新增段里 GFP_KERNEL 出现=$BN(必须 0)"
[ "$BN" = "0" ] || { echo "  !! 红灯：新增段里还有 GFP_KERNEL ⇒ 在 preempt-disabled 的 probe 里会睡 ⇒ 停"; exit 1; }
[ "$(grep -c 'if (unlikely(!current->files))' "$DS")" = "1" ] || { echo "  !! 红灯：rc73 那把护栏被动了 ⇒ 停"; exit 1; }

echo; echo "=== 3) 版本/uapi 对齐(与 rc73 逐字相同) ==="
KB="$M/Kbuild"
cp -n "$KB" "$KB.bak_rc60"
OLD='ccflags-y += -DKSU_VERSION=$(KSU_VERSION)'
if grep -q 'KSU_VERSION_OVERRIDE' "$KB"; then
    echo "  Kbuild 已经改过 ⇒ 跳过"
else
    if grep -qF "$OLD" "$KB"; then
        python3 - "$KB" "$OLD" <<'PY'
import io, sys
p, old = sys.argv[1], sys.argv[2]
s = io.open(p, encoding="utf-8", errors="replace").read()
assert s.count(old) == 1, "anchor=%d" % s.count(old)
new = ("ccflags-y += -DKSU_VERSION=$(if $(KSU_VERSION_OVERRIDE),$(KSU_VERSION_OVERRIDE),$(KSU_VERSION))\n"
       "$(info -- RC60 effective KSU_VERSION = $(if $(KSU_VERSION_OVERRIDE),$(KSU_VERSION_OVERRIDE),$(KSU_VERSION)))")
io.open(p, "w", encoding="utf-8", newline="").write(s.replace(old, new))
print("  Kbuild 已改：ccflags 支持 KSU_VERSION_OVERRIDE")
PY
    else
        echo "  !! 找不到 Kbuild 里那行 ccflags ⇒ 停手(别硬编)"; grep -n 'KSU_VERSION' "$KB" | head -5; exit 1
    fi
fi
echo "  Kbuild 回执:"; grep -n 'KSU_VERSION' "$KB" | sed 's/^/    /'

SC="$U/supercall.h"
cp -n "$SC" "$SC.bak_rc60" 2>/dev/null
sed -i "s/^static const __u32 KERNEL_SU_UAPI_VERSION = .*/static const __u32 KERNEL_SU_UAPI_VERSION = $WANT_UAPI;/" "$SC"
echo "  uapi 回执(sed 之后立刻读回来):"; grep -n 'KERNEL_SU_UAPI_VERSION' "$SC" | head -3 | sed 's/^/    /'

echo; echo "=== 4) 全量重编 ==="
cd "$M" || exit 1
find "$M" -name '*.o' -delete
rm -f "$M"/kernelsu.ko 2>/dev/null
make -C "$KDIR" M="$M" src="$M" CONFIG_KSU=m \
  ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
  OBJCOPY=llvm-objcopy STRIP=llvm-strip \
  KCFLAGS="-I/home/lucy/kshim -I$KDIR/security/selinux/include -I$KDIR/security/selinux -include /home/lucy/ksu_compat54.h" \
  KSU_EXPECTED_SIZE2=0x2c1 \
  KSU_EXPECTED_HASH2=11c42292f3cce107eb5499002948c689b19493b47032d4532e29a618395d4063 \
  KSU_VERSION_OVERRIDE="$WANT_VER" \
  modules -j32
echo "RC=$?"
grep -E ' error: ' "$LOG" | sed 's/.* error: /ERR: /' | sort -u | head -12
grep -E 'warning: .*(implicit declaration|control reaches end)' "$LOG" | sed 's/^/WARN: /' | sort -u | head -12
echo "  生效版本回执:"; grep -a 'RC60 effective' "$LOG" | head -2 | sed 's/^/    /'
ls -l "$M"/kernelsu.ko 2>/dev/null || { echo "!! 没产物"; echo "END $(date)"; exit 1; }

echo; echo "=== 5) ★改动 2：rc74 闸门 ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc74.txt
NU=$(wc -l < /tmp/und_rc74.txt)
# ★第一版这里写死了 155(那是 kmod/check_ko.py 的口径：它按"未定义**引用**"另有一套数法)，
#   而本行量的是 llvm-nm 的 U 计数——同一份 rc73 实测就是 158。⇒ 不变量必须**跟 rc73 现比**，不抄别的工具的数(例 163)。
/usr/bin/llvm-nm /home/lucy/kernelsu_rc73.ko | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc73.txt
NU73=$(wc -l < /tmp/und_rc73.txt)
echo "  未定义引用条数 rc74=$NU rc73=$NU73(必须相等，且**两个方向的差都为空**⇒ 装入门径没变)"
[ "$NU" = "$NU73" ] || { echo "  !! 红灯：未定义引用条数与 rc73 不等 ⇒ 这份多要/少要了内核符号，停"; exit 1; }
[ -z "$(comm -13 /tmp/und_rc73.txt /tmp/und_rc74.txt)" ] || { echo "  !! 红灯：rc74 多了未定义符号：$(comm -13 /tmp/und_rc73.txt /tmp/und_rc74.txt | tr '\n' ' ')"; exit 1; }
[ -z "$(comm -23 /tmp/und_rc73.txt /tmp/und_rc74.txt)" ] || { echo "  !! 红灯：rc74 少了未定义符号：$(comm -23 /tmp/und_rc73.txt /tmp/und_rc74.txt | tr '\n' ' ')"; exit 1; }
MISS=0
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || { echo "  未导出: $s"; MISS=$((MISS+1)); }
done < /tmp/und_rc74.txt
echo "  未导出符号数 = $MISS  (必须 0)"
[ "$MISS" = "0" ] || { echo "  !! 红灯：有未导出符号 ⇒ 这个 .ko 装不上"; exit 1; }
STR=/tmp/str_rc74.txt
strings "$M/kernelsu.ko" > "$STR"
NB=$(grep -ac KSUBIRTH "$STR"); NF=$(grep -ac 'KSUFDINST NULLFILES skip' "$STR")
echo "  KSUBIRTH 串数=$NB(必须 >=4)  NULLFILES 串数=$NF(必须 >=1，rc73 那把护栏还在)"
[ "$NB" -ge 4 ] || { echo "  !! 红灯：出生即装那几句证人串没进产物 ⇒ 这份说不出来源"; exit 1; }
[ "$NF" -ge 1 ] || { echo "  !! 红灯：护栏串丢了 ⇒ 这份不是 rc73 的底"; exit 1; }
echo "  参数名在不在：$(grep -ac 'ksu_mgr_birth_fd' "$STR")(必须 >=1)  MODULE_PARM 侧：$(/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -cw ksu_mgr_birth_fd)"
for k in 'RC72 SKIPREAD' 'r72=%d' 'RC71 LOADFIRST' 'SX2 selfexec-pre'; do
    C=$(grep -ac "$k" "$STR"); echo "  旧实验串 [$k]=$C(必须 0)"
    [ "$C" = "0" ] || { echo "  !! 红灯：还留着上一轮实验的形状 ⇒ 不是单变量"; exit 1; }
done
echo "  MGRDOMAIN 串数(必须 2，同 rc67/rc73)=$(grep -ac MGRDOMAIN "$STR")"
[ "$(grep -ac MGRDOMAIN "$STR")" = "2" ] || { echo "  !! 红灯：MGRDOMAIN 不等于 2 ⇒ allowlist 那份底不对"; exit 1; }
echo "  KSUBEAT 串数=$(grep -ac KSUBEAT "$STR")  Crowning=$(grep -ac 'Crowning manager' "$STR")  CAPCLAMP=$(grep -ac CAPCLAMP "$STR")"
echo "  __versions 段：$(/usr/bin/llvm-objdump -h "$M/kernelsu.ko" | awk '$2=="__versions"{print $3}')(rc73/rc74 都是 000027c0＝159 条×64B ⇒ 符号 CRC 表没动)"
PVH=$(/usr/bin/llvm-objdump -h "$M/kernelsu.ko" | awk '$2=="__param"{print $3}')
PV=$((16#$PVH))
echo "  __param 段：$PVH＝$PV B(rc73=000004d8＝1240 B；本发多一个模块参数 ⇒ 应当严格更大)"
[ "$PV" -gt 1240 ] || { echo "  !! 红灯：__param 没长大(实得 $PV) ⇒ 那个 module_param 根本没进产物"; exit 1; }
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc74.ko && md5sum /home/lucy/kernelsu_rc74.ko

echo "  ★符号表对量：rc73 vs rc74(本发**故意**会多几个符号——那是新代码自己的符号)"
/usr/bin/llvm-nm /home/lucy/kernelsu_rc73.ko 2>/dev/null | awk '{print $NF}' | sort -u > /tmp/s73.txt
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '{print $NF}' | sort -u > /tmp/s74.txt
echo "  只在 rc73 有的符号(必须为空)："; comm -23 /tmp/s73.txt /tmp/s74.txt | head -12
[ -z "$(comm -23 /tmp/s73.txt /tmp/s74.txt)" ] || { echo "  !! 红灯：rc73 有的符号在 rc74 里少了 ⇒ 不止加了代码"; exit 1; }
NEW=$(comm -13 /tmp/s73.txt /tmp/s74.txt)
echo "  只在 rc74 有的符号(应当全是 KSUBIRTH 那几件)："
echo "$NEW" | sed '/^$/d;s/^/    /'
NNEW=$(echo "$NEW" | grep -ac .)
echo "  新符号条数=$NNEW"
[ "$NNEW" -ge 1 ] || { echo "  !! 红灯：一个新符号都没有 ⇒ 补丁没进产物(那前面那些 [OK] 都别信)"; exit 1; }
for want in ksu_mgr_birth_check ksu_mgr_birth_fd; do
    echo "$NEW" | grep -qx "$want" || { echo "  !! 红灯：新符号名单里少了 $want"; exit 1; }
done
echo "  段尺寸对量(本发应当只动 .text / .rodata.str1.1 / __param)"
for sec in .text .rodata .rodata.str1.1 .data .bss __param __versions; do
    A=$(/usr/bin/llvm-objdump -h /home/lucy/kernelsu_rc73.ko 2>/dev/null | awk -v s="$sec" '$2==s{print $3}')
    B=$(/usr/bin/llvm-objdump -h "$M/kernelsu.ko" 2>/dev/null | awk -v s="$sec" '$2==s{print $3}')
    echo "    $sec rc73=$A rc74=$B"
    [ -n "$A" ] && [ -n "$B" ] || { echo "  !! 红灯：$sec 没读到尺寸(锚点/列又错了) ⇒ 这条读数不许算比过"; exit 1; }
    case "$sec" in .data|__versions)
        [ "$A" = "$B" ] || { echo "  !! 红灯：$sec 尺寸变了(新代码不该动它)"; exit 1; } ;;
    esac
    case "$sec" in .rodata|.bss)
        SZA=$((16#$A)); SZB=$((16#$B))
        echo "    $sec 差量字节＝$((SZB - SZA))(本发该长的只有：参数名串＋那三个静态量；上限 64B)"
        [ "$SZB" -ge "$SZA" ] && [ "$((SZB - SZA))" -le 64 ] || { echo "  !! 红灯：$sec 增长不在可解释范围(0~64B)"; exit 1; } ;;
    esac
done
# ★.bss 也要"说得出是谁占了这 20 字节"，不能只量尺寸(第一版把 .bss 写成"必须相等"，被自己那三个静态变量打红)。
for s in ksu_birth_pid ksu_birth_start ksu_birth_queued; do
    L=$(/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -a " [Bb] $s\$" | head -1)
    echo "    .bss 里的 $s → [$L]"
    [ -n "$L" ] || { echo "  !! 红灯：$s 不在 .bss ⇒ 那 20 字节解释不了"; exit 1; }
done
# ★".rodata 变了"要说得出是什么变了。两版都被我自己的读法骗过：
#   第一版写成"尺寸必须相等"→被参数名打红；第二版拿 objdump 的行去比→短行的 ASCII 栏会顶进十六进制栏
#   (`000000 00000000     ........` 里 `........` 成了第 4 栏)，把可解释的增长读成"解释不了"。
#   ⇒ 换成比**串集**(strings -a + sort + comm)：加出来的每一条都必须是这次新代码自己的东西，
#     少掉的必须是噪声(短、且不含 % 与 KSU 这种真格式串)。
strings -a -n 4 /home/lucy/kernelsu_rc73.ko | sort > /tmp/str73.txt
strings -a -n 4 "$M/kernelsu.ko" | sort > /tmp/str74.txt
# 认得的来源：新代码自己的串(符号/参数/格式串) ＋ 新 include 带进来的调试文件名与路径。
# 剩下的按"短片段＝字节错位噪声"放过(≤8 字符，如 G&v; / T(%D —— 这类在两次构建里都会飘)；
# 但**不许有格式串消失**：带 % 的串的条数必须只增不减(单靠长度判噪声会把一条真格式串消失掉，这条补上那一格)。
PCT73=$(grep -ac '%' /tmp/str73.txt); PCT74=$(grep -ac '%' /tmp/str74.txt)
echo "  带 % 的串条数 rc73=$PCT73 rc74=$PCT74(必须不减——不减才允许把短片段当噪声放过)"
[ "$PCT74" -ge "$PCT73" ] || { echo "  !! 红灯：格式串条数减少了 ⇒ 有真串消失，停"; exit 1; }
explain() { # $1=差集文件
    awk '/KSUBIRTH|ksu_mgr_birth|ksu_birth|ksu_fd_install_self_tw|^parm=|^parmtype=|^__param|__UNIQUE_ID|manager_identity|\.h$|\.h\b|\/root\/k\/ksu\/kernel/{next}
         { if (length($0)<=8) next; print }' "$1"
}
comm -13 /tmp/str73.txt /tmp/str74.txt > /tmp/add.txt
comm -23 /tmp/str73.txt /tmp/str74.txt > /tmp/del.txt
ADDM=$(explain /tmp/add.txt | wc -l); DELM=$(explain /tmp/del.txt | wc -l)
echo "  串集对表：A=$(wc -l < /tmp/str73.txt) 条 B=$(wc -l < /tmp/str74.txt) 条；新增 $(wc -l < /tmp/add.txt) 条/说不清=$ADDM  消失 $(wc -l < /tmp/del.txt) 条/说不清=$DELM(两个说不清都必须 0)"
echo "  新增里说不清的："; explain /tmp/add.txt | cut -c1-110 | sed 's/^/      /' | head -8
echo "  消失里说不清的："; explain /tmp/del.txt | cut -c1-110 | sed 's/^/      /' | head -8
[ "$ADDM" = "0" ] || { echo "  !! 红灯：产物里多出认不出的串 ⇒ 停"; exit 1; }
[ "$DELM" = "0" ] || { echo "  !! 红灯：rc73 里有的串在 rc74 消失了 ⇒ 不止加了代码，停"; exit 1; }
N73=$(/usr/bin/llvm-nm /home/lucy/kernelsu_rc73.ko | wc -l); N74=$(/usr/bin/llvm-nm "$M/kernelsu.ko" | wc -l)
echo "  符号条数 rc73=$N73 rc74=$N74(本发允许 rc74 多，但不许多到没边——超过 12 个就停下来看)"
[ "$((N74 - N73))" -le 12 ] || { echo "  !! 红灯：符号多了 $((N74 - N73)) 个 ⇒ 不止那一段新代码"; exit 1; }
ls -l /home/lucy/kernelsu_rc73.ko /home/lucy/kernelsu_rc74.ko 2>/dev/null
echo "END $(date)"
