#!/bin/bash
# w160_official_grant.sh —— 终局演示**全自动版**：加冕 → 官方 UI 里把 Termux 加进名单 → 它敲 su 出 root。
#   与 w158(等人来点)的区别是：第六十三发的界面侦察把三个卡点都解开了 ——
#     ① 抢焦点的是 vivo 的 **USB 已连接** 弹窗(点 (540,2059) 那个"取消"就掉，但它会反复出现)；
#     ② 正确的"到没到前台"信号是 `topResumedActivity`，**不是** `mCurrentFocus`(这台 vivo 恒 null)；
#     ③ **没挂模块时官方 v3.3.0 把整个底部导航都藏了**(dump 里没有"超级用户/模块/设置")
#        ⇒ 所以只能在**窗口内**点，且 tab 的坐标必须**运行时**从 uiautomator 树里取。
#   每一步找不到目标就**把当前界面的文字全打出来**再放弃那一格 —— 下一轮照着它改，不靠猜坐标。
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch + reboot)"; exit 2; }
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
MGR=me.weishu.kernelsu
SUW=com.suw.manager
TGT=com.termux
D=/sdcard/w160.xml
shot() { adb exec-out screencap -p > "$EV/w33_$1.png" 2>/dev/null
         echo "      截图 w33_$1.png $(stat -c %s "$EV/w33_$1.png" 2>/dev/null) 字节"; }
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
WAITFOR() { local f=$1 n=$2 m=$3 i=0 g
    while [ "$i" -lt "$n" ]; do
        g=$(A "grep -acF '$m' $f 2>/dev/null" | tr -dc '0-9')
        case "$g" in ''|*[!0-9]) : ;; *) [ "$g" -ge 1 ] && { echo "      (等到 $f 的[$m])"; return 0; } ;; esac
        sleep 3; i=$((i+1))
    done; echo "      (等满 $((n*3))s 没有[$m])"; return 1; }
