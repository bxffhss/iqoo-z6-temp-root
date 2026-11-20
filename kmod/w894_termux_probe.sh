#!/usr/bin/env bash
# w894: drive the app-domain su test inside ZeroTermux itself (typing leg, with readback before Enter)
# Rule honoured: prove the typed line is correct BEFORE pressing Enter (IME can mangle it).
cd "$(dirname "$0")/.." || exit 1
EV=analysis/ev/w846
mkdir -p "$EV/w894"
A() { MSYS_NO_PATHCONV=1 adb shell "$1" 2>&1; }
shot() {
  N="$1"
  A "uiautomator dump /sdcard/w894.xml >/dev/null 2>&1; wc -c < /sdcard/w894.xml" | head -1
  MSYS_NO_PATHCONV=1 adb pull //sdcard/w894.xml "$EV/w894/$N.xml" >/dev/null 2>&1
  echo "  --- $N screen text:"
  PYTHONUTF8=1 python - "$EV/w894/$N.xml" <<'PY'
import re, sys
t = open(sys.argv[1], encoding='utf-8', errors='replace').read()
vals = re.findall(r'(?:content-desc|text)="([^"]{4,300})"', t)
seen = []
for v in vals:
    v = v.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>')
    if v not in seen:
        seen.append(v)
for v in seen[-10:]:
    print('   |', v.replace('\n', ' | ')[:200])
PY
}
type_in() { A "input text \"$1\""; }

echo "== 0) baseline"
shot base
echo "== 1) warm line (first char gets eaten in a fresh session)"
type_in 'echo%swarm'; A "input keyevent 66"; sleep 2
shot warm
echo "== 2) plain id (who am I in this terminal)"
type_in 'id'; A "input keyevent 66"; sleep 2
shot id
echo "== 3) type the su command, READ IT BACK BEFORE ENTER"
type_in '/system/bin/su%sc%sid'; sleep 1
shot typed_su
echo "== 4) press Enter"
A "input keyevent 66"; sleep 4
shot su_result
echo "== 5) bare /system/bin/su (interactive)"
type_in '/system/bin/su'; A "input keyevent 66"; sleep 5
shot su_interactive
echo "== 6) leave it"
type_in 'exit'; A "input keyevent 66"; sleep 2
A "id" | head -1
echo "== 7) tombstones right now"
A "dumpsys dropbox" | grep -a "$(A 'date +%Y-%m-%d' | tr -d '\r')" | tail -5
echo "== done"
