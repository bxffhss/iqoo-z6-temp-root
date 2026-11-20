#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w822_gen_rc74c_build.py —— 从 kmod/remote_ksu_rc74b.sh **逐锚点派生**出 rc74c 的构建脚本。
   为什么生成而不是手抄：rc74b 那份 341 行里有几十条"怎么才算比过"的闸(串集对表/段尺寸指认/新符号白名单)，
   手抄一定会漏，而漏掉的闸是静默的(例 173④)。这里只做**带断言的定点替换**：任何一条锚不唯一 ⇒ 整个文件不写。
   用法：python3 kmod/w822_gen_rc74c_build.py <w820的md5> <w821的md5>
"""
import hashlib
import io
import sys

SRC = "kmod/remote_ksu_rc74b.sh"
DST = "kmod/remote_ksu_rc74c.sh"
M820 = sys.argv[1] if len(sys.argv) > 1 else "?"
M821 = sys.argv[2] if len(sys.argv) > 2 else "?"

s = io.open(SRC, encoding="utf-8").read()
n = 0


def rep(old, new, label, count=1):
    """带断言的定点替换：锚必须恰好命中 count 次，替换后新文案在、旧文案不在(除显式保留)。"""
    global s, n
    got = s.count(old)
    if got != count:
        print("[x] 锚命中 %d 次(要 %d) ⇒ %s ⇒ **整个文件不写**" % (got, count, label))
        sys.exit(1)
    s = s.replace(old, new)
    n += 1
    print("  [%02d] %s" % (n, label))


HDR = """# rc74c = **rc74b ＋ 第 56 发一手逼出来的两半修法**(md §6.429/§6.430)
#   一手(第 56 发)：`total=64`(满) ＋ `KSUBIRTH cap … refusing more birth fds this boot` 5.2 秒内 1203 行
#     ＋ 当前 Manager `pid=13767` **`fd_ksu=0`** ⇒ 牌子掉 `不支持`，而同一时刻 `su -c` 仍 `uid=0`(用户那句"灭时 su 仍可用")。
#     烧预算的是 `libksud.so`：它是领头、uid 也是 10104，但它**脱离了父进程** ⇒ rc74b 那条"`real_parent` 同 uid 就当子进程挡掉"
#     抓不到它；而且一出生就被 app 域 seccomp 打死(`SIGSYS syscall 142`)，`crash_dump64` 起来收尸 ⇒ 又占一格。
#   这一版改两半(补丁件 `kmod/w820_add_birthfd3.py`，接在 w689 之后打)：
#     A) **helper 名单**：`comm ∈ {libksud.so, crash_dump64, debuggerd64}` ⇒ 不装 fd(返回码 7，每 256 次一条证人)。
#        ★`usap64` 故意**不进名单**——第 51 发实测主进程排队时 comm 就是它；判定函数放在 PURE 区里，宿主测试原样抠走。
#     B) **上限换形状**：`cap` 64→4096(累计闸不再是"十几分钟就烧光"的量级) ＋ 新参数 `ksu_mgr_birth_rate`(默认 8，
#        每 1 秒窗口的放行数；返回码 8)。理由：要防的是"崩溃循环刷分配"，那是**速率**问题，不是**累计**问题。
#   ★单变量：只动那一段(hook/allowlist/sucompat/护栏/那五条 args 全不动)。`ksu_args.txt` 一个字不改。
#   ★逻辑闸换成 `kmod/w821_birth_test3.py`(26 格真值表，含两条靶子：同一条输入只差 comm ⇒ 7 vs 1；
#     65 个不同 pid 在 cap=64 下第 65 个必须 6、在 cap=4096 下必须 1)——**它抠的是打完补丁的 dev_syms.c 原文**。
"""

rep("# rc74b = **rc73 + 那块「Manager 出生即装驱动 fd」的修正版(§6.413 编、§6.414 第 50 发判正并抓到缺陷、本节就是修法)**\n",
    HDR + "# （下面这段是 rc74b 的原说明，保留作来源：rc74b = rc73 + 出生即装的修正版）\n",
    "头部换成 rc74c 的来龙去脉(原文保留)")
rep("LOG=/home/lucy/ksu_rc74b.log", "LOG=/home/lucy/ksu_rc74c.log", "日志路径")
rep('MD5_TESTPY=0142b3cd32acf33f482b3e18333f17c3        # 本地 kmod/w691_birth_test.py(把纯判定函数抠到宿主上跑真值表)',
    'MD5_TESTPY=%s        # 本地 kmod/w821_birth_test3.py(rc74c 的 26 格真值表，抠 dev_syms.c 原文)\n'
    'MD5_BIRTH3PY=%s   # 本地 kmod/w820_add_birthfd3.py(rc74b→rc74c 的补丁件)\n' % (M821, M820),
    "换上传件 md5(w821 替 w691，加 w820)")

SEC2E2 = """echo; echo "=== 2e2) ★rc74c：helper 名单 ＋ 上限换成速率(接在 w689 之后打，先核上传件 md5) ==="
[ -f /home/lucy/w820_add_birthfd3.py ] || { echo "  !! 没有 /home/lucy/w820_add_birthfd3.py ⇒ 停"; exit 1; }
[ "$(md5sum /home/lucy/w820_add_birthfd3.py | cut -d' ' -f1)" = "$MD5_BIRTH3PY" ] \\
    || { echo "  !! 红灯：w820 上传件 md5 不等于预期 ⇒ 停(别打一份说不出来源的补丁)"; exit 1; }
