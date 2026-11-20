#!/system/bin/sh
# w191_race.sh —— 抢在官方 Manager 的"启动只查一次驱动"之前把 fd 塞进去：
#   ① 起 0.4s 看门狗(w161_fdwatch.sh，看到新 pid 就立刻写触发口)
#   ② 杀官方 → 立刻重新起(shell 域 am start) ⇒ 新 pid 出现的一刻被看门狗抓住
#   ③ 等 20s 让它跑完自己的启动查询，然后把 UI 树里 text="..." 全数出来(root 侧读，不靠 PC 往返)
L=/data/local/tmp/w191_race.out
exec >>"$L" 2>&1
OFL=me.weishu.kernelsu
echo "=== race up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1) id=$(id) ==="
rm -f /data/local/tmp/w161_fdwatch.log
setsid nohup /data/local/tmp/w161_fdwatch.sh >/dev/null 2>&1 </dev/null &
sleep 1
echo "看门狗 pid=$(cat /data/local/tmp/w161_fdwatch.pid 2>/dev/null) 在否=$(ls -d /proc/$(cat /data/local/tmp/w161_fdwatch.pid 2>/dev/null) 2>/dev/null && echo Y || echo N)"
runcon u:r:shell:s0 am force-stop $OFL 2>/dev/null; am force-stop $OFL 2>/dev/null
sleep 2
echo "杀掉之后 pidof=[$(pidof $OFL 2>/dev/null)]"
runcon u:r:shell:s0 am start -n $OFL/.ui.MainActivity >/dev/null 2>&1
for q in 1 2 3 4 5 6 7 8; do
    sleep 2
    NP=$(pidof $OFL 2>/dev/null | cut -d' ' -f1)
    [ -n "$NP" ] && { echo "新 pid=$NP (等了 $((q*2))s)"; break; }
done
sleep 18
echo "看门狗这几行:"; tail -4 /data/local/tmp/w161_fdwatch.log 2>/dev/null | sed 's/^/  /'
echo "fd 表里含 ksu_driver 的行:"; ls -l /proc/$NP/fd 2>/dev/null | grep -a ksu_driver | sed 's/^/  原文: /'
echo "王座读口 cat /proc/ksu_crown = [$(cat /proc/ksu_crown 2>/dev/null | tr -d ' \r\n')]"
U=/data/local/tmp/w191_ui3.xml
rm -f "$U"; uiautomator dump "$U" >/dev/null 2>&1
NODES=$(cat "$U" 2>/dev/null | tr '<' '\n' | grep -ac "package=\"$OFL\"")
echo "UI 里官方自己的节点数=$NODES"
# ★§6.194：这个 APK 注册了两条深链(authority `action` 与 `webui`)；无驱动时它只渲染"不支持"页
#   ⇒ 工作态下试这四条，看能不能不靠导航直达超级用户页(能到，最后一格就能自动化)
for D in ksu://action/ ksu://action/su ksu://action/superuser ksu://webui/; do
    runcon u:r:shell:s0 am start -a android.intent.action.VIEW -d "$D" >/dev/null 2>&1
    sleep 5
    rm -f "$U"; uiautomator dump "$U" >/dev/null 2>&1
    NN=$(cat "$U" 2>/dev/null | tr '<' '\n' | grep -ac "package=\"$OFL\"")
    TX=$(cat "$U" 2>/dev/null | tr '>' '\n' | grep -aoE 'text="[^"]+"' | grep -av 'text=""' | tr '\n' '|' | cut -c1-150)
    echo "深链[$D] 之后：官方节点数=$NN 文本=$TX"
done
cat $U 2>/dev/null | tr '>' '\n' | grep -aoE 'text="[^"]+"' | grep -av 'text=""' | sed 's/^/    /' | head -24
echo "getenforce=$(getenforce) mod=$(grep -c kernelsu /proc/modules) up=$(cut -d ' ' -f1 /proc/uptime | cut -d. -f1)"
echo "===== DONE ====="
