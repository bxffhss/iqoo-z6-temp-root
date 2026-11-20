# suw @sushd flaky 修复记录（2026-11-16）

## 症状
`am start ... --es cmd '@sushd:<脚本>'` 派单：脚本时跑时跑不动（管理器的"本 boot"/AI 派单不稳）。
- 早期表现为"收到但不执行"、`sushd.log` 有 `granted=1 exit=0` 但脚本产物不见。
- 复现环境：干净窗里 `@suwksu` 守护甚至**没起**（`z6root.sh` 不起它）；手动起后仍时成时不成。

## 根因（strace 钉死，不再猜）
`strace -f -p <sushd_pid> -e trace=execve,openat` 抓到子进程：
```
execve("/system/bin/sh", ["KSU_EXEC","-c","<script>"]) = 0
execve("<script>", ...) = -1 ENOEXEC (无 shebang)
execve("/system/bin/sh", ["sh","<script>"]) = 0     ← sh 兜底，脚本确实执行了
openat("/sdcard/<out>", O_CREAT, 0666) = 3          ← 写也成功
```
⇒ **daemon + 子进程是好的**（uid=0、脚本真跑、写落地）。**flaky 全在 suw app 的 `run_via_sushd`**：
- 只 connect 一次、失败即放弃；
- 在 **app UI 线程**上轮询 `sushd_out.txt`（60×200ms），app 被 memcg 回收就丢结果；
- 派单**无条件** `return "status=0 via-sushd"`（盲回报，失败也报成功）。

排除项：不是挂载命名空间（adb/daemon/pid1 同 `4026533465`）、不是二进制版本（md5 对源码）、不是 argv[0]=KSU_EXEC（`sh -c` 照跑）。

## 修复（`suw_apk/suwksu_jni.c`）
1. `run_via_sushd`：`void` → `int`；外层**重试 3 次**（每次 connect+send+最多 180×200ms=36s 落盘轮询；拿到落盘才 ok=0）。
2. 派单返回**真状态**：`sr==0 ? "status=0 via-sushd" : "status=FAIL via-sushd"`（删掉盲 0）。
3. 重编：`bash suw_apk/build.sh` → `suw.apk`；`adb install -r`（同签名）。
4. 起守护（B8 punch 不自带）：`su -c 'sh /sdcard/z6root/start_sushd.sh'`（= `setsid ksuctl88 sushd changeme`）。

## 实测
装新 APK + 起守护后，单发 fire：**稳态 5/5**（#1 重装冷启动首缺，之后全中）。

## 注意
- @sushd 要能用 = **①装新 APK ②开窗后起守护**，缺一不可。
- 手用/重注入仍推荐 **su 版 `z6_lsposed_su.sh`**（不依赖 @sushd）。
- 管理器的 "本 boot 已发过 PUNCH = 是/否"（`MainActivity.java:612`）是**本 app 自己的打链按钮(punchSent)状态**，**不是**读 `run.sh` 的 punch —— 别拿它当内核窗口状态看。
