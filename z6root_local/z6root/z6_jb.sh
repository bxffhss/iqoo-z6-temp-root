#!/system/bin/sh
# z6_jb.sh —— 一键恢复「越狱模式」维持（root 跑：su -c 'sh /sdcard/z6root/z6_jb.sh'）
#   场景：LSPosed 还活着(serial=[]) 但 KernelSU 管理器回退"不支持"——
#         即管理器(zygote 子进程)被回收重开成新 pid、而维持件没在岗，新进程没拿到 ko fd。
#   做两件事：① 确保维持件开关在 ② 起 b8_keep（它会立刻给当前管理器补 fd，之后盯 pid 变化自动补）。
#   幂等：可反复跑（b8_keep 无参会先收掉旧实例再起新的）。
touch /data/local/tmp/b8_keep 2>/dev/null
MP=$(pidof me.weishu.kernelsu 2>/dev/null)
echo "mgr_pid=[$MP]"
sh /sdcard/z6root/b8_keep.sh
sleep 2
KP=$(ps -A -o PID,ARGS 2>/dev/null | grep -a 'b8_keep.sh RUN' | grep -av grep | awk '{print $1}')
echo "keeper=[$KP]"
echo "已补 fd + 维持件上岗；打开一次 KernelSU 管理器，首页应回 工作中[越狱模式]。"
echo "（若失败：确认窗口还在 mod=$(grep -c kernelsu /proc/modules)、shd 活；否则先 reboot→run.sh 重开窗。）"
