#!/system/bin/sh
# w425_clean.sh —— 第 26 发窗口内(root 腿，判活之后)清理本发手工铺的东西，**在 reboot 之前**跑。
#   ★为什么必须 root 腿跑：`/data/local/tmp/kd` 现在是 root:root + `apk_data_file` 标签，
#     shell 域删不动(§6.343③ 那条硬限制)，而它跨 boot 会留着 ⇒ 下一发同名 pull 的读数会被造假。
#   本脚本只删上面那几个名字，不碰别的；收尾仍由 kmod/w161_teardown.sh 走（umount→杀看门狗→清载荷→reboot→复核）。
D=/data/local/tmp
echo "===== w425_clean 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) ====="
for f in kd zzsh ksu_dom ksu_shbin w425_swap.sh w425_clean.sh sustatic; do
    rm -f "$D/$f" 2>&1
done
sleep 2
echo "删后 ls（都该 No such file）:"
ls -l $D/kd $D/zzsh $D/ksu_dom $D/ksu_shbin $D/w425_swap.sh $D/sustatic 2>&1
echo "★复证（等过一个节拍再查，防按行写者把名字重建，例 97）：$(ls $D/kd $D/zzsh 2>&1 | tr '\n' ' ')"
echo "/data/local/tmp 里本线名字还剩：$(ls $D | grep -aE '^(kd|zzsh|ksu_dom|ksu_shbin|w425_)' | tr '\n' ' ')"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
