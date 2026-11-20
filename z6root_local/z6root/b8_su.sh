#!/system/bin/sh
# b8_su.sh —— 由 suw 的 root 腿派单：以**每个 app 自己的 uid** 真跑一次 su，看 id 出不出 uid=0。
#   为什么要这么绕：`asuid` 的语义是"先靠 GRANT_ROOT 拿到 root，再 setuid(目标 uid)，再 exec"，
#   从 adb shell(2000) 起它时 GRANT_ROOT 发的是 2000 ⇒ 必然 EPERM（那是调用者无权，不是名单读数）。
OUT=/data/local/tmp/b8_su.out
# ★uid 列表同样从开关现取（不写死），这样加了 Termux 之类也会自动纳入实测。
UIDS=""
[ -f /data/local/tmp/ksa_uids.txt ] && UIDS=$(cut -d' ' -f1 /data/local/tmp/ksa_uids.txt)
if [ -f /data/local/tmp/ksu_two_profiles ]; then
    for t in $(cat /data/local/tmp/ksu_two_profiles); do
        u=${t%%:*}
        case "$u" in ''|*[!0-9]*) continue ;; esac
        UIDS="$UIDS $u"
    done
fi
{
  echo "===== 以 app uid 实跑 su $(date +%H:%M:%S) ====="
  echo "uid 列表(取自开关)=[$(echo $UIDS | tr ' ' ',')]"
  for u in $UIDS; do
    echo "--- uid=$u ---"
    /data/local/tmp/asuid "$u" /product/bin/su -c id 2>&1 | tail -3
  done
  echo "===== DONE"
} > "$OUT" 2>&1
