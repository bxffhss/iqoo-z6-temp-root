#!/bin/bash
# w180_suwdiag.sh —— #74 的只读判据：**王座(suw)自己那个 root 任务**的 uid/gid/groups/整组 cap 到底是什么形状。
#   为什么要重判：§6.167 那次 C1 读到"escape 之后 uid 还是 10319、CapEff=0"，我把它记成"那条 ioctl 对王座没换 cred"。
#   但 #78 之后有了第二种解释：当时 `setuid/setresuid` 还在 vr 的 25 条里(c=4 之后才通)，
#   ⇒ "换了又被按形状拦回去"与"根本没换"这两种读数，用今天这把尺一分就开。
#   ★这一发**纯读**：只跑探针 + 读文件，不写名单、不动桩、不踢框架。
# 用法：bash kmod/w180_suwdiag.sh        (活窗口；rc63 缺省 args=clamp 1)
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
L=$EV/w180_suwdiag.txt
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "${2:-14}"; }
show() {   # show <文件> <标签>：把探针那两行状态与两组计数打出来
    local f=$1 t=$2
    echo "  --- $t ---"
    grep -aE "^\[起点\]|^\[终点\]" "$f" 2>/dev/null | sort -u | cut -c1-260 | sed 's/^/    /'
    echo "    POL EPERM=$(grep -a '^POL ' "$f" 2>/dev/null | grep -ac 'errno=1 ')  CTRL EPERM=$(grep -a '^CTRL ' "$f" 2>/dev/null | grep -ac 'errno=1 ')  行数=$(wc -l < "$f" 2>/dev/null)"
    grep -a "policeprobe DONE" "$f" >/dev/null 2>&1 || echo "    [警告] 没有 DONE 行 ⇒ 可能半截存证(例39)"
}

echo "=== 0) 窗口与载荷 ==="
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 先起窗口"; exit 3; }
adb push cm57/policeprobe /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/policeprobe" >/dev/null
LM=$(md5sum cm57/policeprobe | cut -c1-32); RM=$(A "md5sum /data/local/tmp/policeprobe" | cut -c1-32)
[ "$LM" = "$RM" ] || { echo "  [x] 探针 设备=$RM 本机=$LM ⇒ 停"; exit 3; }
echo "  ok policeprobe $LM"
A "pm list packages -U" | awk '$1=="package:com.suw.manager"{split($2,a,":");print "  suw 的 uid="a[2]"(王座：它自己发的 GRANT_ROOT 走的是 default_root_profile)"}'

echo "=== 1) 王座那条 su 路(@su: 动词 ⇒ 跑在 suw 自己的进程里，输出进 app_su.txt) ==="
A "rm -f /sdcard/Android/data/$SUW/files/app_su.txt" >/dev/null
fire "@su:/data/local/tmp/policeprobe suwctx" 16
A "cat /sdcard/Android/data/$SUW/files/app_su.txt 2>&1" > "$L"
show "$L" "suw(@su:) 上下文"
echo "    这份里 shim 自己的回执行："; grep -aE "SHIM-ESC|uid后=|reboot" "$L" | cut -c1-170 | sed 's/^/      /'

echo "=== 2) agent(@sushd) 上下文同发对照(它才是历史上那个 uid 0) ==="
bash kmod/w177_run.sh > "$EV/w180_agent.log" 2>&1
show "$EV/w177_pp.txt" "agent(@sushd) 上下文"

echo "=== 3) 判读口径(先写好，免得事后挑) ==="
cat <<'TXT'
  · 若 suw 那行是 `uid=0… gid=0… groups=0…` 且 cap=`0x3fffffffff` ⇒ §6.167 那条"没换 cred"要**改成**
    "换了，只是当时 setuid/setresuid 还在被管，读数被 vr 拦回去" ⇒ #74 结案。
  · 若 suw 那行还是 `uid=10319` 或 `cap_prm=0` ⇒ 那条 ioctl 确实**没给王座换 cred**，#74 原题成立，
    得去 ko 的 `is_uid_manager ⇒ use_default` 那条短路里找因由。
  · groups：两处都打 `Groups=` ⇒ 顺手把 #72/#77 那笔"groups 落没落地"的账一次结掉(出厂 root 应是 `Groups: 0`)。
TXT
