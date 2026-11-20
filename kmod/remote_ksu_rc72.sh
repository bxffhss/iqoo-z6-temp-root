#!/bin/bash
# rc72 = **rc67 + 一块补丁：allowlist.c 的 ksu_no_allowlist_read（根本不 filp_open/不 kernel_read）**
#        + 同一条补丁在 syscall_hook.c 的高频行里打进参数现值（正对照，§6.280 要求）
#   为什么是这一格(§6.281 / 任务 #109)：130 发(rc71 firstonly)把"循环走第二圈"摘掉却照死，
#     而 firstonly 下 ko 对 1576 字节文件的动作与"健康的 792 字节单条目"逐字节相同
#     ⇒ 剩下唯一能分开 (甲)"我们的访问动作被外部抓到" 与 (乙)"与我们做什么都无关"的格子
#     ＝让 ko **完全不打开这个文件**，磁盘那份与 129/130 逐字节相同。
#   判据(开枪前写死)：活过 +30 分钟 ⇒ (甲)；仍在 +16~30 秒 ⇒ (乙)；别的时刻 ⇒ 不下结论。
# ★这份脚本是 remote_ksu_rc71.sh 的**逐字复制 + 三处改动**（1/2/3 节与 rc71 一致，不要凭记忆重写 make 行）：
#   改动 1：2d 先把 allowlist.c **还原成 rc67 那份**（补丁器自己有红灯：带 RC71 LOADFIRST 的底不许打），
#           还原用的文件是本地 pull 下来的 `allowlist_w369.c`(md5 3c479222…)，put 成 /home/lucy/allowlist_rc67.c；
#   改动 2：2d 打的是 patch_ksu_noread.py（两个文件一起打），并把**两份源码 md5 与离线 dry-run 预测值对表**
#           （离线 selftest 六格全过后打印：allow=f24f44a8… hook=5ac10253…）；
#   改动 3：5 节的闸门换成 rc72 那套：**RC72 串数>=1、符号 ksu_no_allowlist_read 在、r72= 在、RC71 LOADFIRST 必须=0**、
#           SX2=0、ksu_stat_off=12、未导出=0。
LOG=/home/lucy/ksu_rc72.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
U=/root/k/ksu/uapi
DEVS=/home/lucy/Module.symvers_dev
WANT_VER=${WANT_VER:-32601}
WANT_UAPI=${WANT_UAPI:-2}
MD5_ALLOW_RC67=3c479222cc94106c990a9e9a06a83794
MD5_ALLOW_AFTER=f24f44a8faad7c2d2a6845d5ce6add15
MD5_HOOK_BASE=f30801f0bb30687d365bb77b487c42fd
MD5_HOOK_AFTER=5ac10253ec1c8d15c2dcc7dc0e371f22
AL="$M/policy/allowlist.c"
SH="$M/hook/arm64/syscall_hook.c"
echo "START(rc72) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"

echo "=== 1) 装文件(与 rc71 逐字相同) ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
cp /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h
md5sum /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h

echo; echo "=== 2) 幂等补丁(与 rc71 逐字相同；注意：sucompat.c 马上会被 2c 整份还原覆盖掉) ==="
for f in diag4 sucompat_gates escape_steps decline killscan unlimit visible fdinstall setprof_gate sucompat_steps ksudpath sucompat_gates2 ksudpath2 tracequiet statprobe_steps capclamp; do
    cp "/home/lucy/patch_ksu_$f.py" "/home/lucy/p_$f.py" 2>/dev/null && python3 "/home/lucy/p_$f.py" "$M" || echo "  !! patch_ksu_$f.py 没跑成"
done

echo; echo "=== 2b) selinux.c 还原 pristine 后**照打域回退补丁**(=rc67 的样子；与 rc71 逐字相同) ==="
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

echo; echo "=== 2c) sucompat.c 还原成 rc67 快照，**不打 selfexec** ⇒ 这份的底就是 rc67(与 rc71 逐字相同) ==="
SUC="$M/feature/sucompat.c"
RC67_C=/home/lucy/w343_sucompat_rc67.c
MD5_RC67=e8e53b7bd153aa3d54bf72b5ee294b3e
[ -f "$RC67_C" ] || { echo "  !! 没有 rc67 快照 $RC67_C ⇒ 停(宁可不出货，不出说不出来源的货)"; exit 1; }
[ "$(md5sum "$RC67_C" | cut -d' ' -f1)" = "$MD5_RC67" ] || { echo "  !! rc67 快照本身 md5 不对 ⇒ 停"; exit 1; }
cp "$RC67_C" "$SUC" && echo "  已还原 sucompat.c 到 rc67：$(md5sum "$SUC" | cut -d' ' -f1) 字节=$(wc -c < "$SUC")"
[ "$(md5sum "$SUC" | cut -d' ' -f1)" = "$MD5_RC67" ] || { echo "  !! 红灯：还原后的 sucompat.c md5 不等于 rc67 快照 ⇒ 停"; exit 1; }

