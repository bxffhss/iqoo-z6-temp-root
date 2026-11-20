# === 3.9) ★LEG1ONLY=1 ⇒ 派完 LEG1 就跳过第 4~7 步（默认不给＝交付形状一字不变） ===
#   为什么要有它：#219 那一格的腿**自己会把执法翻回 1**（要测的就是执法下的支配），而 §关窗铁律
#   要求"恢复执法排在所有 root 腿之后"。第 4~6 步都是 root 腿(清 /data/adb／bind su／读名单)，
#   翻完之后它们必然红(§6.441：exec bind 里的 su ⇒ EACCES)，那不是被测坏了，是**仪器排在被测后面**。
#   ⇒ 与其留一串会误导的红灯，不如显式跳过并把这几格记**未测**。
if [ "${LEG1ONLY:-0}" = 1 ]; then
    echo "=== 3.9) LEG1ONLY=1 ⇒ 跳过第 4~7 步(清 /data/adb／bind su／G2 名单／可用判定) ==="
    echo "  ★这几格本轮＝**未测**，不许把缺席读成通过；直接走第 8 步自愈还原。"
    SKIP4=1
fi
if [ "${SKIP4:-0}" != 1 ]; then
echo STEP4_RAN
echo STEP5_RAN
echo STEP6_RAN
echo STEP7_RAN
fi   # ← if [ "${SKIP4:-0}" != 1 ] 的收尾(LEG1ONLY=1 时上面第 4~7 步整段跳过；本轮那几格＝未测)
echo STEP8_RAN
