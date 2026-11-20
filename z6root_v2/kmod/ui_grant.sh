#!/bin/bash
# ui_grant.sh —— 把"官方 Manager 点开关授权"这一串手动动作做成一条命令，并且**每一步都自证**。
#   为什么需要：`ksuctl88 setprof` 与 suw 的 `@setprof:` 都返回 **EPERM**(#95/§6.231②) ——
#     内核只接受 **manager appid(官方 Manager)** 写 SET_APP_PROFILE ⇒ 想授给别的 uid 就只能走官方 UI。
#   难点在"点哪一行"：这条口径改过**两次**，两次都是被一手 dump 逼的——
#     · 第 115 发：★"列表页永久半盲"**只对未过滤那一屏成立**，过滤后的树里文本行是读得到的 ⇒ 从"写死第一张卡"
#       改成"按包名找行"(旧 v1)。
#     · 第 35 发(§6.376)：★**行本身不可点**。真树里 `clickable=true` 只有 8 个节点(全屏容器/搜索字段/Clean/
#       取消/三个底部导航/唯一那张组卡 `[36,318][1044,510]`)，而 v1 挑中的是 `clickable=false` 的文本行
#       ⇒ 连点四下全打在空处。这一条的硬证人＝那次的"Profile 页 dump" `ug_prof.xml` 与 `ug_srch.xml`
#       **md5 一模一样**(`975cc5b58cdb6e40280e1be752384001`)⇒ 页面根本没动。
#       ⇒ v2 改成"**找那张可点的卡**"：卡＝可点容器 ∧ 完整包住 ≥2 条标签 ∧ 最小(排除整屏滚动容器)，
#         命中＝卡内标签含**过滤词**(卡里通常**没有**包名串，共享 uid 的组卡标签是 `Termux user/包含 35 个应用`)，
#         且必须**恰好一张**；0 张(rc3)/多张(rc5)/没有卡(rc4)都**一次点按都不发**，且拒点时输出文件先删(反残留)。
#     ★顺带一条新事实(下一枪的判据要分开写)：**"字段逐字＝过滤词"不等价于"列表被过滤"**——
#       第 35 发那份树里字段是 `termux`，可卡片以下那串picker 行仍有白夜极光/猛鬼宿舍等一堆不相干应用。
#     Profile 页那道第二闸见 `kmod/prof_gate.py`：承重身份是 **`App Profile` ∧ `UID <n>`**，包名只当读数
#       (共享 uid 那一页显示的代表包是 `com.galMag.dataViewer`，整棵树里没有 `com.termux`)。
#   难点之二在"往搜索框里打的那一串"：★2026-10-21 零枪量出来才定型的形状(§6.373，仪器 kmod/w457_ime_probe.py)
#     ——带点的整包名会让本机讯飞每轮漏一条尾巴(实测清完仍剩 'ux'，下一串粘成 'uxcom.termux')，
#     逐字打与"收起输入法再点回来"都治不了它，纯字母词则 4/4 逐字干净 ⇒ ①过滤词自动挑"最长的 [a-z0-9] 段"；
#     ②打字前先**把字段证明为空**(清→读回，最多两轮；证不出来就作废这一轮，绝不往有字的字段上叠字)；
#     ③判据仍是逐字相等(搜索框拿整串做子串匹配，多一个字符列表就空了，"含有"不算过)；
#     ④读数只是期望值的前缀 ⇒ **只重读不重打**(重打就是再制造一次相粘)。
#     这一整条腿的四格形状由 kmod/w458_selftest_uinput.sh 离线双向验(含"零打字"与"零卡片"两条反例)。
#   用法：bash kmod/ui_grant.sh <搜索词(应用名或包名片段)> <期望 uid> [期望包名] [--revoke]
#   ★退出码：0=授权/撤销成立；6=四轮没进对 Profile 页；8=撤销没生效；**9＝输入法不可直接提交(#169 探针：中文组合态/全角)——这是"仪器测不了"，不是腿失败，切英文键盘后重跑**；其余见各分支。
#         例： bash kmod/ui_grant.sh suprobe 10304 com.suprobe.app            # 授权(默认)
#         例： bash kmod/ui_grant.sh suprobe 10304 com.suprobe.app --revoke   # 撤销(**必须显式**)
#         ★uid 必须**现取**：adb shell pm list packages -U | grep -a <包名>   (卸载重装就会换)
#         ★决策表只有四格：grant+off⇒点成 on / grant+on⇒不点 / revoke+on⇒点成 off / revoke+off⇒不点
#           ⇒ **反向动作永远不存在**(grant 不会关、revoke 不会开)，已经是目标状态就什么也不点。
#   ★状态：第 111、112 发**授权腿已在真窗口连证两遍**(含执法下 app 出 root，§6.237/§6.238)；
#     `--revoke` 的决策表与参数解析**离线双向验过**(拿 `w330_prof.xml`(checked=false) 与 `w330_prof2.xml`(checked=true)
#   ★状态：决策表与参数解析离线双向验过(两棵真树 × 两种模式 = 四格)；**两条 UI 序列都已在窗口里跑通**——
#     grant 在第 111/112/113 发连证三遍(含执法下 app 出 root)，`--revoke` 在第 113 发首跑通过
#     (表 `count 2→1` + 行为 `[A]errno=2`/`[C]ERR not-allowed`)。账在 §6.237/§6.238/§6.241。
#     仍保留的老规矩：任何一格 FAIL 就停下来手工做，别把它当"点一下就行"的脚本。
#     任何一格 FAIL 就停下来手工做；它不是"点一下就行"的脚本，是一串带复证的走路。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8      # ★GBK 控制台遇到 '⇒' 会把 python print 打崩(第 110 发真崩了)
# ★撤销必须是**显式参数**：默认行为永远是"只点 ON，绝不误撤销"(§6.237 的理由)。
MODE=grant; ARGS=()
for a in "$@"; do
    if [ "$a" = --revoke ]; then MODE=revoke; else ARGS+=("$a"); fi
