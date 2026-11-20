#!/bin/bash
# w157_official_su_demo.sh —— 终局演示第二版：**加冕与授权都走官方 KernelSU Manager，但通道不拆**。
#   用法：I_KNOW=1 bash kmod/kmod/../kmod/w157_official_su_demo.sh    (会 reboot/装 APK/punch)
#
# ★为什么推翻 w156 的设计(那版在 punch 前卸掉 suw.manager)：
#   `suw_apk/bootstrap.sh --punch` 的**第 3 步就要 suw 的 uid**(起 shd 并把它加进 unix 白名单)，
#   suw 不在它就 `exit 1` ⇒ 锤子根本没派发(第三发实测：punch.log 100 秒不出现，新加的硬闸 18 分钟都没等)。
#   而"王座只有一把"(throne_tracker 找到第一个 is_manager 就停)的正确解法第七十三发早就给过了：
#   **不卸 suw，而是换一份不参与争位的 suw**(`suw_apk/suw_nomgr.apk`，CN=suw-nomgr，
#   证书 d92254fd… 不在 ko 的期望列表里) + 官方 Manager 用 **v2.0.0**
#   (v3.3.0 自己按"只支持 GKI"把 5.4 挡在门外，§6.76③；v2.0.0 的证书 c371061b… 正好等于 ko 的 identity-1)。
#   ⇒ 这样加冕的是官方那份，`@sushd:` 这条 root 侧通道也还在(挂载/取证/收尾都靠它)。
#
# 判据链(每一步都要一手回执，不看退出码)：
#   A `ksuctl mgr`(root 侧)        ⇒ 期望 appid = 官方 Manager 的 uid，**不是 suw 的**
#   B 官方 UI 截图                 ⇒ 期望"工作中"
#   C 官方 UI 里给 Termux 点开开关  ⇒ 坐标用 uiautomator 现找(写死的坐标只对某一个 APK 有效)
#   D stage 代挂 /product/bin      ⇒ su 可见性是我们做的，官方 Manager 只管名单(诚实口径)
#   E Termux 敲 su                 ⇒ 截图 uid=0(root) + `dmesg.live` 里带 Termux uid 的 SU0/X7 脚印
#   F 收尾                         ⇒ root 侧先 umount 成功再删源 → reboot → 复核 mod=0/enf=Enforcing/挂载=0
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch + reboot + 装 APK)"; exit 2; }
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1; }
EV=kmod/w103_evidence; mkdir -p "$EV"
MGR=me.weishu.kernelsu
SUW=com.suw.manager
TGT=com.termux
OFFAPK=suw_apk/backup_official_kernelsu_v2.0.0_22001.apk
SUWAPK=suw_apk/suw_nomgr.apk
[ -f "$OFFAPK" ] || { echo "[x] 缺官方 v2.0.0：$OFFAPK"; exit 2; }
[ -f "$SUWAPK" ] || { echo "[x] 缺不参与争位的 suw：$SUWAPK(先 bash suw_apk/build.sh)"; exit 2; }
shot() { adb exec-out screencap -p > "$EV/w31_$1.png" 2>/dev/null
         echo "    截图 w31_$1.png $(stat -c %s "$EV/w31_$1.png" 2>/dev/null) 字节"; }
gate_install() {   # gate_install <apk>：装 + 点掉 vivo 装机闸，**装完必须复读实况**
    local apk="$1" k
    ( for i in $(seq 1 24); do sleep 3
          adb shell "pm list packages $2" 2>/dev/null | grep -q "$2" && break
          adb shell "input tap 540 1962" >/dev/null 2>&1; sleep 1
          adb shell "input tap 540 2109" >/dev/null 2>&1
      done ) &
    adb install -r -t "$apk" 2>&1 | tail -1 | sed 's/^/      /'
    wait
    for k in 1 2 3; do
        A "pm list packages $2" | grep -q "$2" && return 0
        echo "      第 $k 次复读没看到 $2 ⇒ 再装一次"; adb install -r -t "$apk" >/dev/null 2>&1; sleep 3
    done
    return 1
}
dump_ui() {   # dump_ui <名字> —— 把当前界面的 uiautomator 树存成 $EV/w31_<名字>.xml
    adb shell uiautomator dump /sdcard/w31_$1.xml >/dev/null 2>&1
    adb pull /sdcard/w31_$1.xml "$EV/w31_$1.xml" >/dev/null 2>&1
}

