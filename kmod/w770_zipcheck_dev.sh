#!/system/bin/sh
# w770_zipcheck_dev.sh —— 只验一件事：**分发件(z6root.zip)在手机上解开后仍然自洽**（0 枪，不 punch）。
#   为什么要它：第 53 发认证的是 `adb push` 上去的目录，而你拿到的是 zip ⇒ 中间多一步"手机上解压"，
#   那一步能坏的是**文件名(尤其中文条目)与字节**；包里 z6root.sh 的 MANIFEST 核对正好会撞在这一点上。
Z=z6root_fromzip.zip
cd /sdcard || { echo "[x] 没有 /sdcard"; exit 1; }
echo "起点 up=$(cut -d' ' -f1 /proc/uptime) zip=$(md5sum $Z 2>/dev/null | cut -c1-32) 字节=$(wc -c < $Z 2>/dev/null)"
echo "unzip 在哪=[$(which unzip 2>/dev/null)]"
rm -rf zz 2>/dev/null; mkdir zz
unzip -q "$Z" -d zz 2>&1 | head -3
echo "解出来的顶层=[$(ls /sdcard/zz 2>/dev/null | tr '\n' ' ')]"
cd /sdcard/zz/z6root 2>/dev/null || { echo "[x] 解压后没有 z6root/ 这一层 ⇒ 目录名或结构不对"; exit 1; }
n=0; b=0
while read name size md; do
    [ -n "$name" ] || continue
    a=$(md5sum "$name" 2>/dev/null | cut -c1-32)
    if [ "$a" = "$md" ]; then n=$((n + 1)); else b=$((b + 1)); echo "  [BAD] $name 实得=$a 清单=$md"; fi
done < MANIFEST
echo "MANIFEST 核对：相符=$n 不符=$b ｜ 目录件数=$(ls -1 | grep -ac .)"
echo "中文条目在不在=[$(ls -1 | grep -a 教程 | tr '\n' ' ')]"
echo "包内 ko=$(md5sum kernelsu.ko 2>/dev/null | cut -c1-32)"
cd /sdcard && rm -rf zz "$Z" 2>/dev/null
echo "清理=[$(ls -1 /sdcard | grep -aE '^zz$|fromzip' | tr '\n' ' ')](应为空)"
echo "=== DONE 末行 up=$(cut -d' ' -f1 /proc/uptime) ==="
