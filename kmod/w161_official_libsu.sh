#!/bin/bash
# w161_official_libsu.sh —— #61：**把"装 fd"这一步真的做出来**，再测官方 Manager 的 libsu 那一格。
#   为什么这次值得再烧一发窗口(两条一手事实)：
#   ① 上一发的 ksu_stage.log + dmesg.live 对上了：stage 在 up=511 对 pid=14763 写了
#      /proc/ksu_install_fd，内核只打了"已排队…等它回到用户态"，**整份 dmesg.live 里没有那个 pid 的
#      回调行** ⇒ fd 从没进过 Manager ⇒ 首页"版本 -1 / 红横幅"是**没装 fd** 的样子，不是内核不给力。
#      ⇒ 这次用 root 侧看门狗(0.4s 一轮)盯着 pid 变化立刻重排，并且**判据只看回调行**。
#   ② §6.81 把"超级用户列表页"判死在 libsu 的 root 传输层(app 侧要 shell 出 su)。
#      但那两条前提后来都被我们自己的交付改掉了：bind /product/bin 让 `/system/bin/su`
#      对 app **真的存在**(§6.57 的 ENOENT 不再成立)，而 killguard/no_cred_override 之后
#      app 域派生的 root 子进程能活(#44/#48/#49 真 app Termux 手敲 su 出 uid=0)。
#      ⇒ "RootService 起不来"这个定案**在今天的配置下没重测过**，这一发的正判据就是它：
#        点进超级用户页之后，进程表里该出现一个 ruid=0 的 root 侧进程(app_process 或 su 的子进程)。
#   ★每一步"取现场"都要验回执(§6.141/§6.149/§6.151 三连的教训)；dump 不成只看截图，不猜坐标。
#   ★本脚本跑到"停在窗口内"就结束，**不收尾**：界面要点开看，收尾是 w161_teardown.sh。
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch + reboot)"; exit 2; }
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
MGR=me.weishu.kernelsu
SUW=com.suw.manager
TGT=com.termux
D=/sdcard/w161.xml
shot() { adb exec-out screencap -p > "$EV/w34_$1.png" 2>/dev/null
         echo "      截图 w34_$1.png $(stat -c %s "$EV/w34_$1.png" 2>/dev/null) 字节"; }
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
WAITFOR() { local f=$1 n=$2 m=$3 i=0 g
    while [ "$i" -lt "$n" ]; do
        g=$(A "grep -acF '$m' $f 2>/dev/null" | tr -dc '0-9')
        case "$g" in ''|*[!0-9]) : ;; *) [ "$g" -ge 1 ] && { echo "      (等到 $f 的[$m])"; return 0; } ;; esac
        sleep 3; i=$((i+1))
    done; echo "      (等满 $((n*3))s 没有[$m])"; return 1; }
pk_uid() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }
dump() { local k out
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
center_match() { local b nums
    b=$(A "cat $D" | tr '<' '\n' | grep -aE "$1" | head -1)
    [ -z "$b" ] && return 1
    nums=$(printf '%s' "$b" | grep -aoE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 |
           grep -aoE '[0-9]+' | head -4 | tr '\n' ' ')
    set -- $nums; [ -z "${4:-}" ] && return 1
    echo "$(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))"
}
center_of_bottom() {   # 同名节点取**最靠下**的那个(底部 tab 与页面大标题/卡片同名)
    A "cat $D" | tr '<' '\n' | grep -aE "text=\"$1\"|content-desc=\"$1\"" |
        grep -aoE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' |
        while read -r b; do
            set -- $(printf '%s' "$b" | grep -aoE '[0-9]+')
            [ -z "${4:-}" ] && continue
            echo "$(( ($2 + $4) / 2 )) $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))"
        done | sort -n | tail -1 | cut -d' ' -f2-
}
tap_text() { local label="$1" xy
    xy=$(center_match "text=\"$label\"|content-desc=\"$label\"") || { echo "    [无] $label"; return 1; }
    set -- $xy; echo "    [有] $label ⇒ 点 ($1,$2)"; A "input tap $1 $2" >/dev/null; sleep 4; return 0; }
kill_usb_dialog() { local k
    for k in 1 2 3; do
        dump
        A "cat $D" | grep -aq 'USB 已连接' || return 0
        tap_text "取消" || return 0
    done
    return 0
}
show_focus() { A "dumpsys activity activities 2>/dev/null | grep -a topResumedActivity | head -1"; }
fdcb() {   # 权威判据：内核有没有真的把 fd 装进这个 pid(只看回调行，"已排队"不算)
    #   ★必须同时点名 comm=[weishu：/data/local/tmp/dmesg.live 会**跨重启残留**(刚干跑就看到上一发的
    #   两行)，而 pid 是开机随机的 ⇒ 只按 pid 匹配有撞车的假阳性(记忆"跨重启残留"那一族)。
    A "grep -a 'KSUFDINST 回调跑在 pid=$1' /data/local/tmp/dmesg.live 2>/dev/null | grep -a weishu | tail -2" | cut -c1-150; }

echo "=== 1) uid 实况(纯数字形状闸) ==="
until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 5; done
TGTUID=$(pk_uid "$TGT"); MGRUID=$(pk_uid "$MGR"); SUWUID=$(pk_uid "$SUW")
echo "  Termux=$TGTUID  官方=$MGRUID  suw=$SUWUID"
for v in TGTUID MGRUID SUWUID; do eval "X=\$$v"
    case "$X" in ''|*[!0-9]*) echo "[x] $v 不干净：[$X] ⇒ 停"; exit 3;; esac; done

