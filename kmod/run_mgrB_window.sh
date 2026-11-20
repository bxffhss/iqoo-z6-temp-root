#!/bin/bash
# 第七十三发驱动器：**路线 B 的判据** —— 用官方 KernelSU v2.0.0 Manager 当管理面。
# 为什么是 v2.0.0：v3.3.0 自己按"只支持 GKI 内核"把 5.4 挡在门外(§6.76③)，而 v2.0.0 在同一族
#   内核上显示"工作中"；且它的 signing block 里**没有 v3 pair**(§6.77 那个把验签结果丢掉的坑)，
#   证书指纹 `c371061b…` 正好等于 ko 的 identity-1 ⇒ **零改动**就会被加冕。
# 王座只有一把(throne_tracker 找到第一个 is_manager 就 stop) ⇒ suw.apk 已换成一次性密钥签名
#   (CN=suw-nomgr, sha256 d92254fd…)，不再参与争位，退成"普通被授权 app"。
#
# 判据链(每一步都留一手证据，不看退出码)：
#   A root 侧 `ksuctl mgr`          -> 期望 appid=官方 Manager 的 uid(=10304 一类)，不是 suw 的
#   B 官方 UI 截图                   -> 期望"工作中"，能进超级用户列表
#   C UI 里撤掉 suw 的 root          -> 设备侧自记 granted(suw) 必须翻成 0
#   D 撤掉之后 app 发 @sushd: 请求    -> 守护必须答 granted=0 并回 PERM(★这才是过去做不到的端到端负对照)
#   E UI 里重新给上                  -> granted 回 1
#   F 再发 @sushd:                   -> 以 uid 0 跑掉并留下产物
set -u
cd "$(dirname "$0")/.."
ADB=${ADB:-adb}
S() { MSYS2_ARG_CONV_EXCL='*' $ADB shell "$1" 2>&1 | tr -d '\r'; }
PKG=com.suw.manager
MGRPKG=me.weishu.kernelsu
REPORT=/sdcard/Android/data/$PKG/files/ksu_grant.txt
CTL=/data/local/tmp/ksuctl
OUTDIR=kmod/mgrB_$(date +%m%d_%H%M)
mkdir -p "$OUTDIR"
say() { echo "[$(date +%H:%M:%S)] $*"; }
IDS=$(S "cat /data/local/tmp/ksa_uids.txt 2>/dev/null")
SUWID=${IDS%% *}; MGRID=${IDS##* }
say "uid 真源 ksa_uids.txt = [$IDS] ⇒ suw=$SUWID 官方=$MGRID"

# 触发 app：★必须先 force-stop(app 活着时 am start 只走 onNewIntent，我们的触发点在 onCreate)
step() {
    local tag="$1" cmd="$2" wait="${3:-10}"
    S "am force-stop $PKG; rm -f $REPORT" >/dev/null 2>&1
    sleep 1
    S "am start -n $PKG/.MainActivity --es auto ksuarm --es cmd \"$cmd\"" >"$OUTDIR/$tag.am.txt" 2>&1
    sleep "$wait"
    say "[$tag] 报告:"
    S "cat $REPORT 2>&1" | tee "$OUTDIR/$tag.report.txt" | sed 's/^/     /'
}

say "0 等本 boot 的模块 + 守护(双因子，防上一 boot 的 sushd.log 残留骗人)"
for i in $(seq 1 180); do
    LM=$(S "lsmod | grep -c kernelsu"); SD=$(S "grep -ac 'sushd: 在听' /data/local/tmp/sushd.log 2>/dev/null")
    if [ "$LM" != "0" ] && [ -n "$SD" ] && [ "$SD" != "0" ]; then say "  就绪(第 $i 次)"; break; fi
    sleep 10
done
say "A root 侧问王座:"
S "$CTL mgr 2>&1 | tail -1; $CTL granted $SUWID 2>&1 | tail -1; $CTL granted $MGRID 2>&1 | tail -1" | tee "$OUTDIR/A_root.txt" | sed 's/^/     /'
say "   ★期望 appid=$MGRID(官方被加冕)。若 appid=$SUWID 说明 suw 的签名没换成功/王座被抢。"
S "am force-stop $MGRPKG" >/dev/null 2>&1
ACT=$(S "cmd package resolve-activity --brief $MGRPKG 2>/dev/null | tail -1")
[ -n "$ACT" ] || ACT="$MGRPKG/.MainActivity"
say "B 打开官方 Manager($ACT)，截图看是不是'工作中':"
S "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; sleep 1; am start -n $ACT" >/dev/null 2>&1
sleep 6
adb exec-out screencap -p > "$OUTDIR/B_mgr_home.png" 2>/dev/null
S "input tap 540 1200" >/dev/null 2>&1
sleep 4
adb exec-out screencap -p > "$OUTDIR/B_mgr_tap.png" 2>/dev/null
say "   截图 = $OUTDIR/B_mgr_home.png / B_mgr_tap.png(人眼看：有没有'工作中'、能不能进列表页)"
say "C~F 这三步要**人在 UI 上点开关**，点完再回来跑本脚本的 --second 段(它只读自记阶梯+发 D/F 两次请求)"
if [ "${1:-}" = "--second" ]; then
    step D_run_off "@sushd:id; echo MARK_B_OFF; grep -m1 ^Uid: /proc/self/status" 12
    step F_run_on "@sushd:id; echo MARK_B_ON; grep -m1 ^Uid: /proc/self/status" 12
    say "守护侧现场:"
    S "tail -20 /data/local/tmp/sushd.log" | tee "$OUTDIR/sushd.log" | sed 's/^/     /'
    S "touch /data/local/tmp/ksu_ui_done"
    say "已放行设备侧收尾(它会删干净)"
fi
say "设备侧自记阶梯(每 10s：mgr/granted/名单长度)拉回本地："
S "cp /data/local/tmp/ksu_ui_track.txt /sdcard/ 2>/dev/null; chmod 666 /sdcard/ksu_ui_track.txt 2>/dev/null"
MSYS2_ARG_CONV_EXCL='*' $ADB pull /sdcard/ksu_ui_track.txt "$OUTDIR/" >/dev/null 2>&1
S "grep -E 'GET_MANAGER_APPID|UID_GRANTED_ROOT' $OUTDIR/ksu_ui_track.txt 2>/dev/null | tail -12" 2>/dev/null | sed 's/^/     /'
S "grep -E 'GET_MANAGER_APPID|UID_GRANTED_ROOT' /data/local/tmp/ksu_ui_track.txt 2>/dev/null | tail -14" | sed 's/^/     /'
