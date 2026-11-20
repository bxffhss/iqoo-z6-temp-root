set -u
sleep(){ :; }
adb(){ if [ "$1" = reboot ]; then echo ADB_CALLED_REBOOT; else echo device; fi; }
A(){ case "$1" in
  *kernelsu*) echo "${MOCK_MODS:-0}" ;;
  *uptime*) echo 42.5 ;;
  *sys.boot_completed*) echo 1 ;;
  *boot.reason.history*) echo "reboot,shell,1793560000" ;;
  *ro.boot.bootreason*) echo reboot ;;
  *) echo "" ;; esac; }
#   ★为什么要有它：有一类读数**只活在"当前这个 boot"里**。第 87 发那种"我们自己把它打死"之后，
#     "死后的第一个 boot"是"那次死到底走没走 panic()"唯一还可能带内的证人(§6.512/§6.514)，
#     而原来这条无条件的 `adb reboot` 等于**先把要读的东西抹掉**(ramoops 的 buffer 在新 kernel 注册时被 zap)。
#   ★它自带一把"当前 boot 是干净的"闸：本 boot 若已经开过窗(kernelsu 已在 /proc/modules)，
#     那"1 boot 只 1 枪"就已经花掉了——在脏 boot 上再开窗只会把两枪的读数混成一条，直接拒。
if [ -n "${NOREBOOT:-}" ]; then
    MOD0=$(A 'grep -c "^kernelsu " /proc/modules')
    echo "  ★NOREBOOT=$NOREBOOT ⇒ 跳过 adb reboot＋起机等待，直接在**当前 boot**开窗"
    echo "    当前 boot 自证：up=$(A 'cut -d" " -f1 /proc/uptime') bootreason=[$(A 'getprop ro.boot.bootreason')] kernelsu=$MOD0"
    echo "    hist=[$(A 'getprop persist.sys.boot.reason.history')]"
    [ "$MOD0" = 0 ] || { echo "[x] 当前 boot 已经有 kernelsu 在 ⇒ 这一 boot 的枪可能已花过，NOREBOOT 不许在脏 boot 上开窗"; exit 3; }
else
    adb reboot
    for i in $(seq 1 60); do sleep 5; [ -n "$(adb get-state 2>/dev/null | grep device)" ] && break; done
    until [ "$(A 'getprop sys.boot_completed' | tr -dc '0-9')" = 1 ]; do sleep 10; done
    sleep 40
fi
echo AFTER_BLOCK_RAN
