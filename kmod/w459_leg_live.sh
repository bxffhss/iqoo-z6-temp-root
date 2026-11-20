#!/bin/bash
# w459_leg_live.sh —— 把 kmod/ui_grant.sh 的"打字腿"**原样切片**，拿到本机一个真输入框上真跑(不开枪、不占窗口)。
# 为什么还要这一条：w458 的离线夹具定死了**形状**(证不出空就不打字／前缀只重读)，但它证不了
#   "这条腿在真输入法×真字段上跑得通"——#147 那四轮就是栽在只有真机才有的形状上(§6.373)。
# 宿主=com.absinthe.libchecker 的搜索框：Compose + AutoCompleteTextView + 本机讯飞，和官方 Manager 的搜索框同形状；
#   它是**只读本地搜索**：不发消息、不改用户数据。★唯一痕迹=LibChecker 自己"最近搜索"里多两个词
#   (termux / com.termux)——这条在 §6.373 如实登记，不动它的 app 数据(pm clear 会连用户设置一起清掉)。
# 三格：①纯字母过滤词：腿必须一次过，且**我自己重读树**核对字段逐字＝过滤词(末端证人不是腿打印那句)
#       ②连跑两次带点词(老形状)：不变量=『我自己重读到的字段不是逐字过滤词 ⇒ 腿绝不许报 ok』；
#         第二跑也逐字干净就显式打[没逼出]——那一格不算证人，也不许反过来当红项
#       ③腿打出去的命令串必须就是推导出来的过滤词(证明上机生效的是 pick_term，不是我手工挑的词)
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1 PYTHONUTF8=1 PYTHONIOENCODING=utf-8
fail=0; nchk=0
chk() { nchk=$((nchk+1)); if [ "$2" = 1 ]; then echo "  [OK] $1"; else echo "  [BAD] $1"; fail=1; fi; }
SRC=kmod/ui_grant.sh
# ★W 必须是**相对路径**：adb 是 Windows 程序，看不见 Git Bash 的 /g/... 绝对路径
#   (实测 `adb pull ... /g/项目/...` 静默不产文件 ⇒ 后面每一格都读成"树是空的"，看着像宿主页坏了)。
W=kmod/_tmp_w459
PKG=com.absinthe.libchecker
PY=python
adb get-state 2>/dev/null | grep -q device || { echo "[没跑] adb 不在线 ⇒ 这一条整体按'没测到'算"; exit 9; }
rm -rf "$W"; mkdir -p "$W/ev" || exit 1

echo "=== ① 切片(锚点与 w458 同一批：切不到就硬退出，别把『切片空』读成『腿没问题』) ==="
: > "$W/legs.sh"
for fn in pick_term is_empty_field field_now prove_empty type_term_once refocus_field srch_state dump_to ime_probe ime_cleanup try_latin_ime restore_ime; do
    awk -v F="$fn" '$0 ~ "^"F"\\(\\) \\{" {f=1} f {print} f && /^\}/ {f=0; exit}' "$SRC" >> "$W/legs.sh"
    grep -q "^$fn() {" "$W/legs.sh" || { echo "[x] $fn 没切到 ⇒ $SRC 里那个函数改名或被删"; exit 1; }
done
echo "    切到 $(grep -ac . "$W/legs.sh") 行(八个零件齐)"
# ★切片只切**函数体**，函数依赖的**顶层全局**不在切片里 ⇒ `set -u` 下会被读成"变量未定义"直接崩
#   （第 61 发之后跑总闸就是这样崩的：`legs.sh:163: IME_RESTORE: unbound variable`，红的是我的仪器不是被测）。
#   这里补默认值；源件里同一批量也已改成 `${X:-}`，两边一起改才算修好。
printf 'IME_RESTORE="${IME_RESTORE:-}"\n' >> "$W/legs.sh"

# 切片里的腿要用 S()：这里定义"既记账又真跑"的那一条(切片不含 S，所以不会被覆盖)
# ★#170：这里必须 tee 而不是 >> ——记账型 S() 若把 stdout 一起灌进日志，任何用 $(S …) 取读数的腿
#   (如今晚的 ime_probe / try_latin_ime)在仪器里就**恒得空读数**，会被读成"设备状态读不到"。②″ 那格钉住它。
S() { printf 'S|%s\n' "$1" >> "$W/calls_$NAME.log"; adb shell "$1" 2>&1 | tr -d '\r' | tee -a "$W/calls_$NAME.log"; }
adb() { printf 'A|%s\n' "$*" >> "$W/calls_$NAME.log"; command adb "$@"; }
EV="$W/ev"
source "$W/legs.sh"

