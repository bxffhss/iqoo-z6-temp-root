#!/system/bin/sh
# w104：把新 shim 换成 /dev/ksud(tmpfs，sucompat 真正 exec 的那份)——root 侧代跑，
# 因为 adb shell(uid 2000)对 /dev 没有写位(实测 cp: Permission denied)。
{
    cp /data/local/tmp/ksud.new /data/local/tmp/ksud
    cp /data/local/tmp/ksud.new /dev/ksud
    chmod 755 /data/local/tmp/ksud /dev/ksud
    md5sum /data/local/tmp/ksud /dev/ksud
    ls -l /dev/ksud
} > /data/local/tmp/w104_cp.out 2>&1
chmod 666 /data/local/tmp/w104_cp.out
