#!/bin/bash
# 窗口 96：路线 C 的**管理面端到端**判据(全走 app，不走 PC 侧 root)。
# 每一步都是：force-stop(触发点在 onCreate) -> am start 带 --es cmd "<动词>" -> 读 app 自己的报告。
# 判据链(缺一不算通过)：
#   ① @mgr   : 本 app 必须坐在王座上(appid == uid%100000)，否则 SET_APP_PROFILE 会 only_manager 拒掉
#   ② @list  : 读到内核名单(应当含自己) —— 这是"UI 上的开关状态以内核为准"的读侧
#   ③ @setprof:<目标 uid>:1:<目标包名> : 给**别的 app**加白名单
#   ④ @list  : 目标 uid 必须出现在名单里(★不是"调用没报错"，是"再读一遍看在不在")
#   ⑤ @setprof:<目标 uid>:0:<目标包名> : 撤掉
#   ⑥ @list  : 目标 uid 必须消失
# ★key 必须写目标**真包名**(§6.46：写错 key 的那条会在 prune 时被整条删掉，看起来就像"没生效")。
set -u
cd "$(dirname "$0")/.." || exit 1
PKG=com.suw.manager
REPORT=/sdcard/Android/data/$PKG/files/ksu_grant.txt
TPKG=${TPKG:-}
TUID=${TUID:-}
A() { MSYS_NO_PATHCONV=1 adb "$@"; }
S() { A shell "$@" 2>&1; }
step() {
  local tag="$1" cmd="$2" wait="${3:-12}"
  A shell am force-stop "$PKG" >/dev/null 2>&1
  S "rm -f $REPORT" >/dev/null
  sleep 1
  # ★不要把整条 am 命令拼成一个字符串丢给 adb shell：那要再过一层设备端 sh 的引号规则，
  #   第九十六发就是这么把 auto/cmd 发歪的(报告里 arm=0、动词像 @list)。
  #   直接把参数当 argv 传，动词里没有 shell 元字符 ⇒ 一层引号都不需要。
  A shell am start -n "$PKG/.MainActivity" --es auto ksuarm --es cmd "$cmd" >/dev/null 2>&1
  sleep "$wait"
  echo "----- [$tag] cmd=[$cmd]"
  S "cat $REPORT 2>&1" | grep -aE "判据①|LIST|SETPROF|MGR|结束" | tail -12 | sed 's/^/    /'
}
if [ -z "$TPKG" ] || [ -z "$TUID" ]; then
  echo "[x] 要用 TPKG=<目标包名> TUID=<目标 uid> 指定一个第三方 app(例: TPKG=com.android.settings TUID=10137)"
  echo "    现在能看到这些候选:"
  S "pm list packages -U | grep -vE 'com.suw.manager'" | head -12 | sed 's/^/      /'
  exit 2
fi
step "①王座" "@mgr"
step "②初始名单" "@list"
step "③加白名单" "@setprof:$TUID:1:$TPKG"
step "④名单里应当有 $TUID" "@list"
step "⑤撤销" "@setprof:$TUID:0:$TPKG"
step "⑥名单里应当没有 $TUID" "@list"
echo "===== 汇总(判据要能一眼看) ====="
S "cat $REPORT 2>&1" | tail -3 | sed 's/^/  最后一份报告: /'