echo "=== ② 现量宿主：开这一页 -> 量『搜索』键 -> 量输入框中心(坐标一律从树里量，不写死) ==="
# ★开机后第一次跑必读的一格(第 35 发的收尾复跑就是这么红的)：`input keyevent WAKEUP` **不解锁**，
#   锁屏上 uiautomator 量不到宿主的『搜索』键 ⇒ 这一格按"没测到"红给我看，别读成"腿坏了"。
command adb shell 'input keyevent KEYCODE_WAKEUP; svc power stayon true; sleep 1; input swipe 540 1950 540 800' >/dev/null 2>&1; sleep 2
# ★reboot 之后 vivo 那个「USB 已连接」模态框会自己回来并盖住整页(第 35 发收尾复跑就是这么红的)：
#   它的中心**从树里量**(点"取消"那个文本节点)，量不到就不点——不许为了跑通闸门盲点固定坐标。
dismiss_dialog() {
  local n=0
  while [ $n -lt 2 ]; do
    D
    local cxy; cxy=$(measure text 取消)
    if printf '%s' "$(command adb shell 'dumpsys window 2>/dev/null | grep -ac VivoUsbDialog' | tr -dc '0-9')" | grep -q '[1-9]'        && printf '%s' "$cxy" | grep -qE '^[0-9]+ [0-9]+$'; then
        echo "    有 VivoUsbDialog 模态框 ⇒ 点掉量到的『取消』($cxy)"; command adb shell "input tap $cxy" >/dev/null 2>&1; sleep 2
    else
        return 0
    fi
    n=$((n+1))
  done
}
command adb shell "am start -n $PKG/.features.home.ui.MainActivity" >/dev/null 2>&1; sleep 7
D() { command adb shell 'rm -f /sdcard/w459.xml; uiautomator dump /sdcard/w459.xml >/dev/null 2>&1; echo' >/dev/null 2>&1
      command adb pull //sdcard/w459.xml "$W/dump.xml" >/dev/null 2>&1; }
measure() { $PY - "$W/dump.xml" "$1" "$2" <<'PY'
import re,sys,io
p,what,arg=sys.argv[1],sys.argv[2],sys.argv[3]
s=io.open(p,encoding='utf-8',errors='replace').read()
def a(t,k):
    m=re.search(r'%s="([^"]*)"'%k,t); return m.group(1) if m else ''
out=''
for m in re.finditer(r'<node[^>]*',s):
    t=m.group(0); b=re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',t)
    if not b: continue
    g=[int(x) for x in b.groups()]; cx,cy=(g[0]+g[2])//2,(g[1]+g[3])//2
    if what=='desc' and a(t,'content-desc')==arg: out='%d %d'%(cx,cy); break
    if what=='text' and a(t,'text')==arg: out='%d %d'%(cx,cy); break
    if what=='edit':
        c=a(t,'class')
        if 'Edit' in c or 'AutoComplete' in c: out='%d %d'%(cx,cy); break
print(out)
PY
}
dismiss_dialog                      # ★先按树的读数把模态框点掉(定义在下面，调用必须在这里)
command adb shell "am start -n $PKG/.features.home.ui.MainActivity" >/dev/null 2>&1; sleep 6
D; NAME=setup
SXY=$(measure desc 搜索)
if ! printf '%s' "$SXY" | grep -qE '^[0-9]+ [0-9]+$'; then
    echo "    第一次没量到 ⇒ 再拉起一次宿主并等 9 秒(冷启动/动画里树是空的)"
    command adb shell "am start -n $PKG/.features.home.ui.MainActivity" >/dev/null 2>&1; sleep 9
    D; SXY=$(measure desc 搜索)
fi
chk "②树里量到『搜索』键的整数坐标(实得 [$SXY])" "$(printf '%s' "$SXY" | grep -qE '^[0-9]+ [0-9]+$' && echo 1 || echo 0)"
[ "$fail" = 0 ] || { echo "[x] 宿主没量出来 ⇒ 一个键都不敲；下面两格都不算证人"; exit 1; }
command adb shell "input tap $SXY" >/dev/null 2>&1; sleep 3
D; EXY=$(measure edit x)
chk "②展开后量到输入框中心(实得 [$EXY])" "$(printf '%s' "$EXY" | grep -qE '^[0-9]+ [0-9]+$' && echo 1 || echo 0)"
[ "$fail" = 0 ] || { echo "[x] 输入框没量到 ⇒ 不往里打字"; exit 1; }

echo "=== ②′ #169：宿主输入法能不能「直接提交」拉丁字符(不能就试切一次拉丁键盘；两样都不成⇒这一跑算「没测到」) ==="
#   为什么这一格必须先跑：复位后讯飞回中文组合态——实测打 termux 零提交、打 com.termux 读回带全角句号，
#   那种状态下**下面三格永远不会过**，把它们报成红项就是把宿主的错记到腿头上(例 84 的三种世界)。
NAME=probe
if ime_probe; then chk "②′ 探针一次过(宿主本来就能直接提交)" 1
elif try_latin_ime && ime_probe; then chk "②′ 探针靠切拉丁键盘才过(★退出时 trap 会装回原输入法)" 1
else
  echo "  [没测到] 切键盘之后探针仍不过 ⇒ 一个键都不敲，下面三格都不算证人"
  echo "            下一步：手工在手机上把输入法切到英文再重跑本件；退出码 9＝仪器测不了，不是腿失败"
  exit 9
fi
trap 'NAME="${NAME:-teardown}"; restore_ime' EXIT   # ★不管跑到哪一步退出，都把别人的键盘装回去

cell() { # $1=格名 $2=TERM $3=BASE_OK(1=这一格当作本 round 第一次打字；0=第二次起)
  NAME=$1; TERM=$2; BASE_OK=${3:-1}; : > "$W/calls_$NAME.log"
  UGBASE="$(field_now)"   # ★和出货件同一条规矩：进来时读到的那一串就是"没被我动过"的基准
  command adb shell "input tap $EXY" >/dev/null 2>&1; sleep 1
  echo "    --- $NAME：TERM=[$TERM] ---"
  if prove_empty; then
      if type_term_once; then echo "LEG=ok"; else echo "LEG=retry"; fi
  else
      echo "LEG=refuse"
  fi
}

echo "=== ③ 格①：纯字母过滤词 termux(离线 4/4 干净的那一形状，真机上必须也过) ==="
O1=$(cell c1 termux); echo "$O1" | sed 's/^/    /'
F1=$(field_now 2>/dev/null | tail -1)
chk "③腿一次过(LEG=ok)" "$(printf '%s' "$O1" | grep -q '^LEG=ok$' && echo 1 || echo 0)"
chk "③**我自己重读树**：字段逐字=[termux](实得 [$F1])＝末端证人不许是腿打印那句" \
    "$([ "$F1" = termux ] && echo 1 || echo 0)"
chk "③腿打出去的就是 input text \"termux\"(上机生效的是推导词，不是整包名)" \
    "$(grep -qxF 'S|input text "termux"' "$W/calls_c1.log" && echo 1 || echo 0)"

echo "=== ④ 格②：连跑两次带点词 com.termux(老形状) ⇒ 不变量=『我重读到的字段不是逐字过滤词』时腿绝不许报 ok ==="
#   为什么必须跑两次：零枪矩阵(§6.373)里带点词**第一次是干净的**，尾巴 'ux' 要到第二次清理才冒出来
#   ⇒ 证人只能是第二跑，第一跑只当铺垫(拿第一跑说"闸有效"就是例 116 那种"没有生产者的判据")。
O2=$(cell c2 com.termux 1); echo "$O2" | sed 's/^/    /'
F2=$(field_now 2>/dev/null | tail -1)
# ★这一格真正要证的不是"干净时能打对"(那是格③)，而是**"基准那一支放我打了字，逐字判据也照样把相粘抓住"**：
#   进来时框里已有上一格的 'termux' ⇒ 基准=[$F2 前一读] ⇒ 打字被允许一次 ⇒ 粘成 'termuxcom.termux' ⇒ 必须报不过。
chk "④铺垫格 c2：带着上一格残留打了字，但腿**没**报 ok(实得 $(printf '%s' "$O2" | grep -a '^LEG=' | tail -1)，我重读=[$F2])"     "$(printf '%s' "$O2" | grep -q '^LEG=ok$' && echo 0 || echo 1)"
chk "④c2 的成因那行就是『粘了别的东西』(＝逐字判据在兜住『基准那一支』放进来的一次打字)"     "$(printf '%s' "$O2" | grep -aq '粘了别的东西' && echo 1 || echo 0)"
chk "④c2 只打了 $(grep -ac '^S|input text' "$W/calls_c2.log" | tr -dc '0-9') 串字(允许打一次，但打完就判、不许叠着再打)"     "$([ "$(grep -ac '^S|input text' "$W/calls_c2.log" | tr -dc '0-9')" = 1 ] && echo 1 || echo 0)"
O3=$(cell c3 com.termux 0); echo "$O3" | sed 's/^/    /'
F3=$(field_now 2>/dev/null | tail -1)
if [ "$F3" = "com.termux" ]; then
    echo "    [没逼出] 第二次也逐字干净(字段=[$F3]) ⇒ **这一格不算证人**，不许拿它说『闸有效』"
    echo "    (这一跑了 $(grep -ac '^S|input text' "$W/calls_c3.log" | tr -dc '0-9') 串字；残留没出现时打字是正当的，别把这条读成红项)"
else
    chk "④残留逼出来了(我重读到字段=[$F3]≠逐字)⇒ 腿**没**报 ok(实得 $(printf '%s' "$O3" | grep -a '^LEG=' | tail -1))" \
        "$(printf '%s' "$O3" | grep -q '^LEG=ok$' && echo 0 || echo 1)"
    chk "④而且腿说得出成因(日志里有『不往有字的字段里打字』/『粘了别的东西』/『只收到前缀』之一)" \
        "$(printf '%s' "$O3" | grep -Eq '不往有字的字段里打字|粘了别的东西|只收到前缀' && echo 1 || echo 0)"
fi

echo "=== ⑤ 收尾：收起输入法 + 回桌面(不留焦点) ==="
command adb shell 'input keyevent 4; input keyevent 3' >/dev/null 2>&1
echo "    已回桌面；LibChecker『最近搜索』里会留 termux/com.termux 两个词(登记在 §6.373，不清它)"

echo
if [ "$fail" = 0 ]; then echo "=== w459 全绿：$nchk 项 PASS(条数由本脚本自己现数；设备侧真跑)"; exit 0; fi
echo "=== w459 有红项($nchk 项里) ==="; exit 1
