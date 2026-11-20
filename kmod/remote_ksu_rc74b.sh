#!/usr/bin/env bash
# rc74b = **rc73 + 那块「Manager 出生即装驱动 fd」的修正版(§6.413 编、§6.414 第 50 发判正并抓到缺陷、本节就是修法)**
#   第 50 发已经把机制判正了(一手)：`am force-stop` 之后**只用 `am start`**(不写触发口／不跑恢复腿／不发深链)
#   ⇒ 官方 Manager 首页自己回 `工作中／版本：32601-2／越狱`；内核三件套同 pid 时刻递增。
#   ★但同一发也抓到两处缺陷，所以那一支 ko 不许升默认(默认仍是 rc73 `34b3efa8`)：
#     ①**去重形同虚设**——rc74 用**单槽** `ksu_birth_pid/ksu_birth_start`，而 Manager 一家子(主进程＋它 fork 的
#       `sh`/`id`/`libksud.so`，uid 都是 10104)在同 10 秒里交替开火 ⇒ 彼此顶穿同一个槽
#       ⇒ 一手：`seen/queued/=> fd=` 各 149，同一个 `pid=13318 comm=[sh]` 三次入队，
#         主进程表里 `ksu_driver` 从 14 条涨到 **75** 条 = **驱动 fd 泄漏**；
#     ②**谓词过宽**——`group_leader ∧ is_uid_manager` 把 Manager 自己 fork 的子进程也放进来，
#       而牌子只认主进程(§6.406/§6.414)；子进程在 rc73 的形状里根本没有驱动 fd。
#   ⇒ 这一版(补丁件 `kmod/w689_add_birthfd2.py`)：环状去重 `ksu_birth_ring[16]`((pid,start_time) 双键)
#     ＋只认主进程(`real_parent` 同 uid ⇒ 是 Manager 自己 fork 的 ⇒ 不排)＋每 boot 硬上限 `ksu_mgr_birth_cap=64`
#     ＋分配失败把占掉的槽回滚(`ksu_birth_forget`，免得那个进程被永久拉黑)。
#     热路径上**挡住的分支不打印**(§6.118：console 洪印把机器拖死过一次)，只留 `dupskip/childskip` 每 256 次一条计数证人。
#   ★三条红线(与 rc74 同)：①probe 在 preempt-disabled 下跑 ⇒ 只许 GFP_ATOMIC；②新增未定义符号必须逐条指认且都在 Module.symvers_dev 里
#       (环需要自旋锁；一手实测：`_raw_spin_lock_irqsave/restore` **rc73 本来就引用了** ⇒ U 计数 158=158、
#       `__versions` 都 159 条 000027c0 ⇒ 装入门径逐字同 rc73；闸允许"多"这两条，也接受实测的 0 增量)；
#     ③`!current->files` 护栏必须还在。ksu_args.txt 依旧一字不改(两个新参数默认值就是 rc74b 的形状)。
#   ★判定函数写成**纯函数**并用 BEGIN/END KSUBIRTH-PURE 圈起来 ⇒ 第 2f 节先把那段原文抠到宿主上用 gcc 跑真值表
#     (`kmod/w691_birth_test.py`，25 格＋一条负对照：同一负载喂 rc74 的单槽逻辑必须洪排 400 次)；跑不过不编 ko。
#   ★降 hook printk 仍不混进这一发(那是 rc75 那一格)。
# ★本脚本是 remote_ksu_rc74.sh 的复制＋三处改动(1/2/2b/2c/2d/3/4 与 rc74/rc73 逐字相同，别凭记忆重写 make 行)：
#   改动 1：2e 节打的是 w689(rc74b)那份补丁，并加一条"rc74 那三个单槽变量必须已消失"的反夹具；
#   改动 2：新增 2f 节——逻辑真值表当构建前置闸；
#   改动 3：5 节闸门换成 rc74b 那套(七条 KSUBIRTH 证人串逐条点名／新符号只能来自那份新代码／产物里必须查得到
#           ksu_birth_ring 而 rc74 的单槽符号必须查不到／未定义引用只许多那两条自旋锁且必须已导出)。
LOG=/home/lucy/ksu_rc74b.log
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
MD5_BIRTHPY=8d01f1daad9bfdcc61cdfebe6d9cc25f       # 本地 kmod/w689_add_birthfd2.py 上传件(rc74b 的补丁件)
MD5_TESTPY=0142b3cd32acf33f482b3e18333f17c3        # 本地 kmod/w691_birth_test.py(把纯判定函数抠到宿主上跑真值表)
AL="$M/policy/allowlist.c"
SH="$M/hook/arm64/syscall_hook.c"
DS="$M/infra/dev_syms.c"
SHM="$M/hook/syscall_hook_manager.c"
echo "START(rc74b) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"

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

