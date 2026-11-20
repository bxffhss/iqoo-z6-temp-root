#!/bin/bash
# w183_official_ui.sh —— #82：活窗口里把王座**确定地**指给官方 Manager，验四件事，最后指回来再跑一遍交付回归。
#   前提：KO=kmod/kernelsu_rc65.ko I_KNOW=1 bash kmod/go.sh 已起窗，且**官方 APK 这一发之前没装**。
#   ★为什么"窗口中间才装"是关键一招：加冕只发生在 insmod 那一刻(throne_tracker 扫 /data/app 认第一个匹配者)，
#     窗口中途 `pm install` **不会**重新加冕 ⇒ 先让 suw 照常在起窗时被认成王座、把退路 profile 写好，
#     再装官方、再把王座指过去 —— 反过来(起窗前就共存)就是 §6.169 那个 FAIL=6 的赌局。
#   四件事：① 王座确实换到人(内核侧两来源：slots 的 CROWN 行 + GET_MANAGER_APPID 那类读数)
#           ② 换完之后**我们的通道还活着**(前提=先把 suw 降级成"有 profile 的普通 app"，别裸切)
#           ③ 官方 Manager 能读到模块/驱动状态(截图为证；UI 点击能不能自动化这件事本身也是读数)
#           ④ 指回 suw 之后交付回归 G1~G7 仍全绿(证明这一格没留副作用)
#   收尾：卸载官方 APK(`pm uninstall`)，让设备回到"只装 suw"的交付形态。
#
# ★2026-10-08 两处修正（§6.186 收回"要改 APK"那句之后）：
#   ① 装机换 **root 侧** `runcon u:r:shell:s0 pm install`。今晚实测：`adb install`、shell(2000) 直接 `pm install`、
#      以及换 installer 身份(`-i com.bbk.appstore` / `-i com.android.vending`) **四条全部** `INSTALL_FAILED_ABORTED`
#      (锁屏是有密码的，vivo 那个全屏确认页点不到) ⇒ 原来这行 `adb install` 在无人托管下必挂。
#   ② 起完官方 UI **必须补 `echo <pid> > /proc/ksu_install_fd`**。这份 ksud-less 的 ko 里官方管理器只能扫
#      自身 `/proc/self/fd` 找驱动 fd，没人塞就永远显示"不支持/读不到"——上一发那 17 个 UI 节点里偏偏
#      没有『驱动版本』那一格，就是漏了这一步(不是官方 APK 自己有 GKI 闸)。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
OFLAPK=suw_apk/backup_official_kernelsu_v3.3.0.apk
OFL=${OFL:-}                        # 官方包名：装完之后从 pm list 里 diff 出来，绝不猜
CR=/data/local/tmp/w183_crown.sh
WANT=/data/local/tmp/w183_want.txt
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "${2:-12}"; }
crown() {   # crown <数字或?>：写把手并把 slots 里的回执捞回来
    A "printf '%s\n' '$1' > $WANT; rm -f /data/local/tmp/w183_crown.out" >/dev/null
    fire "@sushd:$CR" 6
    for i in $(seq 1 12); do
        c=$(A "grep -acF '===== DONE' /data/local/tmp/w183_crown.out 2>/dev/null" | tr -dc '0-9')
        [ "${c:-0}" != "0" ] && break; sleep 5
    done
    A "cat /data/local/tmp/w183_crown.out" | grep -aE "want=|CROWN |crown proc=|getenforce" | cut -c1-170 | sed 's/^/      /'
}
uidof() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }

