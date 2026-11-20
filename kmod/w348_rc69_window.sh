#!/usr/bin/env bash
# w348_rc69_window.sh —— rc69 那一发**窗口内**的固定次序(判据三格 + 两条风险同读)。
#
# 前提：`kmod/go.sh` 已经把窗口开起来(insmod rc=0 / mod=1)，这条脚本只负责"量"，不开窗、不 punch、不清场。
# ★次序为什么长这样(都是付过学费的)：
#   1) 先放样本模块，再做任何 UI 判据 —— 没东西可列时"列不出"与"没跑到"同形(§6.251 判据素材)。
#   2) 每次走 suw 的 root 腿(rleg)都会把 suw 顶到前台 ⇒ **读完必须把官方 Manager 拉回前台**再点 UI，
#      否则下一轮点按全落在 suw 上(记忆里那条"点了没变"就是这么来的)。
#   3) 判据 B 的"基线→点页面→再读"必须成对：事后 grep 大 dmesg 会把刚打的那几行挤掉(第 115 发丢的就是这个)。
#   4) 每一步都套 timeout，窗口只有 ~30 分钟，宁可少一格也不能卡死。
set -u
export MSYS_NO_PATHCONV=1 PYTHONUTF8=1 PYTHONIOENCODING=utf-8
EV=kmod/w103_evidence; MGR=me.weishu.kernelsu
mkdir -p "$EV"
S(){ timeout 60 adb shell "$1" 2>&1 | tr -d '\r'; }
# leg() 的三个名字**各自独立**：设备脚本名(rleg 只认这个)、设备上脚本自己写死的产物名、本地存证名(由我加分批后缀)。
#   ★踩过：原来拿 ${脚本%.sh}.out 去 pull，而 w345 写的是 w345_samplemod.out、w347 写的是 w347_rc69.out
#     ⇒ pull 的名字永远不存在；而 rleg **传不进参数**，所以 w347 的 OUT 也不能带 $TAG(否则 t0/t1 写同一个文件、差值判据全废)。
leg(){ local scr=$1 devout=$2 local_out=$3
    S "rm -f /data/local/tmp/$devout" >/dev/null
    timeout 200 bash kmod/w211_ui.sh rleg "$scr" >/dev/null 2>&1
    adb pull "//data/local/tmp/$devout" "$EV/$local_out" >/dev/null 2>&1
    [ -s "$EV/$local_out" ] || echo "  !! $local_out 空的或没拉到 ⇒ **别看旧内容下结论**(判据输入先 rm 再 pull)"
}
front(){ S "am start -n $MGR/.ui.MainActivity" >/dev/null 2>&1; sleep 4; }
deep(){ S "am start -a android.intent.action.VIEW -d ksu://action/superuser $MGR" >/dev/null 2>&1; sleep 3; }
dump(){ local f=$EV/$1.xml; S "rm -f /data/local/tmp/w348_ui.xml" >/dev/null
    S "uiautomator dump /data/local/tmp/w348_ui.xml" >/dev/null 2>&1
    adb pull //data/local/tmp/w348_ui.xml "$f" >/dev/null 2>&1
    [ -s "$f" ] && echo "  dump $1 = $(wc -c <"$f") B" || { echo "  !! dump $1 没产文件(uiautomator 有静默不产的前科)"; return 1; }
}
has(){ PYTHONUTF8=1 python -c "
import io,re,sys
s=io.open(sys.argv[1],encoding='utf-8',errors='replace').read()
t=[x for x in re.findall(r'text=\"([^\"]*)\"',s) if x.strip()]
print('    文本=',t[:14]); print('    节点=',s.count('<node'))
for k in sys.argv[2:]:
    print('    %-22s %s'%(k,'★命中' if k in s else '不中'))
" "$1" "$2" ${3:-} ; }

echo "=== 0) 窗口还在吗(硬闸：mod 必须=1) ==="
MOD=$(S "grep -c kernelsu /proc/modules"); ENF=$(S "getenforce"); UP=$(S "cut -d' ' -f1 /proc/uptime")
echo "  mod=$MOD enf=$ENF up=$UP"
[ "$MOD" = 1 ] || { echo "[x] 模块没加载 ⇒ 窗口不在，什么都别做(官方 UI 此时只会停在'不支持'页)"; exit 3; }

echo; echo "=== 1) ★先放样本模块(判据素材)，放完立刻读回 ==="
S "chmod 755 /data/local/tmp/w345_samplemod_dev.sh /data/local/tmp/w347_rc69_probe_dev.sh" >/dev/null
leg w345_samplemod_dev.sh w345_samplemod.out w345_samplemod.out
grep -a -E 'SAMPLEMOD_OK|modules 目录里现有' "$EV/w345_samplemod.out" 2>/dev/null | sed 's/^/  /' || echo "  !! 没有 SAMPLEMOD_OK ⇒ 素材没成，后面'列不出'就无从判定"

echo; echo "=== 2) 判据 B 的**基线**读数(点页面之前) ==="
cp kmod/w347_rc69_probe_dev.sh /data/local/tmp/ >/dev/null 2>&1
leg w347_rc69_probe_dev.sh w347_rc69.out w347_rc69_t0.out
grep -a -E 'SX2_COUNT|SD1_UID10104|Seccomp|modules 目录=' "$EV/w347_rc69_t0.out" 2>/dev/null | sed 's/^/  /'

echo; echo "=== 3) 把官方 Manager 拉回前台 + 补一次深链(页签要深链才进树，#124) ==="
front; deep
dump ui_before && has "$EV/ui_before.xml" 窗口内模块自测 KernelSU

echo; echo "=== 4) 点'模块'页 ⇒ 触发 ksud Module{List}(这次 SX 块在 SD1 上游，不看名单) ==="
front; sleep 2
# ★这里用的是**常量** (675,2195)：底部四个页签的 bounds 在第 111~113 发里量过、今天 ui_nav 也读到过同样位置。
#   但常量就是常量——所以**点完必须用产物自证**：下一步的 ui_module dump 里若只剩导航文本、
#   或 `当前焦点` 不是官方包，就当作"这点没落在页签上"，**不许拿它当'模块页是空的'的证据**(那是把点空当成判据结果)。
S "input tap 675 2195"; sleep 8
echo "  现在前台=$(S "dumpsys window 2>/dev/null | grep -a -m1 mCurrentFocus" | tr -dc '[:print:]\n')"
dump ui_module && has "$EV/ui_module.xml" 窗口内模块自测 suwmarker

echo; echo "=== 5) ★点完**立刻**再读一次(差值才算数) ==="
leg w347_rc69_probe_dev.sh w347_rc69.out w347_rc69_t1.out
grep -a -E 'SX2_COUNT|SD1_UID10104|SD1_ALL|Seccomp|ksud::cli|modules 目录=|202610' "$EV/w347_rc69_t1.out" 2>/dev/null | sed 's/^/  /'

echo; echo "=== 6) 三选一的分岔(把这次落在哪一格说清) ==="
SX=$(grep -a -o -E 'SX2_COUNT=[0-9]+' "$EV/w347_rc69_t1.out" 2>/dev/null | cut -d= -f2)
SD=$(grep -a -o -E 'SD1_UID10104=[0-9]+' "$EV/w347_rc69_t1.out" 2>/dev/null | cut -d= -f2)
SC=$(grep -a -o -E 'Seccomp:[[:space:]]*[0-9]+' "$EV/w347_rc69_t1.out" 2>/dev/null | head -1 | tr -dc '0-9')
echo "  SX2_COUNT=${SX:-?}  SD1_UID10104=${SD:-?}  Manager.Seccomp=${SC:-?}"
if [ "${SX:-0}" != 0 ]; then
    echo "  ⇒ ①**escape 发生了**。接下来只看模块页有没有内容 + Seccomp 是否 0。"
elif [ "${SD:-0}" != 0 ]; then
    echo "  ⇒ ②**execve 进了 hook 但我的块没命中** ⇒ 问题在尾串文本/uid 闸(把 SX 行的 suffix 值与真路径逐字符比)。"
else
    echo "  ⇒ ③**Manager 那次 execve 根本没进这个钩子** ⇒ 与 allow list/我的块都无关，下一步查钩子覆盖范围(execveat 首行早退? hook_mask?)。"
fi
echo
# ★教训(例 76)：这一行原来写成 echo "…先 `bash kmod/w310_kill.sh` → …" —— **双引号里的反引号是命令替换**，
#   于是那两个清理脚本真的在本机跑了一遍(还把"模块目录是否被剪掉"的时间线弄脏了)。提示一律单引号。
echo '★收尾(手动)：先 bash kmod/w310_kill.sh → bash kmod/w300_clean.sh → reboot；窗口中段就把 /data/adb 脚印清掉。'
