#!/system/bin/sh
# w154_mod.sh —— #56：在**晚加载 + 不重启**的窗口里，验证"脚本型模块"能不能靠
#   ①模块自己的脚本做 bind + ②踢一次框架 来激活（Z5 一手形状，见 §6.136③）。
#
# 为什么这条值得单独立一发：§6.129 我判死的是"内核开机按 modules.rc 做 magic mount"这一条，
# 而 zygisk/LSPosed 型模块的效果**主要来自它自己的脚本**，那部分根本不需要开机钩子。
#
# ★三条已付过学费的钉子，全写在这里：
#   ①只 bind `/product/bin`：盖 `/system/bin` 会把服务列表清空、起不了新 app(§6.124)；
#   ②源目录必须 `cp -a` 原有内容(3 项)：`/vendor/bin` 是指向 `/system/bin` 的符号链接，
#     且 `/system/bin/sh` 需要目录里的 linker64 —— 少一项就会把设备打成需要长按电源的样；
#   ③收尾必须 root 侧"先 umount 成功、再删源"(PC 侧 umount 必 EPERM)。
# ★踢框架是不可逆性最低但**可见**的动作：system_server 会被 vivo 自动拉起(他们也是这么干的)，
#   所以判据要包含"框架回来没有"，不能只看挂载。
L=/data/local/tmp/w154_mod.out
MD=/data/adb/modules/suwegrid
TGT=/product/bin
NB=/data/local/tmp/pbin
{
    echo "===== MOD up=$(cut -d' ' -f1 /proc/uptime) uid=$(id -u) enf=$(getenforce) mod=$(grep -c kernelsu /proc/modules) ====="
    echo "--- [0] 装模块(手工铺 /data/adb/modules/<id>/，等价于 KSU 的 install) ---"
    mkdir -p "$MD" 2>&1
    for f in module.prop post-fs-data.sh service.sh; do
        if [ -f "/data/local/tmp/mod_$f" ]; then cp -f "/data/local/tmp/mod_$f" "$MD/$f"; fi
    done
    chmod 755 "$MD" "$MD"/*.sh 2>/dev/null
    echo "装好=$? 清单=[$(ls -A "$MD" 2>&1 | tr '\n' ' ')]"
    [ -f "$MD/post-fs-data.sh" ] || { echo "ABORT=模块脚本没铺上"; exit 1; }

    echo "--- [1] 模块自己跑 post-fs-data(他们用的就是 runcon u:r:shell:s0 这一手) ---"
    runcon u:r:shell:s0 sh "$MD/post-fs-data.sh" >/dev/null 2>&1
    echo "跑完 rc=$?"
    echo "源目录 su=[$(ls -l $NB/su 2>&1 | cut -c1-52)]"
    echo "挂载点 su=[$(ls -l $TGT/su 2>&1 | cut -c1-52)]"
    echo "MOUNT_LINES=$(grep -ac pbin /proc/self/mountinfo)"
    echo "服务数=$(runcon u:r:shell:s0 service list 2>/dev/null | head -1)"

    echo "--- [2] 踢框架(system_server 会被自动拉起)：判「挂着的 bind 能不能活过软重启」 ---"
    # ★开关用**文件**不用环境变量：`@sushd:` 只能传脚本路径，传不了参数也带不上 env
    #   (这是本项目早就付过学费的一条，见 CONTINUE_HERE 的"mode 文件")。
    if [ -f /data/local/tmp/w154_kick ]; then
        echo "  看到 w154_kick 标记 ⇒ kill -9 system_server zygote64 zygote"
        kill -9 $(pidof system_server) $(pidof zygote64) $(pidof zygote) 2>/dev/null
        echo "  踢完 rc=$? 之后 60~90s 框架会自己回来(vivo 会自愈，这也是他们的做法)"
        sleep 75
        echo "  踢完之后：挂载行=$(grep -ac pbin /proc/self/mountinfo) su=[$(ls $TGT/su 2>&1 | head -1)]"
        echo "  踢完之后：服务数=$(runcon u:r:shell:s0 service list 2>/dev/null | head -1)"
        echo "  踢完之后：第三方包数=$(pm list packages -3 2>/dev/null | wc -l)"
    else
        echo "  没有 w154_kick 标记 ⇒ 不踢框架(只做'模块脚本自己 bind'那一半)"
    fi

    echo "--- [3] 收尾复核(只读) ---"
    echo "挂载行=$(grep -ac pbin /proc/self/mountinfo) su=[$(ls $TGT/su 2>&1 | head -1)]"
    echo "服务数=$(runcon u:r:shell:s0 service list 2>/dev/null | head -1)"
    echo "第三方包数=$(pm list packages -3 2>/dev/null | wc -l)"
    echo "--- [4] 自己收尾(root 侧：先 umount 成功再删源；模块目录也在这里清掉) ---"
    # ★为什么让脚本自己收：踢完框架之后 `@sushd:` 这条信道可能已经断了(sushd 挂在 app 下面)，
    #   那时 PC 侧再派发清理就派不出去。所以清理工夫必须写在**这一份脚本里、踢之后立刻做**。
    i=1
    while [ $i -le 5 ]; do
        grep -aq pbin /proc/self/mountinfo || break
        umount /product/bin >/dev/null 2>&1; echo "  umount#$i rc=$?"
        i=$((i + 1))
    done
    rm -rf /data/adb/modules/suwegrid /data/local/tmp/pbin /data/local/tmp/w154_kick
    echo "  清完：挂载行=$(grep -ac pbin /proc/self/mountinfo) 模块目录=[$(ls -A /data/adb/modules 2>&1 | tr '\n' ' ')] su=[$(ls $TGT/su 2>&1 | head -1)]"
    echo "===== DONE up=$(cut -d' ' -f1 /proc/uptime) ====="
} >"$L" 2>&1
chmod 666 "$L"