echo "=== 0) 前置：窗口在、把手在、官方还没装 ==="
echo "  $(A 'echo mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 先起窗口"; exit 3; }
[ -n "$(A 'ls /proc/ksu_crown 2>/dev/null')" ] || { echo "[x] 没有 /proc/ksu_crown ⇒ ko 不是 rc65，停(什么都不设)"; exit 3; }
BEFORE=$(A "pm list packages -3" | sort)
SUWUID=$(uidof "$SUW")
case "$SUWUID" in ''|*[!0-9]*) echo "[x] suw uid 取不到"; exit 3;; esac
echo "  suw uid=$SUWUID；装第三方包之前的清单条目数=$(echo "$BEFORE" | grep -ac .)"
adb push kmod/w183_crown.sh /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 $CR" >/dev/null

echo "=== 1) 现在的王座是谁(两来源：把手回执 + go.sh 第 6 步那份 GET_MANAGER_APPID) ==="
crown "?"
echo "  $(A 'grep -a GET_MANAGER_APPID /data/local/tmp/w161_g2.out 2>/dev/null | head -1' | cut -c1-130)"

echo "=== 1.5) 窗口中间才装官方(这一刻起它才有 uid；加冕不会因此重跑) ==="
if [ -n "${OFL_PREINSTALLED:-}" ]; then
    echo "  [!] 检测到官方已预装(或手工指定)：OFL=$OFL_PREINSTALLED uid=$(uidof "$OFL_PREINSTALLED")"
    OFL=$OFL_PREINSTALLED; OFLUID=$(uidof "$OFL")
else
    ls -l "$OFLAPK" >/dev/null || { echo "[x] 没有 $OFLAPK"; exit 3; }
    # ★root 侧装：把 APK 放到 /data/local/tmp，让 uid 0 + 域 kernel 的通道代发 `runcon u:r:shell:s0 pm install`
    APKD=/data/local/tmp/w183_official.apk
    MSYS_NO_PATHCONV=1 adb push "$OFLAPK" "$APKD" 2>&1 | tail -1 | sed 's/^/      push: /'
    adb push kmod/w185_install.sh /data/local/tmp/ >/dev/null 2>&1
    A "chmod 755 /data/local/tmp/w185_install.sh; printf '%s\n' '$APKD' > /data/local/tmp/w185_want.txt; rm -f /data/local/tmp/w185_install.out" >/dev/null
    fire "@sushd:/data/local/tmp/w185_install.sh" 20
    for i in $(seq 1 15); do
        c=$(A "grep -acF '===== DONE' /data/local/tmp/w185_install.out 2>/dev/null" | tr -dc '0-9')
        [ "${c:-0}" != "0" ] && break; sleep 5
    done
    A "cat /data/local/tmp/w185_install.out" 2>/dev/null | grep -aE "apk=|rc=|Success|Failure|包数" | cut -c1-170 | sed 's/^/      /'
    AFTER=$(A "pm list packages -3" | sort)
    NEWPKG=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^package://' | head -1)
    [ -n "$NEWPKG" ] || { echo "[x] 装完没看到新增包 ⇒ 停(不猜包名；看上面 w185 回执是哪一层拦的)"; exit 4; }
    OFL=$NEWPKG; OFLUID=$(uidof "$OFL")
    echo "      新装包=$OFL uid=$OFLUID"
fi
case "$OFLUID" in ''|*[!0-9]*) echo "[x] 官方 uid 取不到($OFLUID)"; exit 4;; esac

echo "=== 2) ★先留退路：给 suw 写一条普通 app 的 profile(它降级后还要当 root 通道) ==="
fire "@setprof:$SUWUID:1:$SUW" 10
A "grep -a 'SETPROF uid=' /sdcard/Android/data/$SUW/files/ksu_grant.txt | tail -1" | cut -c1-170 | sed 's/^/      /'