pk_uid() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }
dump() {   # ★先删旧树再 dump，并**验回执**：上一版把 dump 的输出丢进 /dev/null，于是
           #   `uiautomator dump` 失败时我读的是上一份残留的树(只剩底部导航几个字)，
           #   被我当成"这个页面没有列表项"——而实时截图里搜索框和列表明明都在(§6.151)。
    local k out
    for k in 1 2 3 4 5 6; do
        A "rm -f $D" >/dev/null
        out=$(A "uiautomator dump $D" 2>&1)
        case "$out" in *"dumped to"*) : ;; *) sleep 3; continue ;; esac
        [ -n "$(A "ls -l $D 2>/dev/null")" ] || { sleep 3; continue; }
        return 0
    done
    echo "    [!] uiautomator dump 连试 6 次都没成(最后一次输出：$(printf '%s' "$out" | cut -c1-70))"
    echo "        ⇒ 这一格的界面判据作废，只看截图；绝不拿旧树当实时状态"
    return 1
}
texts() { A "cat $D" | tr '<' '\n' | grep -aoE '(text|content-desc)="[^"]{1,34}"' | sort -u; }
center_of() {   # ★先抠 bounds 属性再取数字：节点里 index=/depth= 也带数字(上一版就是这么点错行的)
    local b nums
    b=$(A "cat $D" | tr '<' '\n' | grep -aE "text=\"$1\"|content-desc=\"$1\"" | head -1)
    [ -z "$b" ] && return 1
    nums=$(printf '%s' "$b" | grep -aoE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 |
           grep -aoE '[0-9]+' | head -4 | tr '\n' ' ')
    set -- $nums; [ -z "${4:-}" ] && return 1
    echo "$(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))"
}
center_match() {   # center_match <grep 片段> —— 按**任意属性**(class/text/content-desc)找节点中心
    local b nums
    b=$(A "cat $D" | tr '<' '
' | grep -aE "$1" | head -1)
    [ -z "$b" ] && return 1
    nums=$(printf '%s' "$b" | grep -aoE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 |
           grep -aoE '[0-9]+' | head -4 | tr '
' ' ')
    set -- $nums; [ -z "${4:-}" ] && return 1
    echo "$(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))"
}
tap_match() {   # tap_match <grep 片段> <人话标签>
    local xy; xy=$(center_match "$1") || { echo "    [无] $2"; return 1; }
    set -- $xy; echo "    [有] $2 ⇒ 点 ($1,$2)"; A "input tap $1 $2" >/dev/null; sleep 5; return 0
}
center_of_bottom() {   # 同名节点取**最靠下**的那个(底部 tab 与页面大标题同名，点在标题上=什么都不发生)
    A "cat $D" | tr '<' '
' | grep -aE "text=\"$1\"|content-desc=\"$1\"" |
        grep -aoE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' |
        while read -r b; do
            set -- $(printf '%s' "$b" | grep -aoE '[0-9]+')
            [ -z "${4:-}" ] && continue
            echo "$(( ($2 + $4) / 2 )) $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))"
        done | sort -n | tail -1 | cut -d' ' -f2-
}
tap_text() { local label="$1" xy
    xy=$(center_of "$label") || { echo "    [无] $label"; return 1; }
    set -- $xy; echo "    [有] $label ⇒ 点 ($1,$2)"; A "input tap $1 $2" >/dev/null; sleep 4; return 0; }
kill_usb_dialog() {   # vivo 的 USB 弹窗会反复冒出来，每次进 UI 之前都清一遍
    local k
    for k in 1 2 3; do
        dump
        A "cat $D" | grep -aq 'USB 已连接' || return 0
        tap_text "取消" || return 0
    done
    return 0
}
show_focus() { A "dumpsys activity activities 2>/dev/null | grep -a topResumedActivity | head -1"; }

echo "=== 1) uid 实况(纯数字形状闸) ==="
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
TGTUID=$(pk_uid "$TGT"); MGRUID=$(pk_uid "$MGR"); SUWUID=$(pk_uid "$SUW")
echo "  Termux=$TGTUID  官方=$MGRUID  suw=$SUWUID"
for v in TGTUID MGRUID SUWUID; do eval "X=\$$v"
    case "$X" in ''|*[!0-9]*) echo "[x] $v 不干净：[$X] ⇒ 停"; exit 3;; esac; done

echo "=== 1.5) 把官方 Manager 摆成**要用那一个版本**(v2.0.0) ==="
#   §6.76③ + 第七十三发实测：v3.3.0 自己按"只支持 GKI 内核"把 5.4 挡在门外(界面显示"不支持"、
#   **底部导航整个藏掉**)，显示"工作中"的是 v2.0.0。上一版误把"最近任务"的**缓存快照**
#   当成实时界面，白指了几发(§6.149)。⇒ 版本要核对到字符串，不是"在装就算"。
OFFAPK=suw_apk/backup_official_kernelsu_v2.0.0_22001.apk
[ -f "$OFFAPK" ] || { echo "[x] 缺 $OFFAPK"; exit 2; }
VER=$(A "dumpsys package $MGR" | grep -a versionName | head -1)
echo "  在装的官方 Manager: [$VER]"
case "$VER" in
  *v2.0.0*) echo "  版本就是 v2.0.0 ⇒ 不动它";;
  "") echo "  没装过 ⇒ 装 v2.0.0"; adb install -r -t "$OFFAPK" 2>&1 | tail -1 | sed 's/^/    /';;
  *) echo "  在装的是别的版本 ⇒ 降级不被 -r 接受，先卸载再装"
     A "pm uninstall $MGR" >/dev/null; sleep 3
     adb install -r -t "$OFFAPK" 2>&1 | tail -1 | sed 's/^/    /';;
esac
for k in 1 2 3 4; do
    A "pm list packages $MGR" | grep -q "$MGR" && break
    echo "    第 $k 轮：没装上，点一下 vivo 装机闸再来"
    A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null
    adb install -r -t "$OFFAPK" >/dev/null 2>&1
    dump; tap_text "安装" || tap_text "继续安装" || tap_text "允许" || true
    sleep 4
