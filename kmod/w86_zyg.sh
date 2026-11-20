#!/system/bin/sh
# 窗口 86：把驱动 fd 装进 **zygote64**，让之后每个 fork 出来的 app 天生带着它。
# 动机(§6.87⑤，一手)：官方 Manager 的 `Home.kt:153` 是 `val ksuVersion = if (isManager) Natives.version else null`，
#   而 `Natives.isManager` 是个**普通 JNI getter(不是 Compose state)** ⇒ 首帧读到的 -1 会一直挂在屏幕上，
#   点刷新/切前台都不会重读。事后往已经跑着的进程里补 fd 救不了这一格；要么抢在首帧之前(抢不到，
#   @sushd 一个来回 8 秒)，要么让**新进程一出生就有 fd** —— 而 app 是 zygote fork 出来的、fork 不 exec，
#   `O_CLOEXEC` 在 fork 时不起作用 ⇒ 装进 zygote64 就等于装进之后每个 app 的初始 fd 表。
# 安全性口径：fd 本身不给任何能力，每个 ioctl 仍受内核 perm_check 约束(GET_MANAGER_APPID 之类只认
#   manager/root)；且这只在临时 root 窗口里存在，收尾 reboot。
Z=$(pidof zygote64)
echo "zygote64 pid=[$Z]"
echo "$Z" > /proc/ksu_install_fd
sleep 3
echo "装完后 zygote 里 ksu_driver fd 数=$(ls -l /proc/$Z/fd 2>&1 | grep -c ksu_driver)"
dmesg 2>/dev/null | grep -a KSUFDINST | tail -4
echo "★接下来 PC 侧 am force-stop + am start 官方 Manager，再截图看'工作中 版本'"