echo "=== 2.5) ★把 Termux 的授权【撤掉】，做出「官方点之前拿不到」的基线(§6.188③.1：不撤销就是给自己看既有账) ==="
TGT=com.termux; TGTUID=$(uidof "$TGT")
case "$TGTUID" in ''|*[!0-9]*) echo "      [!] Termux uid 取不到 ⇒ 5c) 那一格只能标'不算'"; TGTUID=;; esac
if [ -n "$TGTUID" ]; then
    fire "@setprof:$TGTUID:0:$TGT" 10
    A "grep -a 'SETPROF uid=$TGTUID' /sdcard/Android/data/$SUW/files/ksu_grant.txt | tail -1" | cut -c1-170 | sed 's/^/      /'
    A "echo $TGTUID > /data/local/tmp/w161_u1.uid; echo $SUWUID > /data/local/tmp/w161_u2.uid; rm -f /data/local/tmp/w161_g2.out" >/dev/null
    fire "@sushd:/data/local/tmp/w161_g2.sh" 6
    BASE=$(A "grep -a \"UID_GRANTED_ROOT uid=$TGTUID\" /data/local/tmp/w161_g2.out 2>/dev/null" | head -1 | cut -c1-140)
    echo "      基线(应为 granted=0)：$BASE"
fi

echo "=== 3) 把王座指给官方 ==="
crown "$((OFLUID % 100000))"

echo "=== 4) 换完之后通道还活着吗(上面 crown 本身就是通过 @sushd 跑的 ⇒ 能出回执=活着) ==="
echo "  (若第 3 步一行回执都没回来 ⇒ 说明 suw 被降级后连不上，立刻进第 6 步指回来)"

echo "=== 5) ★起官方 UI → 写触发口(短腿) → 每 30s 读一次(短腿，原文留档) ——§6.186 那一步的正式版 ==="
A "runcon u:r:shell:s0 am start -n $OFL/.ui.MainActivity" >/dev/null 2>&1
A "am start -n $OFL/.ui.MainActivity" >/dev/null 2>&1
sleep 12
adb push kmod/w186_fdwrite.sh kmod/w186_fdread.sh /data/local/tmp/ 2>&1 | tail -1 | sed 's/^/      push: /'
A "chmod 755 /data/local/tmp/w186_fdwrite.sh /data/local/tmp/w186_fdread.sh; printf '%s\n' '$OFL' > /data/local/tmp/w186_want.txt; rm -f /data/local/tmp/w186_fdwrite.out /data/local/tmp/w186_fdread.out /data/local/tmp/w186_fdline.txt" >/dev/null
fire "@sushd:/data/local/tmp/w186_fdwrite.sh" 8
for i in $(seq 1 10); do   # ★等 DONE 再读(§6.193④：没等到 != 死在写之前)
    c=$(A "grep -acF '===== DONE' /data/local/tmp/w186_fdwrite.out 2>/dev/null" | tr -dc '0-9')
    [ "${c:-0}" != "0" ] && break; sleep 4
done
[ "${c:-0}" != "0" ] || echo "      [!] 写腿 40s 内没等到 DONE ⇒ 只记'没等到'，别记成'死在某一步'(要看 .out 到哪一行)"
A "cat /data/local/tmp/w186_fdwrite.out" 2>/dev/null | grep -aE "pkg=|pid=|写下去|写之前|写完还活着|\[x\]|\[!\]" | cut -c1-175 | sed 's/^/      写腿: /'
WD=$(A "grep -acF '===== DONE' /data/local/tmp/w186_fdwrite.out 2>/dev/null" | tr -dc '0-9')
[ "${WD:-0}" != "0" ] || echo "      ★写腿(只干活 <5s)也没跑到 DONE ⇒ §6.188⑤ 那个死法复现在短腿上，死因偏向'写触发口这条路径对写者本身有影响'，不是'脚本跑太久被收回'"
FD_SEEN=0
for r in 1 2 3 4; do
    sleep 30      # §6.14x：`已排队`→`回调跑在` 实测可隔 0.09s~47s，所以第一读放在 30s
    A "rm -f /data/local/tmp/w186_fdread.out" >/dev/null
    fire "@sushd:/data/local/tmp/w186_fdread.sh" 8
    A "cat /data/local/tmp/w186_fdread.out" 2>/dev/null | grep -aE "pid=|state=|stderr|fd 总数=|含 ksu|KSUFDINST|\[!\]" | cut -c1-175 | sed 's/^/      读'"$r"'(t+'$((r*30))'s): /'
    MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w186_fdline.txt "$EV/w188_fdline_r$r.txt" >/dev/null 2>&1
    # ★§6.193④：不能拿"整段输出里的数字"当计数——文件不存在时 mksh 的报错文本里带着路径中的 `186`，
    #   被 tr -dc 挤成非空 ⇒ 判成"命中"(实际文件 0 字节)。先 `-s`(存在且非空)再取数。
    HIT=$(A "if [ -s /data/local/tmp/w186_fdline.txt ]; then wc -l < /data/local/tmp/w186_fdline.txt; else echo 0; fi" | tr -dc '0-9')
    if [ "${HIT:-0}" != "0" ]; then FD_SEEN=1
        echo "      ✅ 第 $r 读命中：fd 表原文已存 $EV/w188_fdline_r$r.txt ⇒ 这一格坐实(此后**别急着卸载官方**，§6.188①)"
        break
    fi