python3 /home/lucy/w820_add_birthfd3.py "$M" || { echo "  !! 红灯：rc74c 补丁自己退了非 0 ⇒ 停"; exit 1; }
echo "  打完读回：dev_syms=$(md5sum "$DS" | cut -d' ' -f1)"
echo "  现数：helper 证人=$(grep -ac 'KSUBIRTH helper n=' "$DS") 速率证人=$(grep -ac 'KSUBIRTH rate n=' "$DS") 参数=$(grep -ac 'module_param(ksu_mgr_birth' "$DS")(rc74c 应有 fd+cap+rate 三个) cap 默认=$(grep -ac 'ksu_mgr_birth_cap = 4096' "$DS")"
[ "$(grep -ac 'KSUBIRTH helper n=' "$DS")" = "1" ] || { echo "  !! 红灯：helper 证人不在或重复 ⇒ 停"; exit 1; }
[ "$(grep -ac 'KSUBIRTH rate n=' "$DS")" = "1" ] || { echo "  !! 红灯：速率证人不在或重复 ⇒ 停"; exit 1; }
[ "$(grep -ac 'module_param(ksu_mgr_birth' "$DS")" = "3" ] || { echo "  !! 红灯：模块参数不是 fd+cap+rate 三个 ⇒ 停"; exit 1; }
[ "$(grep -ac 'ksu_mgr_birth_cap = 4096' "$DS")" = "1" ] || { echo "  !! 红灯：cap 默认值没换成 4096 ⇒ 停"; exit 1; }
# ★usap64 不许进 helper 名单(第 51 发：主进程排队时 comm 就是它)——这条闸读的是**源码里那张表本身**
if sed -n '/ksu_birth_helper_tbl\\[\\] = {/,/};/p' "$DS" | grep -aq 'usap64'; then
    echo "  !! 红灯：helper 名单里有 usap64 ⇒ 会把要保护的那个主进程挡掉，停"; exit 1
fi
echo "  helper 名单现数：$(sed -n '/ksu_birth_helper_tbl\\[\\] = {/,/};/p' "$DS" | grep -ao '"[a-z0-9_.]*"' | tr '\\n' ' ')(不许有 usap64)"
BN3=$(sed -n '/rc74c(md 6.429)/,$p' "$DS" | grep -ac 'GFP_KERNEL')
echo "  rc74c 新增段里 GFP_KERNEL=$BN3(必须 0：probe 在 preempt-disabled 里)"
[ "$BN3" = "0" ] || { echo "  !! 红灯：新增段里有 GFP_KERNEL ⇒ 停"; exit 1; }

