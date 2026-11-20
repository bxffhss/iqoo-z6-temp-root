#!/bin/bash
# push_ksu.sh —— 把路线 B 的一发窗口所需产物铺到设备并逐条核对（md §6.40(d)）。
# 为什么要脚本化：Git Bash 会把 adb 的远端路径改写成 K:/Git/... 并**谎报成功**，
# 所有 adb push/pull 一律带 MSYS_NO_PATHCONV=1；且推完必须用**设备侧 md5sum** 回读比对，
# 不看 adb 的退出码(本项目口径：ret=0 不等于真的跑了)。
# 用法：bash kmod/push_ksu.sh          (第十八发：rc21)
set -u
cd "$(dirname "$0")/.." || exit 1
KO=${KO:-kmod/kernelsu_rc74c.ko}   # 10-25 第 57 发起默认 rc74c(见 w431 映射行注释)；回退：KO=kmod/kernelsu_rc74b.ko 或 rc73 跑一次   # ★10-24 22:0x 起默认＝rc74b(两发判正，见 md §6.416/§6.417~§6.421)；上一版 `kmod/kernelsu_rc73.ko` 留仓，`KO=kmod/kernelsu_rc73.ko` 一条前缀就指回去

#   ★10-24 换默认＝rc73(`34b3efa8…`)：相对 rc67 只多 §6.394 那条 `files==NULL` 护栏(装 fd 的回调踩到正在退出的任务
#            就会 null deref⇒PS_HOLD)，离线结构差＝`.text`+32B、`.rodata.str1.1`+134B(那句 skip 打印)，
#            `vermagic`/`__param`(1240B)/`__versions`(159 条)/未定义引用(155) **逐字相同** ⇒ `ksu_args.txt` 那五条参数原样吃得下；
#            真窗凭据＝第 48 发单变量那一发(`KO=kmod/kernelsu_rc73.ko`，`insmod rc=0 up=729.15`＋`BIND_RC=0`＋`HEALTH=OK`＋`GO_RC=0`，窗活到 insmod+≈1654 秒)。
#            ★注意：护栏**有没有真挡到一次**仍未取到(#170：那一发只给活着的 Manager 排队，skip 全程 0)——换默认的理由是"少了已知崩溃路径"，不是"治好了什么"。
#   上一版默认＝rc67(`40e0c25d…`，仍留仓、仍可用 `KO=kmod/kernelsu_rc67.ko` 指回去)：=rc63 + `setup_selinux()` 域回退
#            (官方 Profile 下发的 `u:r:ksu:s0` 本机不存在 ⇒ `secctx -22` ⇒ 回退 `u:r:shell:s0`；§6.212⑧ 按用户"帮我选择"定为交付默认)。
#   ★第 105 发起点抓到**这一行以前还写着 rc63** ⇒ 我"跑交付只剩一条命令 go.sh"那句话当时是假的：
#     不带 `KO=` 会推 rc63，而 rc63 下 su 壳停在 `untrusted_app_25`(#96/#97)，执法态下用不了。
#KO=kmod/kernelsu_rc63.ko   # rc63(=#78：cred 的 cap 夹进 CAP_FULL_SET ⇒ vr 不再把交付态 su shell 当可疑任务，POL 组 11 条 EPERM 变 0；ko 与 rc62 只差 `ksu_capclamp` 一个参数，负对照=args 加 `ksu_capclamp=0`，见 §6.179)。
#KO=kmod/kernelsu_rc62.ko   # rc62 = #73：带 /proc/ksu_cfiscan 全表扫 + c=4 写回 clone/setuid/setresuid 三条桩
# 上一版默认是 rc60：# 默认 rc60；#57 用 KO=kmod/kernelsu_rc60_nover.ko 试"无 __versions 表"
# 原来这行是写死的，改成环境变量可覆盖(不改默认行为)。  # rc60 = rc59 + 对外报告的 version 压到 32601、uapi 压到 2(§6.126/#51)
                           #   目的：让**官方 v3.3.0 Manager**(32601/uapi2)不再被"版本过低/uapi 不匹配"
                           #   拦住。第 33 发已证它能被加冕(is_manager:1)并拿到驱动 fd(工作中[越狱模式])。
                           #   这一发要分的唯一一件事：「获取 Root 失败」是版本闸还是真 ABI 错位。
