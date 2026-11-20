#!/system/bin/sh
# w208_install.sh —— root 侧短腿：把"su 之后该读什么"的探针脚本装进 Termux 自己的 home。
#   为什么放 /data/data/com.termux/... 而不是 /data/local/tmp：
#     被测的那个 root 壳**域还是 untrusted_app**(§6.206 正是测这个)，它读 /data/local/tmp 可能被 sepolicy 按域拦，
#     拦了就会把"域不通"误读成"su 失败"。放自己的 home 里，写得到写不到本身就是读数。
O=/data/local/tmp/w208_install.out
exec >"$O" 2>&1
H=/data/data/com.termux/files/home
echo "=== W208 装探针 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
cat >"$H/w208.sh" <<'PEOF'
{
    echo "== up=$(cut -d' ' -f1 /proc/uptime)"
    echo "id=[$(id)]"
    echo "attr_current=[$(cat /proc/self/attr/current 2>&1)]"
    # ★原来这格写的是 `getenforce`，§6.207 的存证里它是 `getenforce: not found`(那个壳的 PATH 里没有) ⇒
    #   我们从来没读到过 su 壳里的执法状态。改成读文件，不依赖 PATH。
    echo "enf_file=[$(cat /sys/fs/selinux/enforce 2>&1)]"
    echo "PATH=[$PATH]"
    echo "cap_eff=[$(grep -m1 CapEff /proc/self/status 2>&1)]"
    echo "seccomp=[$(grep -m1 Seccomp /proc/self/status 2>&1)]"
    echo "ns_mnt=[$(readlink /proc/self/ns/mnt 2>&1)]"
    echo "ps_self=[$(ps -Z -p $$ -o seinfo,ctx 2>&1 | tail -2 | tr '\n' ' ')]"
    echo "try_shell_data_file=[$(head -c 3 /data/local/tmp/w184_sample.out 2>&1 | tr -d '\n')]"
    # ★用 od 打，别用裸 head：0x7F 在 adb 传输里会丢(§6.209 那次显示成 `EL` 就是这个)，
    #   而且失败时要把 errno 文本一起带回来，不能只留一个空(空=读不到?还是读到了但字节被吃了?分不开)。
    echo "try_system_file=[$(head -c 3 /system/bin/sh 2>&1 | od -An -c 2>&1 | tr -d ' \n')]"
    # ★§6.211②那堵墙就测这一格：shell 域的 root 能不能读官方模板目录(执法态由 enf_file 那行自己带)
    echo "try_template_dir=[$(ls /data/adb/ksu/profile/templates 2>&1 | tr '\n' ' ')]"
    echo "try_template_cat=[$(head -c 24 /data/adb/ksu/profile/templates/vivoshell.root 2>&1 | tr -d '\n')]"
} > /data/data/com.termux/files/home/w208.txt 2>&1
chmod 644 /data/data/com.termux/files/home/w208.txt 2>/dev/null
PEOF
chmod 644 "$H/w208.sh"
chown 10667:10667 "$H/w208.sh" 2>/dev/null
ls -lZ "$H/w208.sh" 2>&1
echo "探针内容行数=$(wc -l < "$H/w208.sh" 2>/dev/null)"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
