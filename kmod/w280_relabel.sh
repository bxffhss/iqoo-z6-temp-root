#!/system/bin/sh
# w280_relabel.sh —— #114 的**同发反向格**：执法态下把共享改道目标从 `apk_data_file:s0:c100,c200`
#   改回 plain `s0`，然后 app 侧再敲一次 `/system/bin/su -c id`。
#     改标签成功 + su 又出 root  ⇒ 单变量(只有 MLS 类别)双向闭合，本发一枪就够了；
#     改标签失败(shell 域没有 relabel 权) ⇒ 只能退回跨发对照(第 102 发 plain s0 + 执法 = root)，
#       那也是结论，只是弱一格。**两种都要打印标签回读**，不许靠"我执行了 chcon"。
O=/data/local/tmp/w280_relabel.out
exec >>"$O" 2>&1
T=/data/local/tmp/kd
echo "=== W280 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) ==="
echo "  改前: $(ls -ldZ $T 2>&1 | tr -s ' ')"
chcon u:object_r:apk_data_file:s0 "$T" 2>&1; echo "  chcon rc=$?"
echo "  改后: $(ls -ldZ $T 2>&1 | tr -s ' ')"
echo "  字节/md5 没动过吗: $(ls -l $T | tr -s ' ' | cut -d' ' -f5) $(md5sum $T 2>&1 | cut -c1-32)"
echo "  再确认执法态: enf=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c kernelsu /proc/modules)"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
