#!/bin/bash
# 第七十一发驱动器：管理面闭环(§6.76)。
#   前提：设备侧 ksu_one_stage.sh v44 已经跑到**判据⑤闸门**(等 /data/local/tmp/ksu_ui_done)。
#   这一发的口径 = "改授权的那只手是 KernelSU 自己的管理面"，所以每一步都留一手证据：
#     1 @mgr                 app 问内核"谁坐王座" ⇒ 期望 appid=10284(=我们被 crown 了)
#     2 @sushd:…MARK_ON      守护以 uid 0 跑掉命令(基线)
#     3 @setprof:10172:1     **app 自己**(SET_APP_PROFILE=only_manager)把另一个 app 的 uid 加进名单
#                            ⇒ 报告里 UID_GRANTED_ROOT uid=10172 必须 granted=1，设备侧自记的
#                              NEW_GET_ALLOW_LIST count 也应当从 1 变 2
#     4 @setprof:10172:0     再摘掉 ⇒ granted 必须回 0 ⇒ **双向**都成立才算"手在我们这边"
#     5 @setprof:10284:0     摘自己 ⇒ 期望 granted **仍是 1**：`__ksu_is_allow_uid()` 里
#                            `is_uid_manager(uid)` 那支是"manager is always allowed!"(allowlist.c:264)
#                            ⇒ 这不是判据失败，是 KernelSU 自己的语义；所以"拒掉自己"这一格本机做不到
#     6 @sushd:…MARK_ON2     与第 5 步同一口径的旁证：照样跑得起来
#   收尾写 ksu_ui_done 让设备侧继续清理(不留持久化)。
set -u
cd "$(dirname "$0")/.."
ADB=${ADB:-adb}
S() { MSYS2_ARG_CONV_EXCL='*' $ADB shell "$1" 2>&1 | tr -d '\r'; }
PKG=com.suw.manager
REPORT=/sdcard/Android/data/$PKG/files/ksu_grant.txt
CTL=/data/local/tmp/ksuctl
OUTDIR=kmod/mgr_w_$(date +%m%d_%H%M)
mkdir -p "$OUTDIR"
say() { echo "[$(date +%H:%M:%S)] $*"; }

# 每步：触发 app(带 cmd) -> 等它把报告写完 -> 把报告抓回来
step() {
    local tag="$1" cmd="$2" wait="${3:-9}"
    say "[$tag] am start cmd=[$cmd]"
    # ★必须先 force-stop：app 还活着时 `am start` 只会回
    #   "Activity not started, intent has been delivered to currently running top-most instance"
    #   ⇒ 走 onNewIntent 不走 onCreate，而我们的触发点在 onCreate ⇒ 报告文件根本不会被写
    #   (第七十二发前五步就是这么全部打在空气上的)。
    S "am force-stop $PKG; rm -f $REPORT" >/dev/null 2>&1
    sleep 1
    S "am start -n $PKG/.MainActivity --es auto ksuarm --es cmd \"$cmd\"" >"$OUTDIR/$tag.am.txt" 2>&1
    sleep "$wait"
    say "[$tag] 报告:"
    S "cat $REPORT 2>&1" | tee "$OUTDIR/$tag.report.txt" | sed 's/^/     /'
}

say "证据目录=$OUTDIR"
say "0 等守护起来(★不等判据⑤：判据④要等 app 报告，而本驱动第一步就是触发 app ⇒"
say "   死等闸门会白烧 720s。守护一在听就开跑，触发顺便把判据④喂掉)"
# ★必须两个条件同时成立：lsmod 里有 kernelsu(**本 boot** 才有，模块不跨重启) + 守护在听。
#   第七十一发就是被 /data/local/tmp/sushd.log 的**上一 boot 残留**骗了：守护还没起来就开跑，
#   六步全部打在空气上(和"报告文件跨重启残留"是同一族坑，见记忆 env-shell-gotchas)。
for i in $(seq 1 180); do
    LM=$(S "lsmod | grep -c kernelsu")
    SD=$(S "grep -ac 'sushd: 在听' /data/local/tmp/sushd.log 2>/dev/null")
    if [ "$LM" != "0" ] && [ "$SD" != "0" ] && [ -n "$SD" ]; then
        say "  本 boot 的模块已加载且守护在听(第 $i 次轮询)"
        break
    fi
    sleep 10
done
S "lsmod | grep -i kernelsu; $CTL mgr 2>&1 | tail -1; $CTL info 2>&1 | tail -2" | tee "$OUTDIR/00_root_side_before.txt"

say "  ★root 侧自己问一次王座(perm=manager_or_root ⇒ root 也读得到)：上面 appid 一行"
say "  如果这里 appid=4294967295(未 crown)，后面 app 的 SET_APP_PROFILE 必然 EPERM ⇒ 直接判 identity-2 没成立"

step 10_mgr "@mgr" 8
step 20_run_on "@sushd:id; echo MARK_MGR_ON; grep -m1 ^Uid: /proc/self/status" 12
step 30_add_other "@setprof:10172:1" 8
step 40_del_other "@setprof:10172:0" 8
step 50_revoke_self "@setprof:10284:0" 8
step 60_run_on2 "@sushd:id; echo MARK_MGR_ON2; grep -m1 ^Uid: /proc/self/status" 12

say "守护侧日志(内核答 granted 的那几行才是判定现场):"
S "tail -30 /data/local/tmp/sushd.log" | tee "$OUTDIR/70_sushd.log" | sed 's/^/     /'
say "设备侧自记阶梯(每 10s 一次 mgr/granted/allowlist):"
S "grep -E 'GET_MANAGER_APPID|UID_GRANTED_ROOT uid=10284|NEW_GET_ALLOW_LIST' /data/local/tmp/ksu_ui_track.txt 2>/dev/null | tail -30" \
    | tee "$OUTDIR/71_ui_track.txt" | sed 's/^/     /'
S "cp /data/local/tmp/ksu_ui_track.txt /data/local/tmp/ksu_stage.log /sdcard/ 2>/dev/null; chmod 666 /sdcard/ksu_ui_track.txt /sdcard/ksu_stage.log 2>/dev/null"
MSYS2_ARG_CONV_EXCL='*' $ADB pull /sdcard/ksu_ui_track.txt "$OUTDIR/" >/dev/null 2>&1
MSYS2_ARG_CONV_EXCL='*' $ADB pull /sdcard/ksu_stage.log "$OUTDIR/" >/dev/null 2>&1
say "放行设备侧收尾(它会删干净并结束本 boot 的一切):"
S "touch /data/local/tmp/ksu_ui_done"
say "读结论：$OUTDIR/10_mgr.report.txt(王座) + 30/50(SETPROF rc) + 20/40/60(能不能跑)"
say "判据口径：30 之后 granted(10172)=1 且 count=2；40 之后 granted(10172)=0 且 count 回 1；"
say "          50 之后 granted(10284) 仍=1(manager 永远放行，allowlist.c:264) ⇒ 60 照旧能跑"
