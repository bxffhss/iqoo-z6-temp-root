#!/system/bin/sh
# w212_shellread.sh —— 一发读清两格：
#   (A) **Enforcing 下 `u:r:shell:s0` 这个域能不能读模板目录** —— 这就是"官方 UI + 自制模板"那条路唯一的墙：
#       列模板/读模板走的是 Manager 的 libsu root 壳(`KsuCli.kt:588~598`)，而 rc67 下那个壳的域正是 shell。
#   (B) 顺手把 #55 钉一格：本腿自己 `setenforce 1` 做实验、结束**原样恢复**，before/after 都带时刻。
# ★纪律：读数要打印**转换后的域本身**(`id -Z`)，不能拿"runcon 没报错"当"转换成功"(例49/例52)；
#   嵌套引号是 Git Bash 的老坑，所以内层单独落成一份文件再 runcon，不写三层引号。
O=/data/local/tmp/w212_shellread.out
exec >"$O" 2>&1
I=/data/local/tmp/w212_inner.sh
D=/data/adb/ksu/profile/templates
LIB=$(ls /data/app/*/me.weishu.kernelsu-*/lib/arm64/libksud.so 2>/dev/null | head -1)
BEFORE=$(getenforce)
echo "=== W212 shell 域能不能读模板 up=$(cut -d' ' -f1 /proc/uptime) 起点 enf=$BEFORE uid=$(id -u) 本腿域=$(id -Z 2>&1) ==="
echo "LIB=[$LIB]"
setenforce 1 2>&1
echo "setenforce 1 之后 enf=$(getenforce) up=$(cut -d' ' -f1 /proc/uptime)"

echo "--- (A1) 本腿自己的域直接读，当正对照 ---"
ls -lZ "$D" 2>&1
"$LIB" profile list-templates 2>&1 | sed 's/^/    /'

cat >"$I" <<'IEOF'
{
    echo "  转换后域=[$(id -Z 2>&1)]"
    echo "  uid=[$(id)]"
    echo "  列模板目录: [$(ls /data/adb/ksu/profile/templates 2>&1)]"
    echo "  cat 模板头 24 字节: [$(head -c 24 /data/adb/ksu/profile/templates/vivoshell.root 2>&1)]"
    L=$(ls /data/app/*/me.weishu.kernelsu-*/lib/arm64/libksud.so 2>/dev/null | head -1)
    RES=$("$L" profile list-templates 2>&1)
    echo "  官方 CLI list-templates(shell 域) rc=$? 输出=[$RES]"
    echo "  已知答案对照 head -c3 /system/bin/sh=[$(head -c 3 /system/bin/sh 2>&1)]"
} 2>&1
IEOF
chmod 755 "$I"
sh -n "$I" && echo "内层脚本 sh -n OK" || echo "★内层脚本语法就没过 ⇒ 下面别读"
echo "--- (A2) ★换成 u:r:shell:s0 跑同一套(Manager root 壳的权限形状) ---"
runcon u:r:shell:s0 sh "$I" > /data/local/tmp/w212_inner.out 2>&1
RRC=$?
sed 's/^/  /' /data/local/tmp/w212_inner.out
echo "  (runcon rc=$RRC)"

echo 1 > /sys/fs/selinux/enforce 2>/dev/null
case "$BEFORE" in
  Permissive) echo 0 > /sys/fs/selinux/enforce ;;
esac
echo "恢复之后 enf=$(getenforce) (起点=$BEFORE) up=$(cut -d' ' -f1 /proc/uptime)"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