done
[ "$FD_SEEN" = 1 ] || echo "      四轮(120s)都没命中 ⇒ 只记成'这一发没观察到'，**不记成机制不干活**"
# ★§6.193②：今晚实测——**进程起来之后再补 fd，官方页不会重查**(两次读到的都还是「不支持 GKI」页，
#   而 fd 明明在它 fd 表里)。唯一让它变成「工作中 [越狱模式] 版本：32601-2」的形状是**抢在启动那次查询之前**：
#   起 0.4s 看门狗 → force-stop 官方 → am start → 新 pid 一出现就被塞 fd。整段在设备侧一条腿里跑完(w191_race.sh)。
adb push kmod/w191_race.sh kmod/w161_fdwatch.sh /data/local/tmp/ 2>&1 | tail -1 | sed 's/^/      push: /'
A "chmod 755 /data/local/tmp/w191_race.sh /data/local/tmp/w161_fdwatch.sh; rm -f /data/local/tmp/w191_race.out /data/local/tmp/w161_fdwatch.log" >/dev/null
fire "@sushd:/data/local/tmp/w191_race.sh" 10
for i in $(seq 1 12); do
    c=$(A "grep -acF '===== DONE' /data/local/tmp/w191_race.out 2>/dev/null" | tr -dc '0-9')
    [ "${c:-0}" != "0" ] && break; sleep 5
done
A "cat /data/local/tmp/w191_race.out" 2>/dev/null | grep -aE "race up=|看门狗|新 pid|原文:|王座读口|节点数|text=|getenforce|\[!\]|\[x\]" | cut -c1-170 | sed 's/^/      race: /'
[ "${c:-0}" != "0" ] || echo "      [!] race 腿 60s 没等到 DONE ⇒ 只记'没等到'(.out 停在哪儿就是哪儿)"
echo "=== 5b) 官方页读数：判据就是『驱动版本』那一格在不在(上一发偏偏没有它) ==="
A "dumpsys window 2>/dev/null | grep -aE 'mFocusedApp=' | tail -1" | cut -c1-170 | sed 's/^/      焦点: /'
A "screencap -p /data/local/tmp/w186_official.png" >/dev/null 2>&1
MSYS_NO_PATHCONV=1 adb pull /data/local/tmp/w186_official.png "$EV/w186_official.png" >/dev/null 2>&1 \
    && echo "      存 $EV/w186_official.png ($(stat -c %s "$EV/w186_official.png" 2>/dev/null) 字节)" || echo "      [!] 截图没拿到(不影响 ①②④ 的判定)"