fire() {   # fire <动词> <等待秒>：与 ATT=26 同款(suw 的 onCreate 才是触发点，必须先 force-stop)
    A "am force-stop $SUW" >/dev/null; sleep 1
    A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1
    sleep "$2"
}
WAITFOR() {   # WAITFOR <设备文件> <轮数> <完成标记>
    local f=$1 n=$2 m=$3 i=0 g
    while [ "$i" -lt "$n" ]; do
        g=$(A "grep -acF '$m' $f 2>/dev/null" | tr -d '\r\n')
        case "$g" in ''|*[!0-9]) : ;; *) [ "$g" -ge 1 ] && { echo "    (等到 $f 的『$m』)"; return 0; } ;; esac
        sleep 3; i=$((i+1))
    done
    echo "    (等满 $((n*3))s 没有『$m』⇒ 这一格按没测到算)"; return 1
}

echo "=== 1) 包状态：官方 v2.0.0(要它被加冕) + suw_nomgr(通道，不参与争位) ==="
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
A "input keyevent 224; svc power stayon true" >/dev/null
A "am force-stop $MGR; am force-stop $SUW" >/dev/null
#   上一发已经把官方 v3.3.0 装上了(截图自证"管理器版本 v3.3.0 (32601-2)")⇒ **在装就先读版本、不硬降级**
#   (`adb install -r` 装旧版本会被拒，而"降级"根本不是这一发的命题)。
if A "pm list packages $MGR" | grep -q "$MGR"; then
    echo "  官方 Manager 已在装：$(A "dumpsys package $MGR" | grep -a versionName | head -1 | tr -d '')"
else
    gate_install "$OFFAPK" "$MGR" || { echo "[x] 官方 Manager 装不上 ⇒ 停(没有加冕对象)"; exit 3; }
fi
gate_install "$SUWAPK" "$SUW" || { echo "[x] suw_nomgr 装不上 ⇒ 停(没有 root 侧通道)"; exit 3; }
# ★`grep -w com.termux` 会**同时命中 `com.termux.api`** ⇒ 三个数字拼成 `1066710817`，
#   这正是例 33 那一族(两个命中拼成一个假数)。这里改成"整字段精确匹配 + 必须只有一行"。
pk_uid() {   # pk_uid <包名> —— 整字段精确匹配，只取那一行的 uid 数字
    A "pm list packages -U" | tr -d '\r' |
        awk -v P="package:$1" '$1==P {split($2, a, ":"); print a[2]}'
}
MGRUID=$(pk_uid "$MGR"); SUWUID=$(pk_uid "$SUW"); TGTUID=$(pk_uid "$TGT")
for v in MGRUID SUWUID TGTUID; do
    eval "X=\$$v"
    case "$X" in (*[!0-9]*|"") echo "[x] $v 不干净：[$X] ⇒ 停(绝不带假 uid 往下打)"; exit 3;; esac
    [ "$(printf '%s
' "$X" | wc -l)" = 1 ] || { echo "[x] $v 有多行命中：[$X] ⇒ 停"; exit 3; }
done
echo "  uid 实况：官方=$MGRUID  suw=$SUWUID  目标 app=$TGTUID"
[ -n "$MGRUID" ] && [ -n "$SUWUID" ] && [ -n "$TGTUID" ] || { echo "[x] uid 取不全 ⇒ 停"; exit 3; }
[ "$MGRUID" != "$SUWUID" ] || { echo "[x] 两个 Manager 同一个 uid? 不可能 ⇒ 停"; exit 3; }

echo "=== 2) push ko → reboot → punch(bootstrap 会自己起 shd，suw 在场) ==="
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|uid 真源|^[0-9]+ [0-9]+|ok ksu_args|uname -s =|\[x\]" | sed 's/^/  /' | head -6
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = 1 ]; do sleep 5; done
sleep 40
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log" >/dev/null
I_KNOW=1 bash suw_apk/bootstrap.sh --punch >"$EV/w31_bootstrap.txt" 2>&1
echo "  bootstrap 退出码=$? ；原文最后 6 行："
tail -6 "$EV/w31_bootstrap.txt" | sed 's/^/    /'
PUNCHED=0
for i in $(seq 1 20); do sleep 5
    [ -n "$(A 'ls -l /data/local/tmp/punch.log 2>/dev/null')" ] && { PUNCHED=1; echo "  pr 已起跑(t+$((i*5))s)"; break; }
