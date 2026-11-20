#!/system/bin/sh
# preflight_module.sh —— **不花窗口**的模块战线预检(以 shell 身份跑，无需 root)
#
# 目的：把"窗口里才会做"的每一步都先证明**它缺的只是权限，不是能力**。
#   窗口只有 3~5 分钟，任何一步在里头才发现"toybox 没这个工具/目标根本不存在"就是白烧一发。
# 判据分两色：`OK` = 本机具备；`NEG` = 现在就**应当**失败(负对照，证明这一步真要靠 root)。
T=/data/local/tmp
log() { echo "[$1] $2"; }
chk() { command -v "$1" >/dev/null 2>&1 && log OK "有 $1 ($(command -v $1))" || log MISS "没有 $1"; }

echo "===== ① runner 依赖的工具必须都在(缺一个，窗口里就是白跑) ====="
for c in timeout unzip mount umount md5sum tail pgrep sed grep head find cut wc; do chk "$c"; done
log INFO "toybox 版本 = $(toybox 2>&1 | head -1)"

echo "===== ② bind 目标：必须是**已存在的普通文件**(不是符号链接)，否则 bind 语义跑偏 ====="
for d in /system/etc/hosts /system/build.prop /vendor/build.prop /system/etc/event-log-tags; do
    if [ -L "$d" ]; then log SKIP "$d 是符号链接 ⇒ runner 会跳过它"
    elif [ -f "$d" ]; then log OK "$d 存在 md5=$(md5sum $d 2>/dev/null | cut -d' ' -f1) 首行=[$(head -1 $d 2>/dev/null)]"
    else log MISS "$d 不存在"; fi
done
log INFO "/system 的挂载类型(只读 erofs 不妨碍 bind 覆盖，但要确认): $(grep ' /system ' /proc/mounts | head -1)"

echo "===== ③ 脚本语法：把推上去的 runner 与模块脚本先 sh -n ====="
for f in $T/ksu_module_apply.sh $T/ksu_module_teardown.sh $T/preflight_module.sh $T/mod/post-fs-data.sh; do
    [ -f "$f" ] || { log MISS "缺 $f(先 push)"; continue; }
    sh -n "$f" 2>&1 | head -3
    log OK "sh -n 过了: $f"
done

echo "===== ④ 模块包能不能解开(toybox unzip 的语义各家不同，必须实机验) ====="
if [ -f $T/testmod.zip ]; then
    rm -rf $T/mod; mkdir -p $T/mod
    unzip -o -q $T/testmod.zip -d $T/mod 2>&1 | head -3
    log INFO "解出来: $(find $T/mod -type f 2>/dev/null | tr '\n' ' ')"
    [ -f $T/mod/module.prop ] && log OK "module.prop 在" || log MISS "module.prop 不在 ⇒ 打包方式有问题"
    [ -f $T/mod/system/etc/hosts ] && log OK "system/etc/hosts 在" || log MISS "system/etc/hosts 不在"
    log INFO "hosts 模块版首行=[$(head -1 $T/mod/system/etc/hosts 2>/dev/null)]"
else
    log MISS "缺 $T/testmod.zip"
fi

echo "===== ⑤ 底座本身: toybox mount 到底能不能 bind(实测不能 ⇒ 才有 suwbind) ====="
mount -o bind $T/mod/system/etc/hosts /data/local/tmp/tgt/x > $T/m1.out 2>&1
R1=$?
log INFO "toybox mount -o bind rc=$R1 输出=[$(cat $T/m1.out | tr '
' '|')]"
log INFO "⇒ 上面是 'bad /etc/fstab' 就等于确认 toybox 不支持 bind，必须用 suwbind"
if [ ! -x $T/suwbind ]; then log MISS "缺 $T/suwbind"; else
  $T/suwbind $T/mod/system/etc/hosts /data/local/tmp/tgt/x > $T/m2.out 2>&1; R2=$?
  log INFO "suwbind(shell 身份) rc=$R2 输出=[$(cat $T/m2.out | tr '
' '|')]"
  case "$R2" in
    0) log NEG "shell 竟然挂上了 ⇒ 这台机器的 CAP_SYS_ADMIN 闸比预期松，整条边界要重判";;
    1) log NEG "EPERM ⇒ 正确：bind 这条路只差 root，用法没问题(窗口里必成)";;
    3) log MISS "stat 就失败 ⇒ 路径不存在，先修参数";;
    *) log MISS "意料之外的 rc=$R2";;
  esac
  $T/suwbind --umount /data/local/tmp/tgt/x 2>&1 | head -1
fi

echo "===== ⑥ 模块脚本自己会不会写坏别的东西(它只该写 selftest 那一格) ====="
if [ -f $T/mod/post-fs-data.sh ]; then
    # ★以 shell 身份先跑一遍**全文**：脚本里的 id -u 会是 2000，这不是判据；
    #   判据是"它能跑到底、不报语法/找不到命令"，且写出来的文件内容形如 uid=…/hosts_marker=…
    rm -f /data/local/tmp/ksu_mod_selftest.txt
    timeout 20 sh $T/mod/post-fs-data.sh 2>&1 | head -5
    log INFO "selftest 文件内容(shell 版，uid 应为 2000)："
    sed 's/^/    /' /data/local/tmp/ksu_mod_selftest.txt 2>&1
    rm -f /data/local/tmp/ksu_mod_selftest.txt
fi
echo "===== 预检结束：上面任何 MISS/异常都要在**烧窗口之前**解决 ====="
