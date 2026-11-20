#!/system/bin/sh
# w260_prep.sh —— 第 103 发(#111)的 root 短腿：shim **v3** 上机验收 + 顺手清 #71 那三枚残留。
#   单变量=shim 版本(v2→v3)：落点/标签/ko/args 全部沿用第 102 发赢的那套
#     (`/data/local/tmp/kd` + `u:object_r:apk_data_file:s0`)。
#   v3 改了两件事(§6.223④ + §6.225⑤)：exec 前 `unsetenv(LD_PRELOAD)`、`setenv(PATH,"/system/bin:/system/xbin")`
#     ⇒ 交付形态不再要求用户手打 `LD_PRELOAD=` 前缀，且壳不会带着读不到的 app 私有 PATH。
#   ★认版本只认字节数+md5：v3=2,241,944 / f7a441d2…(v2=2,245,720 / 9aca0a3e…；静态 bionic 自己带
#     "LD_PRELOAD"和"/system/bin:/system/xbin"这两个串，别拿串当判据——例51 的新形态)。
O=/data/local/tmp/w260_prep.out
exec >>"$O" 2>&1
T=/data/local/tmp/kd
D=/data/data/com.termux/files/usr/bin
H=/data/data/com.termux/files/home
V3=/data/local/tmp/sustatic
echo "=== W260 起点 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf_file=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c kernelsu /proc/modules) ==="
echo "STAGE0 done"
for p in $(pidof ksuctl); do echo "  门: pid=$p 域=$(cat /proc/$p/attr/current 2>&1)"; done
echo "STAGE1 done"

# --- 目标必须是 v3(已知答案)，否则这一发测的还是 v2 ---
echo "  目标现值: $(ls -l $T 2>&1 | tr -s ' ' | cut -d' ' -f1,3,4,5,9) md5=$(md5sum $T 2>&1 | cut -c1-32)"
echo "  v3 源:    $(ls -l $V3 2>&1 | tr -s ' ' | cut -d' ' -f5) md5=$(md5sum $V3 2>&1 | cut -c1-32)"
echo "  已知答案: v3=2241944 / f7a441d2a7aa0445bc9c7139df4838a3   (v2=2245720 / 9aca0a3e…)"
SZ=$(ls -l "$T" 2>&1 | tr -s ' ' | cut -d' ' -f5)
if [ "$SZ" != 2241944 ]; then
    cp "$V3" "$T"; echo "  换 v3: cp rc=$?"
    chown 0:0 "$T" 2>/dev/null; chmod 755 "$T"
    SZ=$(ls -l "$T" 2>&1 | tr -s ' ' | cut -d' ' -f5)
fi
echo "  换后: 字节=$SZ md5=$(md5sum $T 2>&1 | cut -c1-32)  $( [ "$SZ" = 2241944 ] && echo 对 || echo '★不是 v3，别往下测')"
echo "  标签: $(ls -lZd $T 2>&1 | tr -s ' ' | cut -d' ' -f1,5)"
echo "STAGE2 done"

# --- #71：翻执法之前把上两发的残留删掉，并由本腿自己列目录复证(例61) ---
for f in "$D/w240.sh" "$H/w240.txt" "$D/kd2" "$D/w230.sh"; do
    [ -e "$f" ] && { rm "$f"; echo "  rm $f rc=$?"; } || echo "  $f 本就不在"
done
echo "  复证 usr/bin 前 4: $(ls -lt $D 2>&1 | head -4 | tr -s ' ' | cut -d' ' -f5,6,7,8,9 | tr '\n' '|')"
echo "STAGE3 done"

# --- app 侧探针(v3 口径：一律**不带** LD_PRELOAD= 前缀) ---
cat >"$D/w260.sh" <<'PEOF'
{
    echo "== uid=$(id -u) 域=[$(cat /proc/self/attr/current 2>&1)] 本壳 LD_PRELOAD=[$LD_PRELOAD]"
    echo "[T1] su -c id  ← 交付判据：**不带任何前缀**"
    /system/bin/su -c /system/bin/id 2>&1
    echo "     T1_rc=$?"
    echo "[T2] echo id | su  ← 不带 -c、命令走 stdin(PATH 那一格)"
    echo id | /system/bin/su 2>&1
    echo "     T2_rc=$?"
    echo "[T3] su -c 'echo PATH=$PATH; echo PRELOAD=[${LD_PRELOAD:-空}]'"
    /system/bin/su -c 'echo P=$PATH; echo PRE=[${LD_PRELOAD:-空}]' 2>&1
    echo "     T3_rc=$?"
    echo "[T4] su -c 'cat /sys/fs/selinux/enforce; getenforce'  ← 自证执法态"
    /system/bin/su -c 'cat /sys/fs/selinux/enforce; getenforce' 2>&1
    echo "     T4_rc=$?"
    echo "[T5] 负对照：PATH 里那份(不改道)  $(command -v su)"
    su -c /system/bin/id 2>&1
    echo "     T5_rc=$?"
} 2>&1 | tee /data/data/com.termux/files/home/w260.txt
PEOF
RC1=$?
chown "$(stat -c '%u:%g' "$D" 2>/dev/null)" "$D/w260.sh" 2>/dev/null
chmod 644 "$D/w260.sh"
echo "  探针写入 rc=$RC1 属主=$(stat -c '%U:%G 0%a' "$D/w260.sh" 2>&1)"
if sh -n "$D/w260.sh" 2>&1; then echo "  内层 mksh sh -n 过"; else echo "  ★内层语法没过(别往下走)"; fi
echo "STAGE4 done"
echo "  名单原样: $(/data/local/tmp/ksuctl88 allowlist 2>&1 | tr -d '\000' | tail -3 | cut -c1-170)"
echo "  名单里 10667: [$(/data/local/tmp/ksuctl88 allowlist 2>&1 | tr -d '\000' | grep -ac 10667)]"
echo "STAGE5 done"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
