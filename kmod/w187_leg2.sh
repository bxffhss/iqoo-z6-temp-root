#!/system/bin/sh
# w187_leg2.sh —— 第一条腿里我自己写坏的三格，趁窗口活着重测(全程 root 侧，一次跑完)：
#   ① 装 fd 只等了 2s ⇒ 太急(§6.14x 量过 `已排队`→`回调跑在` 可以隔 0.09s~47s) ⇒ 这次轮询 90s，
#      **主判据=root 侧读它的 fd 表增量**(§6.154③：拿 shell 身份数别人的 fd 恒 0，那是个永远说"没发生"的判据)。
#   ② 官方页读数：锁屏时 uiautomator 拍的是锁屏 ⇒ 这次改**不靠屏幕**的旁证：Manager 自己的 logcat。
#   ③ 王座换给别人之后要能指回来 ⇒ 结尾照旧指回 10319。
# ★★本脚本已被 §6.189 的两条短腿取代(`kmod/w186_fdwrite.sh` + `kmod/w186_fdread.sh`)，别再整条跑：
#   它这一发就在"写完触发口之后的第一个循环"里消失(死因未定位，§6.188⑤)，而拆短腿正是为了二分这件事。
L=/data/local/tmp/w187_leg2.out
exec >>"$L" 2>&1
APK=/data/local/tmp/w183_official.apk
OFL=me.weishu.kernelsu
SUWUID=10319
echo "=== w187_leg2 up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) ==="
echo "[0] apk 在否: $(ls -l $APK 2>&1 | tail -1)"
echo "[1] root 侧装官方:"
runcon u:r:shell:s0 pm install -r -t "$APK" 2>&1
echo "    rc=$?"
OFLUID=$(runcon u:r:shell:s0 pm list packages -U 2>/dev/null | grep -a "package:$OFL " | sed 's/.*uid://')
echo "    官方 uid=[$OFLUID]"
case "$OFLUID" in ''|*[!0-9]*) echo "[x] uid 取不到 ⇒ 什么都不设，直接退"; echo "===== DONE ====="; exit 0;; esac
echo "[2] 王座指给官方 (现在=$(cat /proc/ksu_crown </dev/null 2>/dev/null)):"
echo $((OFLUID % 100000)) > /proc/ksu_crown 2>&1; echo "    rc=$?"
cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'CROWN [^|]*' | tail -2 | sed 's/^/      /'
echo "[3] 起官方 UI(shell 域) + 找 pid(扫 cmdline，不信 pidof):"
runcon u:r:shell:s0 am start -n $OFL/.ui.MainActivity >/dev/null 2>&1
MP=""
for q in $(seq 1 20); do
    sleep 3
    for d in /proc/[0-9]*; do
        grep -qaF "$OFL" "$d/cmdline" 2>/dev/null && { MP=${d#/proc/}; break; }
    done
    [ -n "$MP" ] && { echo "    pid=$MP (等了 $((q*3))s)"; break; }
done
if [ -z "$MP" ]; then
    echo "    [!] 60s 没起官方进程(锁屏/系统不给起?) ⇒ 下面三格都不算，只把这条记成读数"
    echo "===== DONE ====="; exit 0
fi
echo "[4] 装 fd 之前: fd 数=$(ls -1 /proc/$MP/fd 2>/dev/null | wc -l)  含 ksu=$(ls -l /proc/$MP/fd 2>&1 | grep -aci ksu)"
echo $MP > /proc/ksu_install_fd 2>&1; echo "    echo rc=$?"
FD_OK=0
for q in $(seq 1 18); do
    sleep 5
    N=$(ls -1 /proc/$MP/fd 2>/dev/null | wc -l)
    K=$(ls -l /proc/$MP/fd 2>&1 | grep -aci ksu)
    CB=$(grep -a "KSUFDINST 回调跑在 pid=$MP" /data/local/tmp/dmesg.live 2>/dev/null | tail -1)
    echo "    t+$((q*5))s fd数=$N 含ksu=$K 回调行=[${CB}]"
    [ "$K" != "0" ] && { FD_OK=1; break; }
    [ -n "$CB" ] && { FD_OK=1; break; }
done
echo "    ⇒ fd 那一格: $([ "$FD_OK" = 1 ] && echo '装上了(状态本身为证)' || echo '90s 内没装上(不下结论说机制坏，只说这发没成)')"
echo "[5] 不靠屏幕的旁证：Manager 自己的 logcat(它读到驱动会打版本/失败原因):"
logcat -d -v brief 2>/dev/null | grep -aiE 'kernelsu|libsu|RootService|KernelSU-App' | tail -25 | cut -c1-160 | sed 's/^/      /'
echo "[6] 指回 suw:"
echo $SUWUID > /proc/ksu_crown 2>&1; echo "    rc=$?"
cat /proc/ksu_slots 2>&1 | tr '\n' '|' | grep -ao 'CROWN [^|]*' | tail -3 | sed 's/^/      /'
echo "getenforce=$(getenforce) mod=$(grep -c kernelsu /proc/modules) up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1)"
echo "===== DONE ====="