done
VER2=$(A "dumpsys package $MGR" | grep -a versionName | head -1)
echo "  现在在装的: [$VER2]"
case "$VER2" in *v2.0.0*) : ;; *) echo "[x] 装不上 v2.0.0(现在=[$VER2]) ⇒ 停：整发的界面判读都会作废"; exit 3;; esac
MGRUID=$(pk_uid "$MGR"); SUWUID=$(pk_uid "$SUW")
case "$MGRUID" in ''|*[!0-9]*) echo "[x] 重装后取不到官方 uid：[$MGRUID] ⇒ 停"; exit 3;; esac
echo "  重算 uid：官方=$MGRUID suw=$SUWUID(卸载重装会换号，所以这里必须重取)"

echo "=== 2) push ko → reboot → punch → 等本 boot 的 stage ==="
#   ★上一版这里**漏了 push_ksu** ⇒ 设备上根本没有 kernelsu.ko：锤子照打(Permissive)、post 照跑，
#     但 stage 第一行就 `md5sum: kernelsu.ko: No such file` 并自己判"别在它身上耗窗口"后收工，
#     于是我这边只看到"等满 18 分钟没有判据④"——**原因在 stage 的日志里，不在我的等待里**。
#   args 自己写死(与 ATT=24/25/26 同一套已知安全配置)：不依赖"上一发留了什么在 ksu_args.txt 里"
printf '%s
' "ksu_mass_mark=0 ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud" > kmod/ksu_args.txt
echo "  本轮 args=[$(cat kmod/ksu_args.txt)]"
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|\[x\]" | sed 's/^/  /'
KO_ON=$(adb shell "ls -l /data/local/tmp/kernelsu.ko 2>/dev/null" | grep -ac kernelsu.ko)
[ "${KO_ON:-0}" != "0" ] || { echo "[x] ko 没落到设备上 ⇒ 停(别 punch 一个没有模块的窗口)"; exit 3; }
echo "  ko 已就位"
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
sleep 40
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log" >/dev/null
#   ★punch 之前自己再等一道**更紧的**负载闸：bootstrap 只要求 load1<6，上一发它以 5.91 擦线打完之后
#     整机 HARD_RESET(§6.148)，而历史上成功的发都是在 load1≈3 才动手。宁可多等三分钟。
LD_OK=0
for i in $(seq 1 40); do
    L1=$(A "cat /proc/loadavg" | cut -d. -f1)
    UP=$(A "cut -d' ' -f1 /proc/uptime" | cut -d. -f1)
    if [ "${L1:-99}" -le 3 ]; then echo "  负载够低：load1=$L1 up=$UP (第 $i 轮)"; LD_OK=1; break; fi
    [ $((i % 6)) = 0 ] && echo "    还在等: load1=$L1 up=$UP"
    sleep 15
done
[ "$LD_OK" = 1 ] || echo "  [!] 等满 10 分钟 load1 还 >3 ⇒ 照打，但把这句留在日志里当自变量"
I_KNOW=1 bash suw_apk/bootstrap.sh --punch >"$EV/w33_bootstrap.txt" 2>&1
echo "  bootstrap 退出码=$?"; tail -3 "$EV/w33_bootstrap.txt" | sed 's/^/    /'
for i in $(seq 1 20); do sleep 5; [ -n "$(A 'ls -l /data/local/tmp/punch.log 2>/dev/null')" ] && { echo "  pr 已起跑"; break; }; done
N=0
for i in $(seq 1 220); do sleep 5
    N=$(A "grep -ac '判据④' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  stage 到判据④ (t+$((i*5))s)"; break; }
done
[ "${N:-0}" = "0" ] && { echo "[x] 等满 18 分钟没有判据④ ⇒ 停。**先看 stage 自己怎么说**："
    A "grep -aE '!!|No such file|insmod rc|起点' /data/local/tmp/ksu_stage.log 2>/dev/null | tail -6" | cut -c1-150 | sed 's/^/    /'
    exit 5; }

