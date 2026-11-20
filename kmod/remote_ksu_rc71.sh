#!/bin/bash
# rc71 = **rc67 + 唯一一块新补丁：allowlist.c 的 ksu_load_first_only**（读到第一条记录就 break）。
#   为什么要它(§6.278 / 任务 #108)：128/129 两发已经把致死条件夹到"装载循环多走一圈"这个动作本身
#     （表内容/uid/key/包名真假全部出局），而 §6.277 逐行读过这段代码：无定时、无 work、`kfree_rcu` 写法正确
#     ⇒ 数据侧再也夹不动，只能进 ko：磁盘文件仍逐字节 1576 字节，唯一差别=循环只跑一圈。
#   判据(开枪前写死)：活过 +30 分钟 ⇒ 死在"循环体被执行"；仍 +16~30 秒 ⇒ 死在"打开并读了这个文件"那一层。
# ★这份脚本是 remote_ksu_rc69.sh 的**逐字复制 + 三处改动**（不是凭记忆重写 make 行——`remote_ksu_rc70.sh` 就是这么废的）：
#   改动 1：2b 还原 pristine 后**仍打域回退**——第一次试编用 `llvm-nm` 对量符号表，发现 `ksu_domain_fallback` 在**已交付的 rc67 里有**、还原成 pristine 反而没了 ⇒ pristine 不等于 rc67 的那份(见 2b 里的注释)；
#   改动 2：2c 只把 sucompat.c 还原成 rc67 快照，**不打** selfexec 补丁 ⇒ 闸门反过来：**SX2 串数必须=0**（这就是"这份是 rc67 底"的正面证据）；
#   改动 3：新增 2d 打 loadfirst 补丁，并把**源码 md5 与本地离线 dry-run 的预测值对表**（预测 `762063d82dae4810f9999521a6016218`，由 `kmod/patch_ksu_loadfirst.py` 在 pull 下来的同一份 allowlist.c(md5 `3c479222…`) 上跑出来，自检五格全过）。
LOG=/home/lucy/ksu_rc71.log
exec > "$LOG" 2>&1
KDIR=/root/k/nothing_sm7325_v_mr
M=/root/k/ksu/kernel
U=/root/k/ksu/uapi
DEVS=/home/lucy/Module.symvers_dev
WANT_VER=${WANT_VER:-32601}
WANT_UAPI=${WANT_UAPI:-2}
MD5_ALLOW_AFTER=762063d82dae4810f9999521a6016218
MD5_ALLOW_BEFORE=3c479222cc94106c990a9e9a06a83794
echo "START(rc71) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"

echo "=== 1) 装文件(与 rc69 逐字相同) ==="
cp /home/lucy/ksu_dev_syms.c "$M/infra/dev_syms.c" && echo "  dev_syms.c $(wc -l < "$M/infra/dev_syms.c") 行"
cp /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h
md5sum /home/lucy/ksu_compat54.h /home/lucy/kshim/ksu_compat54.h

echo; echo "=== 2) 幂等补丁(与 rc69 逐字相同；注意：sucompat.c 马上会被 2c 整份还原覆盖掉) ==="
for f in diag4 sucompat_gates escape_steps decline killscan unlimit visible fdinstall setprof_gate sucompat_steps ksudpath sucompat_gates2 ksudpath2 tracequiet statprobe_steps capclamp; do
    cp "/home/lucy/patch_ksu_$f.py" "/home/lucy/p_$f.py" 2>/dev/null && python3 "/home/lucy/p_$f.py" "$M" || echo "  !! patch_ksu_$f.py 没跑成"
done

