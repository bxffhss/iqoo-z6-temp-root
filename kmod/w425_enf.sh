#!/system/bin/sh
# w425_enf.sh —— 第 26 发窗口里的"执法位"腿：$1=1 把 MAC 置 Enforcing；$1=0 放回 Permissive。
#   ★为什么必须有这条：本机的 Permissive 是**我们自己的 ko 在装载那一刻翻的**(stage 起点那行
#     `id=0 enforce=Permissive` 为证，21:23:53)——不是出厂态。而 #117 这一格问的是
#     **"执法下 app 域能不能 exec 这份壳"**，在 Permissive 里拿到"能"等于没测(§6.225 那三条权限
#     在 Permissive 下根本不执法)。⇒ 决定性那半必须在 Enforcing 下取，取完放回。
#   ★方向账：置 1 是**恢复出厂方向**(安全)；放回 0 才是放宽(例 58 记的是"恢复不许依赖 root 腿"，
#     这里两条都带 getenforce 读回，且收尾反正要 reboot 回出厂态)。
D=/data/local/tmp
WANT=${1:-}
echo "===== w425_enf 参数=[$WANT] 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) ====="
case "$WANT" in
  1) echo 1 > /sys/fs/selinux/enforce 2>$D/w425_enf_err.txt; RC=$? ;;
  0) echo 0 > /sys/fs/selinux/enforce 2>$D/w425_enf_err.txt; RC=$? ;;
  *) echo "用法：w425_enf.sh <1|0>"; RC=2 ;;
esac
echo "写 /sys/fs/selinux/enforce rc=$RC 错误=[$(cat $D/w425_enf_err.txt 2>&1 | head -1)]"
echo "现在 getenforce=$(getenforce) 文件现值=$(cat /sys/fs/selinux/enforce 2>&1)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