echo "=== 3) bind su(第六十一发一手证过：没它 Termux 只有 ENOENT) ==="
adb push cm57/sustatic /data/local/tmp/sustatic >/dev/null 2>&1
adb push kmod/w135_fix.sh /data/local/tmp/w135_fix.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh; rm -f /data/local/tmp/w135_fix.out" >/dev/null
fire "@sushd:/data/local/tmp/w135_fix.sh" 8
WAITFOR /data/local/tmp/w135_fix.out 40 "===== DONE"
A "grep -aE 'BIND_RC|SU_AT_TGT|HEALTH' /data/local/tmp/w135_fix.out | cut -c1-110" | sed 's/^/    /'

echo "=== 4) 王座(内核侧那份，权威) ==="
A "echo $TGTUID > /data/local/tmp/w157_tgt.uid" >/dev/null
adb push kmod/w157_g.sh /data/local/tmp/w157_g.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w157_g.sh; rm -f /data/local/tmp/w157_g.out" >/dev/null
fire "@sushd:/data/local/tmp/w157_g.sh" 5
WAITFOR /data/local/tmp/w157_g.out 14 "=== DONE ==="
A "grep -aE 'GET_MANAGER_APPID|UID_GRANTED_ROOT|目标 uid' /data/local/tmp/w157_g.out" | cut -c1-140 | sed 's/^/    /'

