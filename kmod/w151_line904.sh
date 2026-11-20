#!/system/bin/sh
# w151_line904.sh —— 把 packages.list 里那条**多出来的** `com.termux 10817` 的原始字节打出来。
# 目的只有一个：分清 ①"vivo 自己就有这行(格式与 AOSP 不同)"，还是 ②"我们哪一次实验写进去的残留"。
# ★块级重定向(理由见 w148_uid.sh 文件头)。
L=/data/local/tmp/w151_line.out
{
    echo "=== LINE904 up=$(cut -d' ' -f1 /proc/uptime) ==="
    echo "--- 总行数 ---"
    wc -l /data/system/packages.list
    echo "--- 所有以 com.termux 开头的行(带行号，整行) ---"
    grep -an '^com\.termux' /data/system/packages.list
    echo "--- 第 903~906 行的**原始字节**(看分隔符是空格还是 TAB、行尾有没有被截断) ---"
    sed -n '903,906p' /data/system/packages.list | od -c | head -24
    echo "--- 这个文件什么时候被改过(跨 boot 残留的唯一线索就是 mtime) ---"
    ls -l /data/system/packages.list /data/system/packages.xml 2>&1 | cut -c1-80
    echo "--- 谁还在这个 uid 上(sharedUserId 会让一行变多行) ---"
    awk '$2==10817{print "UID10817 " $1}' /data/system/packages.list | head -5
    echo "=== DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
