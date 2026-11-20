#!/system/bin/sh
# w150_why2.sh —— 只回答一个问题：`grep "^com.termux "` 为什么会命中**两行**？
# ★输出用**块级**重定向(`{ … } >"$L"`)，脚本级 `exec >` 之后再 `cat` 会自我喂入(第 45 发把
#   /data 写到 12.4GB)——规矩见 w148_uid.sh 文件头的警告。
L=/data/local/tmp/w150_why2.out
{
    echo "=== WHY2 up=$(cut -d' ' -f1 /proc/uptime) enf=$(getenforce) ==="
    echo "--- 命中的每一行(原样，带上字段号) ---"
    grep -an "^com.termux " /data/system/packages.list | head -4
    echo "--- 行数与 uid ---"
    echo "n=$(grep -ac '^com.termux ' /data/system/packages.list)"
    grep -a "^com.termux " /data/system/packages.list | awk '{print "FIELD1=" $1 " FIELD2=" $2}'
    echo "--- 同 uid 还挂在谁身上(packages.list 里 uid=10667 的所有包) ---"
    awk '$2==10667{print "SAMEUID " $1}' /data/system/packages.list | head -5
    echo "--- 这台机有几个 Android 用户(分身/平行空间会让同一个包出现多次) ---"
    pm list users 2>/dev/null | head -3
    echo "=== DONE up=$(cut -d' ' -f1 /proc/uptime) ==="
} >"$L" 2>&1
chmod 666 "$L"
cat "$L"
