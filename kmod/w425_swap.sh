#!/system/bin/sh
# w425_swap.sh —— 第 26 发窗口内的一条腿(判活之后才跑)：把 su 改道落点 `/data/local/tmp/kd` 里的二进制
#   从 v3 换成 v4，好让 §1.69 的 `SHBIN` 开关真的走 su 那条路。
#   ★为什么要这条腿(这一发抓出来的工具链缺口，一手)：`kmod/push_ksu.sh` 的 `SHIM=cm57/sustatic`(v3)
#     推上机后**改名叫 ksud**，stage 再 `cp ksud → kd` ⇒ su 改道跑的那支从来不是 go.sh 第 5 步推的 `/data/local/tmp/sustatic`。
#     go.sh §1.69 只切了 bind(`/product/bin/su`)那条腿，redirect 这条腿没被切 ⇒ 本发用既有 root 信道手工换并读回。
#   换法：cp 到 .tmp → chmod/chcon → mv 覆盖(同目录，标签跟着走)。全程只读回，不做任何提权动作。
D=/data/local/tmp
echo "===== w425_swap 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) ====="
echo "换前 kd ：md5=$(md5sum $D/kd 2>&1 | cut -c1-32) $(ls -lZd $D/kd 2>&1 | tr -s ' ' | cut -d' ' -f1,5,9)"
echo "v4 源  ：md5=$(md5sum $D/sustatic 2>&1 | cut -c1-32) 字节=$(wc -c < $D/sustatic 2>/dev/null)"
cp $D/sustatic $D/kd.tmp 2>&1; RCP=$?
chmod 755 $D/kd.tmp 2>&1; chcon u:object_r:apk_data_file:s0 $D/kd.tmp 2>&1
mv -f $D/kd.tmp $D/kd 2>&1; RMV=$?
echo "cp=$RCP mv=$RMV"
echo "换后 kd ：md5=$(md5sum $D/kd 2>&1 | cut -c1-32) $(ls -lZd $D/kd 2>&1 | tr -s ' ' | cut -d' ' -f1,5,9) 字节=$(wc -c < $D/kd 2>/dev/null)"
echo "zzsh   ：md5=$(md5sum $D/zzsh 2>&1 | cut -c1-32) $(ls -lZd $D/zzsh 2>&1 | tr -s ' ' | cut -d' ' -f1,5,9)"
echo "ksu_shbin 内容=[$(cat $D/ksu_shbin 2>&1)]"
echo "ksu_dom  内容=[$(cat $D/ksu_dom 2>&1)]"
# ★把 MAC 恢复成**出厂态 Enforcing**——这一发的正题是"调用者域下能不能 exec 那份壳"，
#   而 punch 之后整窗是 Permissive(21:23:53 一手：stage 起手就 `enforce=Permissive`)⇒ Permissive 下的
#   "成功"什么都不证明。这里是**往严的方向恢复**，不是放宽；恢复动作本身由 root 腿做，做完立刻读回。
echo 1 > /sys/fs/selinux/enforce 2>/dev/null; RF=$?
sync
sleep 1
echo "恢复执法：写 rc=$RF 现值=$(getenforce 2>&1) 文件值=$(cat /sys/fs/selinux/enforce 2>&1)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
