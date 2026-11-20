#!/usr/bin/env bash
# w553_drive.sh —— 第 43 发的窗口内驱动器：一见到 mod=1 就(1)抢在 RACE 那 30 秒里拍官方 Manager 首页，
#   (2)把 w552_root_bundle.sh 一次派进 root agent，(3)把派发后的读数拉回来。
#   为什么要有它：第 41 发我把派单发在复位之后＝白烧；窗口寿命实测从 +30 秒到 +20 分钟都有，节拍必须自动化。
set -u
cd "$(dirname "$0")/.." || exit 1
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence
for i in $(seq 1 600); do
    M=$(A 'grep -c kernelsu /proc/modules' | tr -dc '0-9')
    [ "$M" = 1 ] && break
    [ $((i % 20)) = 0 ] && echo "  等 mod=1 第 $i 次 up=$(A 'cut -d. -f1 /proc/uptime')"
    sleep 2
done
[ "${M:-0}" = 1 ] || { echo "[x] 没等到 mod=1 ⇒ 这一发没开窗，别按开窗了去读产物"; exit 7; }
echo "  mod=1 于 up=$(A 'cut -d. -f1 /proc/uptime') 本机 $(date +%H:%M:%S)"
# 1) RACE 期内先拍首页(截图＋无障碍树各一份)
A 'input keyevent 224' >/dev/null
A 'screencap -p /data/local/tmp/w553_home_race.png; uiautomator dump /data/local/tmp/w553_home_race.xml >/dev/null 2>&1; ls -l /data/local/tmp/w553_home_race.* 2>&1 | tail -2'
MSYS_NO_PATHCONV=1 adb pull //data/local/tmp/w553_home_race.png "$EV/w553_home_race.png" >/dev/null 2>&1
MSYS_NO_PATHCONV=1 adb pull //data/local/tmp/w553_home_race.xml "$EV/w553_home_race.xml" >/dev/null 2>&1
echo "  首页两件：png=$(wc -c < "$EV/w553_home_race.png" 2>/dev/null) xml=$(wc -c < "$EV/w553_home_race.xml" 2>/dev/null)"
grep -aoE '越狱模式|工作中|不支持|版本：[0-9]+-[0-9]+' "$EV/w553_home_race.xml" 2>/dev/null | sort -u | sed 's/^/    首页读数: /'
# 2) 派发 root _bundle（一次一单，所以所有事都写在里面）
A 'am start -f 0x4000000 -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:/data/local/tmp/w552_root_bundle.sh"' >/dev/null
echo "  已派发 w552_root_bundle.sh，等它写第一格(#167＋授权)"
for j in $(seq 1 30); do
    sleep 2
    S=$(A 'wc -c < /data/local/tmp/w552_root.out 2>/dev/null' | tr -dc '0-9')
    [ "${S:-0}" -gt 60 ] 2>/dev/null && { echo "  产物 $S 字节（派发后 $((j * 2)) 秒）"; break; }
done
A 'cat /data/local/tmp/w552_root.out 2>&1' | sed 's/^/  | /'
