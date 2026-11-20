#!/system/bin/sh
# w619_kd_why.sh —— 不吞错地问一句：**root 现在删得动 /data/local/tmp/kd 吗，删不动的话是谁挡的**。
#   (T3 那条循环把 stderr 丢了 ⇒ 只告诉我"还剩 kd"，没告诉我为什么。这条把 rc 与原文都留下。)
L=/data/local/tmp/w619_kd_why.out
{
    echo "=== KDW up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) ==="
    echo "  删之前: $(ls -lZ /data/local/tmp/kd 2>&1 | tail -1)"
    rm -fv /data/local/tmp/kd; echo "  rm_rc=$?"
    echo "  删之后: $(ls -lZ /data/local/tmp/kd 2>&1 | tail -1)"
    echo "  目录里同类(kd/ksud/sustatic): $(ls -l /data/local/tmp/ 2>/dev/null | grep -aE ' kd$| ksud$| sustatic$' | tr '\n' ' ' | cut -c1-160)"
    echo "  目录本身: $(ls -ld /data/local/tmp 2>&1 | tail -1)"
    echo "  ★顺带把 T3 里我认为该在的件点一遍(在=腿没删干净):"
    for f in kernelsu.ko ksu_args.txt ksud dmesg2.log dmesg.live ksu_stage.log w184_sample.out ksu_race_fd; do
        echo "    $f -> $(ls -d /data/local/tmp/$f 2>&1 | tail -1 | cut -c1-90)"
    done
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
