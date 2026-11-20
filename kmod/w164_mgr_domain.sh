#!/bin/bash
# w164_mgr_domain.sh —— #63：**让官方 Manager 的 su 子进程一出生就在 shell 域**，看 libsu 的
#   RootService(root 的 app_process)是否因此起得来 ⇒ 官方 UI 那个"超级用户"开关能不能真写进内核名单。
# 为什么只能这么走(§6.154 的两条一手)：
#   ① 上一发 root(uid 0, u:r:kernel:s0)发 SET_APP_PROFILE 也是 `rc=-1 errno=1(EPERM)`
#      ⇒ 这条 ioctl 的 perm 是 **only_manager**，不是 manager_or_root；"从 root 侧补一条 profile"没有门。
#   ② 让 Manager 自己发又正好是坏掉的那条 libsu RootService 路 ⇒ 循环。
#   ⇒ 唯一不依赖运行期 ioctl 的入口 = **insmod 时内核 load_allowlist 读的那份 .allowlist**，
#      现在 ksuctl88 的 mkallow 支持多条目、stage 见到 /data/local/tmp/ksu_two_profiles 就多写一条。
# ★判据形状也修了：上一发我用 shell 身份去 `ls /proc/<app>/fd` 数 ksu ⇒ 恒 0(没权限)⇒ 误判"fd 没装上"，
#   而内核回调行明明写着 `=> fd=902`。⇒ 这一发"fd 在不在"只认**内核回调行**，/proc 那条一律走 root 侧。
# 跑到"停在窗口内"就结束；收尾 `I_KNOW=1 bash kmod/w161_teardown.sh`。
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
shot() { adb exec-out screencap -p > "$EV/w36_$1.png" 2>/dev/null
         echo "      截图 w36_$1.png $(stat -c %s "$EV/w36_$1.png" 2>/dev/null) 字节"; }
fire() { A "am force-stop $SUW" >/dev/null; sleep 1
         A "am start -n $SUW/.MainActivity --es auto ksuarm --es cmd \"$1\"" >/dev/null 2>&1; sleep "$2"; }
WAITFOR() { local f=$1 n=$2 m=$3 i=0 g
    while [ "$i" -lt "$n" ]; do
        g=$(A "grep -acF '$m' $f 2>/dev/null" | tr -dc '0-9')
        case "$g" in ''|*[!0-9]) : ;; *) [ "$g" -ge 1 ] && { echo "      (等到 $f 的[$m])"; return 0; } ;; esac
        sleep 3; i=$((i+1))
    done; echo "      (等满 $((n*3))s 没有[$m])"; return 1; }
pk_uid() { A "pm list packages -U" | awk -v P="package:$1" '$1==P {split($2,a,":"); print a[2]}'; }
fdcb() { A "grep -a 'KSUFDINST 回调跑在 pid=$1' /data/local/tmp/dmesg.live 2>/dev/null | grep -a weishu | tail -1" | cut -c1-150; }

echo "=== 1) uid 实况 + 版本核对 ==="
until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 5; done
TGTUID=$(pk_uid "$TGT"); MGRUID=$(pk_uid "$MGR"); SUWUID=$(pk_uid "$SUW")
echo "  Termux=$TGTUID 官方=$MGRUID suw=$SUWUID"
for v in TGTUID MGRUID SUWUID; do eval "X=\$$v"
    case "$X" in ''|*[!0-9]*) echo "[x] $v 不干净：[$X] ⇒ 停"; exit 3;; esac; done
VER=$(A "dumpsys package $MGR" | grep -a versionName | head -1)
case "$VER" in *v2.0.0*) echo "  官方 Manager=$VER ✓";; *) echo "[x] 在装的是 [$VER]，要 v2.0.0 ⇒ 停"; exit 3;; esac

