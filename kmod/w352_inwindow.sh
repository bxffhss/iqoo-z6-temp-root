#!/usr/bin/env bash
# w352_inwindow.sh —— 第 118 发(**allowlist 加 10104**那一发)窗口内的固定次序。
#
# 前提：`ARGS_FILE=kmod/ksu_args_rc69.txt KO=kmod/kernelsu_rc69.ko I_KNOW=1 bash kmod/go.sh` 已经把窗口开起来。
# 本脚本只量，不开窗、不 punch、不清场。
#
# ★判据顺序(§7 of W345)：①名单(stage 日志 + 内核 count/granted) → ②放模块后**立刻** root 列一次 →
#   ③模块页**截图**(a11y 树在这页只有四个导航标签，第 115/116 发两次一致) → ④SX2 差值 → ⑤Debug{Su} 还跟不跟 EPERM。
# ★两条硬规矩(都是付过学费的)：
#   · 窗口内做 UI 判据**绝不 force-stop 官方 Manager**(§6.258③：fd 装在那个进程里，杀掉就掉回"不支持"，
#     抢装窗口只在 insmod 后几十秒 ⇒ 等于把这一格判据丢到下一个 boot)。
#   · "放模块 → 列 → 截图"挤进同一个 60 秒(§6.255③：/data/adb/modules 会在几分钟内消失，机制未知)。
set -u
export MSYS_NO_PATHCONV=1 PYTHONUTF8=1 PYTHONIOENCODING=utf-8
EV=kmod/w103_evidence; MGR=me.weishu.kernelsu
mkdir -p "$EV"
S(){ timeout 60 adb shell "$1" 2>&1 | tr -d '\r'; }
# leg <设备脚本名> <设备产物名> <本地存证名>   —— 三个名字各自独立(rleg 传不进参数)
leg(){ local scr=$1 devout=$2 lout=$3
    S "rm -f /data/local/tmp/$devout" >/dev/null
    timeout 200 bash kmod/w211_ui.sh rleg "$scr" >/dev/null 2>&1
    adb pull "//data/local/tmp/$devout" "$EV/$lout" >/dev/null 2>&1
    if [ -s "$EV/$lout" ]; then
        grep -ac '===== DONE' "$EV/$lout" >/dev/null 2>&1 && echo "  $lout: 有 DONE($(wc -c <"$EV/$lout") B)" \
            || echo "  !! $lout 拉到了但**没有 DONE 行** ⇒ 只算半程读数"
    else
        echo "  !! $lout 空的或没拉到 ⇒ 别看旧内容下结论"
    fi
}

echo "=== 0) 硬闸：窗口在不在(mod 必须=1) ==="
MOD=$(S "grep -c kernelsu /proc/modules"); ENF=$(S getenforce); UP=$(S "cut -d' ' -f1 /proc/uptime")
echo "  mod=$MOD enf=$ENF up=$UP  现在=$(date +%H:%M:%S)"
[ "$MOD" = 1 ] || { echo "[x] ko 没加载 ⇒ 窗口不在，什么都别做"; exit 3; }

echo; echo "=== 1) ★判据①：名单——stage 日志里'写了几条'与'开关内容' ==="
S "grep -aE 'ksu_two_profiles|开关内容|mkallow|字节|allowlist' /data/local/tmp/ksu_stage.log 2>/dev/null | tail -12" \
  | cut -c1-200 | sed 's/^/  /'
echo '  ★期望三条都在：开关内容=[10104:me.weishu.kernelsu 10304:com.suprobe.app]、mkallow 追加=[…](非空)、wrote …: 8 + 3*784 = 2360 字节'
echo '  若看到"退回单条目"或"两条目分支没成立" ⇒ 名单判据作废，后面的 count 无从解读'

echo; echo "=== 2) 铺设备脚本(md5 对表，不靠'我记得推过了') ==="
for f in w345_samplemod_dev.sh w352_place_list_dev.sh w347_rc69_probe_dev.sh; do
    adb push "kmod/$f" /data/local/tmp/ >/dev/null 2>&1
    L=$(md5sum "kmod/$f" | cut -c1-32); R=$(S "md5sum /data/local/tmp/$f 2>/dev/null" | cut -c1-32)
    echo "  $f 本地=$L 设备=$R $([ "$L" = "$R" ] && echo ✓ || echo '★不一致——这一格的读数不能用')"
done
S "chmod 755 /data/local/tmp/w345_samplemod_dev.sh /data/local/tmp/w352_place_list_dev.sh /data/local/tmp/w347_rc69_probe_dev.sh /data/local/tmp/testmod 2>/dev/null" >/dev/null
adb push kmod/testmod /data/local/tmp/ >/dev/null 2>&1
echo "  素材回执：设备侧 module.prop id=[$(S "grep -m1 '^id=' /data/local/tmp/testmod/module.prop 2>&1 | tr -d '\r')"]"

echo; echo "=== 3) ★一条腿里做完：放模块 → root 列一次 → 内核名单/条数 → SX2 基线 ==="
leg w352_place_list_dev.sh w352_place_list_dev.out w352_place_list.out
grep -a -E 'uid=|SAMPLEMOD|libksud.so=|LIST_RC|suwmarker|uid=10104|uid=10319|uid=10304|count=|allow\[|modules=|SX2_COUNT|SD1_UID10104' \
    "$EV/w352_place_list.out" 2>/dev/null | cut -c1-190 | sed 's/^/  /'

echo; echo "=== 4) ★判据③：模块页**截图**(不 force-stop，不重装) ==="
bash kmod/w351_modpage_shot.sh w352 2>&1 | sed 's/^/  /'

echo; echo "=== 5) 判据④：截图**之后**立刻再读一次 SX2/Seccomp(与第 3 步的差值才算数) ==="
leg w347_rc69_probe_dev.sh w347_rc69.out w347_w352_after.out
grep -a -E 'SX2_COUNT|SD1_UID10104|Seccomp|ksud::cli|modules 目录=|uid=' \
    "$EV/w347_w352_after.out" 2>/dev/null | cut -c1-190 | sed 's/^/  /'

echo; echo "=== 6) 判据⑤：Manager 的 su 动词还报不报 EPERM ==="
S "logcat -d -s KernelSU 2>/dev/null | grep -aE 'Debug \{ command: Su|Operation not permitted|Error' | tail -14" \
  | cut -c1-200 | sed 's/^/  /'

echo
echo '★收尾(手动，一条别少)：bash kmod/w310_kill.sh → bash kmod/w300_clean.sh → adb reboot'
echo '★这一发比平时多一条：rm /data/local/tmp/ksu_two_profiles(留着=下一发默认被改)'
echo "  现在=$(date +%H:%M:%S) up=$(S "cut -d' ' -f1 /proc/uptime")"
