#!/system/bin/sh
# w543_kt.sh —— #170 的护栏直接凭据（P2）：由 root 往 /proc/ksu_install_fd 写一个**内核线程**的 pid。
#   预期（rc73）：出 `KSUFDINST NULLFILES skip`，任务不死、机器不复位；旧形状（rc67）这里应当踩空。
#   ★形状规矩：所有重定向写在脚本内部（打字链会吃掉 `>`）；工具一律绝对路径（root 壳 PATH 不全）。
OUT=/data/local/tmp/w543_kt.out
: > "$OUT"
chmod 666 "$OUT" 2>/dev/null
echo "== 身份与起点 ==" >> "$OUT"
/system/bin/id >> "$OUT" 2>&1
echo "enforce=$(getenforce)" >> "$OUT" 2>&1
echo "uptime=$(cut -d. -f1 /proc/uptime)" >> "$OUT"
echo "== 挑一个内核线程 pid（PPid=2 的那些就是） ==" >> "$OUT"
KT=""
NC=0
for P in /proc/[0-9]*; do
    N=${P#/proc/}
    PP=$(/system/bin/grep -a "^PPid:" "$P/status" 2>/dev/null | /system/bin/tr -dc 0-9)
    [ "$PP" = 2 ] || continue
    NM=$(/system/bin/cat "$P/comm" 2>/dev/null)
    HAS=$(/system/bin/ls "$P/fd" 2>/dev/null | /system/bin/wc -l | /system/bin/tr -dc 0-9)
    NC=$((NC + 1))
    [ "$NC" -le 6 ] && echo "候选 pid=$N comm=[$NM] fd表条数=${HAS:-读不到}" >> "$OUT"
    [ -n "$KT" ] || KT=$N
done
echo "内核线程候选数=$NC 选中 KT=$KT" >> "$OUT"
echo "== 写触发口 A：内核线程 pid（护栏应当挡下） ==" >> "$OUT"
if [ -n "$KT" ]; then
    /system/bin/echo "$KT" > /proc/ksu_install_fd 2>>"$OUT"
    echo "A write_rc=$? KT=$KT up=$(cut -d. -f1 /proc/uptime)" >> "$OUT"
else
    echo "A 没挑到内核线程 pid ⇒ 这一格没测到" >> "$OUT"
fi
echo "== 写触发口 B：正对照＝活着的官方 Manager 的 pid（应当正常装上） ==" >> "$OUT"
MP=$(/system/bin/pidof me.weishu.kernelsu | /system/bin/cut -d' ' -f1)
if [ -n "$MP" ]; then
    /system/bin/echo "$MP" > /proc/ksu_install_fd 2>>"$OUT"
    echo "B write_rc=$? MP=$MP up=$(cut -d. -f1 /proc/uptime)" >> "$OUT"
else
    echo "B 没在跑的 Manager ⇒ 正对照没测到" >> "$OUT"
fi
echo "== 等 3 秒看回执 ==" >> "$OUT"
/system/bin/sleep 3
echo "uptime_after=$(cut -d. -f1 /proc/uptime)" >> "$OUT"
echo "mod=$(grep -ac kernelsu /proc/modules)" >> "$OUT"
echo "== dmesg 里 KSUFDINST 最近 8 行 ==" >> "$OUT"
/system/bin/dmesg 2>/dev/null | /system/bin/grep -a KSUFDINST | /system/bin/tail -8 >> "$OUT" 2>&1
echo "== skip 计数 / 回调计数 ==" >> "$OUT"
D=$(/system/bin/dmesg 2>/dev/null)
echo "skip=$(printf '%s' "$D" | /system/bin/grep -ac 'NULLFILES skip')" >> "$OUT"
echo "queued=$(printf '%s' "$D" | /system/bin/grep -ac '已排队给')" >> "$OUT"
echo "ran=$(printf '%s' "$D" | /system/bin/grep -ac '回调跑在')" >> "$OUT"
echo "== DONE ==" >> "$OUT"
