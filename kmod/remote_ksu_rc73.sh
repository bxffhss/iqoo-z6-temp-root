#!/usr/bin/env bash
# rc73 = **rc67 + 一块补丁：dev_syms.c 的 ksu_fd_install_tw_func 开头加 !current->files 护栏(md §6.394)**
#   为什么要这一格：/proc/ksu_install_fd 这个触发口是**我们自己加的**(上游 KSU 不会往别人的任务上排这种活)。
#   它把"给目标装驱动 fd"排成 task_work；而 task_work_add()(kernel/task_work.c:28) 只在"排队那一刻目标
#   已经是 work_exited"时返回 -ESRCH ⇒ **"排队时活着、随后自己退出"这一路拒不掉**。那条回调可能就在目标
#   自己的 do_exit 收尾里跑：kernel/exit.c 的 exit_files(tsk)(:855，它把 tsk->files = NULL，fs/file.c:443)
#   早于 exit_task_work(tsk)(:860)，而 ksu_install_fd() → get_unused_fd_flags()(fs/file.c:545) →
#   __alloc_fd()(fs/file.c:480) 第一行就 spin_lock(&files->file_lock)，**整条链没有 !files 防护** ⇒ 空指针。
#   同一个形状还有一条更快的路：触发口收**任何 pid**，写一个内核线程的 pid 进去，那个线程本来就 files==NULL。
#   现场：第 38 发(10-22 19:5x~20:0x)FDKA 在跑，insmod 后 ≈170 秒整机复位(PMIC_WATCHDOG_S2/USB_CHARGER)；
#   机制在源码层已证成(一手 w530~w537)，**那一发的归因还差一手**(无 pstore、dropbox 对 shell 拒读)⇒ 这发只
#   造"带护栏的 ko"，不宣称证死了 170 秒那一下。
#   判据(开枪前写死)：①护栏那行 pr_err 的 ASCII 串在产物里；②相对 rc67 **只有一个文件变**(见 5 节闸门)；
#   ③上机后：正常 pid 仍出 "KSUFDINST 回调跑在…fd=N"，而**内核线程 pid / 正在退出的 pid** 出
#     "KSUFDINST NULLFILES skip"且不复位(这条要一发认证，见 #168/#170)。
# ★本脚本是 remote_ksu_rc72.sh 的复制＋四处改动(1/2b/2c 与 rc72 逐字相同，不要凭记忆重写 make 行)：
#   改动 1：1 节 cp 的是 /home/lucy/ksu_dev_syms_rc73.c(=远端基线 5b8d8635 ＋唯一护栏，
#           由本地 kmod/w538_add_fdguard.py 生成；两端 md5 已对 e0da5e8c)；
#   改动 2：2d **不打 noread**，allowlist.c 还原到 rc67 快照(3c479222)、syscall_hook.c 还原到 rc67 快照
#           (f30801f0＝/home/lucy/sh_hook_w372.c) ⇒ rc67↔rc73 的差只剩 dev_syms.c 那一处；
#   改动 3：5 节闸门换成 rc73 那套(NULLFILES 串必须>=1；RC72 SKIPREAD/r72=%d/ksu_no_allowlist_read 必须 0；
#           MGRDOMAIN 串必须=2(它来自 allowlist.c 那份快照)；符号表 rc67↔rc73 **双向**都空)；
#   改动 4：★仓库里那份 kmod/ksu_dev_syms.c 曾是**多 49 行废弃 rc64 mgrdomain 草稿**的旧件(真实现后来搬进
#           policy/allowlist.c)⇒ 基线一律取自构建机，不再手改仓库件；仓库那份已改名
#           kmod/ksu_dev_syms_stale_rc64draft.c，kmod/ksu_dev_syms.c 现在逐字节＝远端基线 5b8d8635。
LOG=/home/lucy/ksu_rc73.log
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
AL="$M/policy/allowlist.c"
SH="$M/hook/arm64/syscall_hook.c"
DS="$M/infra/dev_syms.c"
echo "START(rc73) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"

echo "=== 1) ★改动 1：装 rc73 那份 dev_syms.c(cp 前后各核一次 md5) ==="
[ -f /home/lucy/ksu_dev_syms_rc73.c ] || { echo "  !! 没有 /home/lucy/ksu_dev_syms_rc73.c ⇒ 停"; exit 1; }
[ "$(md5sum /home/lucy/ksu_dev_syms_rc73.c | cut -d' ' -f1)" = "$MD5_DEVSYMS_RC73" ] \
    || { echo "  !! 红灯：上传件 md5 不等于 e0da5e8c(不是那份 基线+单护栏) ⇒ 停"; exit 1; }
