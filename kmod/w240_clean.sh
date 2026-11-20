#!/system/bin/sh
# w240_clean.sh —— 删掉**第 100 发**留在 Termux 目录里的三枚文件，并用 root 腿自己的 `ls -lt` 复证。
#   为什么要重做：§6.223⑦ 我写的是"reboot 后由 app 自己 rm，ls 三行 No such file ⇒ 已清"。
#     这一发起点 root 腿量到 `kd2` mtime=18:47、`w230.sh` mtime=18:52(都是创建时刻) ⇒ **那次清理没生效**，
#     屏上那三行"不存在"与文件系统矛盾 ⇒ 判据换成人家删不动的口径：**root 腿删 + root 腿列目录**。
#   ★必须赶在翻执法之前跑：执法下 shell 域对 app_data_file 没有 unlink 权(§6.223⑦ 同一条)。
O=/data/local/tmp/w240_clean.out
exec >>"$O" 2>&1
D=/data/data/com.termux/files/usr/bin
H=/data/data/com.termux/files/home
echo "=== W240 清上发残留 up=$(cut -d' ' -f1 /proc/uptime) 域=$(cat /proc/self/attr/current 2>&1) enf=$(cat /sys/fs/selinux/enforce 2>&1) ==="
for f in "$D/kd2" "$D/w230.sh" "$H/w230.txt"; do
    rm "$f"; echo "  rm $f rc=$?"
done
echo "  复证(应只剩本发的 w240.sh 与历史那份 su):"
ls -lt "$D" 2>&1 | head -6 | tr -s ' ' | cut -c1-110
echo "  home 下探针输出: $(ls -l $H/w230.txt $H/w240.txt 2>&1 | tr -s ' ' | cut -d' ' -f5,9 | tr '\n' ' ')"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
