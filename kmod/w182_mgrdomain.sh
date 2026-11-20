#!/bin/bash
# w182_mgrdomain.sh —— #81 的同窗单变量：把"王座(Manager)那条 root 的 SELinux 域"设成 shell 再复位，各测一次。
#   前提：窗口用 rc64 起 —— KO=kmod/kernelsu_rc64.ko I_KNOW=1 bash kmod/go.sh
#   为什么这个口值得开(§6.168)：`allowlist.c` 里 `is_uid_manager ⇒ goto use_default` ⇒ 给 Manager 写
#   SET_APP_PROFILE 永不生效，它只能吃 `default_root_profile`；而那份默认域在本机策略里不存在，
#   `setup_selinux()` 对不存在的域=保持起点域 ⇒ 官方 Manager 的 root 任务停在 `untrusted_app`。
# ★判据三条(同一发，缺一不算成)：
#   ① `?` 先读到**起点串**，且此刻 `@su:` 派出的探针 `dom=u:r:untrusted_app`(=§6.181 的读数，基线当场重做)；
#   ② 设成 `u:r:shell:s0` 之后，**新**的 `@su:` 任务 `dom=u:r:shell:s0`；
#   ③ 把起点串写回去(复位)，再来一次 `@su:` ⇒ `dom` 又回到 `untrusted_app`。
#   旁证：三遍之后 `/proc/ksu_cfiscan` 还是 22(这一发不碰任何桩)。
set -u
cd "$(dirname "$0")/.." || exit 1
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
SUW=com.suw.manager
SET=/data/local/tmp/w182_set.sh
WANT=/data/local/tmp/w182_want.txt
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "${2:-14}"; }
setsync() {  # setsync <要写进那个口的整行>
    A "printf '%s\n' \"$1\" > $WANT; rm -f /data/local/tmp/w182_set.out" >/dev/null
    fire "@sushd:$SET" 6
    for i in $(seq 1 12); do
        c=$(A "grep -acF '===== DONE' /data/local/tmp/w182_set.out 2>/dev/null" | tr -dc '0-9')
        [ "${c:-0}" != "0" ] && break; sleep 5
    done
    A "grep -aE 'want=|MGRDOMAIN' /data/local/tmp/w182_set.out" | tail -4 | cut -c1-160 | sed 's/^/      /'
}
leg() {   # leg <标签>：在王座进程里跑探针，只关心 [起点] 那行的 dom=
    local t=$1
    A "rm -f /sdcard/Android/data/$SUW/files/app_su.txt" >/dev/null
    fire "@su:/data/local/tmp/policeprobe mgr_$t" 16
    A "cat /sdcard/Android/data/$SUW/files/app_su.txt 2>&1" > "$EV/w182_$t.txt"
    echo "      [$t] $(grep -a '^\[起点\]' "$EV/w182_$t.txt" | head -1 | cut -c1-230)"
    echo "      [$t] POL EPERM=$(grep -a '^POL ' "$EV/w182_$t.txt" | grep -ac 'errno=1 ')  CTRL EPERM=$(grep -a '^CTRL ' "$EV/w182_$t.txt" | grep -ac 'errno=1 ')  行数=$(wc -l < "$EV/w182_$t.txt")"
}

echo "=== 0) 前置：这发的 ko 得是 rc64(带着那个口) ==="
echo "  $(A 'echo id=$(id -u) mod=$(grep -c kernelsu /proc/modules) enf=$(getenforce) up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)')"
[ "$(A 'grep -c kernelsu /proc/modules' | tr -dc 0-9)" != "0" ] || { echo "[x] 模块没加载 ⇒ 先起窗口"; exit 3; }
adb push cm57/policeprobe kmod/w182_set.sh /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 $SET /data/local/tmp/policeprobe" >/dev/null
LM=$(md5sum cm57/policeprobe | cut -c1-32); RM=$(A "md5sum /data/local/tmp/policeprobe" | cut -c1-32)
[ "$LM" = "$RM" ] || { echo "  [x] 探针 设备=$RM 本机=$LM ⇒ 停"; exit 3; }
echo "  ok policeprobe $LM"

echo "=== 1) 问一次当前值(也顺便证明这个口在) ==="
setsync "?"
BASE=$(A "grep -ao 'MGRDOMAIN 现在=\[[^]]*\]' /data/local/tmp/w182_set.out" | head -1 | sed 's/.*=//; s/^\[//; s/\]$//')
echo "  起点域=[$BASE]  (空=这个口没被写过，行为与 rc63 一致)"

echo "=== 2) 基线腿(应 dom=untrusted_app，§6.181 的读数当场重做) ==="
leg base

echo "=== 3) 设成 shell 域，再来一发 ==="
setsync "u:r:shell:s0"
leg shell

echo "=== 4) 复位：把起点串原样写回去，再验证一次 ==="
setsync "${BASE:-u:r:su:s0}"
leg back

echo "=== 5) 旁证：桩一条没动(应 22) ==="
bash kmod/w171_run.sh > "$EV/w182_cfiscan.log" 2>&1
grep -aE "VRCFI 结束" "$EV/w182_cfiscan.log" | tail -1 | cut -c1-160 | sed 's/^/      /'
echo "  ★期望：base/back 两腿 dom=u:r:untrusted_app…，shell 腿 dom=u:r:shell:s0；cfiscan=22；CTRL 全绿"
echo "  ★收法：I_KNOW=1 bash kmod/w161_teardown.sh"
