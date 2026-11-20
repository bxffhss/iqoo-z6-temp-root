#!/system/bin/sh
# w350_ksud_modlist_dev.sh —— 第 117 发的**主探针**（只读，以 root 跑）：
#   ①直接 exec 官方 APK 里那份 libksud.so 跑 `module list`，看**root 态的 ksud 自己**能不能列出样本模块；
#   ②顺手问内核 `granted 10104`（第 115/116 发从没直接查过 Manager 这一格）。
#
# 为什么这一格优先：第 116 发里 `Module{List}` 一次都没重新发出、模块页卡在"正在刷新…"。
#   那时"ksud 列不出"与"Manager 的 UI/IPC 没显示"两种解释**分不开**，而"加名单"只对第二种有意义。
#   这一格把两者切开：root 直跑 ksud 若列得出 ⇒ 问题在 Manager 侧(授权/IPC)，加名单值得试；
#                     若列不出 ⇒ 问题在 ksud/模块格式，**加名单也白搭**，方向要改。
#
# ★找法：glob 在这条路上**不可靠**(第 117 发实测：三层星号空手而归、`find` 一次命中；真实深度是
#   /data/app/~~X==/PKG-Y==/lib/arm64 = 两层星号 + lib/arm64)。⇒ 两路都跑，但**只有 find 空手**才允许说"文件不存在"。
OUT=/data/local/tmp/w350_ksud_modlist.out
exec > "$OUT" 2>&1
UP=$(cut -d' ' -f1 /proc/uptime)
echo "[$(date +%H:%M:%S)] uid=$(id -u) enf=$(getenforce) up=$UP"
[ "$(id -u)" = 0 ] || { echo "!! 不是 root ⇒ 什么都不做"; exit 1; }

echo "--- ① 找 libksud.so（三层 glob + find 双路，两路都要有回执）---"
P1=$(ls /data/app/*/*/*/lib/arm64/libksud.so 2>/dev/null | head -1)
P2=$(find /data/app -name 'libksud.so' 2>/dev/null | head -1)
echo "  glob  =[$P1]"
echo "  find  =[$P2]"
KSUD=$P1
[ -n "$KSUD" ] || KSUD=$P2
[ -n "$KSUD" ] || { echo "!! 两路都没找到 libksud.so ⇒ 这一格作废(别把'没找到'当'列不出')"; exit 1; }
ls -l "$KSUD"; echo "  可执行=$([ -x "$KSUD" ] && echo y || echo n)"

echo "--- ② ★先立负对照：不带样本模块时它应当列不出 suwmarker ---"
echo "  现在 modules 目录=[$(ls /data/adb/modules 2>&1 | tr '\n' ' ')]"
"$KSUD" module list 2>&1 | head -20
echo "  RC=$?"

echo "--- ③ 正对照：放一个已知模块，再列一次（同一发内前后对照）---"
if [ -d /data/adb/modules/suwmarker ]; then echo "  样本模块已在场"; else echo "  !! 样本模块不在场 ⇒ 这一格只能等 w345 放完再跑(结论要标'未对照')"; fi
"$KSUD" module list 2>&1 | head -20
echo "  RC=$?"
echo "  ★判读：上面两次输出**都**没有 suwmarker ⇒ ksud/格式问题；第二次有 ⇒ 授权/UI 问题。"

echo "--- ④ 内核侧问 granted（10104=官方 Manager / 10319=suw / 10304=suprobe 正对照）---"
C=/data/local/tmp/ksuctl88
[ -x "$C" ] || C=/data/local/tmp/ksuctl
for u in 10104 10319 10304; do
    echo "   uid=$u : $(timeout 10 "$C" granted $u 2>&1 | grep -a UID_GRANTED_ROOT | cut -c1-120)"
done
echo "   appid: $(timeout 10 "$C" mgr 2>&1 | grep -a -o -E 'appid=[0-9]+' | head -1)"

echo "--- ⑤ 名单文件本身（有几条、Manager 在不在里面）---"
ls -l /data/adb/ksu/.allowlist 2>&1 | head -2
timeout 10 "$C" allowlist 2>&1 | grep -a -E 'count=|allow\[' | head -6
echo "[===== DONE =====]"