echo "=== 1.5) 官方 Manager 必须是 v2.0.0(v3.3.0 自己按'只支持 GKI'把 5.4 挡门外) ==="
OFFAPK=suw_apk/backup_official_kernelsu_v2.0.0_22001.apk
[ -f "$OFFAPK" ] || { echo "[x] 缺 $OFFAPK"; exit 2; }
VER=$(A "dumpsys package $MGR" | grep -a versionName | head -1)
echo "  在装的: [$VER]"
case "$VER" in
  *v2.0.0*) echo "  就是 v2.0.0 ⇒ 不动它";;
  "") echo "  没装过 ⇒ 装 v2.0.0"; adb install -r -t "$OFFAPK" 2>&1 | tail -1 | sed 's/^/    /';;
  *) echo "  别的版本 ⇒ 先卸载再装(降级不被 -r 接受)"
     A "pm uninstall $MGR" >/dev/null; sleep 3
     adb install -r -t "$OFFAPK" 2>&1 | tail -1 | sed 's/^/    /';;
esac
for k in 1 2 3 4; do
    A "pm list packages $MGR" | grep -q "$MGR" && break
    echo "    第 $k 轮：没装上，点 vivo 装机闸再来"
    A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null
    adb install -r -t "$OFFAPK" >/dev/null 2>&1
    dump; tap_text "安装" || tap_text "继续安装" || tap_text "允许" || true
    sleep 4
done
VER2=$(A "dumpsys package $MGR" | grep -a versionName | head -1)
echo "  现在在装的: [$VER2]"
case "$VER2" in *v2.0.0*) : ;; *) echo "[x] 装不上 v2.0.0(=[$VER2]) ⇒ 停"; exit 3;; esac
MGRUID=$(pk_uid "$MGR"); SUWUID=$(pk_uid "$SUW"); TGTUID=$(pk_uid "$TGT")
for v in TGTUID MGRUID SUWUID; do eval "X=\$$v"
    case "$X" in ''|*[!0-9]*) echo "[x] 重装后 $v 取不到：[$X] ⇒ 停"; exit 3;; esac; done
echo "  重算 uid：Termux=$TGTUID 官方=$MGRUID suw=$SUWUID"

echo "=== 2) push ko → reboot → punch → 等本 boot 的 stage(判据④) ==="
printf '%s\n' "ksu_mass_mark=0 ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud" > kmod/ksu_args.txt
echo "  本轮 args=[$(cat kmod/ksu_args.txt)]"
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|\[x\]" | sed 's/^/  /'
for f in kmod/w161_fdwatch.sh kmod/w161_fdlaunch.sh kmod/w161_g2.sh; do
    adb push "$f" /data/local/tmp/ >/dev/null 2>&1 || echo "  [!] push $f 失败"