echo; echo "=== 2e) ★改动 1：打 rc74b 的补丁(先去重环+只认主进程；先核上传件 md5，再打，再现数) ==="
[ -f /home/lucy/w689_add_birthfd2.py ] || { echo "  !! 没有 /home/lucy/w689_add_birthfd2.py ⇒ 停"; exit 1; }
[ "$(md5sum /home/lucy/w689_add_birthfd2.py | cut -d' ' -f1)" = "$MD5_BIRTHPY" ] \
    || { echo "  !! 红灯：w689 上传件 md5 不等于 8d01f1da ⇒ 停(别打一份说不出来源的补丁)"; exit 1; }
python3 /home/lucy/w689_add_birthfd2.py "$M" || { echo "  !! 红灯：补丁脚本自己退了非 0 ⇒ 停"; exit 1; }
echo "  打完读回：dev_syms=$(md5sum "$DS" | cut -d' ' -f1)  manager=$(md5sum "$SHM" | cut -d' ' -f1)"
echo "  现数：PURE 标记=$(grep -ac 'BEGIN KSUBIRTH-PURE' "$DS") KSUBIRTH=$(grep -ac KSUBIRTH "$DS") GFP_ATOMIC=$(grep -ac GFP_ATOMIC "$DS") 参数定义=$(grep -ac 'module_param(ksu_mgr_birth' "$DS")(rc74b 应有 fd+cap 两个) 谓词函数=$(grep -ac 'void ksu_mgr_birth_check(void)' "$DS")"
echo "  现数：manager.c 里 调用点=$(grep -ac 'ksu_mgr_birth_check();' "$SHM") extern=$(grep -ac 'extern void ksu_mgr_birth_check' "$SHM")"
[ "$(grep -ac 'BEGIN KSUBIRTH-PURE' "$DS")" = "1" ] || { echo "  !! 红灯：纯函数标记不是恰好 1 对 ⇒ 宿主测试抠不出原文，停"; exit 1; }
[ "$(grep -ac 'void ksu_mgr_birth_check(void)' "$DS")" = "1" ] || { echo "  !! 红灯：谓词函数不是恰好 1 个 ⇒ 停"; exit 1; }
[ "$(grep -ac 'module_param(ksu_mgr_birth' "$DS")" = "2" ] || { echo "  !! 红灯：模块参数不是 fd+cap 两个 ⇒ 停"; exit 1; }
[ "$(grep -ac 'ksu_mgr_birth_check();' "$SHM")" = "1" ] || { echo "  !! 红灯：sys_enter 里的调用点不是恰好 1 行 ⇒ 停"; exit 1; }
[ "$(grep -ac 'GFP_ATOMIC' "$DS")" -ge 1 ] || { echo "  !! 红灯：出生即装那条分配不是 GFP_ATOMIC(probe 里睡=非法) ⇒ 停"; exit 1; }
# ★这条是"别在 probe 里睡"的正闸：新增那一段里不许出现 GFP_KERNEL(锚＝rc74b 那段头)
BN=$(sed -n '/rc74b(md 6.414\/6.415)/,$p' "$DS" | grep -ac 'GFP_KERNEL')
echo "  新增段里 GFP_KERNEL 出现=$BN(必须 0；底里 line1978 那处合法 GFP_KERNEL 在锚点之前，不该被算进来)"
[ "$BN" = "0" ] || { echo "  !! 红灯：新增段里还有 GFP_KERNEL ⇒ 在 preempt-disabled 的 probe 里会睡 ⇒ 停"; exit 1; }
[ "$(grep -c 'if (unlikely(!current->files))' "$DS")" = "1" ] || { echo "  !! 红灯：rc73 那把护栏被动了 ⇒ 停"; exit 1; }
# ★rc74 那三个单槽变量必须**已经不在**——否则这份就是 rc74 而不是 rc74b(第 50 发那处泄漏的原形状)
for s in ksu_birth_pid ksu_birth_start ksu_birth_queued; do
    C=$(grep -ac "$s" "$DS"); echo "  rc74 的单槽变量 [$s] 还剩 $C 处(必须 0)"
    [ "$C" = "0" ] || { echo "  !! 红灯：$s 还在 ⇒ 这份是 rc74(单槽去重)，停"; exit 1; }
