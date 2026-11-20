#!/system/bin/sh
# w270_prep.sh —— 第 104 发(#114 + #71 收口)的 root 短腿。
#   要答的那一格(§6.225⑥ 留下的)：共享落点如果贴成**带类别**的 `apk_data_file:s0:c100,c200`，
#     而主体是 `untrusted_app_25:s0:c512,c768` ⇒ MLS 会不会挡下 exec？
#       挡(执法下 rc=126) ⇒ "共享文件必须留 plain s0"要写进交付说明；
#       不挡(出 root)     ⇒ MLS 不参与 execute 判定 ⇒ 通用性更强(类别无关)。
#   ★本发**不写 app 侧探针**：判据用**手敲**(先 `echo knownanswerN` 自证输入到位，例62)，
#     这样这条腿可以顺手把 #71 那三枚 `app_data_file` 残留**删净并复证** —— 以前每发都要重写探针，
#     残留永远只是"被覆盖"而不是"被删除"。
O=/data/local/tmp/w270_prep.out
exec >>"$O" 2>&1
T=/data/local/tmp/kd
D=/data/data/com.termux/files/usr/bin
H=/data/data/com.termux/files/home
echo "=== W270 起点 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) 域=$(cat /proc/self/attr/current 2>&1) enf_file=$(cat /sys/fs/selinux/enforce 2>&1) mod=$(grep -c kernelsu /proc/modules) ==="
echo "STAGE0 done"
for p in $(pidof ksuctl); do echo "  门: pid=$p 域=$(cat /proc/$p/attr/current 2>&1)"; done
echo "STAGE1 done"

# --- 目标：必须是 v3(字节数+md5)，标签必须是 stage 贴的那个带类别的 ---
echo "  目标: $(ls -lZd $T 2>&1 | tr -s ' ' | cut -d' ' -f1,5,6) md5=$(md5sum $T 2>&1 | cut -c1-32)"
echo "  已知答案: 字节=2241944 md5=f7a441d2a7aa0445bc9c7139df4838a3 标签应含 c100,c200"
SZ=$(ls -l "$T" 2>&1 | tr -s ' ' | cut -d' ' -f5)
[ "$SZ" = 2241944 ] || { cp /data/local/tmp/sustatic "$T"; chmod 755 "$T"; echo "  ★补拷 v3: 现在=$(ls -l $T | tr -s ' ' | cut -d' ' -f5)"; }
echo "STAGE2 done"

# --- #71 收口：把前两发落在 app 私有目录里的东西删净并复证(必须赶在翻执法之前) ---
for f in "$D/w260.sh" "$H/w260.txt" "$D/w240.sh" "$H/w240.txt" "$D/w230.sh" "$H/w230.txt" "$D/kd2"; do
    if [ -e "$f" ]; then rm "$f"; echo "  rm $f rc=$?"; else echo "  不在: $f"; fi
done
echo "  复证 usr/bin 里还剩什么我们的东西(应只见 10-04 那份 su)：$(ls -lt $D 2>&1 | head -4 | tr -s ' ' | cut -d' ' -f5,6,7,8,9 | tr '\n' '|')"
echo "  复证 home 里的 txt: $(ls -l $H/w230.txt $H/w240.txt $H/w260.txt 2>&1 | tr -s ' ' | cut -d' ' -f5,9 | tr '\n' '|')"
echo "STAGE3 done"

# --- 名单(内核口径) ---
echo "  名单原样: $(/data/local/tmp/ksuctl88 allowlist 2>&1 | tr -d '\000' | tail -3 | cut -c1-170)"
echo "  名单里 10667: [$(/data/local/tmp/ksuctl88 allowlist 2>&1 | tr -d '\000' | grep -ac 10667)]"
echo "STAGE4 done"
echo "=== DONE ==="
chmod 666 "$O" 2>/dev/null