echo "=== 2) push ko/载荷 + 两条目开关 → reboot → punch → 等判据④ ==="
printf '%s\n' "ksu_mass_mark=0 ksu_hook_mask=0x2 ksu_no_escape=1 ksu_no_cred_override=1 ksu_ksud_path=/dev/ksud" > kmod/ksu_args.txt
bash kmod/push_ksu.sh 2>&1 | grep -aE "ok kernelsu.ko|ok ksu_args|\[x\]" | sed 's/^/  /'
adb push kmod/w161_fdwatch.sh kmod/w161_fdlaunch.sh kmod/w161_g2.sh kmod/w161_fd1.sh kmod/w161_appc.sh kmod/w163_fds.sh /data/local/tmp/ >/dev/null 2>&1
adb push cm57/ksuctl88 /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w16*_*.sh $CTL" >/dev/null
# ★开关文件里带**两条**额外 profile：一条无关第三方(正对照，验"多条目格式内核收不收")、
#   一条官方 Manager(要验的目标)。顺序=先正对照后目标，这样 count 少了也知道少的是谁。
A "printf '%s\n' '$TGTUID:com.termux $MGRUID:me.weishu.kernelsu' > /data/local/tmp/ksu_two_profiles; cat /data/local/tmp/ksu_two_profiles" | sed 's/^/  开关内容: /'
LM=$(md5sum cm57/ksuctl88 | cut -c1-32); RM=$(A "md5sum $CTL" | cut -c1-32)
[ "$LM" = "$RM" ] || { echo "[x] 设备上 ksuctl88 不是这份(本机=$LM 设备=$RM) ⇒ 停"; exit 3; }
[ -n "$(A 'ls /data/local/tmp/ksu_two_profiles 2>/dev/null' | grep -a ksu_two)" ] || { echo "[x] 两条目开关没落上 ⇒ 停"; exit 3; }
echo "  ksuctl88=$LM 就位；ksu_two_profiles 开关已写"
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
I_KNOW=1 bash suw_apk/bootstrap.sh --punch >"$EV/w36_bootstrap.txt" 2>&1
echo "  bootstrap 退出码=$?"; tail -2 "$EV/w36_bootstrap.txt" | sed 's/^/    /'
for i in $(seq 1 20); do sleep 5; [ -n "$(A 'ls -l /data/local/tmp/punch.log 2>/dev/null')" ] && { echo "  pr 已起跑"; break; }; done
# ★闸门口改了(§6.156 一手)：上一跑 stage 在判据⑥之后被机器复位打断，判据④**永远没来**，
#   而我这个闸只等判据④ ⇒ 白等 18 分钟才停。本发真正需要的前置只有两条：
#   ① 模块在(`grep -c kernelsu /proc/modules`>0)；② stage 跑到了判据⑥(agent fd 装好、suw 通道活着)。
#   判据④只当参考。另外**fail-fast 加一条 uts 健康检查**：punch 那一笔溢出会把
#   `kernel_utsname.sysname` 的最后一字节改成 NUL(`uname -s` 读出 `Linu`)，那时 ART 起不了任何 app
#   ⇒ app/UI 判据必为零报告(第六十八发就是这么废的)，不该再拿它等 18 分钟。
OKGATE=0
for i in $(seq 1 140); do sleep 5
    SIX=$(A "grep -ac '判据⑥' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')
    MODN=$(A 'grep -c kernelsu /proc/modules' | tr -dc '0-9')
    if [ "${SIX:-0}" != "0" ]; then
        echo "  stage 到判据⑥ (t+$((i*5))s) 此刻 mod=${MODN:-?} uts=[$(A 'uname -s')]"
        OKGATE=1; break
    fi
    [ $((i % 10)) = 0 ] && echo "    还在等判据⑥：mod=${MODN:-?} up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1)"
done
if [ "$OKGATE" != 1 ]; then
    echo "[x] 等满 700s stage 都没到判据⑥ ⇒ 停。stage 自己怎么说："
    A "grep -aE '!!|No such file|insmod rc|起点|开关内容' /data/local/tmp/ksu_stage.log 2>/dev/null | tail -8" | cut -c1-160 | sed 's/^/    /'
    exit 5
fi
if [ "${MODN:-0}" = "0" ]; then
    echo "[x] ★模块在 stage 跑到判据⑥ 时**已经不在了**(uptime 连续 ⇒ 不是重启)。这是 #55 那一族的新形状，"
    echo "    先把 insmod 那一秒的快照打出来当唯一凭据，再收窗口："
    A "grep -aE 'insmod rc|名单/王座快照|allowlist:|mgr:|granted\[|开关内容|条目 [0-9]|wrote' /data/local/tmp/ksu_stage.log | tail -14" | cut -c1-170 | sed 's/^/    /'
    A "echo up=\$(cut -d' ' -f1 /proc/uptime) bootreason=\$(getprop ro.boot.bootreason)" | sed 's/^/    /'
    echo "  注意：/data/adb 里的脚印这次**没清**(要 root)，下一发的收尾要补。"
    exit 8
fi
UTS=$(A 'uname -s')
if [ "$UTS" != "Linux" ]; then
    echo "[x] 模块在但 uts 仍是坏的：uname -s=[$UTS] ⇒ ART 起不了任何 app，本发的 app/UI 判据不可能成立 ⇒ 早停"
    A "grep -aE 'LEAK|sysname' /data/local/tmp/punch.log 2>/dev/null | tail -3" | cut -c1-170 | sed 's/^/    punch: /'
    A "grep -aE 'uts:|还是坏的' /data/local/tmp/ksu_stage.log 2>/dev/null | tail -3" | cut -c1-160 | sed 's/^/    stage: /'
    echo "  注意：/data/adb 里的脚印这次**没清**(要 root)，下一发的收尾要补。"
    exit 7
fi
echo "  判据④(参考)=$(A "grep -ac '判据④' /data/local/tmp/ksu_stage.log 2>/dev/null" | tr -dc '0-9')"

echo "=== 3) 两条目名单真的进内核了吗(★先看 stage 在 insmod 那一秒打的快照，再看现在的) ==="
A "grep -aE '开关内容|条目 [0-9]|wrote|allow=|名单/王座快照|allowlist:|mgr:|granted\[' /data/local/tmp/ksu_stage.log | tail -14" | cut -c1-170 | sed 's/^/    stage: /'
adb push kmod/w164_al.sh /data/local/tmp/ >/dev/null 2>&1
A "chmod 755 /data/local/tmp/w164_al.sh; echo $SUWUID > /data/local/tmp/w164_u1.uid; echo $MGRUID > /data/local/tmp/w164_u2.uid; rm -f /data/local/tmp/w164_al.out" >/dev/null
fire "@sushd:/data/local/tmp/w164_al.sh" 10
WAITFOR /data/local/tmp/w164_al.out 20 "===== DONE"
A "cat /data/local/tmp/w164_al.out" | cut -c1-165 | sed 's/^/    /'

echo "=== 4) bind su + 起装 fd 看门狗 ==="
adb push cm57/sustatic /data/local/tmp/sustatic >/dev/null 2>&1
adb push kmod/w135_fix.sh /data/local/tmp/w135_fix.sh >/dev/null 2>&1
A "chmod 755 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh; rm -f /data/local/tmp/w135_fix.out /data/local/tmp/w161_fdlaunch.out" >/dev/null
fire "@sushd:/data/local/tmp/w135_fix.sh" 8
WAITFOR /data/local/tmp/w135_fix.out 40 "===== DONE"
A "grep -aE 'BIND_RC|SU_AT_TGT|HEALTH' /data/local/tmp/w135_fix.out | cut -c1-110" | sed 's/^/    /'
fire "@sushd:/data/local/tmp/w161_fdlaunch.sh" 8
WAITFOR /data/local/tmp/w161_fdlaunch.out 20 "===== DONE"
A "grep -aE '触发口|看门狗' /data/local/tmp/w161_fdlaunch.out | cut -c1-130" | sed 's/^/    /'

echo "=== 5) 起 Manager → 用 root 侧 /proc 判 fd(★不再拿 dmesg 回调行当闸) ==="
#   §6.155 的一手：这一发内核明明装了 fd(root 侧读到 `5 -> anon_inode:[ksu_driver]` 与 `95 -> …`)，
#   而 dmesg.live 里 **KSUFDINST 一行都没有**(连"已排队"都没落盘) ⇒ 观测器整段哑掉时，
#   "日志没那行" 会被读成 "没发生"(记忆例29/例36 那一族)。所以权威判据只有一个：root 去数 /proc。
ACT="$MGR/.ui.MainActivity"
GOT=""
for c in 1 2 3; do
    A "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; am start -n $ACT" >/dev/null 2>&1
    sleep 12
    MP=$(A "pidof $MGR" | cut -d' ' -f1)
    case "$MP" in ''|*[!0-9]*) echo "    第 $c 轮：没拿到 pid"; continue;; esac
    echo "    第 $c 轮 pid=$MP 回调行(仅参考)=[ $(fdcb "$MP") ]"
    A "echo $MP > /data/local/tmp/w161_mgr.pid; rm -f /data/local/tmp/w161_g2.out" >/dev/null
    fire "@sushd:/data/local/tmp/w161_g2.sh" 10
    WAITFOR /data/local/tmp/w161_g2.out 20 "=== DONE ==="
    N=$(A "grep -a 'fd 表里带 ksu 的条数' /data/local/tmp/w161_g2.out | head -1" | tr -dc '0-9')
    echo "      root 侧数出来的 fd 条数=[${N:-?}]  $(A "grep -a 'ksu_driver' /data/local/tmp/w161_g2.out | head -2" | cut -c1-90 | tr '\n' '|')"
    [ "${N:-0}" != "0" ] && { GOT=$MP; break; }
    sleep 20   # 排队→回调最长见过 47s