#KO=kmod/kernelsu_54_rc59.ko   # rc59 = rc58 + stat/faccessat handler 的分步回执 FA0..FA5/FS0..FS5 + ksu_stat_off 开关(§6.119③)
                              #   ostype 这条 sysctl 在本机是 0444，uid 0 也写不动，只能内核侧下笔)
CTL=cm57/ksuctl
POST=kmod/ksu_one_stage.sh
ARGS=${ARGS:-kmod/ksu_args.txt}
STAGE=kmod/ksu_stage.txt
# ★改口径(第 100/101 发连踩两次，§6.224①)：这里原来指 `cm57/ksud_shim`=**§6.20~6.22 那代的老 shim**(它假设
#   exec 之前内核已经换好 cred)，而真正在交付链上跑的是 `cm57/sustatic`(su_static.c：扫 /proc/self/fd
#   拿驱动 fd → ioctl 自提权 → 自证 getuid()==0，再 exec sh)。两份都往**同一个槽**(/data/local/tmp/ksud
#   → stage 复制成改道目标)推，于是"ksud 已是最新"这句 md5 对比**守的是老那份**，改道目标静默退回 v1。
#   ⇒ 交付槽只认 sustatic；老 shim 留在 cm57/ksud_shim 当历史，不再被推。
# ★§6.353：这里改成**可被上游显式指定**——`go.sh` 给了 `SHBIN` 时会 export `SHIM=cm57/sustatic_v4`，
#   因为 su 改道 exec 的其实就是这条链推上去的这份(改名叫 ksud → stage cp 成 kd)；
#   不指定(含单跑本脚本)⇒ 仍是 v3 交付槽，逐字不变。下面那条 md5 对比闸原样生效(它守的就是这一支)。
SHIM=${SHIM:-cm57/sustatic}
SUSM=cm57/susm
SHD=suw_apk/shdbin   # v3: 带 KSUFD(SCM_RIGHTS 把驱动 fd 递给 app)
SUWB=cm57/suwbind
CTL88=cm57/ksuctl88   # ★多条目 .allowlist 只能由它生成(§6.155：旧 ksuctl 会静默丢掉多余条目)
MODAPPLY=kmod/ksu_module_apply.sh
MODDOWN=kmod/ksu_module_teardown.sh
MODPRE=kmod/preflight_module.sh
MODZIP=kmod/testmod.zip
SUW_UID=${SUW_UID:-$(${ADB:-adb} shell "pm list packages -U 2>/dev/null | grep -w com.suw.manager" 2>/dev/null | grep -oE "uid:[0-9]+" | cut -d: -f2)}   # ★不写死：卸载重装就换号(10284→10308)
MGR_UID=${MGR_UID:-$(${ADB:-adb} shell "pm list packages -U 2>/dev/null | grep -w me.weishu.kernelsu" 2>/dev/null | grep -oE "uid:[0-9]+" | cut -d: -f2)}
echo "  探测到 uid: suw=$SUW_UID 官方 Manager=$MGR_UID"
DOMAIN=${DOMAIN:-u:r:shell:s0}   # ★用 shell：历次 app 授权判据都是在 domain=u:r:shell:s0 下拿到的，别再悄悄换变量

A() { MSYS_NO_PATHCONV=1 adb "$@"; }
S() { A shell "$@" 2>&1; }

echo "=== 0. 本地产物 md5 ==="
for f in "$KO" "$CTL" "$CTL88" "$POST" "$ARGS" "$STAGE" "$SHIM" "$SUSM" "$SUWB" "$MODAPPLY" "$MODDOWN" "$MODPRE" "$MODZIP"; do
    [ -f "$f" ] || { echo "[x] 本地缺 $f"; exit 1; }
    printf '  %-34s %s\n' "$f" "$(md5sum "$f" | cut -d' ' -f1)"
done
echo "  uname -s = [$(S 'uname -s' | tr -d '\r')]  (仍是 Linux ⇒ 这个 boot 没打过)"

