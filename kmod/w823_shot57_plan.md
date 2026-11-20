# w823 —— 第 57 发（10-25 15:0x–）判据（**开枪前写死**）：rc74c 首跑 ＋ 用它把「牌子能不能扛住反复进出管理器」钉死

> 变的只有一件事：**ko 从 rc74b 换成 rc74c**（`kmod/kernelsu_rc74c.ko`＝`324eda4dcb5d41ecb6763a5192ea9c31`，5,113,968 B）。
> rc74c＝rc74b 的底 ＋ 出生安装两处修法（一手依据＝第 56 发 §6.429：正常使用 ~12 分钟就把 64 格烧光 ⇒ 新 Manager 进程 `fd_ksu=0` ⇒ 牌子掉 `不支持`）：
> ①helper 名单排除 `libksud.so`/`crash_dump64`/`debuggerd64`（**`usap64` 故意不排**——第 51 发实测主进程排队时 comm 就是它）；
> ②`cap` 64→4096，并新增"每秒速率窗"（用事件自带的 `start_time` 当钟 ⇒ **零新增内核符号**：实测未定义引用 158＝rc73 的 158）。
> 包：`z6root.zip`＝`880e9ef2e259411f7fc3de4a2cb53e88`；忠实性闸 79 项全绿；总闸 `kmod/w413_selftest_sweep.sh`＝`727ec44d`（文档里 5 处登记值待本发跑完轮转）。

## 甲组＝这份包的形状（七条，⑦ 是本发的靶子之一）

1. 设备侧一条命令跑到 `=== Z6ROOT_DONE … mod=1 ===`（宿主必须是 uid=2000 的 `adb shell`）。
2. `入口形状=1`（免 suw／免界面），目标包 uid **现取**（`pm list packages -U`，别抄台账）。
3. 活表 `count=1 uid=<现取>` 且 `granted[<现取>] … granted=1`。
4. 载荷两端各核：MANIFEST 22 条逐条 `ok <名> <md5>`；包内 `kernelsu.ko`＝`324eda4d…`；args 读回＝`67199f48…`。
5. root-only bind 起来：`前置闸一：pbin 行数=0`、`NOSUW_BIND_RC=0`、mountinfo 源＝`/adb/ksu/pbin`（**无 `//deleted`**）、`/product/bin/su` 存在且带 x 位、keeper 日志在推进。
6. **x 位的活证人**：`su -c /data/local/tmp/w450_close.sh` 之外，再加一条包内 `.sh` 用绝对路径直接 execve（`su -c /data/local/tmp/w774_pbin_keeper.sh selfcheck` ⇒ 要看到它自己打的 `PASS`，不是 `exit=126`）。
7. 牌子（只有"焦点 OK"的格子算）＝`工作中／版本：32601-2／越狱有`。

## 乙组＝rc74c 的正题：**反复杀干净再起管理器 20 次，牌子必须每次都在**

8. 循环 20 轮，每轮：`am force-stop me.weishu.kernelsu` → `am start -n me.weishu.kernelsu/.MainActivity` → 等 ≥3 秒 → 读一次牌子。
   **判据：20/20 轮都读到 `工作中`＋`32601-2`＋`越狱有`**（rc74b 在同一台机上第 12 分钟就把预算烧到 `cap` 拒绝、之后重进也回不来）。
9. 循环结束后从 `dmesg2.log` 现数三件（★不许拿"没打印"当凭据，要数到具体行）：
   - `KSUBIRTH cap` 行数 **必须=0**；
   - `queued self fd` 的 `total=` 末值：应当≈领头数（20 上下，允许因 helper 拒绝/去重而少几），**绝不能一路涨到 64**；
   - `KSUBIRTH helper n=` 证人**必须至少出现一次**（说明 libksud.so 那支被正确拒掉、没占预算）；`dupskip n` 增速也记下来。
10. 末轮再取一次当前 Manager pid 的 `fd_ksu`（**必须 ≥1**）＋`su -c id` 仍 `uid=0`。
11. ★诚实性：20 轮里只要有一轮掉，就如实记"第几轮掉的＋当时 total/cap 读数"，不许只报成功的那几轮；掉了＝本组判负、也不升默认。

## 丙组＝顺带记录（不做归因）

12. 全程挂着只读采样器 `kmod/w810_window_watch.sh`（`/proc/stat` 的 fork 增量＋我们 `fired#` 增速＋keeper 行数＋crash 增量）。本发**只报"这一窗活到 insmod+X 秒"**，寿命归因仍归 #189 那条线。

## 丁组＝收尾（顺序是铁律）

13. 跑包内 `w450_close.sh`（第二次认证：产物 PC 侧可读＋七键齐＋keeper 自退）。
14. 执法腿 `su -c /data/local/tmp/w813_enforce_only.sh` 恢复 `enforce=1`（**排在所有 root 腿之后**）→ `adb reboot` → 复位后独立读回 `Enforcing`/`mod=0`/挂载行=0/无 `su`。

## 代价、红路与合作约定

- 代价：rc74c **首跑**；红了就是形状问题，不猜环境。乙组那 20 轮要 ~2 分钟，其间不能做别的读数（会污染"每轮牌子"的对应关系）。
- 若 9 的三件里 `helper` 证人没出现、而 `total` 仍在涨 ⇒ 说明 helper 没被认出来（comm 可能不是 `libksud.so`），那要拿一手 comm 再改名单——**这一格就算判负**。
- 跑成之后才谈交付：**默认升到 rc74c 这份包**，并把上一份（`24664916`，rc74b）标成"当时＝"；同时把教程第 8 条的"反复进出会烧预算"这条限制改掉（因为它已被修掉）。
- 不许顺手做：抬 cap 之外的 ko 改动、`NOBIND=1`（#182）、`ksu_fd_keepalive`（§6.400）、seccomp/#110、以及"开机自动回来"那条已关闭的战线。