cp /home/lucy/ksu_dev_syms_rc73.c "$DS" && echo "  dev_syms.c 行数=$(wc -l < "$DS") 字节=$(wc -c < "$DS")"
[ "$(md5sum "$DS" | cut -d' ' -f1)" = "$MD5_DEVSYMS_RC73" ] || { echo "  !! 红灯：cp 之后不等于那份 ⇒ 停"; exit 1; }
echo "  结构自检：护栏=$(grep -c 'if (unlikely(!current->files))' "$DS")(必须 1) NULLFILES 串=$(grep -c 'KSUFDINST NULLFILES skip' "$DS")(必须 1) 旧裸调=$(grep -c 'int nfd = ksu_install_fd();' "$DS")(必须 0)"
[ "$(grep -c 'if (unlikely(!current->files))' "$DS")" = "1" ] || { echo "  !! 红灯：护栏不在或重复 ⇒ 停"; exit 1; }
[ "$(grep -c 'KSUFDINST NULLFILES skip' "$DS")" = "1" ] || { echo "  !! 红灯：ASCII 证人串不在或重复 ⇒ 停"; exit 1; }
[ "$(grep -c 'int nfd = ksu_install_fd();' "$DS")" = "0" ] || { echo "  !! 红灯：旧裸调形状还在 ⇒ 停"; exit 1; }
echo "  对照：那份里 mgrdomain=$(grep -c 'ksu_mgrdomain' "$DS")(必须 0——真实现在 allowlist.c，仓库旧草稿那份不许上树)"

echo; echo "=== 2) 幂等补丁(与 rc72 逐字相同；注意：sucompat.c 马上会被 2c 整份还原覆盖掉) ==="
for f in diag4 sucompat_gates escape_steps decline killscan unlimit visible fdinstall setprof_gate sucompat_steps ksudpath sucompat_gates2 ksudpath2 tracequiet statprobe_steps capclamp; do
    cp "/home/lucy/patch_ksu_$f.py" "/home/lucy/p_$f.py" 2>/dev/null && python3 "/home/lucy/p_$f.py" "$M" || echo "  !! patch_ksu_$f.py 没跑成"
done

echo; echo "=== 2b) selinux.c 还原 pristine 后**照打域回退补丁**(=rc67 的样子；与 rc72 逐字相同) ==="
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

echo; echo "=== 2c) sucompat.c 还原成 rc67 快照，**不打 selfexec** ⇒ 这份的底就是 rc67(与 rc72 逐字相同) ==="
SUC="$M/feature/sucompat.c"
RC67_C=/home/lucy/w343_sucompat_rc67.c
MD5_RC67=e8e53b7bd153aa3d54bf72b5ee294b3e
[ -f "$RC67_C" ] || { echo "  !! 没有 rc67 快照 $RC67_C ⇒ 停(宁可不出货，不出说不出来源的货)"; exit 1; }
[ "$(md5sum "$RC67_C" | cut -d' ' -f1)" = "$MD5_RC67" ] || { echo "  !! rc67 快照本身 md5 不对 ⇒ 停"; exit 1; }
cp "$RC67_C" "$SUC" && echo "  已还原 sucompat.c 到 rc67：$(md5sum "$SUC" | cut -d' ' -f1) 字节=$(wc -c < "$SUC")"
[ "$(md5sum "$SUC" | cut -d' ' -f1)" = "$MD5_RC67" ] || { echo "  !! 红灯：还原后的 sucompat.c md5 不等于 rc67 快照 ⇒ 停"; exit 1; }