U=/data/local/tmp/w186_ui.xml
RAW=$(A "rm -f $U; uiautomator dump $U >/dev/null 2>&1; cat $U 2>/dev/null")
# ★§6.188②：锁屏时这棵树拍的是**锁屏/下拉栏**，不是官方页 ⇒ 先量"树里有没有官方自己的节点"，为 0 就下面三条一律不算
OWN=$(printf '%s' "$RAW" | tr '<' '\n' | grep -ac "package=\"$OFL\"")
echo "      这棵树里官方自己的节点数=$OWN  $( [ "$OWN" = 0 ] && echo '⇒ 没拍到官方页(锁屏或在别的窗)，下面三条判据本轮作废(§6.188②)' )"
TXT=$(printf '%s' "$RAW" | tr '>' '\n' | grep -aoE 'text="[^"]+"' | grep -av 'text=""' | sed 's/^/        /')
[ -n "$TXT" ] || echo "      UI 树 dump 不出来(与 §6.168 的 Compose 页 null 一致 ⇒ 授权那一下只能真人点)"
echo "$TXT" | head -24
echo "      ---- 三条判据(OWN=0 时一律不看) ----"
echo '      有『驱动版本』格: '"$(echo "$TXT" | grep -a '驱动版本' | wc -l)"
echo '      驱动版本那格里像真值(不含 -1/未知): '"$(echo "$TXT" | grep -a '驱动版本' | grep -avc -E '\-1|未知|无法')"
echo '      仍在说『不支持』: '"$(echo "$TXT" | grep -a '不支持' | wc -l)"
echo "      不靠屏幕的旁证(§6.188⑥)：Manager 自己的 logcat —"
A "logcat -d -v brief 2>/dev/null | grep -aiE 'kernelsu|libsu|RootService' | tail -12" | cut -c1-165 | sed 's/^/        /'

echo "=== 5c) 最后那一格：在官方 UI 里给 Termux 开开关(真人点，或 AUTO_TAP=1 试自动) ==="
TGTUID=$(uidof com.termux)
case "$TGTUID" in ''|*[!0-9]*) echo "      [!] Termux uid 取不到 ⇒ 只能靠截图核对"; TGTUID=;; esac
tap_ofl() {   # 只在**官方自己的节点**里找(绝不点别人的窗)，命中就点 bounds 中心
    local RX=$1 B XY
    B=$(A "rm -f $U; uiautomator dump $U >/dev/null 2>&1; cat $U 2>/dev/null" \
        | tr '<' '\n' | grep -a "$OFL" | grep -aE "text=\"$RX\"|content-desc=\"$RX\"" \
        | grep -aoE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1)
    [ -n "$B" ] || { echo "        没找到节点[$RX]"; return 1; }
    # ★别用 `tr -d 'bounds=[]'`：那会把两组坐标之间的 `][` 一起吃掉，四个数粘成三个 ⇒ 点到天上去(本地干跑抓到的)
    XY=$(echo "$B" | sed -E 's/.*\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\].*/\1 \2 \3 \4/' \
         | awk '{print int(($1+$3)/2)" "int(($2+$4)/2)}')
    echo "        点[$RX] @ $XY  (来自 $B)"
    A "input tap $XY" >/dev/null; sleep 6; return 0
}
KG=$(A "dumpsys window 2>/dev/null | grep -ac 'isKeyguardShowing=true'")
echo "      锁屏在否: $KG  (非 0 = 要先人工解锁，自动点不了)"
if [ "${AUTO_TAP:-0}" = 1 ] && [ "$KG" = 0 ]; then
    tap_ofl "超级用户" || tap_ofl "Superuser"
    tap_ofl "添加菜单项" || tap_ofl "加号" || tap_ofl "+"
    tap_ofl "com.termux" || tap_ofl "Termux"
    tap_ofl "允许" || tap_ofl "Toggle" || true
else
    [ "${AUTO_TAP:-0}" = 1 ] && echo "      [!] 要自动点但锁屏在 ⇒ 跳过点击(§6.188：锁屏下 dump 拍的是锁屏)"
    echo "      手动：超级用户 → ＋ → Termux → 开关(这一步历史上只差人)"
