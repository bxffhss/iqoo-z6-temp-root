#!/bin/bash
# rc63 = rc62 + **#78：把 profile 发来的 cap 掩码夹进 CAP_FULL_SET 再写进 cred**(带 0644 运行时开关)。
#   一手(§6.172)：同一发窗口里三个 uid=0 上下文跑同一个 policeprobe ——
#     agent root / suw `@su:`(cap_eff=0x0000003fffffffff)：vr 那 22 条**一条都不拦**；
#     Termux 手敲 `su`(cap_eff/prm/bnd=0xffffffffffffffff，域 shell)：**11 条全 EPERM**。
#   这台机 CAP_LAST_CAP=37 ⇒ 内核配得出的满集是 0x3fffffffff，`~0` 的高位脏位只可能来自
#   "我们自己在 ksuctl/suw 里写死 ~(uint64_t)0 + app_profile.c 整块 memcpy"。
#   ⇒ 这一版**只改自己发的 cred 形状，不碰厂商桩**；`ksu_capclamp` 是 0644 的模块参数，
#     所以活窗口里能 `echo 0/1` 做单变量前后对照(0=退回 rc62 行为=负对照)。
#   判据：① POL 组随开关翻转 ② CTRL 组两遍全绿 ③ /proc/ksu_cfiscan 两遍都还是 22。
#   补丁本体在 `kmod/patch_ksu_capclamp.py`(已拿远端**当前**那份 app_profile.c 离线试过：4 个锚点各命中 1 次、二跑幂等)。
#   下面 1)~3) 与 rc62 逐字相同(装文件/幂等补丁/版本对齐)，只有 4) 之后的闸门多一条 CAPCLAMP 串数。
LOG=/home/lucy/ksu_rc63.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
U=/root/k/ksu/uapi
DEVS=/home/lucy/Module.symvers_dev
WANT_VER=${WANT_VER:-32601}
WANT_UAPI=${WANT_UAPI:-2}
echo "START(rc63) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"

echo "=== 1) 装文件(与 rc59 逐字相同) ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
cp /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h
md5sum /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h

echo; echo "=== 2) 幂等补丁(与 rc59 逐字相同) ==="
for f in diag4 sucompat_gates escape_steps decline killscan unlimit visible fdinstall setprof_gate sucompat_steps ksudpath sucompat_gates2 ksudpath2 tracequiet statprobe_steps capclamp; do
    cp "/home/lucy/patch_ksu_$f.py" "/home/lucy/p_$f.py" 2>/dev/null && python3 "/home/lucy/p_$f.py" "$M" || echo "  !! patch_ksu_$f.py 没跑成"
done

echo; echo "=== 3) ★版本/uapi 对齐(这一版新增) ==="
KB="$M/Kbuild"
cp -n "$KB" "$KB.bak_rc60"   # rc60 那次已备份，幂等 2>/dev/null
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

echo; echo "=== 5) 闸门自查(与 rc59 同一套：未导出符号必须为 0) ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc63.txt
echo "U 总数 $(wc -l < /tmp/und_rc63.txt)"
MISS=0
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || { echo "  未导出: $s"; MISS=$((MISS+1)); }
done < /tmp/und_rc63.txt
echo "未导出符号数 = $MISS  (必须 0)"
strings "$M/kernelsu.ko" | grep -c 'KSUBEAT' | sed 's/^/KSUBEAT 串数: /'
strings "$M/kernelsu.ko" | grep -c 'Crowning manager' | sed 's/^/Crowning 串数(必须 1): /'
strings "$M/kernelsu.ko" | grep -c "VRCFI" | sed "s/^/VRCFI 串数(必须 >0): /"
strings "$M/kernelsu.ko" | grep -c "fixcfi c=4" | sed "s/^/c=4 串数(必须 1): /"
strings "$M/kernelsu.ko" | grep -c "CAPCLAMP" | sed "s/^/CAPCLAMP 串数(必须 >0): /"
strings "$M/kernelsu.ko" | grep -c "ksu_capclamp" | sed "s/^/ksu_capclamp 串数(必须 >0，参数名在 __param 里): /"
/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -w ksu_capclamp | sed "s/^/  符号回执: /"
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc63.ko && md5sum /home/lucy/kernelsu_rc63.ko
echo "END $(date)"
