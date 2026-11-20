#!/system/bin/sh
# run.sh —— 新版的"一条命令"入口：铺开关 + 拷脚本 + 开窗（等价于旧版那种一行跑完的体验）。
#   为什么需要它：新形状有三件事必须"按顺序"发生，漏一件都不会报错、只会静默降级：
#     ①名单/开关要在**开窗（insmod）之前**铺好（b8_setup.sh）；
#     ②b8_*.sh 要在**stage 跑之前**就躺在 /data/local/tmp（stage 自己会去那儿拉常驻补装）；
#     ③开窗必须带 SU_BIND=1（否则 su 不绑，管理器永远「获取 Root 失败」）。
#   跑法（手机上或 adb shell 都行，目录按 /sdcard/z6root 放）：
#       /system/bin/sh /sdcard/z6root/run.sh
D=$(dirname "$0")
case "$D" in ''|.) D=/sdcard/z6root ;; esac
echo "=== run.sh 目录=$D ==="

echo "--- 1/3 铺开关（uid 现取）---"
/system/bin/sh "$D/b8_setup.sh" || { echo "[x] b8_setup 失败 ⇒ 停（它失败还硬开窗，名单会写错）"; exit 3; }

echo "--- 2/3 把 b8_*.sh 放到 /data/local/tmp ---"
cp "$D"/b8_*.sh /data/local/tmp/ 2>/dev/null
chmod 755 /data/local/tmp/b8_*.sh 2>/dev/null
echo "  已放: $(ls /data/local/tmp/b8_*.sh 2>/dev/null | wc -l) 件"

echo "--- 3/4 开窗（SU_BIND=1）---"
SU_BIND=1 /system/bin/sh "$D/z6root.sh"
RC=$?

echo "--- 4/4 让管理器在「fd 与 su 都在位」之后重起一次 ---"
# 为什么必须有这一步：stage 起管理器时 su 还没绑（bind 在开窗末尾），
# 它那次「获取 Root 失败」会被缓存进进程，之后重造 Activity 也不重查。
# b8_mgr 先开抢装循环再 am start，让 fd 与 su 都赶在它出生之前。
if [ -f /data/local/tmp/b8_mgr.sh ]; then
    am start -n com.suw.manager/.MainActivity --es auto ksuarm --es cmd "@sushd:/data/local/tmp/b8_mgr.sh" >/dev/null 2>&1
    sleep 14
    echo "  管理器 pid=[$(pidof me.weishu.kernelsu 2>/dev/null)]"
    echo "  b8_mgr 回执: $(tail -3 /data/local/tmp/b8_mgr.out 2>/dev/null | tr '\n' '|')"
else
    echo "  [!] /data/local/tmp/b8_mgr.sh 不在 ⇒ 跳过；管理器可能停在「获取 Root 失败」"
fi

echo "=== run.sh 结束 rc=$RC ==="
echo "★自查三样："
echo "  ① stage 日志里的 ★KEEP_AUTO 已起：pid=[…]"
echo "  ② 管理器首页 工作中 [越狱模式] 且没有「获取 Root 失败」"
echo "  ③ /product/bin/su 存在"
exit $RC