done

echo; echo "=== 2f) ★改动 2：把纯判定函数抠到宿主上跑真值表(编 ko 之前，跑不过就别浪费时间编) ==="
[ -f /home/lucy/w691_birth_test.py ] || { echo "  !! 没有 /home/lucy/w691_birth_test.py ⇒ 停"; exit 1; }
[ "$(md5sum /home/lucy/w691_birth_test.py | cut -d' ' -f1)" = "$MD5_TESTPY" ] \
    || { echo "  !! 红灯：w691 上传件 md5 不等于 0142b3cd ⇒ 停"; exit 1; }
python3 /home/lucy/w691_birth_test.py "$DS"; TRC=$?
echo "  逻辑测试 RC=$TRC(必须 0)"
[ "$TRC" = "0" ] || { echo "  !! 红灯：判定函数没通过真值表 ⇒ 不编 ko，先修函数"; exit 1; }

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

echo; echo "=== 5) ★改动 3：rc74b 闸门 ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc74b.txt
NU=$(wc -l < /tmp/und_rc74b.txt)
# ★第一版这里写死了 155(那是 kmod/check_ko.py 的口径)，而本行量的是 llvm-nm 的 U 计数(同一份 rc73 实测 158)。
#   rc74 那发的闸是"与 rc73 相等且双向差都为空"。rc74b **故意**不再相等：环要自旋锁 ⇒ 多要两条内核符号，
#   所以闸改成"只许多名单里那两条，且必须已在 Module.symvers_dev 里导出(下面 MISS 那段真验)"，多一条别的就停。
/usr/bin/llvm-nm /home/lucy/kernelsu_rc73.ko | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc73.txt
NU73=$(wc -l < /tmp/und_rc73.txt)
echo "  未定义引用条数 rc74b=$NU rc73=$NU73(允许 rc74b 多，但只能多这两条：_raw_spin_lock_irqsave / _raw_spin_unlock_irqrestore)"
ADDU=$(comm -13 /tmp/und_rc73.txt /tmp/und_rc74b.txt)
DELU=$(comm -23 /tmp/und_rc73.txt /tmp/und_rc74b.txt)
echo "  rc74b 比 rc73 多了：[$(echo "$ADDU" | tr '\n' ' ')]"
[ -z "$DELU" ] || { echo "  !! 红灯：rc74b 少了 rc73 原本要的符号(不该减)：$(echo "$DELU" | tr '\n' ' ')"; exit 1; }
for s in $ADDU; do
    case "$s" in
      _raw_spin_lock_irqsave|_raw_spin_unlock_irqrestore) echo "    [$s] 在允许名单里(环状去重要自旋锁)" ;;
      *) echo "  !! 红灯：多出来一条认不出的未定义符号 [$s] ⇒ 停"; exit 1 ;;
    esac