echo; echo "=== 1. 推 5 件 + 校验 ==="
push() { # $1=本地 $2=设备名
    A push "$1" "/data/local/tmp/$2" >/dev/null 2>&1 || { echo "[x] push $2 失败"; exit 1; }
    L=$(md5sum "$1" | cut -d' ' -f1)
    R=$(S "md5sum /data/local/tmp/$2" | cut -d' ' -f1 | tr -d '\r')
    if [ "$L" = "$R" ]; then echo "  ok $2 $R"; else echo "  !! $2 设备=$R 本地=$L"; exit 1; fi
}
push "$KO" kernelsu.ko
push "$CTL" ksuctl
push "$CTL88" ksuctl88   # ★以前是"孤儿依赖"：设备上那份是 10-06 留下的、清单里根本没有 ⇒ 谁清掉 /data/local/tmp 就会让两条目分支静默退回单条目、白烧一枪
push "$POST" ksu_post.sh
push "$ARGS" ksu_args.txt
push "$STAGE" ksu_stage.txt
push cm57/susm susm
push "$SHD" shd
push "$SUWB" suwbind
push "$MODAPPLY" ksu_module_apply.sh
push "$MODDOWN" ksu_module_teardown.sh
push "$MODPRE" preflight_module.sh
push "$MODZIP" testmod.zip
# ★B 线：常驻补装的腿要被 stage 直接拉起（ksu_keep_auto），所以必须随包推到设备
push kmod/b8_keep.sh b8_keep.sh
push kmod/b8_mgr.sh b8_mgr.sh
S "chmod 755 /data/local/tmp/ksuctl /data/local/tmp/ksu_post.sh /data/local/tmp/kernelsu.ko /data/local/tmp/susm /data/local/tmp/shd /data/local/tmp/suwbind" >/dev/null

echo; echo "=== 2. 两件依赖(名单文件 / su shim)在不在，缺了就补 ==="
if [ -z "$(S 'ls /data/local/tmp/allow.bin 2>/dev/null' | tr -d '\r')" ]; then
    echo "  allow.bin 缺 ⇒ 用刚推的 ksuctl 现做(uid=$SUW_UID domain=$DOMAIN)"
    S "/data/local/tmp/ksuctl mkallow /data/local/tmp/allow.bin $SUW_UID manual $DOMAIN"
else
    echo "  allow.bin 在: $(S 'ls -l /data/local/tmp/allow.bin' | tr -d '\r')"
fi
# ★原来只"缺了才推"⇒ 换了 shim 而设备上还有旧的那份时**静默用旧的**(ATT=8 第一次就这么差点白烧：
#   新 shim 会自己印 SHIM-ESC，用旧的就什么都看不到，还以为是设计不对)。改成按 md5 对比、不同就换。
L_MD5=$(md5sum "$SHIM" | cut -d' ' -f1)
R_MD5=$(S "md5sum /data/local/tmp/ksud 2>/dev/null" | cut -d' ' -f1 | tr -d '\r\n')
if [ -z "$R_MD5" ] || [ "$L_MD5" != "$R_MD5" ]; then
    echo "  ksud 缺或不是最新(设备=$R_MD5 本地=$L_MD5) ⇒ 推 shim"
    push "$SHIM" ksud
else
    echo "  ksud 已是最新: $R_MD5"
fi

echo; echo "=== 2.5 uid 真源(★无条件写：allow.bin 存在时也要刷新，否则 stage 会拿旧 uid)"
S "echo $SUW_UID $MGR_UID > /data/local/tmp/ksa_uids.txt; chmod 666 /data/local/tmp/ksa_uids.txt"
S "cat /data/local/tmp/ksa_uids.txt"

echo; echo "=== 3. 内核侧自检口径(打标与 hook 位，逐字回显到日志) ==="
S "cat /data/local/tmp/ksu_stage.txt /data/local/tmp/ksu_args.txt"
echo "  ★v27 的口径：stage=7 + ksu_mass_mark=0 + ksu_hook_mask=0x0(一个 syscall hook 都不挂)"
echo "  判据顺序(v27)：P1/P2/P4+A readback → 正对照 grant → 控制面 → shd --ksufd → 等 app 报告 →"
echo "                逐线程 /proc 抓 uid0 → passfd 回归；★不再跑 susm/step*(§6.57 判死的 execve 支路)"
echo "  打完收工后读： /data/local/tmp/ksu_stage.log、app_ksu.txt、dmesg_full.txt"
echo "  ★注意 ksu_stage.log 跨重启还在 ⇒ PC 侧驱动器只认起点行含 'v27' 且 up= 与实时 uptime 相差<3600s 的那一份"
echo "=== 完 ==="
