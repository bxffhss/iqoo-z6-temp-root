#!/bin/bash
# 窗口 98：路线 C 的**管理面端到端**判据(全走 app，不走 PC 侧 root)，比 w96 多两样：
#   ★A) 前置闸门(⓪)：窗口 97 整发被 `uts.sysname=Linu` 打废(app 一个都起不来 ⇒ 六步零报告，
#     看起来像管理面的 bug)。shell 读得到 ostype ⇒ 开跑之前先花 0 个窗口把它查掉，
#     并且每一步都用 `pidof` 证明"app 真的起来了"，不再拿"报告是空的"当结论。
#   ★B) 每条"名单变了"的判据都配一个**第二个来源**：让 root 侧守护替我们跑
#     `ksuctl granted <目标 uid>`(那是另一个进程、另一条 ioctl 路径)，
#     app 自报 + 内核侧回读两个都对上才算成立(本机口径：单一自报不算数)。
#     ★★窗口 100 一手：守护把 cmd **按空格切词** —— `@sushd:/data/local/tmp/ksuctl granted 10667`
#     到了守护那里只剩 `cmd=[/data/local/tmp/ksuctl]`(参数全丢，exit=2 打的是 usage)。
#     ⇒ 第二个来源只能给**一个 token**：命令写进 `kmod/w100_g.sh`(preflight 推上去)，
#     cmd 只填脚本路径；脚本自己把结果落 `/data/local/tmp/w100_g.out` 并 chmod 666 ⇒ shell 读得到。
#     同理：`@sushd:` 后面别带 `;`(intent 里带 shell 元字符会被设备端 sh 再解析一次，⑦就是这么空的)。
# 判据链(缺一不算通过)：
#   ① @mgr                                    本 app 坐在王座上(appid==uid%100000)
#   ② @list                                   读得动内核名单(★count=0 是**正常**的：内核
#                                             `ksu_get_allow_list()` 写着 `!is_uid_manager` ⇒
#                                             Manager 自己永远不进名单，别看错成"读失败")
#   ③ @setprof:<TUID>:1:<TPKG>                给别的 app 加白名单
#   ③k @sushd:/data/local/tmp/w100_g.sh       ★内核侧答 granted=1(第二个来源，读 w100_g.out)
#   ④ @list                                   目标 uid 出现在名单里
#   ⑤ @setprof:<TUID>:0:<TPKG>                撤掉
#   ⑤k @sushd:/data/local/tmp/w100_g.sh       ★内核侧答 granted=0(★双向，不是"调用没报错")
#   ⑥ @list                                   目标 uid 消失，而自己(10319)还在(不能自锁)
# ★key 必须写目标**真包名**(§6.46：key 写错的条目在 insmod 后 0.27s 就被 prune 整条删掉，
#   表现就是"没生效")。TUID 不写死：不给就现查 `pm list packages -U`。
set -u
cd "$(dirname "$0")/.." || exit 1
PKG=com.suw.manager
REPORT=/sdcard/Android/data/$PKG/files/ksu_grant.txt
GOUT=/data/local/tmp/w100_g.out     # 第二个来源：root 侧脚本自己落的那份(666)
TPKG=${TPKG:-com.termux}
TUID=${TUID:-}
A() { MSYS_NO_PATHCONV=1 adb "$@"; }
S() { A shell "$@" 2>&1; }
T_STATE() { adb get-state 2>/dev/null | tr -d '\r\n'; }
FAIL=0
KILLED=

echo "===== ⓪ 前置闸门(这些不成立就别往下烧窗口) ====="
OS=$(S 'cat /proc/sys/kernel/ostype' | tr -d '\r\n')
if [ "$OS" != Linux ]; then
    # ★窗口 98 一手更正：**sysname 坏了不等于 app 起不来**。ART 那句 `strcmp(uts.sysname,"Linux")`
    #   是在 libart 的**静态初始化**里跑的，而 zygote 开机时就跑过了(payload 的破坏发生在 00:55，
    #   zygote 早已 init 完)⇒ 从 zygote fork 出来的 app 进程**不受影响**(实测 pidof 有值)；
    #   真正死掉的是每次都要自己链接 libart 的**新 exec 进程**(artd 等，SIGABRT)。
    #   ⇒ 这一格只当**警告**，别再拦路；权威闸门是下面每一步的 `pidof`。
    echo "  !! sysname=[$OS](payload 打坏了)：artd 这类新 exec 进程会 abort，但从 zygote fork 的 app 不受影响 ⇒ 继续，用每步的 pidof 说话"
