#!/system/bin/sh
# w450_close.sh —— 第 31 发的"根侧收尾"替代腿：本发名单里没有 suw ⇒ 收尾件那两条 `@sushd:` 派单不会有人接，
#   而 /data/adb/ksu/.allowlist 里留着你这个 app 的条目 ⇒ 在还有 root 通道时把它删净(**不留脚印**)。
#   ★10-22 改正这句的理由(第 37 发一手)：**不是**"不删就会把下一发的形状悄悄换掉"——每次装载前 stage 都会用当次参数
#     把那份文件整份重写(一手：`★落盘读回：…字节=792 条目=(uid,key)` 打在 insmod 之前 2 秒)，所以上一发的条目
#     带不进下一发的装载期。删它的意义是**卫生**：名单里不该长期留着谁被授过权。行为一行没改，只改了这两行注释。
#   ★所有重定向都写在脚本内部(exec >)：往 Termux 里 `input text` 长命令会被输入法吃掉 `>`(第 31 发实测)。
#   ★★第 55 发两条新规矩(一手＝第 54 发这条腿的同族缺陷被实测抓出来，md §6.427)：
#     ①**维持件的 kill switch 要第一个删**，并等它自己退(节拍 20 秒，给 25 秒)——不删就留着一条每 20 秒看一次挂载的循环；
#     ②**umount 没真把挂载行收回，就不许删 bind 的源**：失败后照样 `rm -rf` 源，当场就把 mountinfo 写成
#       `…/pbin//deleted` ⇒ **整层 `/product/bin` 变空壳、裸 su 与 Manager 的落点一起没**(今晚那次坏态的形状)。
#       留着一份"挂着但完整"的源不算是坏事：挂载不活过 reboot，源目录 root-only，下一发装载前 stage 的前置闸会重建它。
exec >/sdcard/w450_close.txt 2>&1
#   ★权限要排在写第一行**之前**：第 54 发那条腿把 chmod 放在末尾，而末尾恰好是恢复执法那一步之后 ⇒ 执法一开，
#     产物永远是 0600 root，谁都读不回来(那三项收尾判据就全成了"未复证")。这里落 /sdcard 本来就能读，仍然显式补一道。
/system/bin/chmod 666 /sdcard/w450_close.txt 2>/dev/null
echo "=== CLOSE up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(/system/bin/getenforce) mod=$(grep -c kernelsu /proc/modules) ==="
#   ★第 32 发一手：这行原来写的是裸 `getenforce` ⇒ root 壳 PATH 里没有它，症状是 `6: getenforce: not found`
#     而**整行照打**、只是 `enf=` 后面空着(缺读数，不是假读数)。工具一律绝对路径。
echo "----- [0] 维持件：先删 kill switch，等它自退 -----"
/system/bin/rm -f /data/local/tmp/ksu_pbin_keep; echo "killswitch_rm_rc=$?"
/system/bin/sleep 25
echo "KEEPER_LEFT=$(/system/bin/pgrep -f w774_pbin_keeper >/dev/null 2>&1 && echo 还在 || echo 退了)"
echo "     keeper 日志尾=[$(/system/bin/tail -1 /data/local/tmp/w774_keeper.log 2>/dev/null | /system/bin/cut -c1-90)]"
echo "----- [1] 收回 /product/bin 的挂载 -----"
/system/bin/umount /product/bin; UM1=$?
ML=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null | tr -dc '0-9')
if [ "${ML:-1}" != 0 ]; then
    /system/bin/umount -D /product/bin; UM2=$?
    ML=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null | tr -dc '0-9')
else
    UM2=没重试
fi
echo "umount_rc=$UM1 umount_retry_rc=$UM2 MOUNT_LEFT=${ML:-读数取不到} bin=$(ls -A /product/bin 2>/dev/null | wc -l) su=$(ls /product/bin/su 2>&1 | head -1)"
echo "----- [2] /data/adb -----"
echo "清之前 /data/adb=[$(ls -a /data/adb 2>&1 | tr '\n' ' ')]"
rm -f /data/adb/ksu/.allowlist; echo "rm_allow_rc=$?"
rm -rf /data/adb/su; echo "rm_su_rc=$?"
#   ★第 32 发一手：`清之后 /data/adb=[. .. .suwtest ksu ksud]` ⇒ 那份 `/data/adb/ksud` 是 stage 自己 cp 进去的
#     (`ksu_ksud_path` 走的是 /data/local/tmp/kd，所以它是纯脚印、没 ko 时没能力)，旧版这条腿漏了它。
rm -f /data/adb/ksud; echo "rm_ksud_rc=$?"
if [ "${ML:-1}" = 0 ]; then
    rm -rf /data/adb/ksu/pbin /data/adb/ksu/sustatic; echo "rm_pbin_src_rc=$? 复证=[$(ls -d /data/adb/ksu/pbin /data/adb/ksu/sustatic 2>&1 | tr '\n' '|')]"
else
    echo "★挂载行还剩 ${ML} ⇒ **不删 bind 的源**(删了就当场造出 //deleted 空壳)；源与落点副本留给下一发 stage 的前置闸 rm -rf 重建"
fi
echo "----- [3] /data/local/tmp 的脚印 -----"
rm -rf /data/local/tmp/pbin /data/local/tmp/newbin /data/local/tmp/subin; echo "rm_dirs_rc=$?"
#   ★10-22 18:2x：包里现在**默认铺**那把常驻补装开关(`kmod/z6root.sh` 与 `ksu_race_fd` 并排那句 `touch`)，
#     于是每发都会产生这三个名字：开关本体／stage 自己抽出的 helper／它的日志。`/data/local/tmp` 活过重启
#     ⇒ 不删就是"靠下一次顺手清"（我们登记过的坏形状）。删掉**开关本体**就等于让那条循环自己写 `FDKA STOP`
#     退出（它每轮读一次开关），不需要 pkill、不会留孤儿进程。
rm -f /data/local/tmp/ksu_fd_keepalive /data/local/tmp/ksu_fd_keepalive.sh /data/local/tmp/ksu_fd_keepalive.log; echo "rm_fdka_rc=$?"
#   ★第 54 发起维持件也会产生日志与开关(开关已在 [0] 删)；这里是产物名不是工具名，工具 `.sh` 按规矩留着。
rm -f /data/local/tmp/w774_keeper.log; echo "rm_keeperlog_rc=$?"
echo "ALLOW_LEFT=[$(ls -l /data/adb/ksu/.allowlist 2>&1 | head -1)]"
echo "FDKA_LEFT=[$(ls -a /data/local/tmp 2>/dev/null | grep -a ksu_fd_keepalive | tr '\n' ' ')]"
echo "KEEPER_NAMES=[$(ls -a /data/local/tmp 2>/dev/null | grep -aE 'ksu_pbin_keep|w774_keeper' | tr '\n' ' ')]"
echo "清之后 /data/adb=[$(ls -a /data/adb 2>&1 | tr '\n' ' ')]"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) enf=$(/system/bin/getenforce) MOUNT_LEFT=$(grep -ac pbin /proc/self/mountinfo) —— ★这条腿只到「收回挂载＋删净脚印」；恢复执法由包里另一步做，且必须排在所有 root 腿之后"