echo; echo "=== 2d) ★rc72 改动 1+2：allowlist.c 先还原成 rc67 那份，再与 syscall_hook.c 一起打 noread，两份源码 md5 都要对上预测 ==="
RC67_A=/home/lucy/allowlist_rc67.c
[ -f "$RC67_A" ] || { echo "  !! 没有 rc67 的 allowlist.c 快照 $RC67_A ⇒ 停"; exit 1; }
[ "$(md5sum "$RC67_A" | cut -d' ' -f1)" = "$MD5_ALLOW_RC67" ] || { echo "  !! allowlist_rc67.c 的 md5 不对 ⇒ 停(别拿说不出来源的底去编)"; exit 1; }
BEFORE=$(md5sum "$AL" | cut -d' ' -f1)
echo "  树上那份 allowlist.c 打之前：$BEFORE  (rc67=$MD5_ALLOW_RC67 / rc71 打过 loadfirst=$MD5_ALLOW_AFTER 都不要留)"
cp "$RC67_A" "$AL" && echo "  已把 allowlist.c 还原成 rc67：$(md5sum "$AL" | cut -d' ' -f1)"
[ "$(md5sum "$AL" | cut -d' ' -f1)" = "$MD5_ALLOW_RC67" ] || { echo "  !! 红灯：还原后不等于 rc67 ⇒ 停"; exit 1; }
HB=$(md5sum "$SH" | cut -d' ' -f1)
echo "  syscall_hook.c 打之前：$HB  (未打=$MD5_HOOK_BASE / 已打=$MD5_HOOK_AFTER)"
[ "$HB" = "$MD5_HOOK_BASE" ] || [ "$HB" = "$MD5_HOOK_AFTER" ] || { echo "  !! 红灯：syscall_hook.c 既不是未打也不是已打那份 ⇒ 说不出来源，停"; exit 1; }
cp /home/lucy/patch_ksu_noread.py /home/lucy/p_noread.py || { echo "  !! 补丁脚本没拷到 ⇒ 停"; exit 1; }
python3 /home/lucy/p_noread.py "$AL" "$SH" || { echo "  !! noread 补丁没跑成 ⇒ 停"; exit 1; }
python3 /home/lucy/p_noread.py "$AL" "$SH" || { echo "  !! 幂等确认失败 ⇒ 停"; exit 1; }
GOT_A=$(md5sum "$AL" | cut -d' ' -f1); GOT_H=$(md5sum "$SH" | cut -d' ' -f1)
echo "  打完之后：allow=$GOT_A (预测 $MD5_ALLOW_AFTER)   hook=$GOT_H (预测 $MD5_HOOK_AFTER)"
[ "$GOT_A" = "$MD5_ALLOW_AFTER" ] || { echo "  !! 红灯：allowlist.c 源码 md5 与离线预测不一致 ⇒ 这份产物说不出来源，停"; exit 1; }
[ "$GOT_H" = "$MD5_HOOK_AFTER" ] || { echo "  !! 红灯：syscall_hook.c 源码 md5 与离线预测不一致 ⇒ 停"; exit 1; }
echo "  ✓ 两份源码 md5 都与离线 dry-run 逐字节一致 ⇒ 这一份 .ko 相对 rc67 的唯一差别就是 noread 那一块(含正对照那行)"
P=$(grep -c 'module_param(ksu_no_allowlist_read' "$AL"); G=$(grep -c 'if (ksu_no_allowlist_read)' "$AL"); R=$(grep -c 'r72=%d' "$SH")
echo "  结构自检：module_param=$P(必须 1) 闸=$G(必须 1) 高频行 r72=$R(必须 1) RC71 残留=$(grep -c 'RC71 LOADFIRST' "$AL")(必须 0)"
[ "$P" = 1 ] && [ "$G" = 1 ] && [ "$R" = 1 ] || { echo "  !! 结构不对 ⇒ 停(别拿半成品去编)"; exit 1; }
[ "$(grep -c 'RC71 LOADFIRST' "$AL")" = "0" ] || { echo "  !! 红灯：还留着 loadfirst ⇒ 不是单变量"; exit 1; }