else
    echo "  ok sysname=[$OS]"
fi
ENF=$(S 'getenforce' | tr -d '\r\n')
echo "  enforce=[$ENF]  (Permissive ⇒ app→@sushd 连得上；Enforcing 下 ③k/⑤k 失败是 SELinux 的锅，不是 KSU)"
SUWW=$(S "pm list packages -U" | tr -d '\r' | grep -w "package:$PKG" | grep -oE 'uid:[0-9]+' | cut -d: -f2)
echo "  suw uid=[$SUWW]  设备侧 ksa_uids.txt=[$(S 'cut -d\" \" -f1 /data/local/tmp/ksa_uids.txt' | tr -d '\r\n')]"
if [ -z "$TUID" ]; then
    TUID=$(S "pm list packages -U" | tr -d '\r' | grep -w "package:$TPKG" | grep -oE 'uid:[0-9]+' | head -1 | cut -d: -f2)
    echo "  TUID 没给 ⇒ 现查 $TPKG = [$TUID]"
fi
[ -n "$TUID" ] || { echo "  [x] 目标 app $TPKG 没装/查不到 uid ⇒ 换 TPKG="; exit 2; }
# ★第二个来源要有东西可读：把 root 侧要跑的命令推成脚本(守护只认一个 token)
MSYS_NO_PATHCONV=1 adb push kmod/w100_g.sh /data/local/tmp/w100_g.sh >/dev/null 2>&1
MSYS_NO_PATHCONV=1 adb push kmod/w100_slots.sh /data/local/tmp/w100_slots.sh >/dev/null 2>&1
S "chmod 755 /data/local/tmp/w100_g.sh /data/local/tmp/w100_slots.sh; rm -f $GOUT /data/local/tmp/w100_slots.txt /data/local/tmp/w100_slots.done" >/dev/null
S "echo $TUID > /data/local/tmp/w100_tuid.txt; chmod 666 /data/local/tmp/w100_tuid.txt" >/dev/null
echo "  第二个来源脚本: $(S "md5sum /data/local/tmp/w100_g.sh" | cut -d' ' -f1 | tr -d '\r\n') (本地 $(md5sum kmod/w100_g.sh | cut -d' ' -f1))"
echo "  守护在听吗: pidof ksuctl=[$(S 'pidof ksuctl' | tr -d '\r\n')]  阶段日志起点: $(S "grep -a '=== 起点' /data/local/tmp/ksu_stage.log | tail -1" | tr -d '\r' | cut -c1-100)"
echo

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
  # ★掉线检测(窗口 96 的账：第③步之后机器重启，我当时以为是"报告是空的")。
  #   重启=一条判据，不是"没数据"：必须当场把"是哪一步打死的"钉在日志里。
  if [ -z "$(T_STATE)" ]; then
      echo "----- [$tag] cmd=[$cmd]"
      echo "    ★★★本步发出去之后设备掉线(≈重启) ⇒ 凶手就是这一步；等它回来"
      for q in $(seq 1 40); do sleep 5; [ -n "$(T_STATE)" ] && break; done
      echo "    回来后 uptime=[$(S 'cut -d\" \" -f1 /proc/uptime' | tr -d '\r\n')] ⇒ 窗口没了，往下跑的步数都不算数"
      FAIL=$((FAIL + 1)); KILLED="$tag"; return
  fi
  local pid; pid=$(S "pidof $PKG" | tr -d '\r\n' | cut -d' ' -f1)
  echo "----- [$tag] cmd=[$cmd] app pid=[$pid]"
  if [ -z "$pid" ]; then
      echo "    [x] app 没起来(不是管理面的问题)。最近 6 行 abort："
      S "logcat -d -t 200" 2>/dev/null | grep -aiE 'abort message|Check failed|artd|Fatal' | tail -6 | sed 's/^/      /'
      FAIL=$((FAIL + 1)); return
  fi
  # ★窗口 98 一手：报告文件有**两个写者**(intent 触发的 autoRun + UI 自己刷列表的 ksuPolicy("show"))，
  #   JNI 从 O_TRUNC 改成 O_APPEND 之后，一份报告里会有好几段，每段以
  #   `===== app 侧内核授权自检 arm=N cmd=[...] =====` 开头 ⇒ 只取 **cmd 对得上那一段**，
  #   别再拿"最后写的那段"当这一步的判据(第①步被打成 cmd=[@list] 就是这么来的)。
  S "cat $REPORT 2>&1" | awk -v want="cmd=[$cmd] =====" '
        / arm=[0-9]+ cmd=/ { p = (index($0, want) > 0); hit = hit || p }
        p' | grep -aE "arm=|判据①|LIST|SETPROF|MGR|UID_GRANTED_ROOT|结束" | tail -16 | sed 's/^/    /'
  S "cat $REPORT 2>&1" | grep -ac " arm=[0-9]* cmd=\[" | tr -d '\n' | sed 's/^/    (本份报告里共几段=/' ; echo
}