done
[ "$PUNCHED" = 1 ] || { echo "[x] punch.log 100 秒没出现 ⇒ pr 没派发，问题在 bootstrap 那一层"; exit 6; }
N=0
for i in $(seq 1 220); do sleep 5
    N=$(A "grep -ac '判据④' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  stage 到判据④ (t+$((i*5))s)"; break; }
    [ $((i % 20)) = 0 ] && echo "    还在等 post… t+$((i*5))s"
done
[ "${N:-0}" = "0" ] && { echo "[x] post 整 boot 没跑 ⇒ 这一发做不了"; exit 5; }

echo "=== 3) A 格：加冕到底给了谁(root 侧 ksuctl mgr，权威那份) ==="
adb push kmod/w157_mgr.sh /data/local/tmp/w157_mgr.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w157_mgr.sh; rm -f /data/local/tmp/w157_mgr.out" >/dev/null
fire "@sushd:/data/local/tmp/w157_mgr.sh" 6
WAITFOR /data/local/tmp/w157_mgr.out 40 '=== DONE ==='
A "head -c 2000 /data/local/tmp/w157_mgr.out 2>&1" | sed 's/^/    /'
echo "    ⇒ 期望 appid=$MGRUID(官方)，**不是** $SUWUID(suw_nomgr 只是普通被授权 app)"

echo "=== 4) 先把 su 挂出来(bind /product/bin)——这一发不能省，理由是一手否证"
#   ★第五十九发(本脚本第一版)按"绝对路径 /system/bin/su 能绕开探测、由 ko 的钩子接住"设计，
#     实测被 Termux 自己否掉了：`bash: /system/bin/su: No such file or directory`。
#     ⇒ §6.124 那条"要 bind 才存在 su"仍然成立；钩子接住的是**已存在的** /system/bin/su 的 execve，
#       它不会凭空造出一个文件来。这一格留着当反面教材(推断不能替真机，尤其不能替"我以为我记得")。
#   通道还在(suw_nomgr 参与不了王座但能被授权)，所以 bind 用 @sushd 代跑，不动 stage。
adb push cm57/sustatic /data/local/tmp/sustatic >/dev/null 2>&1
adb push kmod/w135_fix.sh /data/local/tmp/w135_fix.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh; rm -f /data/local/tmp/w135_fix.out" >/dev/null
fire "@sushd:/data/local/tmp/w135_fix.sh" 8
WAITFOR /data/local/tmp/w135_fix.out 40 "===== DONE"
A "grep -aE 'BIND_RC|SU_AT_TGT|SVC_SHELL|HEALTH' /data/local/tmp/w135_fix.out | cut -c1-120" | sed "s/^/    /"
#   ★`adb shell` 与 app 侧**不在同一个挂载命名空间**：shell 里看到"挂载行=0 / 没有 su"**不是**bind 失败，
    #     真正的独立视角是**被授权 app 自己**(第 6 段那次 su：ENOENT=看不见，not-allowed=看得见但没授权)。
