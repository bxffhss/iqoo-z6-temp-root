# B8 窗口结果 —— 官方 Manager 作 manager ＋ 三标准 app 取到 root（成立）

时间：2026-11-12 18:30（insmod up=670.11）～ 18:36
形状：`I_KNOW=1 SU_BIND=1 KO=kmod/kernelsu_rc80.ko`＋设备侧 `/data/local/tmp/ksu_two_profiles`
（`10104:me.weishu.kernelsu 10349:com.omarea.vtools 10475:com.wn.app.np 10261:me.piebridge.brevent`）

## 一、名单（内核真值，用 root 腿读的，不是 shell 读的）

```
--- info ---        GET_INFO rc=0 version=32653 flags=0x5 features=5 uapi=2   (LKM=1 MANAGER=0 LATE_LOAD=1)
--- allowlist ---   NEW_GET_ALLOW_LIST rc=0 count=4 total=4
                    allow[0] uid=10475  allow[1] uid=10342  allow[2] uid=10261  allow[3] uid=10349
--- granted ---     uid=10342 granted=1 ; uid=10104 granted=1 ;
                    uid=10349 granted=1 ; uid=10475 granted=1 ; uid=10261 granted=1
--- su ---          /product/bin/su  -rwxr-xr-x root root 2241944
```

- 落盘证人：`★落盘读回：/data/adb/ksu/.allowlist 字节=3928`，`mkallow 追加=[10104 … 10349 … 10475 … 10261 …]`
- **多条目可用**（`count=4`）：这一条否掉 §6.156 那一格的"内核只收 1 条"疑云。
- 内核把 10104 从 `allow[]` 里略去，但 `granted(10104)=1` ⇒ **manager appid 被隐含允许**（这也解释了 B4/B5 里官方 App 的 `su` 为什么能用）。

## 二、真出 root（以每个 app 自己的 uid 实跑，经 root 腿）

```
--- uid=10349 ---  uid=0(root) gid=0(root) groups=0(root) context=u:r:shell:s0     # Scene
--- uid=10475 ---  uid=0(root) ...                                                 # NP管理器
--- uid=10261 ---  uid=0(root) ...                                                 # 黑域
--- uid=10342 ---  uid=0(root) ...                                                 # suw(通道对照)
```
脚本：`kmod/b8_su.sh`（走 `@sushd`）。

## 三、官方 App 侧

- 加冕：`Crowning manager: me.weishu.kernelsu(uid=10104)`（内核 ts 737.673）＋ `GET_MANAGER_APPID=10104`
- 首页：`工作中 [越狱模式]`、`版本：32653-2`、`SELinux 状态=宽容模式`
- 导航：`主页 / 超级用户 / 模块 / 设置` 四页签全在，**「超级用户」带角标 `4`**（与 `count=4` 对齐）
- `获取 Root 失败` **消失**（前提：必须"su 与 fd 都在 App 出生前就位"，见 §四）

## 四、两条时序铁律（这次是踩出来的）

1. **fd 只属于"那一个进程"**：`/proc/ksu_install_fd` 走 `task_work_add`，fd 在目标线程回到用户态时才装；
   App 一被换进程，fd 就没了，而"支持/不支持"是**启动时一次性分支** ⇒ 事后补装永远白干（B1/B7 各废一次）。
2. **`su` 也要在 App 出生前就位**：否则 `KsuCli` 那次自举失败会被缓存成「获取 Root 失败」，
   **重造 Activity 不重查**（已验两轮），**重启进程又会丢 fd** ⇒ 只能"先开 0.2s 抢装循环，再 am start"。

## 五、可复现的一枪（本窗口最终形态）

```bash
# 1) 设备侧铺开关（suw + 官方 Manager + 三个目标 app）
printf '%s' '10104:me.weishu.kernelsu 10349:com.omarea.vtools 10475:com.wn.app.np 10261:me.piebridge.brevent' \
  > /data/local/tmp/ksu_two_profiles
# 2) PC 侧开枪
I_KNOW=1 SU_BIND=1 KO=kmod/kernelsu_rc80.ko bash kmod/go.sh
# 3) 收窗（root 腿在时才能正确卸模块＋回 Enforcing）
I_KNOW=1 bash kmod/w161_teardown.sh
# 4) ★收窗后务必删开关，否则下一次开窗会"静悄悄换了形状"
adb shell rm -f /data/local/tmp/ksu_two_profiles
```

## 六、证据文件

- `kmod/w103_evidence/go_b8.log`（开窗全过程）
- `/data/local/tmp/ksu_stage.log`（stage 内证人：mkallow/落盘/NOSUW 等）
- `/data/local/tmp/b8_verify.out`、`/data/local/tmp/b8_su.out`（名单真值与真出 root）
- `kmod/w103_evidence/b8_superuser.xml`（超级用户页 dump；列表是 Compose 懒加载，只读到角标 4）
