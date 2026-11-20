#!/system/bin/sh
# w426_enforce.sh —— 实验格里"把 MAC 恢复成出厂的 Enforcing"这一腿，独立成一个文件的原因(§6.352⑤一手)：
#   ①这一发真正要读的判据只在**执法态**下才算数(Permissive 下的"成功"什么都不证明)；
#   ②可是一恢复执法，`suw→@suwksu` 那条 root 派单通道就被 SELinux 关了(`errno=13`)，
#     之后所有 `@sushd:` 腿全部派不出去(第 26 发就是这么丢了一条清理腿的)。
#   ⇒ 所以它必须是**窗口里最后一条 `@sushd:` 腿**：先跑完所有要 root 的腿，再跑这一条，最后才跑判据腿
#     (判据腿走 `@su:`/`@domsu:` 那条**不需要 socket** 的 su 路，执法态下照跑)。
#   ★派单前记得 chmod 755 本件(第 26 发一手：`@sushd:` 是直接 execve，adb push 留的 0666 会被拒，
#     只在 `sushd.log` 里留一行 `exit=126`——报告里看不到)。
echo "===== w426_enforce 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 之前=$(getenforce) ====="
echo 1 > /sys/fs/selinux/enforce 2>/dev/null; RF=$?
sync
sleep 1
echo "写 enforce rc=$RF 现值=$(getenforce) 文件值=$(cat /sys/fs/selinux/enforce 2>&1)"
echo "★这一步之后：@sushd 腿会 connectto 被拒(errno=13)；要判据请走 @su: 那条(不需要 socket)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