done
MISS=0
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || { echo "  未导出: $s"; MISS=$((MISS+1)); }
done < /tmp/und_rc74b.txt
echo "  未导出符号数 = $MISS  (必须 0——这一条才是真·装得上)"
[ "$MISS" = "0" ] || { echo "  !! 红灯：有未导出符号 ⇒ 这个 .ko 装不上"; exit 1; }
NADD=$(echo "$ADDU" | grep -ac .)
V73=$(/usr/bin/llvm-objdump -h /home/lucy/kernelsu_rc73.ko | awk '$2=="__versions"{print $3}')
V73N=$((16#$V73)); V73C=$((V73N / 64))
V7B=$(/usr/bin/llvm-objdump -h "$M/kernelsu.ko" | awk '$2=="__versions"{print $3}')
V7BN=$((16#$V7B)); V7BC=$((V7BN / 64))
echo "  __versions 段：rc73=$V73($V73C 条) rc74b=$V7B($V7BC 条) ⇒ CRC 条目应当**只**多 $NADD 条(每引用一个内核符号一条×64B)"
[ "$((V7BC - V73C))" = "$NADD" ] || { echo "  !! 红灯：CRC 条目增量($((V7BC - V73C))) 与未定义符号增量($NADD)对不上 ⇒ 说不清是谁多了，停"; exit 1; }
STR=/tmp/str_rc74b.txt
strings "$M/kernelsu.ko" > "$STR"
NB=$(grep -ac KSUBIRTH "$STR"); NF=$(grep -ac 'KSUFDINST NULLFILES skip' "$STR")
# ★期望值**从源码现数**，不是我拍的：第一版这里写 `>=9`(那是 dev_syms.c 里 KSUBIRTH 这个 token 的出现次数，
#   含注释与横幅)，产物里真格式串是 7 条 ⇒ 一份完全正确的 ko 被我判红(例 173④第三次重犯，这次栽在"数哪个东西"上)。
EXPF=$(grep -acE 'pr_(info|err)\("KSUBIRTH' "$DS")
echo "  KSUBIRTH 证人串：源码里 pr_*(\"KSUBIRTH…\")=$EXPF 条，产物里=$NB 条(必须**相等**，两边都现数)"
[ "$EXPF" -ge 5 ] || { echo "  !! 红灯：源码里数出的证人串少到不像话($EXPF) ⇒ 抽取/锚点又错了，这条不算比过"; exit 1; }
[ "$NB" = "$EXPF" ] || { echo "  !! 红灯：产物里的 KSUBIRTH 串数与源码不符(源 $EXPF／产物 $NB) ⇒ 停"; exit 1; }
echo "  NULLFILES 串数=$NF(必须 >=1，rc73 那把护栏还在)"
[ "$NF" -ge 1 ] || { echo "  !! 红灯：护栏串丢了 ⇒ 这份不是 rc73 的底"; exit 1; }
# ★逐条点名(第 50 发那三处修法各自都要有产物证人，不能只数总数——总数是 rc74 也会过的弱闸)
for t in 'KSUBIRTH seen Manager' 'KSUBIRTH queued self fd' 'KSUBIRTH dupskip n=' 'KSUBIRTH childskip n=' 'KSUBIRTH cap total=' 'KSUBIRTH kzalloc(ATOMIC) failed' 'ksu_mgr_birth_cap'; do
    C=$(grep -ac "$t" "$STR"); echo "    证人串 [$t]=$C(必须 >=1)"
    [ "$C" -ge 1 ] || { echo "  !! 红灯：[$t] 没进产物 ⇒ 那一处修法没落地，这份不是 rc74b"; exit 1; }
done
echo "  ★反夹具(同框负对照)：rc74 那份产物里这三条新串应当都是 0 ⇒ 上面那三条才是区分 rc74/rc74b 的牙"
for t in 'KSUBIRTH dupskip n=' 'KSUBIRTH childskip n=' 'KSUBIRTH cap total='; do
    echo "    rc74.ko 里 [$t]=$(strings /home/lucy/kernelsu_rc74.ko 2>/dev/null | grep -ac "$t")(应 0)"
done
for k in 'RC72 SKIPREAD' 'r72=%d' 'RC71 LOADFIRST' 'SX2 selfexec-pre'; do
    C=$(grep -ac "$k" "$STR"); echo "  旧实验串 [$k]=$C(必须 0)"
    [ "$C" = "0" ] || { echo "  !! 红灯：还留着上一轮实验的形状 ⇒ 不是单变量"; exit 1; }
done
echo "  MGRDOMAIN 串数(必须 2，同 rc67/rc73)=$(grep -ac MGRDOMAIN "$STR")"
[ "$(grep -ac MGRDOMAIN "$STR")" = "2" ] || { echo "  !! 红灯：MGRDOMAIN 不等于 2 ⇒ allowlist 那份底不对"; exit 1; }
echo "  KSUBEAT 串数=$(grep -ac KSUBEAT "$STR")  Crowning=$(grep -ac 'Crowning manager' "$STR")  CAPCLAMP=$(grep -ac CAPCLAMP "$STR")"
PVH=$(/usr/bin/llvm-objdump -h "$M/kernelsu.ko" | awk '$2=="__param"{print $3}')
PV=$((16#$PVH))
echo "  __param 段：$PVH＝$PV B(rc73=1240 B＝5 条参数；本发多 fd＋cap 两个参数 ⇒ 应当严格更大)"
[ "$PV" -gt 1240 ] || { echo "  !! 红灯：__param 没长大(实得 $PV) ⇒ 那两个 module_param 根本没进产物"; exit 1; }
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc74b.ko && md5sum /home/lucy/kernelsu_rc74b.ko

echo "  ★符号表对量：rc73 vs rc74b(本发**故意**会多几个符号——那是新代码自己的符号)"
/usr/bin/llvm-nm /home/lucy/kernelsu_rc73.ko 2>/dev/null | awk '{print $NF}' | sort -u > /tmp/s73.txt
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '{print $NF}' | sort -u > /tmp/s74b.txt
echo "  只在 rc73 有的符号(必须为空)："; comm -23 /tmp/s73.txt /tmp/s74b.txt | head -12
[ -z "$(comm -23 /tmp/s73.txt /tmp/s74b.txt)" ] || { echo "  !! 红灯：rc73 有的符号在 rc74b 里少了 ⇒ 不止加了代码"; exit 1; }
NEW=$(comm -13 /tmp/s73.txt /tmp/s74b.txt)
echo "  只在 rc74b 有的符号(应当**全部**是出生即装那件东西自己的)："
echo "$NEW" | sed '/^$/d;s/^/    /'
NNEW=$(echo "$NEW" | grep -ac .)
echo "  新符号条数=$NNEW"
[ "$NNEW" -ge 1 ] || { echo "  !! 红灯：一个新符号都没有 ⇒ 补丁没进产物(那前面那些 [OK] 都别信)"; exit 1; }
STRAY=$(echo "$NEW" | grep -avE '^(ksu_birth|ksu_mgr_birth|ksu_fd_install_self_tw|__param_.*birth|__param_str_.*birth|__UNIQUE_ID_.*birth)' | grep -ac .)
echo "  认不出来源的新符号条数=$STRAY(必须 0)"
[ "$STRAY" = "0" ] || { echo "  !! 红灯：新符号里有对不上这份新代码的东西：$(echo "$NEW" | grep -avE '^(ksu_birth|ksu_mgr_birth|ksu_fd_install_self_tw|__param_.*birth|__param_str_.*birth|__UNIQUE_ID_.*birth)' | tr '\n' ' ')"; exit 1; }
for want in ksu_mgr_birth_check ksu_mgr_birth_fd ksu_mgr_birth_cap ksu_birth_ring ksu_fd_install_self_tw; do
    echo "$NEW" | grep -qx "$want" || { echo "  !! 红灯：新符号名单里少了 $want ⇒ 那一处修法没落地"; exit 1; }
done
for gone in ksu_birth_pid ksu_birth_start ksu_birth_queued; do
    C=$(/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -cw "$gone"); echo "    rc74 的单槽符号 [$gone] 在产物里=$C(必须 0——不然这份就是 rc74)"
    [ "$C" = "0" ] || { echo "  !! 红灯：$gone 还在 ⇒ 这份是 rc74(单槽去重)，不是 rc74b"; exit 1; }
done
echo "  段尺寸对量(本发应当只动 .text / .rodata.str1.1 / .rodata / .data / .bss / __param；__versions 见上面那条)"
for sec in .text .rodata .rodata.str1.1 .data .bss __param __versions; do
    A=$(/usr/bin/llvm-objdump -h /home/lucy/kernelsu_rc73.ko 2>/dev/null | awk -v s="$sec" '$2==s{print $3}')
    B=$(/usr/bin/llvm-objdump -h "$M/kernelsu.ko" 2>/dev/null | awk -v s="$sec" '$2==s{print $3}')
    echo "    $sec rc73=$A rc74b=$B"
    [ -n "$A" ] && [ -n "$B" ] || { echo "  !! 红灯：$sec 没读到尺寸(锚点/列又错了) ⇒ 这条读数不许算比过"; exit 1; }
    case "$sec" in __versions)
        # ★别写"必须相等"：每引用一个**新的**内核符号就多一条 CRC 记录(64B)，上面已核过 NADD=$NADD 条；
        #   这条闸现在要求差量**恰好**等于 NADD×64，多一条少一条都红(把"应当没动"当成不变量是例 163 那一族)。
        VZA=$((16#$A)); VZB=$((16#$B))
        echo "    __versions 差量字节＝$((VZB - VZA))，期望＝NADD($NADD)×64＝$((NADD * 64))"
        [ "$((VZB - VZA))" = "$((NADD * 64))" ] || { echo "  !! 红灯：CRC 表差量与新增引用条数对不上 ⇒ 停"; exit 1; } ;;
    esac
    case "$sec" in .rodata|.data|.bss)
        SZA=$((16#$A)); SZB=$((16#$B))
        case "$sec" in
          .bss)  LIM=512; WHY="环 16×16B＋两个计数＋自旋锁＋ring_nr/total" ;;
          .data) LIM=32;  WHY="两个初始化为非 0 的参数(fd=1／cap=64)；rc74 那版把这条写成必须相等，被自己多出来的 cap 打红过 ⇒ 现在按可解释区间" ;;
          *)     LIM=64;  WHY="两个参数名串＋说明串" ;;
        esac
        echo "    $sec 差量字节＝$((SZB - SZA))(上限 ${LIM}B；该长的只有：${WHY})"
        [ "$SZB" -ge "$SZA" ] && [ "$((SZB - SZA))" -le "$LIM" ] || { echo "  !! 红灯：$sec 增长不在可解释范围(0~${LIM}B)"; exit 1; } ;;
    esac
done
# ★"变了"要说得出**是谁**占的(第 50 发那条规矩：只量尺寸不指认＝没比过)。
for s in ksu_birth_ring ksu_birth_ring_nr ksu_birth_total ksu_birth_dupskip ksu_birth_childskip ksu_mgr_birth_fd ksu_mgr_birth_cap; do
    L=$(/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -a "[BbDd] $s\$" | head -1)
    echo "    占位指认 $s → [$L]"
    [ -n "$L" ] || { echo "  !! 红灯：$s 不在 .bss/.data ⇒ 上面那些字节数解释不了"; exit 1; }
done
# ★".rodata 变了"要说得出是什么变了。两版都被我自己的读法骗过：
#   第一版写成"尺寸必须相等"→被参数名打红；第二版拿 objdump 的行去比→短行的 ASCII 栏会顶进十六进制栏
#   (`000000 00000000     ........` 里 `........` 成了第 4 栏)，把可解释的增长读成"解释不了"。
#   ⇒ 换成比**串集**(strings -a + sort + comm)：加出来的每一条都必须是这次新代码自己的东西，
#     少掉的必须是噪声(短、且不含 % 与 KSU 这种真格式串)。
strings -a -n 4 /home/lucy/kernelsu_rc73.ko | sort > /tmp/str73.txt
strings -a -n 4 "$M/kernelsu.ko" | sort > /tmp/str74b.txt
# 认得的来源：新代码自己的串(符号/参数/格式串) ＋ 新 include 带进来的调试文件名与路径。
# 剩下的按"短片段＝字节错位噪声"放过(≤8 字符，如 G&v; / T(%D —— 这类在两次构建里都会飘)；
# 但**不许有格式串消失**：带 % 的串的条数必须只增不减(单靠长度判噪声会把一条真格式串消失掉，这条补上那一格)。
PCT73=$(grep -ac '%' /tmp/str73.txt); PCT7B=$(grep -ac '%' /tmp/str74b.txt)
echo "  带 % 的串条数 rc73=$PCT73 rc74b=$PCT7B(必须不减——不减才允许把短片段当噪声放过)"
[ "$PCT7B" -ge "$PCT73" ] || { echo "  !! 红灯：格式串条数减少了 ⇒ 有真串消失，停"; exit 1; }
# ★"认得出"的口径(第一版这里被 `is_leader`/`parent_is_mgr` 打红——那是我新函数的**形参名**，
#   因 CONFIG_DEBUG_INFO 进了 DWARF ⇒ 是串的合法来源，但我当时只写了硬编码的模式，没把"这次改的源码"当白名单)。
#   现在：①模式白名单(新代码自己的符号/参数/格式串/头文件名) ②**或**该条是一个裸标识符且在这次改的那两份文件里出现过
#   ③长度 <=8 的短片段按字节错位噪声放过(前提是"带 % 的串只增不减"，上面已闸)。
grep -ohE '[A-Za-z_][A-Za-z0-9_]{3,}' "$DS" "$SHM" | sort -u > /tmp/words.txt
echo "  【输入证人】标识符白名单条数=$(grep -ac . /tmp/words.txt)(来自这次改的 dev_syms.c + syscall_hook_manager.c)"
explain() { # $1=差集文件
    awk 'NR==FNR{w[$0]=1; next}
         /KSUBIRTH|ksu_mgr_birth|ksu_birth|ksu_fd_install_self_tw|spin|lock|^parm=|^parmtype=|^__param|__UNIQUE_ID|manager_identity|\.h$|\.h\b|\/root\/k\/ksu\/kernel/{next}
         { if (length($0)<=8) next;
           if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && ($0 in w)) next;
           print }' /tmp/words.txt "$1"
}
comm -13 /tmp/str73.txt /tmp/str74b.txt > /tmp/add.txt
comm -23 /tmp/str73.txt /tmp/str74b.txt > /tmp/del.txt
echo "  【输入证人】差集文件不是空的：add=$(wc -c < /tmp/add.txt) B  del=$(wc -c < /tmp/del.txt) B(两个都是 0 字节＝抽取器可能炸了，不许算比过)"
[ -s /tmp/add.txt ] || { echo "  !! 红灯：/tmp/add.txt 空 ⇒ 串集对表没有输入，这一条不算比过(例 173④那种空读)"; exit 1; }
ADDM=$(explain /tmp/add.txt | wc -l); DELM=$(explain /tmp/del.txt | wc -l)
echo "  串集对表：A=$(wc -l < /tmp/str73.txt) 条 B=$(wc -l < /tmp/str74b.txt) 条；新增 $(wc -l < /tmp/add.txt) 条/说不清=$ADDM  消失 $(wc -l < /tmp/del.txt) 条/说不清=$DELM(两个说不清都必须 0)"
echo "  新增里说不清的："; explain /tmp/add.txt | cut -c1-110 | sed 's/^/      /' | head -8
echo "  消失里说不清的(必须空——rc74 的单槽串相对 rc73 本来就是新增，没有东西该消失)："; explain /tmp/del.txt | cut -c1-110 | sed 's/^/      /' | head -8
[ "$ADDM" = "0" ] || { echo "  !! 红灯：产物里多出认不出的串 ⇒ 停"; exit 1; }
[ "$DELM" = "0" ] || { echo "  !! 红灯：rc73 里有的串在 rc74b 消失了 ⇒ 不止加了代码，停"; exit 1; }
N73=$(/usr/bin/llvm-nm /home/lucy/kernelsu_rc73.ko | wc -l); N7B=$(/usr/bin/llvm-nm "$M/kernelsu.ko" | wc -l)
echo "  符号条数 rc73=$N73 rc74b=$N7B(差 $((N7B - N73))；rc74b 比 rc74 多的那些是环/锁/计数/新参数——**逐条按名字**认，不靠这条数)"
[ "$((N7B - N73))" -le 32 ] || { echo "  !! 红灯：符号多了 $((N7B - N73)) 个 ⇒ 不止那一段新代码"; exit 1; }
ls -l /home/lucy/kernelsu_rc73.ko /home/lucy/kernelsu_rc74.ko /home/lucy/kernelsu_rc74b.ko 2>/dev/null
echo "END $(date)"
