#!/system/bin/sh
# w777_root_tool.sh —— 第 54 发在 **B 形状**下唯一的 root 手（读／破坏／收尾三模，全走目标 app 里 `/system/bin/su -c <本件> <模式>`）。
#   为什么需要它：名单主条目=目标 app ⇒ **suw 未授权 ⇒ PC 侧 `rleg`/`@sushd:` 整条是瞎的**(§6.425 一手：设备上连 .out 都不生成)。
#   ★三条护栏：产物一律 0666(不然 PC 读不到还以为没跑)；每行自带 `up=`(排序只认同源 up)；**恢复执法放在 close 的最后一步**(翻了 MAC 之后什么都做不了)。
L=/data/local/tmp/w777.out
D=/data/local/tmp/w777_dmesg.txt
SW=/data/local/tmp/ksu_pbin_keep
NB=/data/adb/ksu/pbin
TGT=/product/bin
MGR=me.weishu.kernelsu
MODE=${1:-read}

: > "$L" 2>/dev/null
# ★第 54 发一手：权限要**在写第一行之前**就好。原来只在末尾 `chmod 666`——close 模式末尾那步是恢复执法，
#   执法一开就再改不动自己产物的权限了(实得 0600 root，PC 侧只数得出字节数)。
chmod 666 "$L" 2>/dev/null
{
    echo "=== W777 模式=$MODE 起 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(cat /sys/fs/selinux/enforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules) boot_id=$(cat /proc/sys/kernel/random/boot_id) ==="
    P=$(pidof "$MGR" 2>/dev/null | cut -d' ' -f1)

    if [ "$MODE" = read ]; then
        dmesg > "$D" 2>/dev/null
        echo "  dmesg 字节=$(wc -c < "$D" 2>/dev/null) 首=[$(head -1 "$D" | cut -c1-18)] 末=[$(tail -1 "$D" | cut -c1-18)]"
        KL=$(grep -a KSUBIRTH "$D" 2>/dev/null)
        echo "  KSUBIRTH_行数=$(printf '%s\n' "$KL" | grep -ac .) queued=$(printf '%s\n' "$KL" | grep -ac 'queued self fd') seen=$(printf '%s\n' "$KL" | grep -ac 'seen Manager') cap真踢=$(printf '%s\n' "$KL" | grep -ac 'KSUBIRTH cap')"
        echo "  total现值=$(printf '%s\n' "$KL" | grep -a 'queued self fd' | tail -1 | grep -ao 'total=[0-9]*' | tr -dc '0-9') dupskip_n=$(printf '%s\n' "$KL" | grep -a 'dupskip n=' | tail -1 | grep -ao 'n=[0-9]*' | tr -dc '0-9')"
        echo "  SU链 SU0=$(grep -ac 'KSUBEAT SU0' "$D") SU1=$(grep -ac 'KSUBEAT SU1' "$D") SD4=$(grep -ac 'KSUBEAT SD4' "$D") signal6=$(grep -ac 'received signal 6' "$D")"
        echo "  keeper 在否=$(pgrep -f w774_pbin_keeper >/dev/null 2>&1 && echo 在 || echo 不在) 开关=$(ls -l $SW 2>&1 | cut -c1-40)"
        echo "  keeper日志尾=[$(tail -2 /data/local/tmp/w774_keeper.log 2>/dev/null | tr '\n' '|' | cut -c1-160)]"
        echo "  $TGT/su 在否=$([ -e "$TGT/su" ] && echo 在 || echo 不在) mountinfo_pbin=[$(grep -a pbin /proc/self/mountinfo 2>/dev/null | cut -c1-92 | tr '\n' '|')]"
        [ -n "$P" ] && echo "  Manager pid=$P fd_ksu=$(ls -l /proc/$P/fd 2>/dev/null | grep -ac ksu_driver) Seccomp=$(grep -aE '^Seccomp:' /proc/$P/status 2>/dev/null | tr -dc '0-9')"
        echo "  /data/adb=[$(ls /data/adb 2>&1 | tr '\n' ' ')]"
    fi

    if [ "$MODE" = break ]; then
        # 人为把 root-only 源删掉（今晚那种坏态），然后交给维持件去修——观察窗在 PC 侧(shell 就能看 /product/bin/su)
        echo "  破坏前：$TGT/su=$([ -e "$TGT/su" ] && echo 在 || echo 不在) 源内=$(ls -A "$NB" 2>/dev/null | wc -l) mountinfo=[$(grep -a pbin /proc/self/mountinfo | cut -c1-70 | tr '\n' '|')]"
        rm -rf "$NB" 2>/dev/null
        echo "  已 rm -rf $NB rc=$? ⇒ 现在 $TGT/su=$([ -e "$TGT/su" ] && echo 还在 || echo 没了) mountinfo=[$(grep -a pbin /proc/self/mountinfo | cut -c1-70 | tr '\n' '|')]"
        i=0
        while [ "$i" -lt 14 ]; do
            i=$((i + 1)); sleep 3
            if [ -e "$TGT/su" ]; then echo "  修好了：第 $((i * 3)) 秒 $TGT/su 复现"; break; fi
        done
        [ -e "$TGT/su" ] || echo "  ★14×3=42 秒还没修好 ⇒ 维持件没生效(看 keeper日志尾)"
        echo "  末态 mountinfo=[$(grep -a pbin /proc/self/mountinfo | cut -c1-70 | tr '\n' '|')] 源内=$(ls -A "$NB" 2>/dev/null | wc -l) keeper尾=[$(tail -2 /data/local/tmp/w774_keeper.log 2>/dev/null | tr '\n' '|' | cut -c1-150)]"
    fi

    if [ "$MODE" = close ]; then
        rm -f "$SW" 2>/dev/null
        echo "  开关已删 ⇒ 等维持件自退(≤25 秒)"; sleep 25
        echo "  keeper 还在否=$(pgrep -f w774_pbin_keeper >/dev/null 2>&1 && echo 在 || echo 退了)"
        umount "$TGT" 2>/dev/null; echo "  umount rc=$? 挂载读回=[$(grep -a pbin /proc/self/mountinfo 2>/dev/null | cut -c1-60 | tr '\n' '|')]"
        rm -rf "$NB" /data/adb/ksu/pbin 2>/dev/null
        ls -d /data/adb/ksu >/dev/null 2>&1 && rm -rf /data/adb/ksu/.allowlist /data/adb/ksu/bin 2>/dev/null
        rm -rf /data/adb/ksud /data/adb/ksu /data/adb/su 2>/dev/null
        echo "  /data/adb 清之后=[$(ls /data/adb 2>&1 | tr '\n' ' ')]"
        cd /data/local/tmp 2>/dev/null
        rm -f w777_dmesg.txt w774_keeper.log ksu_pbin_keep w731_root.txt w731_root.pid w731_root_sampler.out w720_dmesg.txt w720_lines.txt w720_ksubirth_dump.out w76*.xml w772.xml dmesg.live dmesg2.log dmesg2.log.tmp dmesg_full.txt ksu_stage.log ksu_stage.txt punch.log sushd_last.out w625_seedrestart.out w625_lock 2>/dev/null
        echo "  本轮脚印剩下=[$(ls -1 /data/local/tmp | grep -aE 'w77[0-9]|w73[0-9]|w72[0-9]|dmesg|punch|ksu_stage' | tr '\n' ' ')]"
        echo "  留着的工具腿=[$(ls -1 /data/local/tmp | grep -aE '^w(6|7)[0-9][0-9].*\.sh$' | tr '\n' ' ')]"
        echo 1 > /sys/fs/selinux/enforce 2>/dev/null
        echo "  ★最后一步恢复执法：回读=$(cat /sys/fs/selinux/enforce 2>/dev/null) getenforce=$(getenforce 2>/dev/null) mod=$(grep -c kernelsu /proc/modules)"
        sync
    fi
    echo "=== W777 完 模式=$MODE up=$(cut -d' ' -f1 /proc/uptime) ==="
} >> "$L" 2>&1
chmod 666 "$L" 2>/dev/null
echo "W777 mode=$MODE rc=$? out=$L"
