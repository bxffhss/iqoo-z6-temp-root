#!/bin/bash
# w162_domain_window.sh —— #62：把"官方 Manager 的 su 子进程"从 `u:r:untrusted_app` 换成
#   `u:r:shell:s0`，看 libsu 的 RootService(root 的 app_process)是否因此起得来 ⇒ 官方 UI 那个
#   "超级用户"开关能不能真的写进内核名单。
# 一手依据(§6.153)：开关点下去 toast"更新 App Profile 失败"，内核 SET_APP_PROFILE 命中 0 次；
#   而 Manager 名下那两个 root shell 是 `uid=0 ctx=u:r:untrusted_app:s0:c61,c257,c512,c768`；
#   对照自测：root 在 kernel 域 `app_process64 --help` 0.18s 通、`exec 9<>/dev/binder` 通。
#   ⇒ 唯一缺口就是"给 Manager 自己写一条 domain=shell 的 profile"，而这必须**从 root 侧发**
#     (suw 不是王座 ⇒ SET_APP_PROFILE 被 manager_or_root 拒：rc=-1 errno=1)。
# 新工具：cm57/ksuctl88(多了 `setprof <uid> <pkg> <domain|->` 动词；编法见 cm57/build_ksuctl.sh，
#   ★少了 -fno-emulated-tls 会得到一个上机就 Aborted 的二进制)。
# ★本脚本跑到"停在窗口内"就结束，界面最后两下(搜 Termux → 点那一行 → 翻开关)由 PC 侧照**实时截图**点；
#   收尾一律 `I_KNOW=1 bash kmod/w161_teardown.sh`。
set -u
cd "$(dirname "$0")/.." || exit 1
[ "${I_KNOW:-}" = 1 ] || { echo "[x] 要 I_KNOW=1(会 punch + reboot)"; exit 2; }
export MSYS_NO_PATHCONV=1
A() { adb shell "$1" 2>&1 | tr -d '\r'; }
EV=kmod/w103_evidence; mkdir -p "$EV"
MGR=me.weishu.kernelsu
SUW=com.suw.manager
TGT=com.termux
CTL=/data/local/tmp/ksuctl88
shot() { adb exec-out screencap -p > "$EV/w35_$1.png" 2>/dev/null
         echo "      截图 w35_$1.png $(stat -c %s "$EV/w35_$1.png" 2>/dev/null) 字节"; }
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
WAITFOR() { local f=$1 n=$2 m=$3 i=0 g
    while [ "$i" -lt "$n" ]; do
        g=$(A "grep -acF '$m' $f 2>/dev/null" | tr -dc '0-9')
        case "$g" in ''|*[!0-9]) : ;; *) [ "$g" -ge 1 ] && { echo "      (等到 $f 的[$m])"; return 0; } ;; esac
        sleep 3; i=$((i+1))
    done; echo "      (等满 $((n*3))s 没有[$m])"; return 1; }
pk_uid() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }
fdcb() {   # 只看**回调行**且点名 comm(§6.153①：'已排队' 与 '回调' 之间可以隔 0.09s~47s)
    A "grep -a 'KSUFDINST 回调跑在 pid=$1' /data/local/tmp/dmesg.live 2>/dev/null | grep -a weishu | tail -2" | cut -c1-150; }
fdcnt() { A "ls -l /proc/$1/fd 2>/dev/null | grep -ac ksu" | tr -dc '0-9'; }
show_focus() { A "dumpsys activity activities 2>/dev/null | grep -a topResumedActivity | head -1"; }

echo "=== 1) uid 实况 + 版本核对 ==="
until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 5; done
TGTUID=$(pk_uid "$TGT"); MGRUID=$(pk_uid "$MGR"); SUWUID=$(pk_uid "$SUW")
echo "  Termux=$TGTUID 官方=$MGRUID suw=$SUWUID"
for v in TGTUID MGRUID SUWUID; do eval "X=\$$v"
    case "$X" in ''|*[!0-9]*) echo "[x] $v 不干净：[$X] ⇒ 停"; exit 3;; esac; done
