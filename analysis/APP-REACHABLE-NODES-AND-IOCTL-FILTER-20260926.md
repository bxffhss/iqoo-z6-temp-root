# app 可达面收敛：464 个节点里只有 14 个能开 ⇒ 165 个 ioctl 候选压到 6 个（2026-09-26 19:40）

## 1. 一手枚举（P66 失败 → P67 成功）

- **P66 的教训**：`opendir("/dev")` 对 app 返回 **EACCES**（SELinux 不允许 app 搜 `device` 目录），
  但**按完整路径 `open()` 是可以试的**（我们一直能开 `/dev/binder`、`/dev/ashmem`）。
  ⇒ 枚举必须由**外部提供名字清单**、由 app 逐个试开：清单用 shell `find /dev -maxdepth 2 -not -type d`
  取得（只是名字，不涉及权限），写进生成的 C 数组里在 app 内跑。
- P67（464 个候选，去掉块设备/disk-by）结果：**可打开 14 个、EACCES/EPERM 446、其他 2**
  （`/dev/fd` errno=21 EINVAL、`/dev/tty` errno=6 ENXIO）。

```
/dev/ashmem            /dev/ashmem9b8ace4b-...   /dev/binder      /dev/hwbinder
/dev/kgsl-3d0          /dev/log/common  /dev/log/drop  /dev/log/much
/dev/null  /dev/ptmx  /dev/random  /dev/urandom  /dev/zero
/dev/stdin  /dev/stdout  /dev/stderr
```
注意：**没有 `/dev/ion`**（项目记忆里"ION 是 app 可用的映射原语"这条要复核：这台机器上 `/dev/ion`
不在可打开列表里；dmabufheaps 的 `/dev/dmabuf_heap/*` 也没出现在 464 候选中 ⇒ 需单独确认路径）。

## 2. 与 CFI `unlocked_ioctl` 同类型集合(165)的交集 ⇒ 真正可审的只有 6 个

| 可达节点 | handler | 本机一手判定 |
|---|---|---|
| `/dev/ashmem` | `ashmem_ioctl` / `compat_ashmem_ioctl` | 已审：**无 copy-out**；`SET_NAME` 的 249B 窗口只覆盖 `pd+0x0b..0x10a`，越不出自有对象 |
| `/dev/binder` | `binder_ioctl` / `binder_ctl_ioctl` | 已审（见 `BINDER-*` 三份） |
| `/dev/log/{common,drop,much}` | `logger_ioctl` | AOSP `drivers/android/logger.c` 形状；`logger_write` 在镜像里**没有任何 `bl` 调用点** ⇒ printk 不会进来，**不是事后日志通道**；`logger_read` 的未初始化字节问题另查 |
| `/dev/ptmx` | `tty_ioctl`（+`tty_compat_ioctl`） | 被调集里有 `_copy_to_user`/`_copy_from_user`/`tiocgetd`/`tioccons`/`ptm_open_peer`/`capable`；`tioccons` 要 `CAP_SYS_CONSOLE_OWNER`（我们有 `capable` 这道门 ⇒ 预期被拒），`tiocgetd`=TIOCGDEV 拷的是 `dev_t`（**不是内核指针**） |
| `/dev/random`,`urandom` | `random_ioctl` | 被调集**空**（纯 getrandom/读） |
| `/dev/kgsl-3d0` | `kgsl_ioctl` / `kgsl_compat_ioctl` | **唯一还没被审的大面积面**：只到 `kgsl_ioctl_helper` 一层，子 ioctl 上百个 ⇒ 正在单独过一遍"拷贝回用户且源是内核对象"的点 |

⇒ 此前那份 165 个 handler 的审计（`IOCTL-CFI-165-AUDIT/REFRAME`）**没有先做可达性过滤**，
所以大量精力花在 app 根本打不开的节点上（ipa3/qseecom/synx/spcom/vsoc/haptic/fastrpc/…）。
**这是本轮的方法论修正：攻击面筛选的第一层应该是 `open()` 能不能成功，不是 CFI 类型集。**

## 3. 新增可复用资产

- `C:\qemu_test\appdapk\devnodes.txt` —— 设备节点全清单（shell 侧 find）。
- `C:\qemu_test\appdapk\jni_p67.c` —— "用显式清单在 app 域批量试开"的模板（改清单即可复用到别的路径空间，
  如 `/dev/socket`、`/sys/devices/...`）。
- `C:\qemu_test\ioctl165_inv.txt` —— **一次 awk 全量扫过的产物**：165 个 handler 各自的被调函数表
  （`### 名字` + `   -> callee`）。重建命令见本文 §4。以后任何"谁调用了 X / X 里有没有 copy_to_user"
  的问题都可以直接查它，不必再扫 333 MB 反汇编。
- `C:\qemu_test\appdapk\bi.sh` —— 编译+打包+**可靠安装**（自己点掉 vivo 安装拦截页）+启动；
  旧 `install.sh` 在拦截页出现时会永久阻塞在 `wait` 上。

## 4. 重建 ioctl165_inv.txt（一次 awk 全量过，约 40 秒）

```sh
# /tmp/h165.txt = 165 个 handler 名(从 analysis/cfi_type_tables.txt 里 n=165 那行按 '|' 拆)
awk 'NR==FNR{gsub(/\r/,""); n[$0]=1; b=$0; sub(/\$.*/,"",b); base[b]=1; next}
 { if (match($0,/^[0-9a-f]+ <[^>]+>:$/)) { lab=$0; sub(/^[0-9a-f]+ </,"",lab); sub(/>:$/,"",lab);
     bb=lab; sub(/\$.*/,"",bb); on=(lab in n)||(bb in base); if(on) print "### " lab; next }
   if (on && /bl[ \t]+0x/ && match($0,/<[^>]+>/)) print "   -> " substr($0,RSTART+1,RLENGTH-2) }
' /tmp/h165.txt vmlinux_full.asm > ioctl165_inv.txt
```
（两个坑：① `ARGV1` 不是 awk 变量，第一个文件要用 `NR==FNR` 区分；
 ② 符号名带 `$hash` 后缀（如 `ashmem_ioctl$58a1...`），要同时按原名与前缀名匹配。）
