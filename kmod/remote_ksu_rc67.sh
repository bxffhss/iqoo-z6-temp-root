#!/bin/bash
# rc67 = rc63 + **§6.206/§6.207 的"域"那一格：su 提权时 profile 的域解析失败 ⇒ 回退到这台机存在的域**。
#   一手事实：官方 Manager 的 App Profile 默认发 `u:r:ksu:s0`，本机基础策略没这个域，
#     `security_secctx_to_secid` 返 -22 ⇒ `transive_to_domain()` 只打日志不改 `tsec->sid`
#     ⇒ 官方 UI 点出来的壳是 `uid=0 + CapEff=0x3fffffffff + Seccomp:0` 但**域仍是 untrusted_app_25**，
#     实测连 `/system/bin/sh` 的头三字节都读不到(§6.207②)。
#   补丁本体 `kmod/patch_ksu_domainfallback.py`：已拿远端**当前**那份 selinux.c(md5 ccbf5bac…)离线试过
#     —— 两个锚各命中 1 次、二跑幂等、6101→7008 字节。
#   回退只挂在 `setup_selinux()`(su 那条路)，**不碰** `setup_ksu_cred()`(那是我们自己的内核凭据，换域是另一码事)。
#   参数 `ksu_domain_fallback`：默认 "u:r:shell:s0"；insmod 时给空串 = **负对照**(退回 rc63 行为)。
#     ★本 ko 在 init 里 kobject_del 了 /sys/module/kernelsu ⇒ 参数只在 insmod 那一刻定。
#   1)~5) 与 rc63 逐字相同，只在 2) 之后多一步 selinux.c 的"还原 pristine → 打域回退补丁"，闸门多两条 DOMAIN 串数。
LOG=/home/lucy/ksu_rc67.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
U=/root/k/ksu/uapi
DEVS=/home/lucy/Module.symvers_dev
WANT_VER=${WANT_VER:-32601}
WANT_UAPI=${WANT_UAPI:-2}
echo "START(rc67) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"

echo "=== 1) 装文件(与 rc63 逐字相同) ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
cp /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h
md5sum /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h

echo; echo "=== 2) 幂等补丁(与 rc63 逐字相同) ==="
for f in diag4 sucompat_gates escape_steps decline killscan unlimit visible fdinstall setprof_gate sucompat_steps ksudpath sucompat_gates2 ksudpath2 tracequiet statprobe_steps capclamp; do
    cp "/home/lucy/patch_ksu_$f.py" "/home/lucy/p_$f.py" 2>/dev/null && python3 "/home/lucy/p_$f.py" "$M" || echo "  !! patch_ksu_$f.py 没跑成"
done

echo; echo "=== 2b) ★rc67 新增：selinux.c 先还原 pristine，再打"域回退"补丁 ==="
SL="$M/selinux/selinux.c"
if [ ! -f "$SL.pristine" ]; then
    cp "$SL" "$SL.pristine" && echo "  已存 pristine 快照(此刻还没打域补丁)：$(md5sum "$SL.pristine" | cut -d' ' -f1)"
else
    echo "  pristine 已存在：$(md5sum "$SL.pristine" | cut -d' ' -f1)"
fi
cp "$SL.pristine" "$SL" && echo "  selinux.c 已还原成 pristine：$(md5sum "$SL" | cut -d' ' -f1)"
cp /home/lucy/patch_ksu_domainfallback.py /home/lucy/p_domainfallback.py || echo "  !! 补丁脚本没拷到"
python3 /home/lucy/p_domainfallback.py "$SL" || { echo "  !! 域回退补丁没跑成 ⇒ 停"; exit 1; }
echo "  打完之后：$(md5sum "$SL" | cut -d' ' -f1)  行数=$(wc -l < "$SL")"
echo "  锚点自检：setup_selinux=$(grep -c '^void setup_selinux' "$SL") 回退分支=$(grep -c 'ksu_domain_fallback' "$SL") module_param=$(grep -c module_param_string "$SL")"

echo; echo "=== 3) ★版本/uapi 对齐(与 rc63 逐字相同) ==="
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

echo; echo "=== 5) 闸门自查(rc63 那一套 + 两条 DOMAIN) ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc67.txt
echo "U 总数 $(wc -l < /tmp/und_rc67.txt)"
MISS=0
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || { echo "  未导出: $s"; MISS=$((MISS+1)); }
done < /tmp/und_rc67.txt
echo "未导出符号数 = $MISS  (必须 0)"
strings "$M/kernelsu.ko" | grep -c 'KSUBEAT' | sed 's/^/KSUBEAT 串数: /'
strings "$M/kernelsu.ko" | grep -c 'Crowning manager' | sed 's/^/Crowning 串数(必须 1): /'
strings "$M/kernelsu.ko" | grep -c "VRCFI" | sed "s/^/VRCFI 串数(必须 >0): /"
strings "$M/kernelsu.ko" | grep -c "fixcfi c=4" | sed "s/^/c=4 串数(必须 1): /"
strings "$M/kernelsu.ko" | grep -c "CAPCLAMP" | sed "s/^/CAPCLAMP 串数(必须 >0): /"
strings "$M/kernelsu.ko" | grep -c "ksu_capclamp" | sed "s/^/ksu_capclamp 串数(必须 >0): /"
# ★DOMAIN 那几句里只有前缀是 ASCII(中文那部分 strings 抓不到，别拿它当判据——例 53)
strings "$M/kernelsu.ko" | grep -c "DOMAIN" | sed "s/^/DOMAIN 串数(必须 >=2：回退分支 + 一次就成): /"
strings "$M/kernelsu.ko" | grep -c "u:r:shell:s0" | sed "s/^/回退默认域串 u:r:shell:s0 数(必须 >0): /"
/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -w ksu_domain_fallback | sed "s/^/  符号回执: /"
/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -w ksu_capclamp | sed "s/^/  符号回执: /"
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc67.ko && md5sum /home/lucy/kernelsu_rc67.ko
echo "END $(date)"