VER=$(A "dumpsys package $MGR" | grep -a versionName | head -1)
case "$VER" in *v2.0.0*) echo "  官方 Manager=$VER ✓";; *) echo "[x] 在装的是 [$VER]，要 v2.0.0 ⇒ 停"; exit 3;; esac

echo "=== 2) push ko + 载荷 → reboot → punch → 等判据④ ==="
printf '%s\n' "ksu_mass_mark=0 ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud" > kmod/ksu_args.txt
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|\[x\]" | sed 's/^/  /'
adb push kmod/w161_fdwatch.sh kmod/w161_fdlaunch.sh kmod/w161_g2.sh kmod/w161_fd1.sh kmod/w161_appc.sh /data/local/tmp/ >/dev/null 2>&1
adb push cm57/ksuctl88 /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w161_*.sh $CTL" >/dev/null
[ "$(A "md5sum $CTL" | cut -c1-32)" = "$(md5sum cm57/ksuctl88 | cut -c1-32)" ] || { echo "[x] 设备上的 ksuctl88 与本机不一致 ⇒ 停"; exit 3; }
echo "  ksuctl88 已就位(带 setprof 动词)"
[ "$(A 'ls /data/local/tmp/kernelsu.ko 2>/dev/null' | grep -ac kernelsu.ko)" != "0" ] || { echo "[x] ko 没落上 ⇒ 停"; exit 3; }
adb reboot
until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 5; done
sleep 40
A "rm -f /data/local/tmp/ksu_stage.log /data/local/tmp/punch.log /data/local/tmp/dmesg.live /data/local/tmp/w161_fdwatch.log /data/local/tmp/w161_r0.txt" >/dev/null
for i in $(seq 1 40); do
    L1=$(A "cat /proc/loadavg" | cut -d. -f1)
    [ "${L1:-99}" -le 3 ] && { echo "  负载够低：load1=$L1 up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1)"; break; }
    [ $((i % 6)) = 0 ] && echo "    还在等: load1=$L1"
    sleep 15
done
I_KNOW=1 bash suw_apk/bootstrap.sh --punch >"$EV/w35_bootstrap.txt" 2>&1
echo "  bootstrap 退出码=$?"; tail -2 "$EV/w35_bootstrap.txt" | sed 's/^/    /'
for i in $(seq 1 20); do sleep 5; [ -n "$(A 'ls -l /data/local/tmp/punch.log 2>/dev/null')" ] && { echo "  pr 已起跑"; break; }; done
N=0
for i in $(seq 1 220); do sleep 5
    N=$(A "grep -ac '判据④' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    [ "${N:-0}" != "0" ] && { echo "  stage 到判据④ (t+$((i*5))s)"; break; }
done
[ "${N:-0}" = "0" ] && { echo "[x] 没等到判据④ ⇒ 停。stage 自己怎么说："
    A "grep -aE '!!|No such file|insmod rc|起点' /data/local/tmp/ksu_stage.log 2>/dev/null | tail -6" | cut -c1-150 | sed 's/^/    /'
    exit 5; }

echo "=== 3) bind su + 起装 fd 看门狗 ==="
adb push cm57/sustatic /data/local/tmp/sustatic >/dev/null 2>&1
adb push kmod/w135_fix.sh /data/local/tmp/w135_fix.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh; rm -f /data/local/tmp/w135_fix.out" >/dev/null
fire "@sushd:/data/local/tmp/w135_fix.sh" 8
WAITFOR /data/local/tmp/w135_fix.out 40 "===== DONE"
A "grep -aE 'BIND_RC|SU_AT_TGT|HEALTH' /data/local/tmp/w135_fix.out | cut -c1-110" | sed 's/^/    /'
A "rm -f /data/local/tmp/w161_fdlaunch.out" >/dev/null
fire "@sushd:/data/local/tmp/w161_fdlaunch.sh" 8
WAITFOR /data/local/tmp/w161_fdlaunch.out 20 "===== DONE"
A "grep -aE '触发口|看门狗' /data/local/tmp/w161_fdlaunch.out | cut -c1-130" | sed 's/^/    /'

echo "=== 4) 起 Manager → 等回调行 → 确认 fd 在它进程里 ==="
ACT="$MGR/.ui.MainActivity"
for c in 1 2 3 4 5 6; do
    A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; am start -n $ACT" >/dev/null 2>&1
    sleep 10
    MP=$(A "pidof $MGR" | cut -d' ' -f1)
    case "$MP" in ''|*[!0-9]*) echo "    第 $c 轮：没拿到 pid"; continue;; esac
    CB=$(fdcb "$MP"); N=$(fdcnt "$MP"); N=${N:-0}
    echo "    第 $c 轮 pid=$MP fd条数=$N 回调=[${CB:-无}]"
    [ "$N" != "0" ] && break
    sleep 8   # 排队→回调最长见过 47s，多给它一点时间(不重开进程，避免又丢 fd)