echo; echo "=== 3) 版本/uapi 对齐(与 rc71 逐字相同) ==="
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

echo; echo "=== 5) 闸门自查(rc71 那一套，但 RC71 反过来=0、换成 RC72 三个证人) ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc72.txt
echo "U 总数 $(wc -l < /tmp/und_rc72.txt)"
MISS=0
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || { echo "  未导出: $s"; MISS=$((MISS+1)); }
done < /tmp/und_rc72.txt
echo "未导出符号数 = $MISS  (必须 0)"
[ "$MISS" = "0" ] || { echo "  !! 红灯：有未导出符号 ⇒ 这个 .ko 装不上"; exit 1; }
echo "  RC72 串数(必须 >=1): $(strings "$M/kernelsu.ko" | grep -c 'RC72 SKIPREAD')"
[ "$(strings "$M/kernelsu.ko" | grep -c 'RC72 SKIPREAD')" -ge 1 ] || { echo "  !! 红灯：新块根本没进产物"; exit 1; }
echo "  高频行 r72= 串数(必须 >=1): $(strings "$M/kernelsu.ko" | grep -c 'r72=%d')"
[ "$(strings "$M/kernelsu.ko" | grep -c 'r72=%d')" -ge 1 ] || { echo "  !! 红灯：正对照那行没进产物 ⇒ 这一发的参数现值不可证"; exit 1; }
/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -w ksu_no_allowlist_read | sed "s/^/  符号回执: /"
[ -n "$(/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -w ksu_no_allowlist_read)" ] || { echo "  !! 红灯：符号 ksu_no_allowlist_read 不在产物里"; exit 1; }
echo "  RC71 LOADFIRST 串数(必须 0): $(strings "$M/kernelsu.ko" | grep -c 'RC71 LOADFIRST')"
[ "$(strings "$M/kernelsu.ko" | grep -c 'RC71 LOADFIRST')" = "0" ] || { echo "  !! 红灯：产物里还留着 loadfirst ⇒ 这一发不是单变量"; exit 1; }
SX2N=$(strings "$M/kernelsu.ko" | grep -c "KSUBEAT SX2 selfexec-pre")
[ "$SX2N" = "0" ] || { echo "  !! 红灯：SX2 串数=$SX2N(这份 rc67 底应当 0) ⇒ 这份混进了 selfexec"; exit 1; }
UNDUP=$(grep -c 'if (ksu_stat_off)' "$M/feature/sucompat.c")
[ "$UNDUP" = "12" ] || { echo "  !! 红灯：ksu_stat_off 闸=$UNDUP 份(还原成 rc67 应当 12)"; exit 1; }
echo "  红灯闸：未导出=0 ✓  RC72>=1 ✓  r72= 在 ✓  符号在 ✓  RC71=0 ✓  SX2=0 ✓  ksu_stat_off=12 ✓"
strings "$M/kernelsu.ko" | grep -c 'KSUBEAT' | sed 's/^/KSUBEAT 串数: /'
strings "$M/kernelsu.ko" | grep -c "Crowning manager" | sed 's/^/Crowning 串数(必须 1): /'
strings "$M/kernelsu.ko" | grep -c "CAPCLAMP" | sed 's/^/CAPCLAMP 串数(必须 >0): /'
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc72.ko && md5sum /home/lucy/kernelsu_rc72.ko
echo "★符号表对量(唯一变量的证法)：rc67 vs rc72"
/usr/bin/llvm-nm /home/lucy/kernelsu_rc67.ko 2>/dev/null | awk '{print $NF}' | sort -u > /tmp/s67.txt
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '{print $NF}' | sort -u > /tmp/s72.txt
echo "  只在 rc72 有的符号:"; comm -13 /tmp/s67.txt /tmp/s72.txt | head -12
echo "  只在 rc67 有的符号(必须为空):"; comm -23 /tmp/s67.txt /tmp/s72.txt | head -12
ls -l /home/lucy/kernelsu_rc67.ko /home/lucy/kernelsu_rc72.ko 2>/dev/null
echo "END $(date)"