# kread <tag> <期望 granted> —— 第二个来源的读数不在 app 报告里，在**守护侧脚本自己落的文件**里
#   (窗口 100 一手：cmd 被按空格切词 ⇒ 只能给脚本路径一个 token；脚本把结果落 w100_g.out 并 chmod 666)。
kread() {
    echo "----- [$1] 内核侧第二个来源(root 进程独立 ioctl)，期望 granted=$2"
    local got
    got=$(S "grep -a uid=$TUID $GOUT 2>&1" | grep -oE "granted=[0-9]+" | head -1 | cut -d= -f2)
    echo "    uid=$TUID 内核答=[$got]"
    if [ "$got" = "$2" ]; then echo "    ★对上了(app 自报 + 内核侧回读同一答案)"; else echo "    !! 没对上 ⇒ 这一格判据不成立"; FAIL=$((FAIL + 1)); fi
}

echo "===== ①-② 王座 + 初始名单 + 自签 key 正对照 ====="
step "①王座" "@mgr"
step "②初始名单" "@list"
# ★②b 是**正对照**：key 用自己(§6.78 已双向验过的写法)。它若成功而 ③ 若打死机器，
#   变量就只剩一个 —— "给一个名单里从没出现过的外来包名落 profile"。
# ★窗口 98 的那次重启**不记在它头上**：活落盘崩前最后几行是 `servicemanager: Since 'artd' could
#   not be found...` + `send_signal sig 9 ... init 1 -> artd` ⇒ artd 因为 uts.sysname 被打坏而
#   崩溃循环、init 反复重启它，整机重启是这条链升级出来的(①②也各发过 am start 都没事)。
#   这一发 rc51 先把 uts 修好，所以 ②b 只当对照留着。
step "②b 自签 key(正对照)" "@setprof:${SUWW}:1:${PKG}"
if [ -n "$KILLED" ]; then echo "[x] 在 ②b 就掉线 ⇒ 停在这里，别再往下打"; exit 4; fi
echo "===== ③-⑥ 外来 key(这一格才是路线 C 的真问题) ====="
step "③加白名单($TPKG/$TUID)" "@setprof:$TUID:1:$TPKG"
if [ -n "$KILLED" ]; then echo "[x] ★③(外来 key 加白)之后重启 ⇒ §6.96② 那条怀疑复现：SET_APP_PROFILE 给新 key 落盘会打死机器"; exit 4; fi
step "③k 内核侧应当答 granted=1" "@sushd:/data/local/tmp/w100_g.sh"
kread "③k" 1
step "④名单里应当有 $TUID" "@list"
step "⑤撤销" "@setprof:$TUID:0:$TPKG"
if [ -n "$KILLED" ]; then echo "[x] ★⑤(外来 key 撤销)之后重启"; exit 4; fi
step "⑤k 内核侧应当答 granted=0" "@sushd:/data/local/tmp/w100_g.sh"
kread "⑤k" 0
step "⑥名单里应当没有 $TUID(而自己还在)" "@list"
echo "===== 归档：让 root 侧把内核快照抄成 shell 可读的一份 ====="
# ★单个 token、不带 `;`(窗口 100 一手：带 `;` 的那步 app 压根没起来 —— intent 里的 shell 元字符
#   会被设备端再解析一次)。抄+放权限这两件事都在 w100_g.sh 里做不了(它跑的是 granted)，
#   所以这里只抄，读得到读不到由下一步的 cat 说了算。
step "⑦抄 /proc/ksu_slots" "@sushd:/data/local/tmp/w100_slots.sh" 10
echo
echo "===== 汇总 ====="
echo "  app 没起来的步数=$FAIL(非 0 ⇒ 这一发的 app 侧判据不完整)"
S "cat $REPORT 2>&1" | tail -3 | sed 's/^/  最后一份报告: /'
echo "  回读要点：③k 与 ⑤k 必须是 granted=1 / granted=0 这一对；④/⑥ 是同一判据的第二个来源。"