echo "=== 5) 进官方 UI：先清 vivo 弹窗，再核对前台，再看它这次怎么说自己 ==="
#   ★★这一发的新线索(待证)：窗口明明是活的(Permissive、appid=10315 内核侧已答)，官方界面却报"不支持"，
#     而更早那发(没被我 force-stop 过)显示的是"工作中 [越狱模式]"。Manager 是在启动时调
#     `Natives.becomeManager(uid)` 去坐王座的，而**王座可能只认第一次认领** ⇒ 我 `am force-stop` 之后
#     重启它，可能就把已经拿到手的会话丢了(表现正是"不支持"+底部导航被藏)。
#     ⇒ 这一版**不再 force-stop 官方 Manager**，只把它带到前台；并且先看它现在说什么，再决定要不要动它。
A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null
ACT=$(A "cmd package resolve-activity --brief $MGR" | tail -1)
case "$ACT" in */*) : ;; *) ACT="$MGR/.ui.MainActivity" ;; esac
echo "  入口组件=[$ACT](现查，不写死)"
A "am start -n $ACT" >/dev/null 2>&1; sleep 7
kill_usb_dialog
echo "  焦点: $(show_focus)"
dump; echo "  首页文字(前 18 条)："; texts | head -18 | sed 's/^/    /'
for w in 工作中 越狱 不支持; do
    A "cat $D" | grep -aq "text=\"$w\"" && echo "    [有] $w" || echo "    [无] $w"
done

echo "=== 6) 超级用户页 → 搜索 Termux → 进详情 → 开 Root ==="
#   上一版的失败形状很有教学价值：tab **点对了**(实时截图里已经是超级用户页，列表第一项就是
#   `SU 白名单 com.suw.manager` 带着 ROOT/CUSTOM 徽标)，但我在**列表渲染完成之前**就 dump，
#   于是树里只有底部导航那几个字 ⇒ 看起来像"页面是空的/没有添加按钮"。判据读早了，结论就是假的。
TABXY=$(center_of_bottom "超级用户") || TABXY=""
if [ -z "$TABXY" ]; then
    echo "    [x] 没有『超级用户』这个 tab ⇒ 这一格没证到；整页文字如下："
    texts | head -30 | sed 's/^/      /'
else
    set -- $TABXY; echo "    超级用户 tab 中心 ($1,$2)"; A "input tap $1 $2" >/dev/null
    sleep 8; kill_usb_dialog; shot su_tab; dump
    echo "  列表页(渲染后)能读到的包名/文字："; texts | head -22 | sed 's/^/    /'
    echo "  --- 用搜索框定位 Termux(列表是字母序，滚不如搜) ---"
    if tap_match 'class="android.widget.EditText"' "搜索框"; then
        A "input text 'com.termux'" >/dev/null; sleep 5; dump
        texts | head -10 | sed 's/^/      /'
    fi
    if tap_match 'text="com.termux"' "Termux 那一行"; then
        sleep 6; kill_usb_dialog; dump
        echo "  详情页文字："; texts | head -22 | sed 's/^/    /'
        shot detail
        echo "  --- 找 Root 开关(文字可能是 授予 Root / Root 权限 / Root) ---"
        OK=0
        for w in "授予 Root" "授予Root" "Root 权限" "Root"; do
            if tap_text "$w"; then OK=1; break; fi
        done
        [ "$OK" = 1 ] || { echo "    [!] 详情页里没找到 Root 开关 ⇒ 这一格没点到；文字全打出来："; texts | head -30 | sed 's/^/      /'; }
        sleep 4; shot after_toggle
    else
        echo "    [!] 列表/搜索里没点到 Termux ⇒ 这一格没证到(不猜坐标)"
    fi
fi

echo "=== 7) 内核侧复读：名单里现在有没有 Termux ==="
A "rm -f /data/local/tmp/w157_g.out" >/dev/null
fire "@sushd:/data/local/tmp/w157_g.sh" 5
WAITFOR /data/local/tmp/w157_g.out 14 "=== DONE ==="
A "grep -aE 'UID_GRANTED_ROOT|GET_MANAGER_APPID' /data/local/tmp/w157_g.out" | cut -c1-140 | sed 's/^/    /'
GR=$(A "grep -a UID_GRANTED_ROOT /data/local/tmp/w157_g.out | tail -1" | tr -dc '0-9')
echo "  granted 那行的数字尾巴=[$GR](含 uid，只作参考，判定看上面那行原文)"

echo "=== 8) Termux 敲 su(看得见 + 名单里有 ⇒ 期望 uid=0(root)) ==="
A "am force-stop $TGT" >/dev/null; sleep 1
A "am start -n $TGT/.app.TermuxActivity" >/dev/null 2>&1 || A "monkey -p $TGT 1" >/dev/null 2>&1
sleep 12
A "input text '/system/bin/su'"; A "input keyevent 66"; sleep 5
A "input text 'id'; input keyevent 66"; sleep 8; shot termux_su
A "grep -aE \"KSUBEAT (SU0|X7|X8)\" /data/local/tmp/dmesg.live 2>/dev/null | grep -a 'uid=$TGTUID' | tail -5" | cut -c1-150 | sed 's/^/    /'

echo "=== 9) 收尾：root 侧先 umount 成功再删源 → reboot → 复核 ==="
adb push kmod/w135_off.sh /data/local/tmp/w135_off.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w135_off.sh; rm -f /data/local/tmp/w135_off.out" >/dev/null
fire "@sushd:/data/local/tmp/w135_off.sh" 8
WAITFOR /data/local/tmp/w135_off.out 40 "===== DONE"
A "grep -aE 'MOUNT_LEFT|SU_GONE|RM_DIRS_OK' /data/local/tmp/w135_off.out | cut -c1-110" | sed 's/^/    /'
A "rm -f /data/local/tmp/w157_g.sh /data/local/tmp/w157_g.out /data/local/tmp/w157_tgt.uid" >/dev/null
adb reboot
for i in $(seq 1 60); do sleep 5; [ -n "$(adb get-state 2>/dev/null | grep device)" ] && break; done
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = "1" ]; do sleep 10; done
sleep 20
A "echo 收尾复核: up=\$(cut -d' ' -f1 /proc/uptime) mod=\$(grep -c kernelsu /proc/modules) enf=\$(getenforce) 挂载=\$(grep -c pbin /proc/self/mountinfo) bin=\$(ls -A /product/bin | wc -l)" | sed 's/^/  /'
echo "  截图/界面树都在 $EV/w33_*"
