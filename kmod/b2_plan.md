# B2 计划 —— 官方 Manager(v3.3.0) 作 manager 的第二枪

> 写在开枪前。B1(11-12 15:2x 那一枪) 的读数已经拿到，缺口已经定位；本文件只记"下一枪改哪三处、以及为什么"。

## 一、B1 拿到了什么（已成立，不用再验）

| 判据 | 读数 | 出处 |
|---|---|---|
| boot 时加冕官方 App | `KernelSU: Crowning manager: me.weishu.kernelsu(uid=10104)` | `w103_evidence/ksu_stage_gcNUvM.log:187` |
| ko 侧 manager appid | `GET_MANAGER_APPID rc=0 appid=10104` | 同上 |
| v3.3.0 与 ko 握手 | `GET_INFO version=32601 flags=0xd features=5 uapi=2`（内核层**没有**拒它） | stage log:264+ |
| fd 注入机制本身好不好使 | `dmesg2.log` 63 条 `KSUFDINST 回调跑在 pid=1345 ... fd=141..215` | `kmod/w103_evidence/` |

⇒ **A 窗那条"加冕时序"假说被证伪**：官方 App 在 boot 前装好就一定被加冕。"重冠"这一层**不需要改 ko**。

## 二、B1 为什么没走到超级用户页（两个真缺口）

### 缺口①：fd 注入成功，但**晚到了**
`ksu_install_fd` 的实现是 `task_work_add()`（`ksu_dev_syms.c:2039`）⇒ fd 要等**目标线程自己回到用户态**那一刻才 `fd_install`。
B1 实测：`race_rearm` 从 up≈1628 起写了 75 轮，回调**全部**在 `up=1858.81` 一次性跑完（fds 141→215 连号）。
而官方首页的"支持/不支持"是**启动时一次性分支**（`ksu_one_stage.sh:785`）⇒ fd 晚到 200 秒，页面早定死了。
★我上一轮的诊断 `ls /proc/1345/fd | grep -c ksu = 0` **是错读数**：shell 读不到别的 uid 的 `/proc/<pid>/fd`，`ls` 报错被 `grep` 吃成 0。真凭据在 dmesg。

### 缺口②：root 只在 stage 活着的那些秒里存在
B1 结束后实测：`allowlist` 全空（`granted 10342 = 0`、`granted 10104 = 0`），`/product/bin/su -c id` 对 shell 报 `提权失败 uid=2000 ioctl ret=-1 errno=1`。
⇒ stage 一退，`@sushd` 派单、`asuid`、`setprof` 全部失能；**这一窗剩下的授权动作一个都做不了**（`/proc/ksu_install_fd` 0600 root，也再写不进去）。

## 三、B2 的三处改动（最小集，其余逐字沿用交付链）

1. **`SU_BIND=1`** —— 让 `go.sh` 第 5 步跑 `w135_fix.sh`，把 `sustatic` bind 成 `/product/bin/su`。
   （B1 是我在窗口里事后补的，补完就把唯一拿到 fd 的那个实例 kill 了 —— 自伤，不是机制问题。）
2. **打开 FDKA 开关 `/data/local/tmp/ksu_fd_keepalive`** —— 把"30 秒抢装"升级成**种进 zygote64**：
   app 从 zygote fork、不走 execve ⇒ fd 出生即在，彻底消掉缺口①的时间窗（`ksu_one_stage.sh:807-908`）。
   这是内核侧**设计好的** LKM 姿态，不是我造的旁路。安全面已读实：dispatch 每个动词都挂 `perm_check`，`GRANT_ROOT` 只认 su-session fd。
3. **`KO=kmod/kernelsu_rc80.ko`**（md5 `98bf4052`）+ 交付 args（md5 `fec3d301`）—— 与稳定交付路线逐字一致。

## 四、开完枪之后的动作（不需要 root）

fd 到手 ⇒ 官方 UI 首页应显示 **工作中 [越狱模式]**（`MANAGER=0` 所以是越狱模式）+ 底部导航。
之后全部走 UI：`bash kmod/ui_grant.sh <词> <uid> <包名>` ×3，再读 `ksuctl88 granted <uid>`（只读，shell 可跑）复证。

判据表：
- 好：三条 `granted=<uid> rc=0 granted=1`，且 `asuid <uid> /product/bin/su -c id` → `uid=0`
- 坏：UI 仍"不支持" ⇒ 看 stage log 里 `FDKA INST Z / INST M` 有没有落，再判是开关没生效还是 zygote 挑错

## 五、收窗
`I_KNOW=1 bash kmod/w161_teardown.sh`；若它因为名单空而失能，**reboot 就是干净的收窗**（ko 卸载、SELinux 回 Enforcing、bind 消失），boot 后复核 `mod=0 / Enforcing / 无 /product/bin/su`。