echo; echo "=== 2b) ★rc71 改动 1：selinux.c 还原 pristine 后**照打域回退补丁**(=rc67 的样子) ==="
# ★为什么改回来：第一次试编 rc71 时用 `llvm-nm` 对量 rc67 vs rc71 的符号表，发现
#   `ksu_domain_fallback` 那一族符号**在已交付的 rc67 里有、还原成 pristine 之后反而没了**
#   ⇒ "pristine"不等于 rc67 的 selinux.c(它是 rc67 构建**之后**才被当作 pristine 存的)，
#   而 rc69 头部那句"rc69 = rc67 + 域回退"记错了。⇒ 这一节按符号证据走：要像 rc67，就得把这块打上。
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
echo "  锚点自检：setup_selinux=$(grep -c '^void setup_selinux' "$SL") 回退分支=$(grep -c 'ksu_domain_fallback' "$SL") module_param=$(grep -c module_param_string "$SL")"
[ "$(grep -c 'ksu_domain_fallback' "$SL")" -ge 1 ] || { echo "  !! 红灯：selinux.c 里没有域回退 ⇒ 与 rc67 的符号表对不上，停"; exit 1; }

echo; echo "=== 2c) ★rc71 改动 2：sucompat.c 还原成 rc67 快照，**不打 selfexec** ⇒ 这份的底就是 rc67 ==="
SUC="$M/feature/sucompat.c"
RC67_C=/home/lucy/w343_sucompat_rc67.c
MD5_RC67=e8e53b7bd153aa3d54bf72b5ee294b3e
[ -f "$RC67_C" ] || { echo "  !! 没有 rc67 快照 $RC67_C ⇒ 停(宁可不出货，不出说不出来源的货)"; exit 1; }
[ "$(md5sum "$RC67_C" | cut -d' ' -f1)" = "$MD5_RC67" ] || { echo "  !! rc67 快照本身 md5 不对 ⇒ 停"; exit 1; }
cp "$RC67_C" "$SUC" && echo "  已还原 sucompat.c 到 rc67：$(md5sum "$SUC" | cut -d' ' -f1) 字节=$(wc -c < "$SUC")"
[ "$(md5sum "$SUC" | cut -d' ' -f1)" = "$MD5_RC67" ] || { echo "  !! 红灯：还原后的 sucompat.c md5 不等于 rc67 快照 ⇒ 停"; exit 1; }
echo "  ✓ sucompat.c 逐字节＝rc67（SX 块不在，闸门下面会反过来验 SX2=0）"

echo; echo "=== 2d) ★rc71 改动 3：allowlist.c 打 ksu_load_first_only，并与离线预测 md5 对表 ==="
AL="$M/policy/allowlist.c"
BEFORE=$(md5sum "$AL" | cut -d' ' -f1)
echo "  打之前：$BEFORE  (未打=$MD5_ALLOW_BEFORE / 已打=$MD5_ALLOW_AFTER)"
cp /home/lucy/patch_ksu_loadfirst.py /home/lucy/p_loadfirst.py || { echo "  !! 补丁脚本没拷到 ⇒ 停"; exit 1; }
if [ "$BEFORE" = "$MD5_ALLOW_AFTER" ]; then
    echo "  远端这份**已经是打好的一版**(上一次构建留下的) ⇒ 只跑幂等确认，不再重复打"
elif [ "$BEFORE" = "$MD5_ALLOW_BEFORE" ]; then
    python3 /home/lucy/p_loadfirst.py "$AL" || { echo "  !! loadfirst 补丁没跑成 ⇒ 停"; exit 1; }
else
    echo "  !! 红灯：远端 allowlist.c 既不是未打也不是已打那份 ⇒ 说不出来源，停(别拿这份产物说话)"; exit 1
