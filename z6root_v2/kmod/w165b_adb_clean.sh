#!/system/bin/sh
# w165b_adb_clean.sh —— 把 /data/adb 里**我们这个项目留下的**东西清干净(只认这三样，别的不动)。
#   §6.160 一手：`w165_adb_clean.sh` 只删了 .allowlist 与 ksud，跑完 `ls -a /data/adb` 还剩
#   `.suwtest  ksu  su` —— `su/` 是运行时 su 兼容层的控制面(su.policy/su.ctrl，cm57/round9_cleanup.sh 里
#   专门有一条 `rm -rf /data/adb/su` 就是冲它)，`ksu` 是刚被掏空的目录，`.suwtest` 是 suw 的测试标记。
# ★只列＋只删这四样(su / .suwtest / ksud / ksu 整目录)；`/data/adb` 是 0700，shell 连 stat 都吃 EACCES ⇒ 必须 root 侧跑。
L=/data/local/tmp/w165b_adb_clean.out
{
    echo "=== CLEAN2 up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) ==="
    echo "  清之前 /data/adb = [$(ls -a /data/adb 2>&1 | tr '\n' ' ')]"
    echo "  su/ 里有什么: $(ls -l /data/adb/su 2>&1 | tr '\n' ' ' | cut -c1-160)"
    rm -rf /data/adb/su 2>&1 | sed 's/^/  rm su: /'
    rm -f /data/adb/.suwtest 2>&1 | sed 's/^/  rm .suwtest: /'
    rm -f /data/adb/ksud 2>&1 | sed 's/^/  rm ksud: /'
    # ★10-23 第 41/42/44 发**三发同一读数**：`清之前 /data/adb=[. .. ksu ksud]` ⇒ `清之后` 一字不差，一手报错
    #   `rmdir ksu: Directory not empty`(#206)——`ksu/` 里除了 `.allowlist` 还有 Manager 自己写的东西(#71)，
    #   所以"删掉那一个文件再 rmdir"这条走不通，只能整目录删。改 `rm -rf` 之后 #167 才有闭得掉的可能。
    rm -rf /data/adb/ksu 2>&1 | sed 's/^/  rm ksu: /'
    echo "  清之后 /data/adb = [$(ls -a /data/adb 2>&1 | tr '\n' ' ')]"
    echo "  还在的每一项都列出来(空=干净): $(ls -laR /data/adb 2>&1 | tr '\n' ' ' | cut -c1-220)"
    echo "===== DONE"
} > "$L" 2>&1
chmod 666 "$L"
