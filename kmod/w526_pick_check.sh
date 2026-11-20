#!/system/bin/sh
# w526_pick_check.sh —— 0 枪：在**真机 /proc** 上验 §6.391 那条修法的两个前提。
#   ①失效模式真实存在吗：并发拉几个 app，快速采样 pidof zygote64，看会不会出现"不止一个 pid"。
#   ②ppid=1 这个判据选出来的，是不是真的 zygote？——用一个**独立的**证人交叉核：system_server 的父亲
#     就是生它的那个 zygote(init 只把 zygote 当服务起，system_server 又是 zygote fork 出来的)。
#   ★只读＋只拉起 app(可逆)，不碰漏洞、不 insmod。工具一律绝对路径，重定向写在脚本内部(记忆里那条 Termux 坑)。
exec >/data/local/tmp/w526_pick.txt 2>&1
echo "=== up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(/system/bin/getenforce) mod=$(grep -c kernelsu /proc/modules) ==="
SELF=/data/local/tmp/ksu_fd_keepalive.sh
[ -f "$SELF" ] || echo "[!] 包内 helper 不在(它是 §6.388 那段字节的唯一副本)⇒ 用包里的 ksu_post.sh 现场抽一份"
if [ ! -f "$SELF" ]; then
    sed -n '/# FDKA-BE[GIN]/,/# FDKA-EN[D]/p' /sdcard/z6root/ksu_post.sh > "$SELF"
fi
echo "helper 字节=$(wc -c < $SELF) md5=$(md5sum $SELF | cut -d' ' -f1)"
# 把抽出来的那段喂进来，只为拿到 pick_zygote(不执行循环本体)
. "$SELF" >/dev/null 2>&1
LOGK=/data/local/tmp/w526_pick.log; PRCK=/proc; FBL=0
: > "$LOGK"
SS=$(pidof system_server | cut -d' ' -f1)
AUTH=$(cut -d' ' -f4 "/proc/$SS/stat" 2>/dev/null | tr -dc '0-9')
echo "独立证人：system_server=[$(pidof system_server)] 它的父亲(=真 zygote)=[$AUTH]"
echo "---- 1) 静态一次：pick_zygote 选到谁 ----"
P1=$(pick_zygote zygote64)
echo "raw pidof=[$(pidof zygote64)] picked=[$P1] 与独立证人相符=$([ "$P1" = "$AUTH" ] && echo YES || echo NO)"
echo "---- 2) 并发拉 app，采样 12 次看会不会出现多候选 ----"
i=0; MULTI=0; MAXN=0; MISMATCH=0
while [ "$i" -lt 12 ]; do
    i=$((i + 1))
    case "$i" in
        1|5|9)  /system/bin/am start -n com.termux/.app.TermuxActivity >/dev/null 2>&1 ;;
        2|6|10) /system/bin/am start -n me.weishu.kernelsu/.ui.MainActivity >/dev/null 2>&1 ;;
        3|7|11) /system/bin/am start -n com.termux/.app.TermuxActivity >/dev/null 2>&1 ;;
    esac
    RAW=$(pidof zygote64)
    N=$(echo $RAW | wc -w)
    [ "$N" -gt "$MAXN" ] && MAXN=$N
    [ "$N" -gt 1 ] && MULTI=$((MULTI + 1))
    PK=$(pick_zygote zygote64)
    [ "$PK" != "$AUTH" ] && MISMATCH=$((MISMATCH + 1))
    echo "  第 $i 次：候选数=$N raw=[$RAW] picked=[$PK] 对得上独立证人=$([ "$PK" = "$AUTH" ] && echo Y || echo N)"
    /system/bin/sleep 1
done
echo "---- 3) 结论读数(全部由本脚本现数) ----"
echo "出现过多个候选的采样次数=$MULTI/12  最多同时看到候选数=$MAXN"
echo "pick_zygote 选错(与独立证人不符)的次数=$MISMATCH/12"
echo "FALLBACK 行数=$(grep -ac 'ZG_FALLBACK' $LOGK 2>/dev/null)"
echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime)"
