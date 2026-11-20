# hid-multitouch 越界写 —— 受控命中实证 (2026-09-21 22:1x)

## 一句话
`/dev/uhid` 触发的 hid-multitouch 堆越界 memset, 现在可以**稳定地打在指定的相邻内核对象上**,
并且**对照/实验分离干净**。此前两轮堆风水全部空手, 根因是 objsize 算错(见下)。

## ★ 根因: 本机 kmalloc 最小 cache 是 128 字节, 不是 16
```
/proc/config.gz  (设备上可直接读!)
  CONFIG_SLAB_FREELIST_RANDOM=y     ← 页内 freelist 随机, "先分配=物理在前" 不成立
  CONFIG_SLAB_FREELIST_HARDENED=y   ← freepointer 混淆存储
  CONFIG_SLUB_CPU_PARTIAL=y
  CONFIG_HARDENED_USERCOPY=y
  CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y
  CONFIG_SLUB=y
  CONFIG_SLAB_MERGE_DEFAULT is not set   ← 没有 cache 合并/别名
/sys/kernel/slab/ 只列出: kmalloc-128, -256, -512, -1k, -2k, -4k, -8k (+ kmalloc-rcl-*)
  ⇒ 没有 kmalloc-16/32/64/96/192
```
原因: arm64 `ARCH_DMA_MINALIGN = 128` ⇒ `KMALLOC_MIN_SIZE = 128`, `KMALLOC_SHIFT_LOW = 7`。
`kmalloc_index(size)` 里 `if (size <= KMALLOC_MIN_SIZE) return KMALLOC_SHIFT_LOW;`
⇒ **`kmalloc(x)` 对一切 x ≤ 128 都返回 128 字节对象, 全部落在 kmalloc-128。**

实测佐证 (uhid_t4, 绑 20000 个 AF_UNIX 抽象名 socket):
- namelen=7  (对象 16 字节)  → kmalloc-128 act +39725 (~2/个, 其中一个就是 unix_address)
- namelen=100 (对象 109 字节) → kmalloc-128 act +9832/5000个 (同样比例)
  两种长度落在**同一个 cache**, 这只有在"最小 cache = 128"时才成立。
- `lsm_file_cache`(16B) 的增长 = 每个 socket 一个 file security blob, 不是 unix_address。

### 由此产生的一切后果
| 项 | 旧 (错) | 新 (对) |
|---|---|---|
| 漏洞缓冲 | kmalloc(9) → 16 字节槽 | kmalloc(9) → **128 字节槽** |
| 越界公式 | `n2 + 2 - 16` | **`n2 + 2 - 128 = n2 - 126`** |
| rcnt=24 | 越界 10 字节 | **越界 0 字节(根本没越界)** ← v1/v2 全 0 的真因 |
| rcnt=127/128 | 越界 113/114 | 越界 1/2 字节(不可观测) ← v2 第二轮"1 字节"的真因 |
| rcnt=200/512/1023 | 185/385/896 | 74/386/897 ← 与"崩"的实测一致 |
| 靶子 | namelen=7 (16B) | **namelen=100 (109B) → 同为 kmalloc-128** |

崩溃阈值表在**新几何**下解释得完全自洽: rcnt ≤ 127 无越界(存活), 200 起有实质越界(崩溃)。

## ★ 另一个关键事实: 探针是异步的
uhid_t1 实测: `write(UHID_CREATE2)` **3.1ms 返回**, 之后 4.7ms 才收到 `UHID_GET_REPORT`,
且 write 期间线程从 cpu1 漂到 cpu0。
⇒ `hid_add_device` 的 probe(mt_probe → hid_hw_start → hidinput_connect → mt_feature_mapping
→ mt_get_feature) 跑在**内核 workqueue 线程**里, 不是 write 的调用线程。
⇒ 缓冲区在"我们没回复"的情况下会阻塞最多 2s(uhid raw request 超时), 这就是可用的**风水窗口**。
⇒ 喷射线程和创建设备必须考虑 CPU 亲和(groom3 单核绑定下越界变致命, 说明确实写到了东西)。

## ★★ 成功方案: 单 CPU 步进式认领页 (C:\qemu_test\uhid_groom6.c)
每发:
```
1) burst1(40) 个 bind  → 耗尽当前活动 slab 页, 逼分配器"认领"一张新页(32 槽), 我们用掉几个
2) write(UHID_CREATE2) → 同 CPU 上 kworker 的 hid_alloc_report_buf(9) 落在**我们刚认领的页**
3) 等 GET_REPORT(内核线程阻塞在 raw request, 最多 2s)
4) burst2(64) 个 bind  → 把该页剩余槽位填成靶子(即越界写的物理邻居)
5) 回 UHID_GET_REPORT_REPLY(data[0]=2 伪造 ID) → kworker 恢复 → memset(rcnt-1 字节)
   → 越界 10 字节正好清零相邻靶子的 refcnt+len(+名字开头 2 字节)
```
回读(安全, 绝不用 getsockname):
```
被清零 len 的 unix_address 在 unix_seq_show 里 len<0 ⇒ 一个字节都不打印
⇒ 数 /proc/net/unix 里 "@zz#####" 的条数, 少掉的个数 = 被越界写命中的靶子数
(getsockname 在 len=0 时 memcpy size 会变成 0xFFFFFFFE ⇒ 必崩内核, 禁用)
```