fi
# ★§6.188③.1：这一格只有"2.5) 撤销成功(BASE 里 granted=0)"时才成立，否则读到 1 是**既有账**
if [ -z "$TGTUID" ] || case "$BASE" in *granted=0*) false;; *) true;; esac; then
    echo "      [x] 基线不是 granted=0(BASE=[$BASE]) ⇒ 这一格**不判**，别把既有授权当成官方点出来的"
else
    echo '      ★轮询内核名单(不靠界面)：等 uid='"$TGTUID"' 的 UID_GRANTED_ROOT 从 0 变 1，最多 '"$(( ${HOLD:-6} * 60 ))"'s'
    for i in $(seq 1 $(( ${HOLD:-6} * 12 ))); do
        A "echo $TGTUID > /data/local/tmp/w161_u1.uid; echo $SUWUID > /data/local/tmp/w161_u2.uid; rm -f /data/local/tmp/w161_g2.out" >/dev/null
        fire "@sushd:/data/local/tmp/w161_g2.sh" 6
        G=$(A "grep -a \"UID_GRANTED_ROOT uid=$TGTUID\" /data/local/tmp/w161_g2.out 2>/dev/null" | head -1 | cut -c1-140)
        echo "        $G"
        case "$G" in *granted=1*) echo "      ✅ 撤销过之后又变回 1 ⇒ 这一写只可能来自官方 Manager(王座现在是它)"; break;; esac
        sleep 4
    done
fi

echo "=== 6) 指回 suw，并复跑交付回归(证明这一格没留副作用) ==="
crown "$((SUWUID % 100000))"
# ★2.5) 撤掉的 Termux 授权要还得回去：否则这一窗后半段(以及 regress 里"真 app 敲 su"那格)是被我自己抽掉的前提(例43)
if [ -n "$TGTUID" ]; then
    fire "@setprof:$TGTUID:1:$TGT" 10
    A "echo $TGTUID > /data/local/tmp/w161_u1.uid; echo $SUWUID > /data/local/tmp/w161_u2.uid; rm -f /data/local/tmp/w161_g2.out" >/dev/null
    fire "@sushd:/data/local/tmp/w161_g2.sh" 6
    echo "      还回去之后：$(A "grep -a \"UID_GRANTED_ROOT uid=$TGTUID\" /data/local/tmp/w161_g2.out 2>/dev/null" | head -1 | cut -c1-140)"
fi
SKIP_CHAIN=1 KEEP=1 I_KNOW=1 bash kmod/regress_ksu.sh 2>&1 | grep -aE "^\s*\[G|汇总" | tail -10 | sed 's/^/      /'
echo "=== 7) 卸载官方，回到"只装 suw"的交付形态 ==="
if [ "${KEEP_OFL:-0}" = 1 ]; then
    echo '      [i] KEEP_OFL=1 ⇒ 不卸载(要接着人工看/点官方 UI)。★用完记得 root 侧 runcon u:r:shell:s0 pm uninstall <包名> 再收尾'
elif [ -z "${OFL_PREINSTALLED:-}" ] && [ -n "${OFL:-}" ]; then
    MSYS_NO_PATHCONV=1 adb uninstall "$OFL" 2>&1 | tail -1 | sed 's/^/      /'
    echo "      现在还在的第三方包数=$(A 'pm list packages -3' | grep -ac .)  官方在否=$(A "pm list packages | grep -ac "$OFL"")"
else
    echo "      [i] 官方是发前就装的 ⇒ 不自动卸载(那是你机器上的既有 app)"
fi
echo "  ★判据：①两次 CROWN 回执都对得上 appid ②换王座后 @sushd 仍出回执 ③官方 UI 截图里能看到驱动版本/工作状态"
echo "         ④指回之后 G1~G7 仍全 PASS。★收法：I_KNOW=1 bash kmod/w161_teardown.sh"