"""
rep('echo; echo "=== 2f) ★改动 2：把纯判定函数抠到宿主上跑真值表(编 ko 之前，跑不过就别浪费时间编) ==="',
    SEC2E2 + 'echo; echo "=== 2f) ★rc74c：把纯判定函数抠到宿主上跑真值表(编 ko 之前，跑不过就别浪费时间编) ==="',
    "插入 2e2 段(w820 补丁＋六条读回)并改 2f 标题")
rep("[ -f /home/lucy/w691_birth_test.py ] || { echo \"  !! 没有 /home/lucy/w691_birth_test.py ⇒ 停\"; exit 1; }",
    "[ -f /home/lucy/w821_birth_test3.py ] || { echo \"  !! 没有 /home/lucy/w821_birth_test3.py ⇒ 停\"; exit 1; }",
    "2f：宿主测试换成 w821(文件存在性)")
rep('[ "$(md5sum /home/lucy/w691_birth_test.py | cut -d\' \' -f1)" = "$MD5_TESTPY" ] \\\n    || { echo "  !! 红灯：w691 上传件 md5 不等于 0142b3cd ⇒ 停"; exit 1; }',
    '[ "$(md5sum /home/lucy/w821_birth_test3.py | cut -d\' \' -f1)" = "$MD5_TESTPY" ] \\\n    || { echo "  !! 红灯：w821 上传件 md5 不对 ⇒ 停"; exit 1; }',
    "2f：md5 比对换成 w821")
rep('python3 /home/lucy/w691_birth_test.py "$DS"; TRC=$?',
    'python3 /home/lucy/w821_birth_test3.py "$DS"; TRC=$?', "2f：跑 w821")
# ★★注意位置：rc74b 那句"模块参数=fd+cap 两个"的断言跑在 **w689 之后、w820 之前** ⇒ 那时确实还是 2 个，
#    把它改成 3 就是我自己把闸拧错地方(远端第一次构建就是被这条红灯停住的：2e 段还没到 2e2)。
#    "三个参数(fd+cap+rate)"的断言在 2e2 段里，那才是 w820 打过之后的正确位置。
rep("for t in 'KSUBIRTH seen Manager' 'KSUBIRTH queued self fd' 'KSUBIRTH dupskip n=' 'KSUBIRTH childskip n=' 'KSUBIRTH cap total=' 'KSUBIRTH kzalloc(ATOMIC) failed' 'ksu_mgr_birth_cap'; do",
    "for t in 'KSUBIRTH seen Manager' 'KSUBIRTH queued self fd' 'KSUBIRTH dupskip n=' 'KSUBIRTH childskip n=' 'KSUBIRTH cap total=' 'KSUBIRTH kzalloc(ATOMIC) failed' 'ksu_mgr_birth_cap' 'KSUBIRTH helper n=' 'KSUBIRTH rate n=' 'ksu_mgr_birth_rate'; do",
    "第 5 节：逐条点名的证人串加上 helper/rate 三条")
rep("for want in ksu_mgr_birth_check ksu_mgr_birth_fd ksu_mgr_birth_cap ksu_birth_ring ksu_fd_install_self_tw; do",
    "for want in ksu_mgr_birth_check ksu_mgr_birth_fd ksu_mgr_birth_cap ksu_mgr_birth_rate ksu_birth_ring ksu_fd_install_self_tw; do",
    "第 5 节：新符号必须包含 ksu_mgr_birth_rate")
rep('cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc74b.ko && md5sum /home/lucy/kernelsu_rc74b.ko',
    'cp "$M/kernelsu.ko" /home/lucy/kernelsu_rc74c.ko && md5sum /home/lucy/kernelsu_rc74c.ko',
    "产物改名 kernelsu_rc74c.ko")
rep('ls -l /home/lucy/kernelsu_rc73.ko /home/lucy/kernelsu_rc74.ko /home/lucy/kernelsu_rc74b.ko 2>/dev/null',
    'ls -l /home/lucy/kernelsu_rc73.ko /home/lucy/kernelsu_rc74.ko /home/lucy/kernelsu_rc74b.ko /home/lucy/kernelsu_rc74c.ko 2>/dev/null',
    "末尾 ls 加上 rc74c")
rep('echo "START(rc74b) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"',
    'echo "START(rc74c) $(date)  目标 version=$WANT_VER uapi=$WANT_UAPI"', "START 横幅")

# ── rc74c 需要的两条派生规则(第一次构建就是被这两处卡住的) ────────────────────
# ①串集白名单：helper 名单里的字面量是**这次新代码自己的串**，但 explain() 的"标识符白名单"只认裸标识符，
#   `libksud.so` 带点过不了 ⇒ 白名单里补上这三条(其余任何新串仍然要停)。
rep("manager_identity|",
    "manager_identity|libksud[.]so|crash_dump64|debuggerd64|helper_tbl|",
    "串集白名单补上 helper 名单的字面量")
# ②那句解释文字别说谎：rc74c 是 fd+cap+rate 三个参数。
rep("本发多 fd+cap 两个参数 => 应当严格更大".replace("fd+cap","fd＋cap").replace("=>","⇒"),
    "rc74c 有 fd＋cap＋rate 三个参数 ⇒ 应当严格更大",
    "__param 那句解释改成三个参数")

io.open(DST, "w", encoding="utf-8", newline="\n").write(s)
print("写了 %s（%d 处锚点替换，行数=%d）" % (DST, n, s.count("\n") + 1))
for k in ("w820_add_birthfd3.py", "w821_birth_test3.py", "kernelsu_rc74c.ko", "ksu_mgr_birth_rate", "KSUBIRTH helper n="):
    print("  复证 %s 出现 %d 次" % (k, s.count(k)))