done
[ -n "$GOT" ] || echo "  [!] root 侧三次都没数到 ksu fd ⇒ fd 这一格没成立(下面按'没装 fd'解读)"

echo "=== 6) 开超级用户页 → 让 libsu 起 root shell → 看它的**域**和 fd ==="
A "input tap 801 789" >/dev/null; sleep 16
shot list_page
A "rm -f /data/local/tmp/w163_fds.out" >/dev/null
fire "@sushd:/data/local/tmp/w163_fds.sh" 12
WAITFOR /data/local/tmp/w163_fds.out 20 "===== DONE"
A "cat /data/local/tmp/w163_fds.out" | cut -c1-170 | sed 's/^/    /'
echo "  ★判据：A) 段里 root shell 的 ctx 现在是 u:r:shell:s0 还是 u:r:untrusted_app；"
echo "         再看有没有 root 的 app_process(=libsu RootService 起来了)。"
echo "=== 7) 停在窗口内 ==="
echo "  Manager pid=${GOT:-?} mod=$(A 'grep -c kernelsu /proc/modules') enf=$(A getenforce) up=$(A 'cut -d" " -f1 /proc/uptime' | cut -d. -f1)"
echo "  界面最后两下照实时截图点：搜索框(540,474) → 切英文 → 输 Termux → 点 ZeroTermux 行(540,990) → 翻开关(912,825)"
echo "  判据复读：fire '@sushd:/data/local/tmp/w161_g2.sh' 之后看 UID_GRANTED_ROOT uid=$TGTUID"
echo "  收尾：I_KNOW=1 bash kmod/w161_teardown.sh"