## 实测结果 (2026-09-21 22:1x, 全部同一配置, 只改 pwn 一个参数)
配置: cpu=4, prefill=16000 个靶子(namelen=100), nshots=20, burst1=40, burst2=64,
      delay=200ms, rcnt=136(越界 10 字节), 靶子/缓冲同为 kmalloc-128

| 运行 | 回的报告 ID | 发数 | 靶子总数 | 被清零的靶子 |
|---|---|---|---|---|
| **对照** | 1 (正确) | 20 | 16000 → 18080 (+104/发) | **0** |
| **实验** | 2 (伪造) | 19 | 16000 → 17969 (+103/发) | **7** (单调递增 1,2,3,3,4,4,4,4,4,5,5,5,6,6,6,7,7,7,7) |

- 对照: 每发 +104 = burst1(40)+burst2(64), /proc 计数与记账**逐发精确吻合** ⇒ 回读零误报
- 实验: 每发仍 +103, 但累计"消失"个靶子逐发爬升 ⇒ 名字是被**清零 len** 打掉的, 不是 bind 失败
- 命中率 ~7/19 ≈ 37%/发
- 用最小越界(10 字节)时**不崩内核**, 整套跑完设备存活; 早期用 14/114 字节那种"大越界"会在
  命中后几发内把内核打崩(受害者不是我们的对象时, 清它 14 字节就够致命)

### 副作用(也是佐证)
被测靶子的 `refcnt` 同样被清零。进程退出时 close() 会对 refcnt=0 递减 ⇒ 内核打
"refcount_t: decrement hit 0; leaking memory" WARN; Android 用户版 panic_on_warn=1
⇒ **设备会在进程退出时重启**。所以演示要用 `hold=1` 让进程挂住不退出。
(反过来说: 这个重启本身证明我们确实清零了受害者头部。)

## 工具 (C:\qemu_test\)
| 文件 | 用途 |
|---|---|
| **uhid_groom6.c** | ★ 本次成功方案: 单 CPU 步进式认领页 + 受控命中, 参数全可调 |
| uhid_groom4.c | 全 CPU 喷射版(8 线程) + 任意 namelen/n1(可切 cache), 未命中但证明"喷射不覆盖页" |
| uhid_t1.c | 时序探针: 证明 probe 异步、write 快速返回、线程会漂 CPU |
| uhid_t2/t3/t4.c | slabinfo 差分工具: t4 带噪声基线, 用于定位"某分配落在哪个 cache" |
| uhid_t5.c | 让 M 个设备卡在 GET_REPORT 使缓冲区常驻, 再差分(受 2s 超时限制, 需在窗口内快照) |
| uhid_flood.c | 原来的 48 设备放大器(注意: 本机有一次它被写成了全 0 文件, 运行前先 `head -c4 \| xxd` 验证 ELF 头) |

## 复现命令
```
adb push C:/qemu_test/uhid_groom6 /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/uhid_groom6
# 对照 (应 0 丢失)
adb shell 'cd /data/local/tmp && ./uhid_groom6 4 20 40 64 200 136 0 100 16000'
# 实验 (应看到 丢失 逐发爬升; 结束时设备会因 refcount WARN 重启)
adb shell 'cd /data/local/tmp && ./uhid_groom6 4 20 40 64 200 136 1 100 16000'
```

## 下一步(方向)
1. **把"清 len"升级成"改 len"**: memset 只能写 0, 所以目前只能清字段。要想利用需选
   "清 0 即变强"的字段: 目标候选 = 同 cache 的 `hid_field` / `unix_address.refcnt` /
   其它 kmalloc-128 对象。控 Rcnt 走 `n2 - 126` 精确选字节区间。
2. **提高命中率**: 靶子密度是唯一瓶颈(受 RLIMIT_NOFILE=32768 限制)。可换更省 fd 的
   kmalloc-128 喷射物(候选: msg_msg 消息体、SO_ATTACH_FILTER 的 bpf_prog、keyring payload),
   目标把命中率从 ~37% 拉到接近 100%。
3. **窗口内逐槽对齐**: burst2 的个数可以按"该页剩余槽位"精确控制(32 槽, 已知 buffer 占 1),
   进一步保证 buffer 的物理邻居就是靶子。
4. 利用 `CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y`(新分配全零)与 `SLAB_FREELIST_HARDENED` 的组合,
   评估"清 freepointer"能不能做成可控的 freelist 攻击(目前 memset 固定写 0, 先验上难)。