done
KO_ON=$(adb shell "ls -l /data/local/tmp/kernelsu.ko 2>/dev/null" | grep -ac kernelsu.ko)
[ "${KO_ON:-0}" != "0" ] || { echo "[x] ko 没落到设备上 ⇒ 停(别 punch 一个没有模块的窗口)"; exit 3; }
echo "  ko + 三份 w161 载荷已就位"
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 5; done
sleep 40
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log /data/local/tmp/w161_fdwatch.log /data/local/tmp/dmesg.live /data/local/tmp/w161_r0.txt" >/dev/null
LD_OK=0
for i in $(seq 1 40); do
    L1=$(A "cat /proc/loadavg" | cut -d. -f1)
    UP=$(A "cut -d' ' -f1 /proc/uptime" | cut -d. -f1)
    if [ "${L1:-99}" -le 3 ]; then echo "  负载够低：load1=$L1 up=$UP (第 $i 轮)"; LD_OK=1; break; fi
    [ $((i % 6)) = 0 ] && echo "    还在等: load1=$L1 up=$UP"
    sleep 15
done
[ "$LD_OK" = 1 ] || echo "  [!] 等满 10 分钟 load1 还 >3 ⇒ 照打，但把这句留在日志里当自变量"
I_KNOW=1 bash suw_apk/bootstrap.sh --punch >"$EV/w34_bootstrap.txt" 2>&1
echo "  bootstrap 退出码=$?"; tail -3 "$EV/w34_bootstrap.txt" | sed 's/^/    /'
for i in $(seq 1 20); do sleep 5; [ -n "$(A 'ls -l /data/local/tmp/punch.log 2>/dev/null')" ] && { echo "  pr 已起跑"; break; }; done
N=0
for i in $(seq 1 220); do sleep 5
    N=$(A "grep -ac '判据④' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  stage 到判据④ (t+$((i*5))s)"; break; }
done
[ "${N:-0}" = "0" ] && { echo "[x] 等满 18 分钟没有判据④ ⇒ 停。先看 stage 自己怎么说："
    A "grep -aE '!!|No such file|insmod rc|起点' /data/local/tmp/ksu_stage.log 2>/dev/null | tail -6" | cut -c1-150 | sed 's/^/    /'
    exit 5; }

echo "=== 3) bind su(§6.124：没它 app 侧只有 ENOENT，libsu 那格根本无从谈起) ==="
adb push cm57/sustatic /data/local/tmp/sustatic >/dev/null 2>&1
adb push kmod/w135_fix.sh /data/local/tmp/w135_fix.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh; rm -f /data/local/tmp/w135_fix.out" >/dev/null
fire "@sushd:/data/local/tmp/w135_fix.sh" 8
WAITFOR /data/local/tmp/w135_fix.out 40 "===== DONE"
A "grep -aE 'BIND_RC|SU_AT_TGT|HEALTH' /data/local/tmp/w135_fix.out | cut -c1-110" | sed 's/^/    /'
echo "  app 视角能不能 stat 到 su：$(A 'ls -l /system/bin/su 2>&1' | cut -c1-90)"

echo "=== 3.5) 起 root 侧装 fd 看门狗(setsid，160s) ==="
A "chmod 755 /data/local/tmp/w161_fdwatch.sh /data/local/tmp/w161_fdlaunch.sh /data/local/tmp/w161_g2.sh; rm -f /data/local/tmp/w161_fdlaunch.out" >/dev/null
fire "@sushd:/data/local/tmp/w161_fdlaunch.sh" 8
WAITFOR /data/local/tmp/w161_fdlaunch.out 20 "===== DONE"
A "grep -aE '触发口|看门狗 pid|uid=' /data/local/tmp/w161_fdlaunch.out | cut -c1-130" | sed 's/^/    /'

