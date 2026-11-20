# KASLR slide **已解出**（2026-09-27，本次开机）

```
runtime _text = 0xffffffeda8a80000        slide = +0x2d98a00000  (= 93381 个 2MB)
```

工具：`analysis/slide.py`（读一份 IP 清单 ⇒ 输出候选 + 每候选的热点函数 top10）。
采样：`adb shell /data/local/tmp/perfips <秒>`（shell 域 `perf_event_open` 可用，
`perf_event_paranoid = -1`；app 域是 EACCES，所以**必须由 shell 采**）。

## 为什么这次能定，而 09-26 不能

09-26 否掉 perf→slide 的理由至今成立，且被本次的做法绕开了：

| 09-26 的失败原因 | 本次的绕法 |
|---|---|
| "IP 落在某符号区间内" 是恒真判据（符号区间铺满 text）⇒ 两次采集解出相差 42KB 的 slide 都"通过" | **不用它当判据**，只用它做**粗筛**；真正的判别是"热点函数合不合理" |
| 文本非零字比例 0.997 ⇒ "是不是合法指令" 没有判别力 | 同上，弃用 |
| 链接期 `_text` 低 21 位 = 0x80000 非 2MB 对齐 ⇒ "低 21 位相等"猜 slide 不成立 | 改成硬约束：候选必须满足 `T ≡ 0x80000 (mod 2MB)`，一步就把空间压到 **2 个候选** |
| 当时没有同构建符号表，`_etext` 是估的 | 现在有逐字同构建的 kallsyms+Image ⇒ `text_len = _etext-_text = 0x1520000` 是**准的** ⇒ 主簇整体平移后仍要落在 text 内 ⇒ 只剩 2 档 |

关键三点：**① 2MB 栅格 + 0x80000 相位；② 用主簇宽度 ≈ text 长度做区间约束；③ 语义判据定胜负。**

## 判据的实际形态（两次独立采集，同一答案）

主簇 436~458 个样本（另有 3~4 个离群样本在 `0xffffffed3d49…`，那是模块区，忽略）；
候选只有两档，差一个 2MB：

```
== T=ffffffeda8a80000  slide=+2d98a00000  区间内 419/436 ==
   热点: kmem_cache_alloc link_path_walk kfree kmem_cache_free avc_lookup number
         memset __d_lookup vsnprintf __check_object_size          ← 全是最热内核路径 ✓
== T=ffffffeda8c80000  slide=+2d98c00000  区间内 418/436 ==
   热点: rebalance_domains find_busiest_group enqueue_entity inet6_addr_modify
         ip6_finish_output2 ip6_route_info_create rcu_cpu_kthread show_rsc_cpu_usage
         do_timer_create ext4_symlink                            ← 不可能同时这么热 ✗
```

正对照（专门做的）：一边跑 `while :; do stat /system/bin/sh; done` 一边采样 ⇒
胜者档的热点里出现了 **`link_path_walk`**（stat 的主路径）与 `avc_lookup`/`__d_lookup`/`number`(vsprintf) ✓✓
错位档则把这些样本映到 IPv6/负载均衡函数上 ⇒ 明显错。
两次独立采集（sha256sum 负载 / stat 负载）**给出同一个 T** ⇒ 判定稳定。

## 落到 exploit 的数（runtime = link + 0x2d98a00000）

| 目标 | 链接期 | 本次开机 runtime |
|---|---|---|
| `selinux_state`（`enforcing` 在 +1，`initialized` 在 +0，`policy` 在 +0x10） | `0xffffffc012b18000` | **`0xffffffedab518000`** |
| `init_task` | `0xffffffc01292e200` | `0xffffffedab32e200` |
| `init_cred` | `0xffffffc01293d528` | `0xffffffedab33d528` |
| `commit_creds` | `0xffffffc01031f154` | `0xffffffeda8d1f154` |
| `prepare_kernel_cred` | `0xffffffc01031f67c` | `0xffffffeda8d1f67c` |
| `security_hook_heads` | `0xffffffc01222b400` | `0xffffffedaac2b400` |
| `remove_waiter`（漏洞点，用于自检 slide 是否变了） | `0xffffffc010378d58` | `0xffffffeda8d78d58` |

## 工程约束（下次开机怎么办）

* **slide 每次开机都变**（见 [[device-observability-limits]]）⇒ 载荷里的所有内核地址都是**本次开机**的；
* app 域不能采 perf ⇒ 流程固定为：`adb shell /data/local/tmp/perfips 25` → 主机/或推到设备上的 `slide.py`
  → 把 `runtime _text` **通过 Intent extra 传给 app**（`am start --es base ffffffeda8a80000`）。
  不要用 `/data/local/tmp/*.txt` 让 app 读 —— `untrusted_app` 读 `shell_data_file` 被 SELinux 拒；
* 自检：app 拿到 base 后，若 punch 前需要确认 base 没错，可校验"payload 里所有指针都落在
  `[base, base+_end-base]` 内"；真正的运行时校验只能是 punch 的效果本身（有 oops 风险）；
* 若将来要脱离 adb，就必须回到任务 #20（app 域内核指针泄露）——但**本线现在不需要**：
  ghost 与覆盖通道都已在真机成立，slide 由 shell 侧提供即可达成"临时 root"演示。