echo; echo "=== 2d) ★改动 2：allowlist.c 与 syscall_hook.c **都还原成 rc67 快照，一块补丁都不打** ==="
RC67_A=/home/lucy/allowlist_rc67.c
[ -f "$RC67_A" ] || { echo "  !! 没有 rc67 的 allowlist.c 快照 ⇒ 停"; exit 1; }
echo "  打之前：allow=$(md5sum "$AL" | cut -d' ' -f1)  hook=$(md5sum "$SH" | cut -d' ' -f1)"
cp "$RC67_A" "$AL" && echo "  已把 allowlist.c 还原成 rc67：$(md5sum "$AL" | cut -d' ' -f1)"
[ "$(md5sum "$AL" | cut -d' ' -f1)" = "$MD5_ALLOW_RC67" ] || { echo "  !! 红灯：还原后不等于 rc67 快照 ⇒ 停"; exit 1; }
cp /home/lucy/sh_hook_w372.c "$SH" && echo "  已把 syscall_hook.c 还原成 rc67：$(md5sum "$SH" | cut -d' ' -f1)"
[ "$(md5sum "$SH" | cut -d' ' -f1)" = "$MD5_HOOK_RC67" ] || { echo "  !! 红灯：hook 不是 f30801f0(rc67 那份) ⇒ 停"; exit 1; }
echo "  反夹具式复核：allow 里 noread=$(grep -c 'ksu_no_allowlist_read' "$AL")(必须 0) mgrdomain=$(grep -c 'mgrdomain' "$AL")(必须 >=1，MGRDOMAIN 串的来源)  hook 里 r72=$(grep -c 'r72=%d' "$SH")(必须 0)"
[ "$(grep -c 'ksu_no_allowlist_read' "$AL")" = "0" ] || { echo "  !! 红灯：allowlist 还带着 rc72 的 noread ⇒ 不是单变量"; exit 1; }
[ "$(grep -c 'mgrdomain' "$AL")" -ge 1 ] || { echo "  !! 红灯：allowlist 里没有 mgrdomain ⇒ 这份底不是 rc67 那份"; exit 1; }
[ "$(grep -c 'r72=%d' "$SH")" = "0" ] || { echo "  !! 红灯：hook 还带着 rc72 的正对照行 ⇒ 不是单变量"; exit 1; }

echo; echo "=== 3) 版本/uapi 对齐(与 rc72 逐字相同) ==="
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
echo "  生效版本回执:"; grep -a 'RC60 effective' "$LOG" | head -2 | sed 's/^/    /'
ls -l "$M"/kernelsu.ko 2>/dev/null || { echo "!! 没产物"; echo "END $(date)"; exit 1; }