done
WORD=${ARGS[0]:?用法: ui_grant.sh <搜索词> <期望uid> [期望包名] [--revoke]}
WANT_UID=${ARGS[1]:?要传期望 uid}
WANT_PKG=${ARGS[2]:-$WORD}
# ★★过滤词不是包名(2026-10-21 零枪量出来的，§6.373)：拿带点的整包名去打字，本机讯飞每轮都会漏一条尾巴
#   (实测 com.termux -> 清完仍剩 'ux'/'mux'，下一串粘成 'uxcom.termux'；逐字打、收起输入法都治不了它，
#    换纯字母词 termux 则 4/4 逐字干净)。第 110~115 发窗口里读到的 [erm]/[ermu]/[uxer] 就是这一族形状
#   ——**不是"字符被重排"，是"上一条的尾巴和这一条相粘"**，所以我原先写在这里的"suprobe 被打成 obesup/besupr"
#   那句归因是错的，已按实测改掉(别让下一位再照着错原因修)。
#   ⇒ 打字只用"最长的那个 [a-z0-9] 段"(com.termux -> termux)；**找那张卡也用同一个词**(第 35 发：卡里根本没有
#     包名串)，整包名 $WANT_PKG 退去只当 Profile 页的一条形读数；末端证人＝`App Profile` ∧ `UID <n>`(见 kmod/prof_gate.py)。
pick_term() { # 候选=WORD 本身 + WORD/包名按点切开的每一段，各自剥成 [a-z0-9] 后取最长的那个
  local c best=''
  # ★候选**只有按点切开的段**：把整串(com.termux)也当候选会选出 comtermux——比 termux 长，
  #   而带点整串正是这条腿要避开的成因(离线夹具第⑨格抓到的就是它)。
  for c in $(printf '%s %s' "$WANT_PKG" "$WORD" | tr '.' ' '); do
    c=$(printf '%s' "$c" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
    [ -n "$c" ] || continue
    [ ${#c} -gt ${#best} ] && best=$c
  done
  printf '%s' "$best"
}
TERM=$(pick_term)
MGR=me.weishu.kernelsu
EV=kmod/w103_evidence
# 搜索框中心：第 110 发现在"未过滤那一屏"的树里读不到这个框(只有四个页签) ⇒ 沿用现量过的坐标；
#   它安不安全不靠坐标本身，靠后面两道读数：树里有没有「取消」+ 字段能不能被证明是空的。
SBX=540
SBY=470
S() { adb shell "$1" 2>&1 | tr -d '\r'; }
PY=${PY:-python}   # ★可覆盖：本机 bash 的 PATH 里没有 python，调用方写 PY=<绝对路径> 即可

# ★dump 前先删**两端**：残留的旧树会被下一格当成"现状"(离线对照里真复现过 stale coord 被 read 走)。
# ★首跑静默不产文件有前科 ⇒ 最多两跑，两跑都空就明说"dump 没成"，绝不让它落到旧内容上。
dump_to() {
  local t=$1 k
  adb shell "rm -f /sdcard/ug.xml" >/dev/null 2>&1
  rm -f "$t"
  for k in 1 2; do
    adb shell "uiautomator dump /sdcard/ug.xml >/dev/null 2>&1; echo" >/dev/null 2>&1
    adb pull //sdcard/ug.xml "$t" >/dev/null 2>&1
    [ -s "$t" ] && { echo "  dump#$k -> $t $(wc -c < "$t") B"; return 0; }
    echo "  dump#$k 没产出文件(有前科那一类)，重试"; sleep 2
  done
  echo "  [!] dump 两跑都空 ⇒ 后面那格会按'dump 没成'处理，不会拿旧树下结论"
  return 1
}

echo "=== 0) 前置：设备在线、模块已加载、窗口还开着(否则 UI 会停在'不支持'页) ==="
S 'getenforce; echo mod=$(grep -c kernelsu /proc/modules); cut -d" " -f1 /proc/uptime' | sed 's/^/  /'
[ "$(S 'grep -c kernelsu /proc/modules')" = 1 ] || { echo "[x] 模块没加载 ⇒ 官方列表不可用，这条脚本此时跑不了"; exit 3; }

echo "=== 1) 亮屏 + 解锁 + 保持常亮(每 boot 要重设) ==="
S 'input keyevent KEYCODE_WAKEUP; svc power stayon true; sleep 1; input swipe 540 1800 540 700' >/dev/null; sleep 2
S "am start -n $MGR/.ui.MainActivity" >/dev/null; sleep 3
# vivo「USB已连接/开发模式」弹窗会吃掉第一次点按。★只在它真的在前台时才点(540,2054)——
#   无条件盲点会在 Manager 首页落到别的东西上(mCurrentFocus 常为 null ⇒ 看 mFocusedApp)。
FOC=$(S 'dumpsys window 2>/dev/null | grep -aE "mFocusedApp|mCurrentFocus" | head -4')
echo "  当前前台: $FOC"
if printf '%s' "$FOC" | grep -qaEi 'vivo|usb|installer'; then
  echo "  -> 有系统弹窗，先点掉 (540,2054)"; S 'input tap 540 2054' >/dev/null 2>&1; sleep 1
else
  echo "  -> 无系统弹窗，不盲点"
fi
S "am start -a android.intent.action.VIEW -d ksu://action/superuser $MGR" >/dev/null 2>&1; sleep 3

echo '=== 1.5) ★确保 fd 赶上官方的**首次查询**：首页必须是 版本：32601-2 且有四个页签(第 111 发钉出来的判别式) ==='
# 一手对照：`32601-0` + "uapi 不匹配"红字 = fd 晚到(task_work 在它首次查询之后才跑) ⇒ **导航条不渲染**；
#           `32601-2` + 无红字 = 赶上了 ⇒ 四个页签在树里。所以这里 force-stop 重来直到抓到 2(最多 6 次)。
# 前提：root 侧抢装看门狗在跑(400×0.4s≈160s)——**这条脚本自己起**，不靠我记得手工打。
GOT2=0
# ★★B5/B6 两手(11-12 17:3x–17:4x)：**先读现值，好了就一个都不许动**。
#   原来这段是无条件 `am force-stop` 六次等看门狗补 fd。在 NOSUW 形状(名单主条目＝官方 Manager、bind 由 stage 做、
#   suw 不在名单)下，上面那条 rleg 派单根本起不了看门狗（`ug_fdlaunch.out` 是上一发留下的旧文件 ⇒ 那句
#   "看门狗活着"是**陈旧证据**），于是 force-stop 唯一的效果就是**把刚带 fd 的好实例杀掉**，
#   新实例立刻退回「不支持」，且这一窗不可逆（B5、B6 各废一次就是这条）。
#   ★B6 那一发还暴露第二个坑：这个 pre-check 若排在第 112 行的 `ksu://action/superuser` 深链**之后**，
#     dump 到的不是主页 ⇒ 状态读成"未知"、页签只有 2 ⇒ 判据落空、照样掉进循环。
#     ⇒ ①先把 MainActivity 叫回前台（**不 force-stop**）再 dump；②判据不用"页面叫什么"，
#       只用「**没有**『不支持』」∧「读得到『工作中』或『超级用户』」——那两条就是"fd 在里面"的等价说法。
S "am start -n $MGR/.ui.MainActivity" >/dev/null 2>&1; sleep 4
dump_to "$EV/ug_home.xml" >/dev/null 2>&1
PRE=$($PY - "$EV/ug_home.xml" <<'PY'
import re,io,sys,os
s='' if not os.path.exists(sys.argv[1]) else io.open(sys.argv[1],encoding='utf-8',errors='replace').read()
st='不支持' if '不支持' in s else ('工作中' if '工作中' in s else '未知')
tabs=len([t for t in re.findall(r'text="([^"]*)"',s) if t in ('主页','超级用户','模块','设置')])
ok='OK' if ('不支持' not in s and '获取 Root 失败' not in s and ('工作中' in s or '超级用户' in s)) else 'NO'
print('%s %s %d' % (ok, st, tabs))
PY
)
PRE_OK=$(printf '%s' "$PRE" | cut -d' ' -f1)
PRE_ST=$(printf '%s' "$PRE" | cut -d' ' -f2); PRE_TB=$(printf '%s' "$PRE" | cut -d' ' -f3)
echo "  现值: 可用=[$PRE_OK] 状态=[$PRE_ST] 页签数=[$PRE_TB]"
if [ "$PRE_OK" = OK ]; then
  GOT2=1; echo "  ★现值已是『fd 在里面』（无『不支持』且读得到页签）⇒ 跳过 1.5 的 force-stop 重来"
fi
if [ "$GOT2" = 0 ]; then
echo "  起抢装看门狗(走 suw 的 root 腿，约 40s)…"
adb push kmod/w161_fdwatch.sh kmod/w161_fdlaunch.sh /data/local/tmp/ >/dev/null 2>&1
S 'chmod 755 /data/local/tmp/w161_fdwatch.sh /data/local/tmp/w161_fdlaunch.sh' >/dev/null 2>&1
bash kmod/w211_ui.sh rleg w161_fdlaunch.sh >/dev/null 2>&1
adb pull //data/local/tmp/w161_fdlaunch.out "$EV/ug_fdlaunch.out" >/dev/null 2>&1
grep -a "看门狗" "$EV/ug_fdlaunch.out" 2>/dev/null | tail -2 | sed 's/^/    /'
fi
for t in 1 2 3 4 5 6; do
  [ "$GOT2" = 1 ] && break
  S "am force-stop $MGR" >/dev/null 2>&1; sleep 1
  S "am start -n $MGR/.ui.MainActivity" >/dev/null 2>&1; sleep 7
  dump_to "$EV/ug_home.xml"
  R=$($PY - "$EV/ug_home.xml" <<'PY'
import re,io,sys,os
s='' if not os.path.exists(sys.argv[1]) else io.open(sys.argv[1],encoding='utf-8',errors='replace').read()
v=re.search(r'版本：(\d+)-(\d+)',s)
tabs=len([t for t in re.findall(r'text="([^"]*)"',s) if t in ('主页','超级用户','模块','设置')])
print('%s %s %d' % ('不支持' if '不支持' in s else ('工作中' if '工作中' in s else '未知'), v.group(2) if v else '?', tabs))
PY
)
  echo "  第 $t 次: $R"
  set -- $R
  if [ "$1" = 工作中 ] && [ "$2" = 2 ]; then
    # ★第 113 发：`N=2` 只是**必要条件**，页签要靠**深链当触发器**才进无障碍树(冷启动后不发深链 ⇒ 永远 tabs=0，
    #   我上一版 1.5 步就是这么把自己锁死六次的)。⇒ 见到 N=2 就补一发深链，再读一次 tabs。
    S "am start -a android.intent.action.VIEW -d ksu://action/superuser $MGR" >/dev/null 2>&1; sleep 5
    dump_to "$EV/ug_home.xml"
    T2=$($PY - "$EV/ug_home.xml" <<'PY'
import re,sys,io,os
s='' if not os.path.exists(sys.argv[1]) else io.open(sys.argv[1],encoding='utf-8',errors='replace').read()
print(len([t for t in re.findall(r'text="([^"]*)"',s) if t in ('主页','超级用户','模块','设置')]))
PY
)
    echo "    补发深链后 tabs=$T2"
    if [ "$T2" = 4 ]; then GOT2=1; echo "  ★32601-2 + 深链后四个页签显形 ⇒ 可以走路"; break; fi
  else
    [ "$1" = 不支持 ] && echo "  ▲ 掉回'不支持' ⇒ 看门狗可能已过期(160s)，先重打 rleg w161_fdlaunch.sh"
  fi
done
[ "$GOT2" = 1 ] || { echo "[x] 六次都没凑齐『32601-2 + 深链后页签显形』 ⇒ 停(别在这个状态下走路)"; exit 4; }

echo "=== 2) 进'超级用户'页：★只点树里读得到的页签，绝不盲点(第 110 发盲点 (400,2140) 落在主页「支持开发」卡片上，把浏览器拉了起来) ==="
# 两道断言合成一个读数：前台必须是官方(package 集合恰为它)，且「超级用户」页签要在树里(在=可点，不在=没显形)。
# ★第 111 发踩到的"失败朝开"：原来坐标与拒绝原因走同一条 stdout，`tail -1` 取到了那句中文原因，
#   `[ -z ]` 判成"有坐标" ⇒ 把句子喂给 `input tap` 抛异常。**坐标只认 build_ug_nav.txt，且必须是两个整数。**
nav_center() {          # 人读的输出直接打屏；坐标**只**写进 build_ug_nav.txt
  : > build_ug_nav.txt
  dump_to "$EV/ug_nav.xml"
  $PY - "$EV/ug_nav.xml" <<'PY'
import re,sys,io,os
p=sys.argv[1]; out=''; why=''
if not (os.path.exists(p) and os.path.getsize(p)): why='dump 没产出文件'
else:
    s=io.open(p,encoding='utf-8',errors='replace').read()
    pk=sorted(set(re.findall(r'package="([^"]*)"',s)))
    if pk!=['me.weishu.kernelsu']:
        why='★前台不是官方，是 %s ⇒ 一个点都不许发' % pk
    else:
        hit=[m.group(0) for m in re.finditer(r'<node[^>]*',s)
             if '超级用户' in ((re.search(r'text="([^"]*)"',m.group(0)) or [None,''])[1])]
        if not hit: why='官方在前台，但树里没有「超级用户」页签 ⇒ 导航条没显形(第 110 发就是这个状态)'
        else:
            b=re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',hit[0])
            if b:
                g=[int(x) for x in b.groups()]; out='%d %d' % ((g[0]+g[2])//2,(g[1]+g[3])//2)
io.open('build_ug_nav.txt','w',encoding='utf-8').write(out)
print('  '+ (why if why else '页签在树里，坐标 -> %s' % out))
PY
}

# 搜索态那棵树里能读到的两样东西：字段当前的文本、以及清空键 Clean 的中心(都写进 build_ug_*.txt)。
srch_state() {
  : > build_ug_clean.txt; : > build_ug_field.txt; : > build_ug_fld.txt
  $PY - "$EV/ug_srch.xml" <<'PY'
import re,sys,io,os
p=sys.argv[1]; cl=''; fld=''; fxy=''
if os.path.exists(p) and os.path.getsize(p):
    s=io.open(p,encoding='utf-8',errors='replace').read()
    for m in re.finditer(r'<node[^>]*',s):
        t=m.group(0)
        if 'clickable="true"' not in t: continue
        b=re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',t)
        if not b: continue
        g=[int(x) for x in b.groups()]
        if g[3]>320: continue                     # 只看顶部搜索条那一带(第 111 发实测字段 y=143..287)
        txt=(re.search(r'text="([^"]*)"',t) or [None,''])[1]
        cd =(re.search(r'content-desc="([^"]*)"',t) or [None,''])[1]
        cx,cy=(g[0]+g[2])//2,(g[1]+g[3])//2
        # ★Clean 在 content-desc 里(text 是空的)——第 111 发对着真树打印才发现，别按 text 找它
        if cd=='Clean' and not cl: cl='%d %d' % (cx,cy)
        elif txt and txt!='取消' and not fld:
            fld=txt
            fxy='%d %d' % (cx,cy)                 # ★字段自己的中心：重新聚焦要点它，不能回点"展开搜索框"那个老坐标
io.open('build_ug_clean.txt','w',encoding='utf-8').write(cl)
io.open('build_ug_field.txt','w',encoding='utf-8').write(fld)
io.open('build_ug_fld.txt','w',encoding='utf-8').write(fxy)
print('  字段=[%s] Clean=%s 字段中心=%s' % (fld, cl or '没读到', fxy or '没读到'))
PY
}

# ---- 打字这一腿的三个零件(成因与判据见上面 §6.373 那段注释；离线双向自测=kmod/w458_selftest_uinput.sh) ----
# 读一次搜索框：顺带把 Clean 键的坐标刷进 build_ug_clean.txt(键只在字段非空时才在树里)。
field_now() {
  dump_to "$EV/ug_srch.xml" >/dev/null 2>&1
  srch_state >/dev/null 2>&1
  tr -d '\r' < build_ug_field.txt 2>/dev/null
}
# "空"的形状：这类搜索框把提示语放在 text 里(第 111 发在真树上发现的同一族坑)，所以空不止是空串。
is_empty_field() {
  case "$1" in ''|'搜索'|'搜索…'|'Search'|'搜索设置项'|'请输入搜索内容') return 0 ;; *) return 1 ;; esac
}
# 证明字段是空的：Clean(键在才有坐标) + 退格，清完**必须读回来**。
# ★"空"有两种认法：①读数落在我认识的占位符名单里；②`BASE_OK=1` 时读数逐字等于**我进来时看到的那一串**
#   ——官方那个框的占位符长什么样**我从来没读到过**(每一次观测时框里都已有文本)，只靠名单会把这条腿
#   在一个从没见过的框上永远判"证不出空"⇒ 一步都走不动(那是把"我不知道"写成"不行")。
#   ⇒ 所以名单外再给一次机会：**只有本 round 的第一次打字**可以按"回到进来时的形状"算干净；
#     第二次起必须回到名单里的空(那时任何残留都是我自己打进去的)。
# ★★对带点的词，两轮退格都删不掉那条尾巴(w459 真机复现：com.termux -> 退 14 次剩 'ux'，再退 20 次还是 'ux')
#   ⇒ 这条腿**不解释机制**(输入法重提交还是键流没落地，我没定)，它只兜住后果：证不出来就拒打字。
prove_empty() {
  local j B A CL CY why
  A=""
  for j in 1 2; do
    B=$(field_now)
    if is_empty_field "$B"; then echo "    证空第 $j 轮：[$B] => 空(在认识的占位符名单里)"; return 0; fi
    if [ "$BASE_OK" = 1 ] && [ "$B" = "$UGBASE" ]; then
      echo "    证空第 $j 轮：[$B] => 和我刚进来时读到的一模一样 ⇒ 这一轮第一次打字按'没被我动过'算干净"
      return 0
    fi
    CL=""; CY=""
    read -r CL CY < build_ug_clean.txt 2>/dev/null || true
    if [[ "$CL" =~ ^[0-9]+$ && "$CY" =~ ^[0-9]+$ ]]; then S "input tap $CL $CY" >/dev/null 2>&1; sleep 1; fi
    # ★退格条数在**本机**算好、拼成一条一行命令发过去：以前写 `for i in $(seq 1 N); do …; done`，
    #   而 $() 在 Git Bash 里带进来的换行会原样落到远端命令里(实测读数变成 "for i in 1\n2\n3…")——
    #   能跑，但形状不由我控(例 138 那两颗 awk 雷的同一族：把算术交给别的壳去解释)。
    local q DELS=''
    for ((q = 0; q < ${#B} + ${#TERM} + 6; q++)); do DELS="$DELS; input keyevent 67"; done
    S "${DELS#; }" >/dev/null 2>&1
    sleep 1
    A=$(field_now)
    echo "    证空第 $j 轮：[$B] -> [$A]"
    [ "$A" = "$B" ] && echo "    ▲ 读数一字没变 ⇒ 退格这条腿可能没落到字段上(别再退，下一轮换打法)"
  done
  is_empty_field "$A" && { echo "    证空：清到最后是[$A] => 空"; return 0; }
  echo "  [!] 两轮都证明不了字段是空的(最后读到 [$A]；刚进来时是 [$UGBASE]) ⇒ **不往有字的字段里打字**"
  return 1
}
# 打一串并读回：逐字等于过滤词才算 0。对不上时成因分三类打印，绝不在这条里"顺手再打一遍"。
type_term_once() {
  local F j
  S "input text \"$TERM\"" >/dev/null 2>&1
  F=$(field_now)
  for j in 1 2; do
    [ "$F" = "$TERM" ] && break
    case "$TERM" in "$F"* ) : ;; *) break ;; esac     # 只有"是期望值的前缀"才值得再等——重打只会造 merge
    sleep 1
    F=$(field_now)
  done
  FIELD_LAST=$F
  [ "$F" = "$TERM" ] && { echo "    字段逐字 = $TERM"; return 0; }
  if [ -n "$F" ] && case "$TERM" in "$F"* ) true ;; *) false ;; esac; then
    echo "    [!] 只收到前缀 [$F] ⇒ 键还没落地"
  elif printf '%s' "$F" | grep -aq -- "$TERM"; then
    echo "    [!] [$F] 里粘了别的东西 ⇒ 残留相粘(过滤器拿整串匹配，多一字符就列空)"
  else
    echo "    [!] 字段 [$F] 与过滤词 $TERM 对不上 ⇒ 漏字/粘字"
  fi
  return 1
}

# 重新聚焦到字段本身(点**现量到的**字段中心；没有合法坐标就一条都不点)。
refocus_field() {
  local FX FY
  FX=""; FY=""
  read -r FX FY < build_ug_fld.txt 2>/dev/null || true
  if [[ "$FX" =~ ^[0-9]+$ && "$FY" =~ ^[0-9]+$ ]]; then S "input tap $FX $FY" >/dev/null 2>&1; sleep 1; return 0; fi
  echo "    (树里没读到字段中心 ⇒ 不重焦点)"
  return 1
}

# ★★★#169(10-22 01:3x 一手)：打字之前先证"这台机的输入法现在能把拉丁字符**直接提交**"。
#   为什么需要：复位后讯飞会回到**中文组合态**——打 `termux` 一个字符都不提交(字段仍读回占位符)，
#   打 `com.termux` 读回 `termuxcom。`(点被换成全角 `。`，上一串的尾巴延迟落下来)。
#   ⇒ 那种状态下"重试三轮/四轮"永远不会过，白烧一发。所以这里**一次判定、不过就停手**，
#     并且用**独立退出码 9** 把"仪器测不了"与"腿失败"分开(例 84：判据红有三种世界)。
ime_cleanup() {   # 探针那个字符必须清回空并**读回**——绝不能把残留留给下一串(例 110 那一族)
  local B A CL CY q D=''
  B=$(field_now)
  CL=""; CY=""
  read -r CL CY < build_ug_clean.txt 2>/dev/null || true
  if [[ "$CL" =~ ^[0-9]+$ && "$CY" =~ ^[0-9]+$ ]]; then S "input tap $CL $CY" >/dev/null 2>&1; sleep 1; fi
  for ((q = 0; q < ${#B} + 6; q++)); do D="$D; input keyevent 67"; done
  S "${D#; }" >/dev/null 2>&1; sleep 1
  A=$(field_now)
  if is_empty_field "$A"; then echo "    探针收尾：[$B] -> [$A] 已清回空"; return 0; fi
  echo "  [!] 探针收尾：清完还读到 [$A] ⇒ 停手(别把探针的字符留给下一串)"
  return 1
}
ime_probe() {     # 0=能直接提交；9=不能(调用方据此停手，不去重试)
  local P
  S "input text \"q\"" >/dev/null 2>&1; sleep 1
  P=$(field_now)
  if [ "$P" = q ]; then
    echo "    探针：打 q 后字段逐字 = q ⇒ 输入法处于能直接提交的状态(拉丁/英文)"
    ime_cleanup || return 9
    return 0
  fi
  echo "    [!] 探针：打 q 之后字段读到 [$P]"
  case "$P" in
    ''|'搜索'|'搜索…'|'Search'|'搜索设置项'|'请输入搜索内容')
        echo "        ⇒ 一个字符都没提交＝字母进了拼音**合成区**(中文组合态)" ;;
    *)  echo "        ⇒ 提交出来的是别的东西＝输入法在做转换(全角/候选/联想)" ;;
  esac
  echo "        ★这一发不该继续打字，也不该判成「腿失败」：请在手机上切到英文/系统键盘再重跑(退出码 9)"
  ime_cleanup || true
  return 9
}

IME_RESTORE=''                       # 空＝没动过宿主输入法；非空＝切过，退出时必须装回
# 探针不过时**只试一次**：切到本机 ime list 里那个没有中文合成的键盘，切完必须读回核对。
try_latin_ime() {
  local CUR NEW='com.locnet.gamekeyboard2/.SoftKeyboard' G
  CUR=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
  if [ -z "$CUR" ]; then echo '    [!] 读不到当前输入法 ⇒ 不做切换(不敢瞎改不确定的状态)'; return 1; fi
  S "ime enable $NEW" >/dev/null 2>&1
  S "ime set $NEW"    >/dev/null 2>&1; sleep 2
  G=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
  if [ "$G" != "$NEW" ]; then echo "    [!] 切到 $NEW 没生效(读回 [$G]) ⇒ 不硬来"; return 1; fi
  IME_RESTORE="$CUR"
  echo "    已切到 $NEW(原 [$CUR])；★退出时装回(trap 兜住，含失败出口)"
  return 0
}
restore_ime() {
  # `${…:-}`：这份函数会被**离线夹具切片**（w459 只切函数体、不含上面的 `IME_RESTORE=''`），
  # 在 `set -u` 下裸写 `$IME_RESTORE` 会让**仪器**先崩（第 61 发之后跑总闸就红在这里）。
  [ -n "${IME_RESTORE:-}" ] || return 0
  S "ime set $IME_RESTORE" >/dev/null 2>&1; sleep 1
  local G; G=$(S 'settings get secure default_input_method' | tr -d '[:space:]')
  if [ "$G" = "$IME_RESTORE" ]; then echo "    ✓ 输入法已装回 [$G]"
  else echo "    [!] 没装回去(读回 [$G]) ⇒ 请手工切回 $IME_RESTORE"; fi
  IME_RESTORE=''
}
trap restore_ime EXIT                  # 例 105：收尾不挂 trap＝把失败出口排除在外

# ★★★重试环：第 110 发首跑就是栽在"拿固定 sleep 当页面就绪判据"——那一刻列表还在"正在刷新…"，
#   点搜索框与点卡片都打在空处(事后 dump 里只有「取消」)。出口只认 Profile 页的身份核对。
OK=0
for n in 1 2 3 4; do
  echo "--- 第 $n 轮：先把官方拉到前台，再等列表刷完('正在刷新…')，睡 $((6*n)) 秒"
  S "am start -n $MGR/.ui.MainActivity" >/dev/null 2>&1; sleep 2
  sleep $((6*n))
  rm -f build_ug_nav.txt
  nav_center
  NX=""; NY=""
  read -r NX NY < build_ug_nav.txt 2>/dev/null || true
  if ! [[ "$NX" =~ ^[0-9]+$ && "$NY" =~ ^[0-9]+$ ]]; then
    echo "  [!] 没拿到合法坐标(上面那行就是原因) ⇒ 这一轮不许点，重发深链再来一轮"
    S "am start -a android.intent.action.VIEW -d ksu://action/superuser $MGR" >/dev/null 2>&1
    continue
  fi
  echo "  页签中心 ($NX,$NY) ⇒ 点它"; S "input tap $NX $NY"; sleep 4
  S "input tap $SBX $SBY"; sleep 2                          # 点搜索框(展开搜索态)
  dump_to "$EV/ug_srch.xml"; srch_state
  # ★搜索态开没开，树里读得到的证据就是「取消」；第 111 发新事实：**字段文本、Clean 键、字段中心都在这棵树里**
  #   ⇒ 输入不靠"打完就算"，也不靠"打完就猜"：先证明字段是空的 → 打 → 读回逐字对 → 只是前缀就重读(不重打)。
  if ! grep -qa '取消' "$EV/ug_srch.xml" 2>/dev/null; then
    echo "  [!] 树里没有「取消」⇒ 搜索框没展开，本轮作废重来"
    S 'input keyevent 4' >/dev/null 2>&1; continue
  fi
  if [ -z "$TERM" ]; then
    echo "  [!] 过滤词从 [$WANT_PKG] 剥出来是空串 ⇒ 不打字，本轮作废"
    S 'input keyevent 4' >/dev/null 2>&1; continue
  fi
  if [ "${IME_OK:-0}" != 1 ]; then      # ★每发只测一次宿主状态(过了就别再花两次 dump 问它)
    if ! ime_probe; then                #   退出码 9＝仪器测不了(输入法不可直接提交)，不是腿失败
      echo '    [i] 探针没过 ⇒ 只试一次切到「没有中文合成」的拉丁键盘，再验一遍'
      try_latin_ime && ime_probe || exit 9
    fi
    IME_OK=1
  fi
  echo "  打字用过滤词 [$TERM](取自 $WANT_PKG 的最长 [a-z0-9] 段；行匹配仍用整包名)"
  # ★进来时先读一次这个框：官方那个框的占位符我没见过，所以"空"的第二种认法要有基准(只给第一次打字用)。
  UGBASE=$(field_now)
  echo "  刚进搜索态时字段读到 [$UGBASE]"
  GOOD=0; FIELD_LAST=""
  for k in 1 2 3; do
    BASE_OK=0; [ "$k" = 1 ] && BASE_OK=1          # ★第二次起不许再用"回到进来时的形状"蒙(那时残留都是我打的)
    if prove_empty && type_term_once; then GOOD=1; break; fi
    echo "  [!] 第 $k 次没过(字段最后读到 [$FIELD_LAST]) ⇒ 下一轮先证空再打，绝不往有字的字段上叠字"
    refocus_field
  done
  adb exec-out screencap -p > "$EV/ug_search.png" 2>/dev/null
  [ "$GOOD" = 1 ] || { echo "  [!] 三次都没打对(见 $EV/ug_search.png) ⇒ 这一轮作废，不去点卡片"; S 'input keyevent 4' >/dev/null 2>&1; continue; }
  echo '=== 3) 找**那张可点的卡**并点它(v2，第 35 发纠正：过滤后的树里行是 clickable=false，唯一可点的是组卡) ==='
  #   第 115 发把"写死 tap 540 424"换成"按包名找行"；第 35 发又发现**行本身不可点**(§6.376)：
  #   卡片标签是 `Termux user / 包含 35 个应用` 这一族，**没有包名串** ⇒ 命中判据改成"卡内标签含过滤词"，
  #   且必须恰好一张；一张没有 / 多于一张都拒点(拒点时 row_pick 自己先把输出文件删掉)。
  rm -f build_ug_row.txt          # ★残留坐标绝不能被本轮 read 拿去点(离线对照真复现过)
  $PY kmod/row_pick.py "$EV/ug_srch.xml" "$WANT_PKG" build_ug_row.txt "$TERM"; ROWRC=$?
  read RX RY < build_ug_row.txt 2>/dev/null || true     # ★不信 read 的返回码，只校验变量形状(例 70)
  if [ "$ROWRC" != 0 ] || ! [[ "$RX" =~ ^[0-9]+$ && "$RY" =~ ^[0-9]+$ ]]; then
      echo "  [!] 这一屏没读到 $WANT_PKG 的行(rc=$ROWRC) ⇒ 本轮作废，**不点卡片**；先看上面那行列出来的都有谁"
      S 'input keyevent 4' >/dev/null 2>&1; continue
  fi
  echo "  点卡片：可点卡中心=($RX,$RY)(卡里通常**没有**包名串，命中靠的是过滤词，见上面 row_pick 那一览)"; S "input tap $RX $RY"; sleep 3
  dump_to "$EV/ug_prof.xml"
  rm -f build_ug_coord.txt build_ug_srch.txt     # ★上一跑的残留坐标绝不能被本跑的 read 拿去点(离线对照里真复现过)
  # ★身份闸第 35 发改过一次口径(一手件 kmod/w103_evidence/w462_prof.xml，离线对照=kmod/_tmp_selftest_rdst/run_rowpick.sh)：
  #   旧闸要"整包名 ∧ UID"同时中，但被 35 个应用共用的那个 uid，官方那一页显示的代表包是
  #   `com.galMag.dataViewer`，整棵树里没有 `com.termux` 这个串 ⇒ **旧闸在正确的页上也必然判不中**。
  #   新闸＝`App Profile`(确实是 Profile 页) ∧ `UID <n>`(确实是那个 uid——内核名单本身就按 uid 记)；
  #   包名核对降级成读数(不中时把这一页自己的代表包打出来)，**不再当闸门**。
  $PY kmod/prof_gate.py "$EV/ug_prof.xml" "$WANT_PKG" "$WANT_UID" build_ug_coord.txt; PGRC=$?
  # ★两条一手坑(第 111 发)：①`read` 读"末尾无换行"的文件**返回非零但变量已填好** ⇒ 不信返回码，只校验变量；
  #   ②python 在 Windows 文本模式下会把补的 '\n' 写成 '\r\n' ⇒ IDENT 变成 "1\r" 就对不上 ⇒ **不写换行**，并脱一次 \r。
  CX=""; CY=""; CHK=""; IDENT=""
  read -r CX CY CHK IDENT < build_ug_coord.txt 2>/dev/null || true
  IDENT=${IDENT%$'\r'}; CHK=${CHK%$'\r'}
  if [[ "$CX" =~ ^[0-9]+$ && "$CY" =~ ^[0-9]+$ ]]; then
    if [ "$IDENT" = 1 ]; then OK=1; break; fi
    echo "  [!] 这一页的 UID $WANT_UID / App Profile 没同时中(prof_gate rc=$PGRC) ⇒ **绝不在这一页点开关**，退回重来"
  else
    echo "  [!] 本轮没从 Profile 页拿到开关坐标(prof_gate rc=$PGRC，读数见上面) ⇒ 重来，不猜坐标"
  fi
  S 'input keyevent 4' >/dev/null 2>&1; sleep 1
  S 'input keyevent 4' >/dev/null 2>&1; sleep 1               # 退回列表页再走下一轮
done
[ "$OK" = 1 ] || { echo "[x] 四轮都没进对 Profile 页 ⇒ 停，手工做(证据见 $EV/ug_prof.xml 与 $EV/ug_search.png)"; exit 6; }
echo "  ✓ Profile 页身份核对通过：UID $WANT_UID ∧ App Profile(包名 $WANT_PKG 只当读数)⇒ 开关在 ($CX,$CY)，当前 checked=$CHK"

# ★决策表只有四种组合，全部由 `MODE` 决定"要点成什么"：
#   grant  + checked=false ⇒ 点 → 复证 true ；grant + true ⇒ **不点**(幂等)
#   revoke + checked=true  ⇒ 点 → 复证 false ；revoke + false ⇒ **不点**(幂等)
#   ⇒ 反向动作永远不存在：grant 不会关，revoke 不会开；已经是目标状态就什么也不点。
WANT_STATE=true; [ "$MODE" = revoke ] && WANT_STATE=false
if [ "$CHK" = "$WANT_STATE" ]; then
  echo "  已经是 $MODE 想要的状态(checked=$CHK) ⇒ 不点(幂等，也绝不做反向动作)"
else
  echo "=== 4) 点开关（模式=$MODE：checked $CHK → $WANT_STATE）==="
  adb shell "input tap $CX $CY" >/dev/null 2>&1; sleep 4
  dump_to "$EV/ug_prof2.xml"
  # ★属性顺序是真树里的 `checkable="true" checked="..."`(离线对 w330_prof/w330_prof2 两棵树验过)，反序那条只是保险
  grep -o "checkable=\"true\"[^>]*checked=\"$WANT_STATE\"" "$EV/ug_prof2.xml" >/dev/null 2>&1 \
    || grep -o "checked=\"$WANT_STATE\"[^>]*checkable=\"true\"" "$EV/ug_prof2.xml" >/dev/null 2>&1 \
    || { echo "[x] 点完仍读不到 checked=$WANT_STATE ⇒ 没点到位"; exit 7; }
  echo "  复证：开关 checked=$WANT_STATE ✓"
fi

echo "=== 5) 内核口径复证(唯一算数的判据：UI 变绿/变灰都不等于写进内核) ==="
adb push kmod/w205_list.sh /data/local/tmp/w205_list.sh >/dev/null 2>&1
adb shell "chmod 755 /data/local/tmp/w205_list.sh" >/dev/null 2>&1
bash kmod/w211_ui.sh rleg w205_list.sh 2>&1 | tail -1
rm -f "$EV/ug_list.out"                                       # ★同理：别拿上一跑的名单当这次的
adb pull //data/local/tmp/w205_list.out "$EV/ug_list.out" >/dev/null 2>&1
[ -s "$EV/ug_list.out" ] || { echo "[x] 名单没读回来(腿或 pull 坏了) ⇒ 这一格不算数"; exit 8; }
grep -a -E "NEW_GET_ALLOW_LIST|allow\[" "$EV/ug_list.out" | sed 's/^/  /'
if grep -aq "uid=$WANT_UID" "$EV/ug_list.out"; then HAVE=1; else HAVE=0; fi
if [ "$MODE" = grant ]; then
  [ "$HAVE" = 1 ] && { echo "  ★名单里有 uid=$WANT_UID ⇒ 授权成立"; exit 0; }
  echo "[x] 内核名单里没有 uid=$WANT_UID(见 $EV/ug_list.out) ⇒ 这一格没成"; exit 8
else
  [ "$HAVE" = 0 ] && { echo "  ★名单里已无 uid=$WANT_UID ⇒ 撤销成立(count 那一行的数字就是本次真值)"; exit 0; }
  echo "[x] 撤销没生效：内核名单里仍有 uid=$WANT_UID ⇒ 这一格没成"; exit 8
fi
