#!/system/bin/sh
# w149_offline.sh —— #53 的**离线闸门**：`SET_APP_PROFILE` 能不能用**纯用户态**的方式证伪？
#
# 为什么必须有这一发：给设备上写一份"域不存在的 profile"会**改变每一发的准入条件**
# (内核可能因此 decline、也可能照单全收)，而"ioctl 回 rc=0"从来不代表内核按你给的那份解释。
# 用户 2026-10-04 的提醒：不要论证"不必测"，低成本实验照测。
# ⇒ 所以先在不碰设备状态的前提下问一句：**这份 profile 到底有没有被按语义校验过？**
#   做法 = mkallow 只**生成文件**、不发给内核(它写的是 /data/adb/ksu/.allowlist，
#   而那个文件在本 boot 已被删掉、内核只在 insmod 时读它) ⇒ 零副作用，能看出
#   "我们自填的域"和"default 模板的域"在结构上是不是同一回事。
L=/data/local/tmp/w149_offline.out
CTL=/data/local/tmp/ksuctl87
U=${U:-10667}
{
    echo "===== W149-OFFLINE up=$(cut -d' ' -f1 /proc/uptime) enf=$(getenforce) ====="
    echo "--- [0] .allowlist 还在不在(不在=内核本 boot 不会再读它 ⇒ 生成文件零副作用) ---"
    ls -l /data/adb/ksu/.allowlist 2>&1 | head -1
    echo "--- [1] 三种域各生成一份 profile，逐字节比较(只有 domain 那一段该变) ---"
    for d in u:r:shell:s0 u:r:kernel:s0 u:r:zzz_no_such_domain:s0; do
        $CTL mkallow /dev/null "$U" - "$d" 2>&1 | head -1 | sed "s/^/  mkallow[$d] /"
    done
    echo "--- [2] 起点域(不加 su)：这台机现在整体是 Permissive ⇒ 域不参与判定，先记下 ---"
    cat /proc/self/attr/current; echo " getenforce=$(getenforce)"
    echo "--- [3] 目标 uid 现在的域与凭据(以 $U 起一个普通脚本，PATH 只给挂载点) ---"
    $CTL supath "$U" /product/bin /system/bin/id 2>&1 | head -4
    echo "--- [4] 内核侧上一次关于域的解不开回执(跨 boot 不残留：dmesg2.log 是本 boot 的) ---"
    grep -aE "secctx_to_secid|setup_selinux|X6 |X2 profile" /data/local/tmp/dmesg2.log 2>/dev/null | tail -4 | cut -c1-150
    echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