fi
python3 /home/lucy/p_loadfirst.py "$AL" || { echo "  !! 幂等确认失败 ⇒ 停"; exit 1; }
GOT=$(md5sum "$AL" | cut -d' ' -f1)
echo "  打完之后：$GOT  字节=$(wc -c < "$AL")  (离线预测 $MD5_ALLOW_AFTER)"
[ "$GOT" = "$MD5_ALLOW_AFTER" ] || { echo "  !! 红灯：源码 md5 与离线预测不一致 ⇒ 这份产物说不出来源，停"; exit 1; }
echo "  ✓ 源码 md5 与离线 dry-run 逐字节一致 ⇒ 这一份 .ko 与 rc67 的唯一差别就是 loadfirst 那一块"
echo "  结构自检：module_param=$(grep -c 'module_param(ksu_load_first_only' "$AL")(必须 1) break 段=$(grep -c 'if (ksu_load_first_only)' "$AL")(必须 1) 标记数=$(grep -c 'RC71 LOADFIRST' "$AL")(必须 3)"
H=$(grep -c 'if (ksu_load_first_only)' "$AL"); P=$(grep -c 'module_param(ksu_load_first_only' "$AL")
[ "$H" = 1 ] && [ "$P" = 1 ] || { echo "  !! 结构不对 ⇒ 停(别拿半成品去编)"; exit 1; }

echo; echo "=== 3) 版本/uapi 对齐(与 rc69 逐字相同) ==="
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

echo; echo "=== 5) 闸门自查(rc69 那一套，但 SX2 反过来=0、DOMAIN 也应当 0) ==="
/usr/bin/llvm-nm "$M/kernelsu.ko" | awk '$1=="U"{print $2}' | sort -u > /tmp/und_rc71.txt
echo "U 总数 $(wc -l < /tmp/und_rc71.txt)"
MISS=0
while read -r s; do
  awk -F'\t' -v s="$s" '$2==s{f=1} END{exit !f}' "$DEVS" || { echo "  未导出: $s"; MISS=$((MISS+1)); }
done < /tmp/und_rc71.txt
echo "未导出符号数 = $MISS  (必须 0)"
[ "$MISS" = "0" ] || { echo "  !! 红灯：有未导出符号 ⇒ 这个 .ko 装不上"; exit 1; }
strings "$M/kernelsu.ko" | grep -c "RC71 LOADFIRST" | sed "s/^/RC71 串数(必须 >=1): /"
[ "$(strings "$M/kernelsu.ko" | grep -c 'RC71 LOADFIRST')" -ge 1 ] || { echo "  !! 红灯：新块根本没进产物"; exit 1; }
/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -w ksu_load_first_only | sed "s/^/  符号回执: /"
[ -n "$(/usr/bin/llvm-nm "$M/kernelsu.ko" | grep -w ksu_load_first_only)" ] || { echo "  !! 红灯：符号 ksu_load_first_only 不在产物里"; exit 1; }
SX2N=$(strings "$M/kernelsu.ko" | grep -c "KSUBEAT SX2 selfexec-pre")
[ "$SX2N" = "0" ] || { echo "  !! 红灯：SX2 串数=$SX2N(这份 rc67 底应当 0) ⇒ 这份混进了 selfexec"; exit 1; }
DOMN=$(strings "$M/kernelsu.ko" | grep -c "u:r:shell:s0" )
echo "  回退默认域串 u:r:shell:s0 数=$DOMN(rc67 底：允许 >0，因为 profile 默认域就是它；不当闸)"
UNDUP=$(grep -c 'if (ksu_stat_off)' "$M/feature/sucompat.c")
[ "$UNDUP" = "12" ] || { echo "  !! 红灯：ksu_stat_off 闸=$UNDUP 份(还原成 rc67 应当 12)"; exit 1; }
echo "  红灯闸：未导出=0 ✓  RC71>=1 ✓  符号在 ✓  SX2=0(＝rc67 底) ✓  ksu_stat_off=12 ✓"
strings "$M/kernelsu.ko" | grep -c 'KSUBEAT' | sed 's/^/KSUBEAT 串数: /'
strings "$M/kernelsu.ko" | grep -c "Crowning manager" | sed 's/^/Crowning 串数(必须 1): /'
strings "$M/kernelsu.ko" | grep -c "CAPCLAMP" | sed 's/^/CAPCLAMP 串数(必须 >0): /'
cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc71.ko && md5sum /home/lucy/kernelsu_rc71.ko
echo "END $(date)"
