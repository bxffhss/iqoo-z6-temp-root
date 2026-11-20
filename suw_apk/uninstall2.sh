#!/bin/bash
# vivo **卸载**闸: 与 install2.sh 同一套点闸引擎，只是后台命令换成 `pm uninstall <PKG>`。
#   为什么需要它(2026-10-02 第七十发)：`adb shell pm uninstall` 会**静默挂住**(不报错、不返回、
#   包还在)，屏幕上也没有对话框 —— 装/卸在 vivo 上是同一个拦截者，必须有人点。
#   用法: PKG=me.weishu.kernelsu bash uninstall2.sh
#
# ★ 两个必须知道的坑 (2026-09-29 拿真机 dump 实测, 见 ui.xml):
#   1) 弹窗上的按钮文案在 **content-desc** 里, text 是空的:
#        <Button text="" content-desc="继续安装" clickable="true" bounds="[144,2040][936,2178]">
#        <TextView text="继续安装" clickable="false" .../>   <- 有文字但不能点
#      只按 text 匹配 => 永远取不到按钮 (install.sh / ui_scan.py 都中了这个招)。
#   2) 复选框可能已经是 checked="true", 再 tap 一次等于**取消勾选**, 按钮随即 enabled=false 变灰。
#      所以必须读 checked 属性, 只在未勾选时才点。
#
# 结构: python 负责解析弹窗并**决定本轮唯一动作**, bash 只负责执行 tap。
#   早期版本把 "x y checked enabled label" 交给 bash 用 set -- 拆字段, 但
#   shell 拆词会把**空字段折叠掉** (enabled 缺失时 label 就顶到了 $4), 错位是静默的。
set -u
cd "$(dirname "$0")"
ADB="${ADB:-C:/adb/platform-tools/adb.exe}"
DEV="${DEV:-<DEVICE_SERIAL>}"
A() { MSYS2_ARG_CONV_EXCL='*' "$ADB" -s "$DEV" "$@"; }
PY="C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe"  # 强制 utf-8 输出, 否则中文 label 在管道里变乱码
APK=suw.apk
PKG=${PKG:-com.suw.manager}
XML=/sdcard/suwi.xml
LOCAL_UI=ui_uninst_last.xml   # 不覆盖 ui.xml(那是 09-29 抓的真机参考 dump)
LOG=uninstall_out.log

ROUNDS=${ROUNDS:-40}                    # 每轮 ~1.5-2.5s, 40 轮 ≈ 90s 上限
CHK_KEYS='已了解,同意'                   # 复选框文案候选, 靠前的优先
GO_KEYS='继续安装,仍要安装,直接安装,继续,卸载,仍要卸载,确定,同意,允许' # 确认按钮文案候选

# adb install 必须活在这同一条命令里: 子 shell/工具调用一结束它就被带走(实测日志变空)
tap() { A shell "input tap $1 $2" >/dev/null 2>&1; }

