#!/system/bin/sh
# 兜底：post-fs-data 那一次没挂上(或被系统自愈卸掉)时，这里再挂一次 + 记一笔。
# 理由来自 Z5 教程的一手："绑定环境被系统自愈弄坏 ⇒ exec '/system/bin/sh' failed: Permission denied
# ⇒ 只能重启" —— 所以挂载需要一把**重挂看门狗**，不能只挂一次。
/data/local/tmp/sustatic -c 'sh /data/adb/modules/suwegrid/post-fs-data.sh' >/dev/null 2>&1
echo "service.sh up=$(cut -d' ' -f1 /proc/uptime) pbin=$(grep -c pbin /proc/self/mountinfo)" >> /data/local/tmp/modsu.log
