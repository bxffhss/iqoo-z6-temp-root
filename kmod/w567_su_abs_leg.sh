#!/usr/bin/env bash
# w567_su_abs_leg.sh —— 第 44 发：在**执法态**的 Termux 屏幕上拿 `/system/bin/su`(ko 改道唯一匹配的那条路径) 的凭据。
#   ★为什么不只敲 `su`：裸 `su` 命中 `/product/bin/su`(静态 su→root agent 那条路)，恢复执法后 agent socket 被 SELinux 关掉
#     ⇒ 一手报错就是上一条腿里的 `连 @suwshd 失败 errno=13`(与 #104 同一条机制)，它**不证**交付那条改道路。
#   ★为什么要第二条 chmod 证：#116/#117 已证默认形状下 root 壳的输出**写不回 app 终端**(TE 缺规则，不是 MLS)
#     ⇒ "屏幕上出现 uid=0(root)" 这一格在本形状里结构上拿不到(要 DOM_MAP)。所以第二条把判据换成
#     **"只有 root 能做的动作 + 由 app 自己的 ls 打印出来"**：落点文件属主是 shell(2000)，
#     Termux(10667) 无权 chmod ⇒ 模式若从 644 变 600，执行者只能是 root，而打印者是 Termux 自己(写得回屏)。
#   打字规矩(环境记忆)：空格＝%s；不用引号、不打 `>`/`|`(会被输入法吃掉)；先暖一行防首字符被吞。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
EV=kmod/w103_evidence
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
T() { A "input text $1; input keyevent 66"; }

echo "=== 0) 现态与焦点(必须是 Termux 在前台，否则字打进别的窗口) ==="
A 'echo up=$(cut -d" " -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) tmx=$(pidof com.termux)'
A 'dumpsys window 2>/dev/null | grep -aE "mFocusedApp" | head -2'

echo "=== 1) 暖一行(新会话首字符会被吞) ==="
T '#warm'
sleep 1

echo "=== 2) 交付那条路：/system/bin/su -c id ==="
T '/system/bin/su%s-c%sid'
sleep 5
A 'screencap -p /sdcard/w567_su_abs.png; rm -f /sdcard/w567_a.xml; uiautomator dump /sdcard/w567_a.xml >/dev/null 2>&1; ls -l /sdcard/w567_su_abs.png /sdcard/w567_a.xml' | sed 's/^/  /'
adb pull //sdcard/w567_a.xml "$EV/w567_a.xml" >/dev/null 2>&1
adb pull //sdcard/w567_su_abs.png "$EV/w567_su_abs.png" >/dev/null 2>&1

echo "=== 3) 造 chmod 靶子(属主 shell:shell，先读初态) ==="
A 'rm -f /data/local/tmp/w567_probe; echo probe > /data/local/tmp/w567_probe; chmod 644 /data/local/tmp/w567_probe; ls -l /data/local/tmp/w567_probe' | sed 's/^/  初态: /'

echo "=== 4) root 才做得动的动作(经 /system/bin/su 改道) ，再由 Termux 自己 ls 打印 ==="
T '/system/bin/su%s-c%schmod%s600%s/data/local/tmp/w567_probe'
sleep 5
T 'ls%s-l%s/data/local/tmp/w567_probe'
sleep 4
A 'screencap -p /sdcard/w567_chmod.png; rm -f /sdcard/w567_b.xml; uiautomator dump /sdcard/w567_b.xml >/dev/null 2>&1; ls -l /sdcard/w567_chmod.png /sdcard/w567_b.xml' | sed 's/^/  /'
adb pull //sdcard/w567_b.xml "$EV/w567_b.xml" >/dev/null 2>&1
adb pull //sdcard/w567_chmod.png "$EV/w567_chmod.png" >/dev/null 2>&1
echo "  设备侧独立复证(不靠屏幕)：$(A 'ls -l /data/local/tmp/w567_probe')"
echo "  终态读数：$(A 'echo enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) up=$(cut -d" " -f1 /proc/uptime)')"
echo "判据口径：①屏幕出现 uid=0(root) ⇒ 直接成立；②只出现命令行没有输出 ⇒ 那是 #116 那格(写不回终端)，本发改由"
echo "          ③ls -l 那行显示模式已从 644 变 600(而属主是 shell、Termux 无权 chmod) 来出 root 的一手凭据。"