# uiautomator 在动画/无障碍未空闲时会 fail, 所以重试并校验拿到的是 XML
dump_ui() {
  local i
  for i in 1 2 3; do
    A shell "uiautomator dump $XML >/dev/null 2>&1; cat $XML" 2>/dev/null \
      | tr -d '\r' > "$LOCAL_UI"
    grep -q '<node' "$LOCAL_UI" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# 输出一行本轮动作: TAP <x> <y> <CHECK|GO> <label>  /  WAIT <原因>  /  NONE <原因>
plan() {
  PYTHONIOENCODING=utf-8 "$PY" - "$1" "$CHK_KEYS" "$GO_KEYS" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
rows = []
for m in re.finditer(r'<node\b[^>]*>', s):
    t = m.group(0)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', t)
    if not b:
        continue
    def att(k):
        r = re.search(k + r'="([^"]*)"', t)
        return r.group(1) if r else ''
    x1, y1, x2, y2 = map(int, b.groups())
    rows.append({'text': att('text'), 'desc': att('content-desc'),
                 'cls': att('class'), 'click': att('clickable'),
                 'enable': att('enabled'), 'checked': att('checked'),
                 'cx': (x1 + x2) // 2, 'cy': (y1 + y2) // 2,
                 'area': max(1, (x2 - x1) * (y2 - y1))})

def find(wants):
    # text 或 content-desc 任一命中即可; 按 wants 顺序取第一个有命中的文案,
    # 同一文案多节点时优先 Button, 再取面积最小(避免拿到外层容器)
    for w in wants:
        hit = [r for r in rows if r['click'] == 'true'
               and (w in r['text'] or w in r['desc'])]
        if not hit:
            continue
        hit.sort(key=lambda r: ('button' not in r['cls'].lower(), r['area']))
        if len(hit) > 1:
            sys.stderr.write('  [候选] %s: %s\n' % (w, ' | '.join(
                '%s@%d,%d' % (q['cls'].split('.')[-1], q['cx'], q['cy'])
                for q in hit[:4])))
        return hit[0]
    return None

def label(r):
    return ' '.join((r['text'] or r['desc']).split()) or r['cls'].split('.')[-1]

chk = find([k for k in sys.argv[2].split(',') if k])
go = find([k for k in sys.argv[3].split(',') if k])

if chk and chk['checked'] != 'true':
    print('TAP\t%d\t%d\tCHECK\t%s' % (chk['cx'], chk['cy'], label(chk)))
elif go and (go['enable'] or 'true') == 'true':
    print('TAP\t%d\t%d\tGO\t%s' % (go['cx'], go['cy'], label(go)))
elif go:
    print('WAIT\t-\t-\t-\t按钮 %s enabled=%s 还是灰的' % (label(go), go['enable']))
elif chk:
    print('WAIT\t-\t-\t-\t已勾选但没找到确认按钮')
else:
    print('NONE\t-\t-\t-\t弹窗还没出现')
PY
}

# ---- 前置 ------------------------------------------------------------------
A shell "input keyevent KEYCODE_WAKEUP; sleep 1; wm dismiss-keyguard" >/dev/null 2>&1

# 判据一律用"捕获输出"而不是退出码: adb shell 的 exit code 在 Windows/Git Bash 链路上不可信
if [ -n "$(A shell "pm list packages | grep -w $PKG" 2>/dev/null | tr -d '\r')" ]; then
  echo "[i] $PKG 已装过, 本次用 -r 覆盖"
else
  echo "[i] $PKG 未安装, 首次安装"
fi

# 上一次失败会把 packageinstaller 孤零零留在前景, 那这次的 dump 读到的是旧闸, 必须先收掉
if [ -n "$(A shell "dumpsys window | grep PackageInterceptActivity" 2>/dev/null | tr -d '\r')" ]; then
  echo "[i] 检测到残留的安装弹窗, 先 BACK 收掉再重打"
  A shell "input keyevent KEYCODE_BACK" >/dev/null 2>&1
  sleep 1
fi

# 刚重启过的设备上, "USB 已连接(仅充电/传输照片/管理文件/连接车辆)" 会抢焦点:
# 那时 dump 里只有一个「取消」, 而 install 会永远等不到它要点的闸 —— 表现为对着**上一个窗口**的
# 旧坐标连点几十轮"继续安装"全空转、install_out.log 一直是 0 字节(2026-09-29 踩过)。
if dump_ui && grep -q 'VivoUsbDialog' "$LOCAL_UI" 2>/dev/null; then
  UX=$(PYTHONIOENCODING=utf-8 "$PY" - "$LOCAL_UI" <<'PY'
import io, re, sys
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
for m in re.finditer(r'<node\b[^>]*>', s):
    t = m.group(0)
    if 'clickable="true"' not in t:
        continue
    lab = re.search(r'(?:text|content-desc)="([^"]*)"', t)
    if not lab or lab.group(1).strip() != u'取消':
        continue
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', t)
    if b:
        x1, y1, x2, y2 = map(int, b.groups())
        print('%d %d' % ((x1 + x2) // 2, (y1 + y2) // 2))
    break
PY
)
  if [ -n "$UX" ]; then
    echo "[i] 先点掉 USB 模式选择框的[取消] @ $UX"
    tap $UX
    sleep 1
  fi
fi

echo "[*] pm uninstall $PKG ..."
A shell "pm uninstall $PKG" > "$LOG" 2>&1 &
INST=$!
echo "[i] 等弹窗..."
sleep 4

GO_TAPS=0
FINISHED=0
for ((round = 1; round <= ROUNDS; round++)); do
  if ! kill -0 $INST 2>/dev/null; then
    echo "[i] 安装进程结束 (round=$round)"
    FINISHED=1
    break
  fi
  if ! dump_ui; then
    echo "[!] round=$round 拿不到 UI dump, 等下一轮"
    sleep 2
    continue
  fi
  # 一轮只做一个动作, 做完必定重新 dump —— 勾选会改按钮状态, 拿旧坐标签必然踩空
  IFS=$'\t' read -r ACT X Y WHICH REST < <(plan "$LOCAL_UI" | tr -d '\r')
  case "$ACT" in
    TAP)
      if [ "$WHICH" = GO ]; then GO_TAPS=$((GO_TAPS + 1)); fi
      echo "[i] round=$round tap $WHICH ($REST) @ $X,$Y  [第 $GO_TAPS 次点确认]"
      tap "$X" "$Y"
      sleep 1.5
      ;;
    WAIT)
      echo "[i] round=$round $REST, 等界面刷新"
      sleep 1.5
      ;;
    *)
      echo "[.] round=$round $REST (install 仍在跑)"
      sleep 1
      ;;
  esac
done

# 超时兜底: 别让 wait 把整个脚本挂死在这里
if [ "$FINISHED" != 1 ] && kill -0 $INST 2>/dev/null; then
  echo "[x] 跑了 $ROUNDS 轮安装进程还没结束 —— 杀掉, 保留最后一份 $LOCAL_UI 供排查"
  kill $INST 2>/dev/null
  cp -f "$LOCAL_UI" ui_fail.xml 2>/dev/null && echo "    已存 ui_fail.xml"
  echo "    共点确认按钮 $GO_TAPS 次; >0 说明文案/坐标对了但闸还在, 直接看屏幕"
fi
wait $INST 2>/dev/null

echo "=== 安装输出 ==="
tr -d '\r' < "$LOG"
echo "=== 校验: 包还在不在(应当已卸载) ==="
A shell "pm path $PKG >/dev/null 2>&1 && echo '还在(闸没点掉)' || echo '已卸载'" 2>&1 | tr -d '\r'
