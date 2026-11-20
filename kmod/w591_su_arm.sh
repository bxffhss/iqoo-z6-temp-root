#!/usr/bin/env bash
# w591_su_arm.sh —— 第 47 发的 A/B 两臂打字腿：`bash kmod/w591_su_arm.sh <A|B>`
#   在 Termux 里敲一条**单 token** 的 su 命令(避开 #208)，判据只押两样：
#     主判据＝ PC 侧无 root 读 **marker 文件的数字属主**(uid=0 ⇒ 提权成立 / uid=10667 ⇒ 没提权)；
#     次判据＝ 屏幕(截图＋无障碍树)——#116 说过 root 写不回终端，所以屏幕只是"命令确实敲进去了"的证人。
#   ★A 臂(Permissive)是 B 臂的**正对照**：属主这个判别式必须在 A 臂动过，B 臂读到 10667 才算数(例 164/155)。
#   打字坑(全在这台的记忆里)：新会话吞首字符⇒先暖一行；空格＝%s；引号与 > 会被吃掉⇒命令里没有；
#   force-stop 重开也算新会话⇒每臂都重暖。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
TAG="${1:-}"
case "$TAG" in A|B) ;; *) echo "用法: bash kmod/w591_su_arm.sh <A|B>"; exit 2 ;; esac
W=kmod/w103_evidence
M=/data/local/tmp/w590_enf_marker
L=/data/local/tmp/w590_enf.out
CMD='/system/bin/su%s-c%s/data/local/tmp/w590_enf_marker.sh'
A() { adb shell "$1" 2>&1 | tr -d '\r'; }

echo "=== 0) 现态 + ★闸：marker 必须不在(在⇒这一臂的属主读数会读到上一臂的) ==="
A 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) tmx=$(pidof com.termux)'
A "rm -f $M $L" >/dev/null
# ★判别式只认整行的 PRESENT/ABSENT：原来我 grep 路径本身，而 `ls` 的**错误消息里就带这个路径**
#   ⇒ 文件不存在时也会命中(例 166① 那一类：从错误文本里抠读数)。
PRE=$(A "test -e $M && echo PRESENT || echo ABSENT" | tr -d ' \r\n')
if [ "$PRE" = PRESENT ]; then
    echo "  [x] marker 还在 ⇒ 停(别把上一臂的属主当这一臂的)"
    A "ls -ln $M" | sed 's/^/    /'; exit 3
fi
echo "  marker 起始状态=[$PRE](必须逐字 ABSENT ⇒ 这一臂的属主才是新产生的)"

echo "=== 1) 起 Termux + 焦点确认 + 暖行 ==="
A 'am start -n com.termux/.app.TermuxActivity' >/dev/null; sleep 6
A 'dumpsys window | grep -a mFocusedApp | head -1' | sed 's/^/  焦点=/'
# ★暖行不能用 `#warm`：`#` 在 mksh 里是**词首**注释符，`input text #warm` 会被截成 `input text`(命令根本没带参数)。
#   用 echo + %s，敲进去会在屏上回显 warm ⇒ 顺带证"这个终端此刻收得到字"。
A 'input text echo%swarm; input keyevent 66' >/dev/null; sleep 2

echo "=== 2) 敲那一条 su 命令(单个 token，载荷已在设备上) ==="
A "input text $CMD; input keyevent 66"
sleep 9

echo "=== 3) 主判据：marker 的数字属主(0=root / 10667=没提权) ==="
A "ls -ln $M; ls -lZ $M; id -u" | sed 's/^/  /'

echo "=== 4) 次判据：屏幕 ==="
A "screencap -p /sdcard/w591_$TAG.png; rm -f /sdcard/w591_$TAG.xml; uiautomator dump /sdcard/w591_$TAG.xml >/dev/null 2>&1; ls -l /sdcard/w591_$TAG.*" | sed 's/^/  /'
adb pull "/sdcard/w591_$TAG.png" "$W/w591_${TAG}_screen.png" >/dev/null 2>&1
adb pull "/sdcard/w591_$TAG.xml" "$W/w591_${TAG}_screen.xml" >/dev/null 2>&1
if [ -s "$W/w591_${TAG}_screen.xml" ]; then
    tr '<' '\n' < "$W/w591_${TAG}_screen.xml" | grep -a 'text=' | grep -aiE 'uid=|root|w590|Permission|denied|# |/data' | sed -n '1,20p' | sed 's/^/    /'
else
    echo "  [!] dump 没产文件 ⇒ 屏幕这半按没测到算(主判据不受影响)"
fi

echo "=== 5) 拉载荷自己写的那份(含 mac/id/self_attr/fd_ksu/marker_touch_rc) ==="
adb pull "$L" "$W/w591_${TAG}_enf_out.txt" >/dev/null 2>&1
if [ -s "$W/w591_${TAG}_enf_out.txt" ]; then
    sed 's/^/    /' "$W/w591_${TAG}_enf_out.txt"
else
    echo "  shell 读不到 $L(标签/属主问题) ⇒ 主判据仍押在第 3 步的 ls -ln 上"
    A "stat -c '%U %u %G %g %s' $M" | sed 's/^/  stat: /'
fi
echo "===== W591 arm=$TAG 跑完 enf=$(A getenforce)"
