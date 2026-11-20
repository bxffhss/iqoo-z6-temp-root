# ION：非特权 app 可从系统级/TEE 相邻 heap 无限制分配（vivo iQOO Z6, 5.4.281-qgki）

日期：2026-09-26 · 设备：iQOO Z6（PD2220，SM7325，Android 14，SPL 2025-04-01，BL 锁，SELinux enforcing，无 root）
攻击域：`u:r:untrusted_app_27:s0`，uid=10172，`CapEff=0`，app seccomp(filter)
证据：`P23/P24/P27/P28/P41` 探针；源码 `C:/qemu_test/appdapk/jni_p27.c`、`jni_p28.c`、`jni_p41.c`；
原始日志 `trace_p27.txt`、`trace_p28.txt`、`trace_p41.txt`（`run-as com.poc.probe cat` 可取）
静态佐证：`ION-ASHMEM-STATIC-20260926.md`（`ion_ioctl@0xffffffc010edea68`）

---

## 1. 结论

**一个零权限的 Android 应用，可以在只读打开的 `/dev/ion` 上分配并 CPU 读写映射来自
`qsecom` / `qsecom_ta` / `secure_display` / `display` / `audio_ml` 这些系统级与 TEE 相邻 ION heap 的内存，
且对 `qsecom` 未观察到有效配额（75 MiB 连抢成功、零失败）**。

影响类型：**跨信任域的本地资源耗尽（DoS）**。不是信息泄露、不是越权映射（见 §4 已排除项）。
其中最重的一条是 `qsecom`：该 heap 在高通平台上用于与 **QSEECom（TrustZone 通道）** 交换数据，
其合法消费者是 keystore / gatekeeper / 指纹 / DRM 等系统服务 —— 非特权进程能量耗尽它。

## 2. 复现配方（全部为实测常量，非上游标准值）

该内核是 **厂商改造版 ION**，ioctl 号与上游 `drivers/staging/android/ion` 不同：

| 项 | 值 |
|---|---|
| ALLOC | `_IOWR('I',0,24)` = **`0xc0184900`**（magic 是 **`'I'`(0x49)**，不是上游 `'i'`） |
| HEAP_QUERY | `_IOWR('I',8,24)` = **`0xc0184908`** |
| （未知）| `_IOR('I',9,4)` = `0x80044909` → 返回 `2` |
| ALLOC 结构 | **24 字节** `{u64 len; u32 heap_id_mask; u32 flags; u32 fd_out}` —— **没有 `align` 字段**，与上游 `ion_allocation_data`(32B) 不兼容 |
| 入口前置 | `open("/dev/ion", O_RDONLY)` —— 节点是 `crw-rw-r-- system:system`(0664)，app **写不进去**，只读可开 |

关键机制：`ion_ioctl` 全程**不解引用 `filp`**（静态确认：无 `capable()`、无 `FMODE_WRITE` 检查、无 uid/SELinux 判断），
而 VFS 的 `vfs_ioctl()` 也**不会**因为 `O_RDONLY` 就拒绝 `_IOWR` 命令 —— DAC 只在 `open()` 时检查一次。
⇒ **"只读 fd"完全不妨碍分配**，这正是本漏洞得以成立的结构原因，也是一个值得记住的设计陷阱。

HEAP_QUERY 枚举到的 9 个 heap（按 bit 序）：
`system`、`secure_display`、`secure_heap`、`qsecom`、`user_contig`、`audio_ml`、`display`、`qsecom_ta`、`ion_system_heap`。

## 3. 实测上限（P41，app 域，每笔 64KB，抢完立即 close 归还）

| heap | 连抢结果 | 单笔 4MiB | 单笔 64MiB | 单笔 128MiB |
|---|---|---|---|---|
| **`qsecom`** | **1200 笔 = 75 MiB，零失败**（撞自设上限，非配额；首次失败 errno=0） | 成功 | 成功 | 失败 |
| `system` | 1200 笔 = 75 MiB，零失败 | 成功 | 成功 | 成功 |
| `qsecom_ta` | 281 笔 ≈ 17 MiB（ENOMEM） | 成功 | 失败 | 失败 |
| `audio_ml` | 288 笔 ≈ 18 MiB（ENOMEM） | 成功 | 失败 | 失败 |
| `display` | 256 笔 ≈ 16 MiB（ENOMEM） | 成功 | 失败 | 失败 |
| `secure_display` | 256 笔 ≈ 16 MiB（ENOMEM） | 成功 | 失败 | 失败 |
| `secure_heap` / `user_contig` / `ion_system_heap` | 分配即 `ENODEV`（不可用） | — | — | — |

- 每一行都验证过 **归还后可再分配成功** ⇒ 是配额/池耗尽，不是永久占用；探针自身不留残余。
- 设备 `MemTotal ≈ 11.3 GiB` ⇒ 75 MiB 只是"未触顶"的下界，真实上限可能更高（本次刻意自设 1200 笔为界，未继续加压）。

## 4. 已排除项（避免夸大）

- **不是信息泄露**：同 heap 连续两笔 4KB 无物理页别名；新分配缓冲**全零**（`CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y`，
  `INIT_ON_FREE` 未开但分配即清零）⇒ 读不到上一个使用者的残留。
- **不是任意映射越权**：映射的都是自己刚分配的 dma-buf fd，`fstat` 尺寸正确、mode 600。
- 未测：`ION_FLAG_SECURE` 语义下的行为（`flags≠0` 未扫），以及这些缓冲能否经 binder 传给系统服务并被其接受。

## 5. 建议整改方向（按性价比）

1. `/dev/ion` 节点权限收到 `0660` + 专用组，或直接去掉 app 域的 `ion_device:chr_file {open read ioctl}` ——
   Android 14 上 app 本不该能用 ION（应走 `dmabufheaps`，而本机 `CONFIG_DMABUF_HEAPS` 未编译）。
2. `ion_ioctl` 入口加 `FMODE_WRITE` 检查（或 `capable()`/uid 判定），别依赖"写打开才能 ioctl"这一直觉假设 —— 它不成立。
3. 给 `qsecom` / `qsecom_ta` / `secure_display` / `display` / `audio_ml` 加 **per-uid / per-heap 配额**；
   非特权 uid 应当完全拿不到这几个 heap id（掩码过滤）。

## 6. 备注

- 同一结构缺陷也存在于 `/dev/ashmem`：其厂商改造版 ioctl magic 是 `'w'`(0x77) 而非上游 `'A'`，
  `SET_SIZE/SET_NAME/SET_PROT` 对 app 全部可用；但它的 `mmap` 被单独焊死成 **EPERM**，故危害远低于 ION。
- 本发现与项目主线（GhostLock / binder 写通道）无关，是可达面普查过程中意外得到的独立问题；
  在此之前**项目任何文档都未记录过它**，故单独成文。
