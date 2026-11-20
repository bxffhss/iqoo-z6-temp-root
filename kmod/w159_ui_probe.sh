#!/bin/bash
# w159_ui_probe.sh —— **不需要 root 窗口**的界面侦察：把官方 KernelSU Manager 的选择器定死。
#   动机(§6.147 一手)：第六十一/六十二发"点不动"的真因是 vivo 的 **USB 已连接** 系统弹窗抢焦点，
#   而我的焦点探测用错了字段(`mCurrentFocus` 在这台 vivo 上恒 null，正确的信号是
#   `topResumedActivity`)。这一发只测三件事：① 关弹窗 ② 认底部 tab ③ 进超级用户页看有没有"添加"入口。
#   ⇒ 全程不 punch、不装东西、不动名单，纯只读 + 点按。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
D=/sdcard/w159.xml

dump() { A "uiautomator dump $D" >/dev/null 2>&1; }
texts() { A "cat $D" | tr '<' '\n' | grep -aoE '(text|content-desc)="[^"]{1,30}"' | sort -u; }
# 找某个文字节点的**中心坐标**(纯数字，绝不把引号带进算术)
center_of() {   # center_of <文字正则>
    local b nums
    b=$(A "cat $D" | tr '<' '\n' | grep -aE "text=\"$1\"|content-desc=\"$1\"" | head -1)
    [ -z "$b" ] && return 1
    # ★必须**先抠出 bounds 属性再取数字**：节点里还有 index=/depth= 这类带数字的属性，
    #   上一版直接 `grep -oE [0-9]+ | head -4` 把 index 当成了坐标 ⇒ 点到"仅充电"那一行去了。
    nums=$(printf '%s' "$b" | grep -aoE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 |
           grep -aoE '[0-9]+' | head -4 | tr '\n' ' ')
    set -- $nums
    [ -z "${4:-}" ] && return 1
    echo "$(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))"
}
tap_text() {   # tap_text <文字> —— 找到就点中心，找不到就明说
    local label xy
    label="$1"
    xy=$(center_of "$label") || { echo "    [无] $label"; return 1; }
    set -- $xy
    echo "    [有] $label ⇒ 点 ($1,$2)"
    A "input tap $1 $2" >/dev/null; sleep 4; return 0
}

echo "=== 1) 起 Manager，用**正确的**前台信号 ==="
A "am force-stop me.weishu.kernelsu" >/dev/null; sleep 1
A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null; sleep 1
A "am start -n me.weishu.kernelsu/.ui.MainActivity" >/dev/null 2>&1; sleep 6
A "dumpsys activity activities 2>/dev/null | grep -aE 'topResumedActivity' | head -1" | sed 's/^/  /'

echo "=== 2) vivo 的 USB 弹窗在不在？在就点掉(可能要按几次) ==="
for k in 1 2 3; do
    dump
    if A "cat $D" | grep -aq 'USB 已连接'; then
        echo "  第 $k 次：弹窗在(选项：$(texts | grep -ac 'text='))"
        tap_text "取消" || break
    else
        echo "  第 $k 次：没有 USB 弹窗 ⇒ 前台干净"; break
    fi
done

echo "=== 3) 首页文字与底部 tab ==="
dump; texts | head -20 | sed 's/^/    /'
for w in 超级用户 模块 设置 首页; do
    xy=$(center_of "$w") && echo "    [有] $w → 中心 $xy" || echo "    [无] $w"
done

echo "=== 4) 进超级用户页，看有没有\"添加应用\"的入口 ==="
tap_text "超级用户" || echo "    (进不去 ⇒ 后面的侦察作废)"
dump
texts | head -26 | sed 's/^/    /'
echo "  --- 疑似添加入口(content-desc 里找 add/添加/新建) ---"
A "cat $D" | tr '<' '\n' | grep -aiE 'content-desc="[^"]*(add|添加|新建|new)' | head -4 | sed 's/^/    /'
echo "  --- 页面里出现的 app 名字(有没有 Termux) ---"
A "cat $D" | tr '<' '\n' | grep -aoE 'text="[^"]*(Termux|终端|白名单|KernelSU)[^"]*"' | sort -u | head -6 | sed 's/^/    /'
echo "=== 完(没动设备上的任何东西；截图可另跑 screencap) ==="