echo "=== 4) 起 Manager → 等**回调行**(最多 4 轮；'已排队'不算) ==="
ACT=$(A "cmd package resolve-activity --brief $MGR" | tail -1)
case "$ACT" in */*) : ;; *) ACT="$MGR/.ui.MainActivity" ;; esac
echo "  入口组件=[$ACT]"
GOTPID=""
for c in 1 2 3 4; do
    A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null
    A "am start -n $ACT" >/dev/null 2>&1; sleep 8
    MP=$(A "pidof $MGR" | cut -d' ' -f1)
    case "$MP" in ''|*[!0-9]*) echo "    第 $c 轮：没有 Manager pid"; sleep 4; continue;; esac
    CB=$(fdcb "$MP")
    echo "    第 $c 轮 pid=$MP 回调行=[${CB:-无}]"
    if [ -n "$CB" ]; then GOTPID=$MP; break; fi
    echo "      ⇒ 还没回到用户态(多半被冻在后台)，再带它回前台一次"
    A "am start -n $ACT" >/dev/null 2>&1; sleep 8
    CB=$(fdcb "$MP"); echo "      复查 pid=$MP 回调行=[${CB:-无}]"
    if [ -n "$CB" ]; then GOTPID=$MP; break; fi
    echo "      ⇒ 换进程重来(force-stop 会丢掉已装的 fd，所以只有没装成才允许重来)"
    A "am force-stop $MGR" >/dev/null; sleep 3
done
[ -n "$GOTPID" ] || echo "  [!] 四轮都没等到回调行 ⇒ fd 这一格没成立，后面全部按'没装 fd'解读"

echo "=== 5) 权威复读(内核侧 + 进程侧，不依赖界面) ==="
A "echo $TGTUID > /data/local/tmp/w161_u1.uid; echo $MGRUID > /data/local/tmp/w161_u2.uid; rm -f /data/local/tmp/w161_g2.out" >/dev/null
fire "@sushd:/data/local/tmp/w161_g2.sh" 8
WAITFOR /data/local/tmp/w161_g2.out 20 "=== DONE ==="
A "cat /data/local/tmp/w161_g2.out" | cut -c1-160 | sed 's/^/    /'

echo "=== 6) 首页：截图 + (dump 得动就读文字) —— 看红横幅在不在 ==="
A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null
A "am start -n $ACT" >/dev/null 2>&1; sleep 8
kill_usb_dialog
shot home0
echo "  焦点: $(show_focus)"
if dump; then
    echo "  首页文字(前 20 条)："; texts | head -20 | sed 's/^/    /'
    for w in 工作中 越狱 不支持 过低 "获取 Root 失败" 超级用户 模块; do
        A "cat $D" | grep -aq "$w" && echo "    [有] $w" || echo "    [无] $w"
    done
fi

echo "=== 7) 点进超级用户页 → 等 25s → 看 libsu 的 root 进程起没起(#61 的正判据) ==="
TABXY=$(center_of_bottom "超级用户") || TABXY=""
if [ -z "$TABXY" ]; then
    echo "    [x] 树里没有『超级用户』节点 ⇒ 不猜坐标；这一格留给 PC 侧照实时截图点"
    A "cat /data/local/tmp/w161_fdwatch.log 2>/dev/null | tail -3" | sed 's/^/      看门狗: /'
else
    set -- $TABXY; echo "    底部『超级用户』中心 ($1,$2) ⇒ 点"; A "input tap $1 $2" >/dev/null
    sleep 25; kill_usb_dialog; shot su_page
    if dump; then echo "  列表页文字(前 24 条)："; texts | head -24 | sed 's/^/    /'; fi
    A "rm -f /data/local/tmp/w161_g2.out" >/dev/null
    fire "@sushd:/data/local/tmp/w161_g2.sh" 8
    WAITFOR /data/local/tmp/w161_g2.out 20 "=== DONE ==="
    echo "  --- 点进列表页之后的复读(重点看 C 段有没有 ruid=0 的新进程) ---"
    A "cat /data/local/tmp/w161_g2.out" | cut -c1-160 | sed 's/^/    /'
fi

echo "=== 8) 停在窗口内(没收尾) ==="
MODN=$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)
UPN=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1)
echo "  窗口现在是活的：mod=$MODN enforce=$(A getenforce) up=$UPN"
echo "  界面要点开看 ⇒ 照实时截图点(不猜坐标)：adb shell input tap <x> <y>"
echo "  内核侧复读：adb shell 'rm -f /data/local/tmp/w161_g2.out' 之后用 suw 通道跑 w161_g2.sh"
echo "  收尾一律走：I_KNOW=1 bash kmod/w161_teardown.sh"