echo; echo "=== 5) ★改动 3：rc73 闸门(相对 rc67 只许 dev_syms.c 一处变) ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc73.txt
echo "U 总数 $(wc -l < /tmp/und_rc73.txt)"
MISS=0
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || { echo "  未导出: $s"; MISS=$((MISS+1)); }
done < /tmp/und_rc73.txt
echo "未导出符号数 = $MISS  (必须 0)"
[ "$MISS" = "0" ] || { echo "  !! 红灯：有未导出符号 ⇒ 这个 .ko 装不上"; exit 1; }
NUL=$(strings "$M/kernelsu.ko" | grep -c 'KSUFDINST NULLFILES skip')
echo "  护栏证人串 'KSUFDINST NULLFILES skip'(必须 >=1): $NUL"
[ "$NUL" -ge 1 ] || { echo "  !! 红灯：护栏根本没进产物 ⇒ 这一份说不出来源"; exit 1; }
echo "  KSUFDINST 串总数(与 rc67 同为 8，护栏那句另加): $(strings "$M/kernelsu.ko" | grep -ac KSUFDINST)"
echo "  RC72 SKIPREAD 串(必须 0): $(strings "$M/kernelsu.ko" | grep -c 'RC72 SKIPREAD')"
[ "$(strings "$M/kernelsu.ko" | grep -c 'RC72 SKIPREAD')" = "0" ] || { echo "  !! 红灯：产物里还有 rc72 的 noread 块 ⇒ 不是单变量"; exit 1; }
echo "  r72=%d 正对照串(必须 0): $(strings "$M/kernelsu.ko" | grep -c 'r72=%d')"
[ "$(strings "$M/kernelsu.ko" | grep -c 'r72=%d')" = "0" ] || { echo "  !! 红灯：hook 还是 rc72 那份 ⇒ 不是单变量"; exit 1; }
echo "  ksu_no_allowlist_read 符号(必须 0): $(/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -cw ksu_no_allowlist_read)"
[ "$(/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -cw ksu_no_allowlist_read)" = "0" ] || { echo "  !! 红灯：allowlist 还是 rc72 那份 ⇒ 不是单变量"; exit 1; }
echo "  RC71 LOADFIRST 串(必须 0): $(strings "$M/kernelsu.ko" | grep -c 'RC71 LOADFIRST')"
[ "$(strings "$M/kernelsu.ko" | grep -c 'RC71 LOADFIRST')" = "0" ] || { echo "  !! 红灯：还留着 loadfirst"; exit 1; }
echo "  MGRDOMAIN 串(必须 2，同 rc67): $(strings "$M/kernelsu.ko" | grep -c 'MGRDOMAIN')"
[ "$(strings "$M/kernelsu.ko" | grep -c 'MGRDOMAIN')" = "2" ] || { echo "  !! 红灯：MGRDOMAIN 串数不等于 rc67 的 2 ⇒ allowlist 那份底不对"; exit 1; }
echo "  dev_syms 那份的 mgrdomain 符号(必须 0，防仓库旧草稿那份混进来): $(/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -c 'ksu_mgrdomain_fops\|ksu_mgrdomain_write\|ksu_mgrdomain_pe')"
SX2N=$(strings "$M/kernelsu.ko" | grep -c "KSUBEAT SX2 selfexec-pre")
[ "$SX2N" = "0" ] || { echo "  !! 红灯：SX2 串数=$SX2N(这份 rc67 底应当 0) ⇒ 这份混进了 selfexec"; exit 1; }
UNDUP=$(grep -c 'if (ksu_stat_off)' "$M/feature/sucompat.c")
[ "$UNDUP" = "12" ] || { echo "  !! 红灯：ksu_stat_off 闸=$UNDUP 份(还原成 rc67 应当 12)"; exit 1; }
echo "  红灯闸：未导出=0 ✓  NULLFILES>=1 ✓  RC72=0 ✓  r72==0 ✓  noread 符号=0 ✓  RC71=0 ✓  MGRDOMAIN=2 ✓  SX2=0 ✓  ksu_stat_off=12 ✓"
strings "$M/kernelsu.ko" | grep -c 'KSUBEAT' | sed 's/^/KSUBEAT 串数: /'
strings "$M/kernelsu.ko" | grep -c "Crowning manager" | sed 's/^/Crowning 串数(必须 1): /'
strings "$M/kernelsu.ko" | grep -c "CAPCLAMP" | sed 's/^/CAPCLAMP 串数(必须 >0): /'
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc73.ko && md5sum /home/lucy/kernelsu_rc73.ko
echo "★符号表对量(唯一变量的证法)：rc67 vs rc73，**两个方向都必须为空**(护栏只加一条分支，不引入新符号)"
/usr/bin/llvm-nm /home/lucy/kernelsu_rc67.ko 2>/dev/null | awk '{print $NF}' | sort -u > /tmp/s67.txt
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '{print $NF}' | sort -u > /tmp/s73.txt
echo "  只在 rc73 有的符号(必须为空):"; comm -13 /tmp/s67.txt /tmp/s73.txt | head -12
echo "  只在 rc67 有的符号(必须为空):"; comm -23 /tmp/s67.txt /tmp/s73.txt | head -12
echo "  段尺寸对量(护栏应当只动 .text 与 .rodata.str1.1)"
echo "    ★第一版这里取错列(把 \$4=vma 当 size)⇒ 四行全打印 0，看着像比过了其实什么都没比(#197)。现值取 \$3。"
echo "    ★本发实测一手(rc73 已编好)：.text 00012cb0→00012cd0(+32B＝一条判空分支)，"
echo "      .rodata.str1.1 00007aaa→00007b30(+134B＝护栏那句 ASCII)，其余段尺寸逐字节相同，符号条数 837=837。"
for sec in .text .rodata .rodata.str1.1 .data .bss; do
    A=$(/usr/bin/llvm-objdump -h /home/lucy/kernelsu_rc67.ko 2>/dev/null | awk -v s="$sec" '$2==s{print $3}')
    B=$(/usr/bin/llvm-objdump -h "$M/kernelsu.ko" 2>/dev/null | awk -v s="$sec" '$2==s{print $3}')
    echo "    $sec rc67=$A rc73=$B"
    [ -n "$A" ] && [ -n "$B" ] || { echo "  !! 红灯：$sec 没读到尺寸(锚点/列又错了) ⇒ 这条读数不许算比过"; exit 1; }
    case "$sec" in .data|.bss|.rodata)
        [ "$A" = "$B" ] || { echo "  !! 红灯：$sec 应当逐字节同尺寸却变了"; exit 1; } ;;
    esac
done
N67=$(/usr/bin/llvm-nm /home/lucy/kernelsu_rc67.ko | wc -l); N73=$(/usr/bin/llvm-nm "$M/kernelsu.ko" | wc -l)
echo "  符号条数 rc67=$N67 rc73=$N73 (必须相等——护栏只加一条分支，不引入新符号)"
[ "$N67" = "$N73" ] || { echo "  !! 红灯：符号条数变了 ⇒ 这份不止改了那处"; exit 1; }
ls -l /home/lucy/kernelsu_rc67.ko /home/lucy/kernelsu_rc73.ko 2>/dev/null
echo "END $(date)"