A "echo shell 命名空间里(仅参考): 挂载行=$(grep -c pbin /proc/self/mountinfo)" | sed "s/^/    /"

echo "=== 5) B 格：官方 Manager 自己怎么说(加冕的权威证据是它自己的首页) ==="
ACT=$(A "cmd package resolve-activity --brief $MGR" | tail -1)
case "$ACT" in */*) : ;; *) ACT="$MGR/.ui.MainActivity" ;; esac
echo "  入口 = [$ACT](现查)"
A "am force-stop $MGR"; sleep 1
A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard" >/dev/null
#   上一发 `am start -n <组件>` 之后 uiautomator 只读到 "KernelSU"/"SU 白名单" 两张卡 ⇒
#   那是**最近任务**界面(截图里那条 ||| ✕ 手势栏就是证据)，Manager 根本没到前台。
#   ⇒ 用 launcher intent 起，并且**每步都核对当前焦点**，起不来就重试，绝不点"看不见的界面"。
FOC=""
for k in 1 2 3 4; do
    A "monkey -p $MGR 1" >/dev/null 2>&1; sleep 8
    FOC=$(A "dumpsys window 2>/dev/null | grep -a mCurrentFocus | head -1" | tr -d '')
    echo "    第 $k 次拉起：焦点=[$FOC]"
    case "$FOC" in *"$MGR"*) break;; esac
    A "am start -n $ACT -f 0x10000000" >/dev/null 2>&1; sleep 6
    FOC=$(A "dumpsys window 2>/dev/null | grep -a mCurrentFocus | head -1" | tr -d '')
    case "$FOC" in *"$MGR"*) echo "    (am start 后焦点对了)"; break;; esac
    A "input keyevent KEYCODE_HOME" >/dev/null; sleep 2
done
case "$FOC" in
  *"$MGR"*) : ;;
  *) echo "    [x] 官方 Manager 拉不到前台(焦点=[$FOC]) ⇒ C 格没法点，如实记没测到";;
esac
shot mgr_home
dump_ui mgr_home
for w in 工作中 越狱 32601 超级用户; do
    if tr "<" "\n" < "$EV/w31_mgr_home.xml" 2>/dev/null | grep -aq "$w"; then echo "    [有] $w"; else echo "    [无] $w"; fi
done

echo "=== 6) C/E 格：官方 UI 里把 $TGT 加进名单 → 它敲 su 出 root"
#   KSU 3.x 的超级用户页只列**名单里**的 app，所以要走"添加应用"那一支(不是弹窗——我们的 ko
#   没有实现"su 请求通知 Manager"这条路，这条也是本发实测出来的形状)。
tap_text() {   # tap_text <正则> <失败时说什么> —— uiautomator 现找 bounds，找不到就明说
    adb shell uiautomator dump /sdcard/w31.xml >/dev/null 2>&1
    adb pull /sdcard/w31.xml "$EV/w31_$3.xml" >/dev/null 2>&1
    B=$(tr "<" "\n" < "$EV/w31_$3.xml" 2>/dev/null | grep -aE "$1" | head -1 |
        grep -aoE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1)
    [ -z "$B" ] && { echo "    [!] 找不到 [$1] ⇒ 这一格没点到(绝不猜坐标)；看 $EV/w31_$3.png/.xml"; return 1; }
    set -- $(printf '%s' "$B" | sed -E "s/.*\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1 \2 \3 \4/")
    CX=$(( ($1 + $3) / 2 )); CY=$(( ($2 + $4) / 2 ))
    echo "    [$1,$2][$3,$4] ⇒ 点 ($CX,$CY)  ← $1 匹配 [$1]"
    A "input tap $CX $CY"; sleep 5; return 0
}
case "$FOC" in
  *"$MGR"*) A "input tap 270 2290" >/dev/null 2>&1; sleep 5;;
  *) echo "    (没焦点 ⇒ 跳过底部 tab 的固定坐标点击)";;
esac
shot su_tab
tap_text "超级用户" "" s0 || true
A "uiautomator dump /sdcard/x.xml" >/dev/null 2>&1
shot su_list
echo "    列表页里现在有哪些 app(tr 出来的 text)："
adb shell uiautomator dump /sdcard/w31.xml >/dev/null 2>&1
adb pull /sdcard/w31.xml "$EV/w31_list.xml" >/dev/null 2>&1
tr "<" "\n" < "$EV/w31_list.xml" 2>/dev/null | grep -aoE 'text="[^"]{1,28}"' | head -18 | sed "s/^/      /"
tap_text "添加|新增|Add|\+" "" add || true
shot add_page
tap_text "Termux" "" pick || true
shot picked
tap_text "确定|允许|保存|OK|完成" "" confirm || true
shot confirmed
echo "  --- 内核侧独立读数(名单里现在有没有 Termux) ---"
A "echo $TGTUID > /data/local/tmp/w157_tgt.uid" >/dev/null
adb push kmod/w157_g.sh /data/local/tmp/w157_g.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w157_g.sh; rm -f /data/local/tmp/w157_g.out" >/dev/null
fire "@sushd:/data/local/tmp/w157_g.sh" 6
WAITFOR /data/local/tmp/w157_g.out 40 "=== DONE ==="
A "grep -aE 'UID_GRANTED_ROOT|GET_MANAGER_APPID|bad-uid|目标 uid' /data/local/tmp/w157_g.out 2>&1 | cut -c1-140" | sed "s/^/    /"
echo "  --- Termux 敲 su(这一次 su 文件真的存在) ---"
A "am force-stop $TGT" >/dev/null; sleep 1
A "am start -n $TGT/.app.TermuxActivity" >/dev/null 2>&1 || A "monkey -p $TGT 1" >/dev/null 2>&1
sleep 12
A "input text '/system/bin/su'"; A "input keyevent 66"; sleep 5
A "input text 'id'; input keyevent 66"; sleep 8; shot termux_su
echo "    (截图 w31_termux_su.png 里期望看到 uid=0(root)；Termux 的终端内容 uiautomator 读不出来，"
echo "     所以这一格的第二来源是内核脚印，不是屏幕文字)"
A "grep -aE 'KSUBEAT (SU0|X7|X8)' /data/local/tmp/dmesg.live 2>/dev/null | grep -a 'uid=$TGTUID' | tail -5" | cut -c1-150 | sed "s/^/    /"
A "grep -acE 'KSUBEAT (SU0|X7|X8)' /data/local/tmp/dmesg.live 2>/dev/null" | sed "s/^/    脚印总条数: /"

echo "=== 7) F 格：收尾 → reboot → 复核(这一发没挂过载，所以只删载荷并复核行数) ==="
A "echo 收尾前: 挂载行=$(grep -c pbin /proc/self/mountinfo) su在product=$(ls /product/bin/su 2>&1 | head -1 | cut -c1-40)" | sed 's/^/    /'
A "rm -f /data/local/tmp/w157_mgr.sh /data/local/tmp/w157_mgr.out" >/dev/null
adb reboot
for i in $(seq 1 60); do sleep 5; [ -n "$(adb get-state 2>/dev/null | grep device)" ] && break; done
until [ "$(A 'getprop sys.boot_completed' | tr -dc 0-9)" = "1" ]; do sleep 10; done
sleep 20
echo "  收尾复核: $(A 'echo up=$(cut -d\" \" -f1 /proc/uptime) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) 挂载=$(grep -c pbin /proc/self/mountinfo) bin=$(ls -A /product/bin | wc -l)')"
echo "  截图/存证都在 $EV/w31_*"
