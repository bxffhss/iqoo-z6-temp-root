#!/usr/bin/env bash
# w429_termux_leg.sh —— 第 27 发「看得见字」那条腿：在 **Termux 自己的终端**里手敲 su，判据取屏幕(截图＋uiautomator 文本)。
#   ★为什么必须打在屏幕上：#116 已证"root 壳能把结果写进文件、但写不回 app 终端"，
#     所以"文件里有字节"从来不等于"看得见字"；这条腿的判据只有截图与无障碍树两样。
#   ★空格在 `input text` 里是 %s(不是 %20)；连引号都会被吃掉 ⇒ 这里一个引号都不用。
#   本脚本只读＋敲键，不改设备侧任何开关。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
W=kmod/w103_evidence
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
echo "=== 0) 现态(要看 enf：这条腿最有价值的形状是执法态下；也记录 suw/termux 在不在跑) ==="
A 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) suw=$(pidof com.suw.manager) tmx=$(pidof com.termux) bid=$(cat /proc/sys/kernel/random/boot_id)'

echo "=== 1) 起 Termux 并读它自己的原域(末端证人要跟这一串逐字比) ==="
A 'am start -n com.termux/.app.TermuxActivity' | sed 's/^/  /'
sleep 7
# ★mCurrentFocus 在这台常是 null(例：要看 mFocusedApp)——敲键前确认焦点真在 Termux 上
A 'dumpsys window | grep -a mFocusedApp | head -1' | sed 's/^/  焦点=/'
CTXBEFORE=$(A "for p in \$(pidof com.termux); do cat /proc/\$p/attr/current | tr -d '\\000'; echo; done" | tr -d ' \r' | grep -a '^u:' | head -1)
echo "  Termux 进程域=[$CTXBEFORE]"
[ -n "$CTXBEFORE" ] || { echo "  [x] 读不到 Termux 的域 ⇒ 停(判据不能猜)"; exit 2; }

echo "=== 2) 敲 su 回车(提权)，再敲 id 回车，再敲 cat%s/proc/self/attr/current 回车 ==="
A 'input text su; input keyevent 66'
sleep 6
A 'input text id; input keyevent 66'
sleep 5
A 'input text cat%s/proc/self/attr/current; input keyevent 66'
sleep 5

echo "=== 3) 判据一：截图(要人眼看 # 提示符与两行输出) ==="
A 'screencap -p /sdcard/w429_termux.png; ls -l /sdcard/w429_termux.png' | sed 's/^/  /'
adb pull //sdcard/w429_termux.png "$W/w429_termux.png" >/dev/null 2>&1
ls -l "$W/w429_termux.png" 2>&1 | sed 's/^/  本机存证：/'

echo "=== 4) 判据二：无障碍树里的屏幕文本(★首跑可能静默不产文件 ⇒ 先确认在不在) ==="
A 'rm -f /sdcard/w429.xml; uiautomator dump /sdcard/w429.xml >/dev/null 2>&1; ls -l /sdcard/w429.xml 2>&1' | sed 's/^/  /'
adb pull //sdcard/w429.xml "$W/w429_termux.xml" >/dev/null 2>&1
if [ -s "$W/w429_termux.xml" ]; then
    echo "  ── 屏幕文本里含 uid= 或 root 或 untrusted 的行(整行原文) ──"
    tr '<' '\n' < "$W/w429_termux.xml" | grep -a 'text=' | grep -aiE 'uid=|root|untrusted_app|#|/proc/self' | sed -n '1,25p' | sed 's/^/    /'
else
    echo "  [!] dump 没产文件 ⇒ 这一半按没测到算，只能靠截图"
fi

echo "=== 5) 收尾提示(不自己动)：这条腿读完就该走 §0 的收尾＋reboot ==="
echo "  判据口径：正＝屏幕上出现 # 提示符＋id 那行含 uid=0(root)＋attr/current 那行逐字=[$CTXBEFORE]"
echo "            ★注意 #116：如果屏幕上只有命令行、没有输出行 ⇒ 那是『写不回终端』那格，不算这格成立"
