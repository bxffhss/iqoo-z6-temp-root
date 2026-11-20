#!/system/bin/sh
# shot13_verdict.sh —— 第 13 发（rc80 + 0x1a）社区 su 路线判据，由 @sushd(root) 派单。
# ★与旧 w1200 的差别：干净 boot 下 setprof 运行期授权已被复位清空，默认名单只有
#   com.suw.manager=10342 ⇒ 正对照只用 10342；10667 与 2000 都是负对照。
#   （w1200 把 10667 标 POS 是 §6.582「已 setprof 授权 + 0x1a 改道」窗口的形状，不适用本发。）
OUT=/data/local/tmp/shot13_verdict.out
exec >"$OUT" 2>&1
echo "===== shot13 社区 su 判据 $(date) ====="
echo "up=$(cut -d' ' -f1 /proc/uptime)  id=$(id)"
echo "mod=[$(grep -i kernelsu /proc/modules | tr -s ' ')]"
echo "enf=$(getenforce)"
echo "--- 前提① /system/bin/su 必须真的不存在(否则下面都是静态文件给的) ---"
ls -l /system/bin/su 2>&1
echo "  exists=$([ -e /system/bin/su ] && echo YES || echo NO)"
echo "--- 前提② overlay 必须是 0(静态 su 那条已废弃) ---"
mount | grep -c ' /system/bin ' | sed 's/^/  overlay_on_system_bin=/'
echo "--- 前提③ /dev/ksud 0666 在 ---"
ls -l /dev/ksud 2>&1

for U in 10342 10667 2000; do
    if [ "$U" = 10342 ]; then TAG="POS(名单内 suw, granted=1)"; else TAG="NEG(名单外)"; fi
    echo "===== uid=$U  $TAG ====="
    asuid "$U" /system/bin/sh -c '
        echo "  id=[$(id)]"
        if [ -x /system/bin/su ]; then echo "  access([-x /system/bin/su])=OK"; else echo "  access([-x /system/bin/su])=FAIL"; fi
        if [ -f /system/bin/su ]; then echo "  stat([-f])=OK"; else echo "  stat([-f])=FAIL"; fi
        echo "  ls -l /system/bin/su -> [$(ls -l /system/bin/su 2>&1)]"
        echo "  which su -> [$(which su 2>&1)]"
        echo "  su -c id -> [$(su -c id 2>&1)]"
    ' 2>&1
    echo
done

echo "--- ioctl 通道回归(0x1a 不该破坏 /dev/ksud + GRANT_ROOT) ---"
/data/local/tmp/asuid_grant 10342 2>&1
echo "  ---"
/data/local/tmp/asuid_grant 10667 2>&1

echo "===== 判据(人工照抄, 脚本不自判) ====="
echo "  前提: /system/bin/su 不存在 + overlay=0 + /dev/ksud 0666"
echo "  POS 10342: access=OK stat=OK ls 打出 ksud which=/system/bin/su su -c id 出 uid=0"
echo "  NEG 10667/2000: access/stat/which/su 全假(且 /system/bin/su 仍不存在)"
echo "  ioctl: 10342 GRANT_ROOT rc=0/uid=0 ; 10667 rc=-1 EPERM"
echo "===== DONE ====="
chmod 666 "$OUT" 2>/dev/null
