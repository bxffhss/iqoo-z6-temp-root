#!/bin/bash
# rc66 = rc65 + **`/proc/ksu_crown` 的两处健壮性**(§6.188④ 那颗静默地雷)；除这个口的这两处之外，其余与 rc65 逐字相同：
#   ① 空写/纯空白/非数字开头 ⇒ 只记 `CROWN 忽略…` 的回执、**不动王座**
#      (一手事故：`printf '?\n' > /proc/ksu_crown` 会产生两次 write，第二次空串被 simple_strtoul 解析成 0
#       ⇒ 王座被清零，而那正好发生在"救窗口"的中途——下次再撞就是"王座莫名其妙没了")
#   ② 加 **read 处理器** ⇒ `cat /proc/ksu_crown` 直接回当前 appid
#      (能读就没人会用写去问：这比在写口里加解释更对症)
#   ★默认不写这个口时，rc66 与 rc63/rc65 行为逐字相同 ⇒ 仍然只是实验版，交付默认是 rc63。
#   为什么必须自己开这个口：加冕只在 insmod 那一刻由 throne_tracker 扫 /data/app、按签名认**第一个**匹配者
#   (ko 只烤了两个期望值 EXPECTED_HASH / EXPECTED_HASH2)，而 suw 与官方 Manager 的证书不同 ⇒
#   两者共存时谁戴冠不确定(§6.169 就是官方占着王座、把 suw 的闸门打成 FAIL=6)。
#   ⇒ 要可重复地测"用官方 UI 授权"，就得能在活窗口里把王座指给某个 appid，并且能指回来。
#   形状：`echo <appid> > /proc/ksu_crown`；`echo ? >…` 只把当前值写进 /proc/ksu_slots；appid>100000 直接拒绝。
#   ★切走之前先留退路：用当时的王座给 suw 自己写一条普通 app 的 profile，否则 suw 一旦被降级，
#     `@sushd:`/`@setprof` 全断(它是唯一 root 通道)。
#   其余(装文件/幂等补丁/版本对齐/闸门)与 rc65 逐字相同；dev_syms 换成 rc66 那份。
LOG=/home/lucy/ksu_rc66.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
U=/root/k/ksu/uapi
DEVS=/home/lucy/Module.symvers_dev
WANT_VER=${WANT_VER:-32601}
WANT_UAPI=${WANT_UAPI:-2}
echo "START(rc66) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"

echo "=== 1) 装文件(与 rc59 逐字相同) ==="
cp /home/lucy/ksu_dev_syms_rc66.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
cp /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h
md5sum /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h

echo; echo "=== 2) 幂等补丁(与 rc59 逐字相同) ==="
for f in diag4 sucompat_gates escape_steps decline killscan unlimit visible fdinstall setprof_gate sucompat_steps ksudpath sucompat_gates2 ksudpath2 tracequiet statprobe_steps capclamp mgrdomain; do
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
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc66.txt
echo "U 总数 $(wc -l < /tmp/und_rc66.txt)"
MISS=0
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || { echo "  未导出: $s"; MISS=$((MISS+1)); }
done < /tmp/und_rc66.txt
echo "未导出符号数 = $MISS  (必须 0)"
strings "$M/kernelsu.ko" | grep -c 'KSUBEAT' | sed 's/^/KSUBEAT 串数: /'
strings "$M/kernelsu.ko" | grep -c 'Crowning manager' | sed 's/^/Crowning 串数(必须 1): /'
strings "$M/kernelsu.ko" | grep -c "VRCFI" | sed "s/^/VRCFI 串数(必须 >0): /"
strings "$M/kernelsu.ko" | grep -c "fixcfi c=4" | sed "s/^/c=4 串数(必须 1): /"
strings "$M/kernelsu.ko" | grep -c "CAPCLAMP" | sed "s/^/CAPCLAMP 串数(必须 >0): /"
strings "$M/kernelsu.ko" | grep -c "MGRDOMAIN" | sed "s/^/MGRDOMAIN 串数(必须 >0): /"
strings "$M/kernelsu.ko" | grep -c "ksu_mgrdomain" | sed "s/^/ksu_mgrdomain 串数(必须 >0): /"
strings "$M/kernelsu.ko" | grep -c "CROWN" | sed "s/^/CROWN 串数(必须 >0): /"
# ★rc66 这两处**不能用 strings 验**：中文串在 .ko 里会被 strings 的 ASCII 边界切断(第一版这条闸门恒 0，是判据自己写错，§6.191)。
#   ⇒ 这里只做源码级证明"编进去的是带守卫的那份"；运行级证明留给窗口里(w183_crown.sh：cat 读口 + 空写不复零)。
grep -c "CROWN 忽略空写" "$M/infra/dev_syms.c" | sed "s/^/rc66 空写守卫(源码级，必须 1): /"
grep -c "ksu_crown_read" "$M/infra/dev_syms.c" | sed "s/^/rc66 读处理器(源码级，必须 2: 定义+fops): /"
strings "$M/kernelsu.ko" | grep -c "ksu_capclamp" | sed "s/^/ksu_capclamp 串数(必须 >0，参数名在 __param 里): /"
/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -w "ksu_capclamp\|ksu_set_mgr_domain\|ksu_get_mgr_domain" | sed "s/^/  符号回执: /"
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc66.ko && md5sum /home/lucy/kernelsu_rc66.ko
echo "END $(date)"
