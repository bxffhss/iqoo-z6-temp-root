#!/system/bin/sh
# w450_close.sh —— 第 31 发的"根侧收尾"替代腿：本发名单里没有 suw ⇒ 收尾件那两条 `@sushd:` 派单不会有人接，
#   而 /data/adb/ksu/.allowlist 是**下一发装载时会读进去的东西**(跨 boot 有真实内核效应) ⇒ 必须在还有 root 通道时删掉。
#   ★所有重定向都写在脚本内部(exec >)：往 Termux 里 `input text` 长命令会被输入法吃掉 `>`(第 31 发实测)。
exec >/sdcard/w450_close.txt 2>&1
echo "=== CLOSE up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(/system/bin/getenforce) ==="
#   ★第 32 发一手：这行原来写的是裸 `getenforce` ⇒ root 壳 PATH 里没有它，症状是 `6: getenforce: not found`
#     而**整行照打**、只是 `enf=` 后面空着(缺读数，不是假读数)。工具一律绝对路径。
/system/bin/umount /product/bin
echo "umount_rc=$?"
echo "MOUNT_LEFT=$(grep -ac pbin /proc/self/mountinfo) bin=$(ls -A /product/bin | wc -l) su=$(ls /product/bin/su 2>&1 | head -1)"
echo "清之前 /data/adb=[$(ls -a /data/adb 2>&1 | tr '\n' ' ')]"
rm -f /data/adb/ksu/.allowlist; echo "rm_allow_rc=$?"
rm -rf /data/adb/su; echo "rm_su_rc=$?"
#   ★第 32 发一手：`清之后 /data/adb=[. .. .suwtest ksu ksud]` ⇒ 那份 `/data/adb/ksud` 是 stage 自己 cp 进去的
#     (`ksu_ksud_path` 走的是 /data/local/tmp/kd，所以它是纯脚印、没 ko 时没能力)，旧版这条腿漏了它。
rm -f /data/adb/ksud; echo "rm_ksud_rc=$?"
rm -rf /data/local/tmp/pbin /data/local/tmp/newbin /data/local/tmp/subin; echo "rm_dirs_rc=$?"
echo "ALLOW_LEFT=[$(ls -l /data/adb/ksu/.allowlist 2>&1 | head -1)]"
echo "清之后 /data/adb=[$(ls -a /data/adb 2>&1 | tr '\n' ' ')]"
echo "===== DONE"