done
[ "${N:-0}" != "0" ] || { echo "[x] fd 没装上 ⇒ 后面全部作废，停"; exit 6; }

echo "=== 5) ★root 侧给 Manager 写 profile：domain=u:r:shell:s0 ==="
adb push kmod/w162_sp.sh /data/local/tmp/w162_sp.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w162_sp.sh; echo $MGRUID > /data/local/tmp/w162_mgr.uid; rm -f /data/local/tmp/w162_sp.out" >/dev/null
fire "@sushd:/data/local/tmp/w162_sp.sh" 10
WAITFOR /data/local/tmp/w162_sp.out 20 "===== DONE"
A "cat /data/local/tmp/w162_sp.out" | cut -c1-170 | sed 's/^/    /'

echo "=== 6) 重启 Manager(换 pid) → 看门狗补 fd → 开超级用户页让 libsu 起 root shell ==="
A "am force-stop $MGR" >/dev/null; sleep 3
A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; am start -n $ACT" >/dev/null 2>&1; sleep 12
MP=$(A "pidof $MGR" | cut -d' ' -f1)
A "echo $MP > /data/local/tmp/w161_mgr.pid" >/dev/null
A "rm -f /data/local/tmp/w161_fd1.out" >/dev/null
fire "@sushd:/data/local/tmp/w161_fd1.sh" 10
WAITFOR /data/local/tmp/w161_fd1.out 20 "===== DONE"
A "grep -aE '目标 pid|fd 表里|写触发口' /data/local/tmp/w161_fd1.out | cut -c1-140" | sed 's/^/    /'
echo "    把 Manager 带回前台(让 task_work 有机会跑)"; A "am start -n $ACT" >/dev/null 2>&1; sleep 8
echo "    首页那张『超级用户』卡(§6.153 实测坐标 801,789) ⇒ 点"; A "input tap 801 789" >/dev/null; sleep 14
shot list_page
echo "    焦点: $(show_focus)"
A "rm -f /data/local/tmp/w161_appc.out" >/dev/null
fire "@sushd:/data/local/tmp/w161_appc.sh" 12
WAITFOR /data/local/tmp/w161_appc.out 20 "===== DONE"
echo "  ★正判据在下面的 A) 段：Manager 名下 root shell 的 ctx 现在是 shell 还是 untrusted_app"
A "cat /data/local/tmp/w161_appc.out" | cut -c1-170 | sed 's/^/    /'
echo "=== 7) 停在窗口内 ==="
echo "  pid(Manager)=$MP  fd条数=$(fdcnt "${MP:-0}")  mod=$(A 'grep -c kernelsu /proc/modules')  enf=$(A getenforce)"
echo "  接下来照实时截图点：搜索框(540,474) → 切英文 → 输 Termux → 点 ZeroTermux 那行 → 翻『超级用户』开关"
echo "  判据复读：fire '@sushd:/data/local/tmp/w161_g2.sh' 之后看 UID_GRANTED_ROOT uid=$TGTUID"
echo "  收尾：I_KNOW=1 bash kmod/w161_teardown.sh"
