#!/bin/bash
# rc62 = rc61 + **c=4：只改桩地写回 #73 那三条(clone 220 / setuid 146 / setresuid 147)**(任务 #73 第二步)。
#   与 c=3 分开一个值，就是为了"单独触发、单独归因"：交付流程每发都在跑 c=3 那五条，
#   这一笔要是不巧把机器打 PS_HOLD，凶手没有第二种解释。触发法：echo 4 > /proc/ksu_fixcfi。
#   一手(§6.167)：escape 过的任务 clone(220)/setuid(146)/setresuid(147) 吃 -EPERM 而本体 kretprobe 零命中，
#   可我们过去只**点查** 5 条桩 ⇒ vr 到底管几条从没数过。这一版只加"读"：新触发口 /proc/ksu_cfiscan，
#   判据只认"B 目标或桩+8 的 .quad 解析出模块名==vr"(在已知 5 条上给出 3 中/2 干净才算能用)。
#   ★不新增任何写；写桩(c=3)留给 #73 第二步，等这一发的读数回来再动。
#
# 为什么要这一版：第 33 发一手证明官方 Manager 能被加冕(`is_manager: 1`)、能拿到驱动 fd
#   (首页绿卡「工作中 [越狱模式] 版本：32653-4」)，但被它自己的两道闸拦住：
#     管理器版本 (32601) 与驱动版本 (32653) 不匹配 / 请升级至 32653 或以上
#     管理器 uapi (2) 与驱动 uapi (4) 不匹配
#   ⇒ 而 (a) 路已死：官方**最新** release 就是 v3.3.0=32601(我们 ko 版本 = 30000 + git 提交数，
#     树在 v3.3.0 之后 52 个提交)，不存在 >=32653 的已发布 Manager。所以只能让 ko 去对齐。
#
# 风险已先离线排掉两条：① 我们自己的用户态(suwksu_jni.c / ksuctl.c)只**打印** version/uapi，
#   不设任何闸 ⇒ 压数字不会回归已交付的 suw.apk 通路；② ko 里本来就有 `get_info_legacy`
#   处理入口 ⇒ 旧(uapi2)客户端的结构体有人接。
#
# 这一版要答的唯一问题(只有上机才能答)：「获取 Root 失败」到底是版本闸，还是真 ABI 错位。
#
# ★两处改动都要求**可核对回执**，不接受"我 sed 过了"：
#   - Kbuild：ccflags 那行换成 `$(if $(KSU_VERSION_OVERRIDE),…,…)`，并加一行 $(info) 打印**生效值**；
#   - uapi/supercall.h：常量 4→2，sed 之后**立刻 grep 回来**印在日志里。
LOG=/home/lucy/ksu_rc62.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
U=/root/k/ksu/uapi
DEVS=/home/lucy/Module.symvers_dev
WANT_VER=${WANT_VER:-32601}
WANT_UAPI=${WANT_UAPI:-2}
echo "START(rc62) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"

echo "=== 1) 装文件(与 rc59 逐字相同) ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
cp /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h
md5sum /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h

echo; echo "=== 2) 幂等补丁(与 rc59 逐字相同) ==="
for f in diag4 sucompat_gates escape_steps decline killscan unlimit visible fdinstall setprof_gate sucompat_steps ksudpath sucompat_gates2 ksudpath2 tracequiet statprobe_steps; do
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
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc62.txt
echo "U 总数 $(wc -l < /tmp/und_rc62.txt)"
MISS=0
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || { echo "  未导出: $s"; MISS=$((MISS+1)); }
done < /tmp/und_rc62.txt
echo "未导出符号数 = $MISS  (必须 0)"
strings "$M/kernelsu.ko" | grep -c 'KSUBEAT' | sed 's/^/KSUBEAT 串数: /'
strings "$M/kernelsu.ko" | grep -c 'Crowning manager' | sed 's/^/Crowning 串数(必须 1): /'
strings "$M/kernelsu.ko" | grep -c "VRCFI" | sed "s/^/VRCFI 串数(必须 >0): /"
strings "$M/kernelsu.ko" | grep -c "fixcfi c=4" | sed "s/^/c=4 串数(必须 1): /"
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc62.ko && md5sum /home/lucy/kernelsu_rc62.ko
echo "END $(date)"
