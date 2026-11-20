#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc69(#125)：把 selfexec 那块从 **SD1 下游**搬到 **SD1 上游**（第 115 发证过下游那条走不到）。

为什么要有这一版（一手账在 md §6.251/§6.252）：
  - rc68 把调用点插在 `addr/fn = ...` 之后，而那两行在 `SD1`（不在 allow list 就 `goto do_orig_execve`）**之后**
    ⇒ `ksu_selfexec_uid=10104` 不构成通行证，Manager 不在名单里就**根本走不到 SX1**。
  - 第 115 发实测：`SX1_COUNT=0`、Manager 仍 `Seccomp:2`；而且**官方 Manager 压根不在超级用户列表里**
    （搜 `kernelsu` 只命中 `com.lhkernelsu` / `com.rifsxd.ksunext` 两台第三方 fork）
    ⇒ "先在 UI 里给它授权"这条前置**不成立**（它的 `Debug{Su}` 在 ksud 里就被 app 域 seccomp 的 SIGSYS 打死了，
      请求没落到名单 ⇒ 鸡生蛋）。
  - ⇒ 只能让**参数自己当唯一凭据**：命中 `ksu_selfexec_uid` + 尾串就 escape，不看名单。

★热路径代价（诚实写明）：这一版在**每次 execve** 上都会进 `ksu_selfexec_hit()`，所以 helper 内部**必须**是这个顺序：
  `suffix 空→false` ⇒ `uid 不符→false` ⇒ **然后才**第一次读用户内存(`*filename_user` + `strncpy_from_user`)。
  ⇒ 参数不给=**连一次用户内存读都不发生**；给了 uid 也只多两次比较。**默认全关，与 rc68 一样。**
  ★这条不变量是第 115 发之后纠错加上的：**第一版调用点在进入 helper 之前**就算 `untagged_addr(*filename_user)`，
    那等于"默认关也每次 execve 读一次用户内存"，与我当时写进文档的"零成本"**自相矛盾**（账在 md §6.254）。
  ⇒ 所以 helper 的形参是 `const char __user **filename_user`(指针的指针)，不是算好的 `fn`。

锚点唯一性（对着 `w343_sucompat_rc67.c` 数过）：
  参数块 module_param_string(ksu_ksud_path...) = 1
  宿主函数签名 = 1
  ★`    if (!ksu_is_allow_uid_for_current(current_uid().val)) {` 这一句**裸着命中 3 次**（stat 腿里也有），
    所以 SD1 锚点**必须带上它下面那行中文注释**才唯一 ⇒ 本脚本用的是两行合起来的锚点。

用法：python3 patch_ksu_selfexec_pre.py <KSU 源码根>     # 幂等：二跑看到标记就跳过
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
SC = M + "/feature/sucompat.c"

MARK = "rc69(#125) selfexec-pre"

# ---- 锚点 1：参数块（与 rc68 同一族，只在 insmod 那一刻定） ----
A1 = 'module_param_string(ksu_ksud_path, ksu_ksud_path, sizeof(ksu_ksud_path), 0444);'

P1 = A1 + """

/* rc69(#125) selfexec-pre：见文件头。默认全关。 */
static char ksu_selfexec_suffix[128] = "";
module_param_string(ksu_selfexec_suffix, ksu_selfexec_suffix, sizeof(ksu_selfexec_suffix), 0444);
MODULE_PARM_DESC(ksu_selfexec_suffix, "execve 尾串匹配命中 ⇒ 只 escape(清 seccomp)+换 cred，然后**原样**让它 exec 自己这个文件；空=关");

static unsigned int ksu_selfexec_uid;
module_param(ksu_selfexec_uid, uint, 0444);
MODULE_PARM_DESC(ksu_selfexec_uid, "★rc69：这一块在 SD1 上游，所以非 0 时它就是唯一凭据(不看名单)；0=仍要求调用者在 allow list 里");
"""

# ---- 锚点 2：辅助函数插在宿主函数**之外**（插进函数体里就是非法 C，§6.245③ 抓到过） ----
A2 = "static long ksu_handle_execve_sucompat_common(const char __user **filename_user,"

P2_HEAD = """/* rc69(#125) selfexec-pre：命中尾串就返回 true。
 * ★自带 256 字节缓冲：调用者那个 `char path[sizeof(su_path)+1]` 只有 16 字节，libksud 真身路径 ~110 字符
 *   会 -E2BIG（§6.245②）。
 * ★uid 闸：`ksu_selfexec_uid!=0` 时**只认那一个 uid**，且因为这一块在 SD1 上游，这就是唯一凭据；
 *   `==0` 时仍然要求调用者已在 allow list 里（参数给错也不放大权限）。
 * ★顺序：suffix 空→立即 false；uid 不符→立即 false；只有两道闸都过了才去 strncpy_from_user 读路径。 */
static bool ksu_selfexec_hit(const char __user **filename_user)
{
    const char __user *fn;
    char sp[256];
    int n;
    size_t sl;

    if (ksu_selfexec_suffix[0] == '\\0')
        return false;

    if (ksu_selfexec_uid) {
        if (current_uid().val != ksu_selfexec_uid)
            return false;
    } else if (!ksu_is_allow_uid_for_current(current_uid().val)) {
        return false;
    }

    /* ★所有会短路返回的检查都排在**解引用用户指针**之前：这一块现在在 SD1 上游 ⇒ 每次 execve 都会进这里，
     *   参数没给的时候必须真的什么都不做(连 `*filename_user` 都不读)。*/
    fn = (const char __user *)untagged_addr((unsigned long)*filename_user);

    n = strncpy_from_user(sp, fn, sizeof(sp) - 1);
    if (n <= 0)
        return false;
    sp[n] = '\\0';

    sl = strlen(ksu_selfexec_suffix);
    if ((size_t)n < sl)
        return false;
    return memcmp(sp + n - sl, ksu_selfexec_suffix, sl) == 0;
}

"""

# ---- 锚点 3：调用点插在 SD1 **之前**（带注释的那两行才是唯一锚点） ----
A3 = """    if (!ksu_is_allow_uid_for_current(current_uid().val)) {
        /* \u2605这条就是 uid 2000 的死刑"""

P3_INS = """    /* rc69(#125) selfexec-pre：★在 SD1 **上游**，所以命中不要求调用者在名单里。
     * 命中 ⇒ escape(摘 seccomp，按 profile 换 cred)，然后**原样放行**这次 execve(不动 regs/argv/envp)。 */
    if (ksu_selfexec_hit(filename_user)) {
        long sre = escape_with_root_profile();

        pr_info("KSUBEAT SX2 selfexec-pre: suffix=[%s] uid=%u pid=%d escape=%ld\\n",
                ksu_selfexec_suffix, current_uid().val, current->pid, sre);
        goto do_orig_execve;
    }

"""

A4 = MARK  # 只用来检查 escape 那行的存在性(与 rc68 同法)


def main():
    try:
        raw = io.open(SC, "rb").read()
        s = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        print("  !! %s 不是合法 UTF-8(%s) ⇒ 停，不做有损读写" % (SC, e))
        return 2
    orig_bytes = len(raw)

    if MARK in s:
        print("  [skip] %s 已经打过 selfexec-pre 补丁(幂等)，字节数=%d" % (SC, orig_bytes))
        return 0

    for name, a in (("A1(参数块)", A1), ("A2(宿主函数头)", A2), ("A3(SD1 上游锚点)", A3)):
        c = s.count(a)
        if c != 1:
            print("  !! 锚点 %s 命中 %d 次(必须 1) ⇒ **停，别硬改**" % (name, c))
            return 1

    s = s.replace(A1, P1, 1)
    s = s.replace(A2, P2_HEAD + A2, 1)
    s = s.replace(A3, P3_INS + A3, 1)

    if s.count(MARK) != 3:
        print("  !! 标记数=%d(期望 3：参数块 / 辅助函数头注释 / 调用点) ⇒ 停" % s.count(MARK))
        return 1
    # 结构自检：定义在函数外、调用点在 SD1 之前
    if s.count("static bool ksu_selfexec_hit(") != 1:
        print("  !! 辅助函数定义不是 1 份 ⇒ 停"); return 1
    if s.count("KSUBEAT SX2 selfexec-pre") != 1:
        print("  !! 调用点不是 1 份 ⇒ 停"); return 1
    i_call = s.find("KSUBEAT SX2 selfexec-pre")
    i_sd1 = s.find("SD1 decline")
    if not (0 <= i_sd1 and i_call < i_sd1):
        print("  !! 红灯：调用点(%d)不在 SD1(%d) 之前 ⇒ 这一版的意义就没了" % (i_call, i_sd1)); return 1
    # ★每块插入文本**自己**必须花括号平衡(第 115 发之后改 helper 签名时，调用点曾留下过一个多余的 `}`——
    #   标记数/串数都照样对，只有平衡会抓到)
    for nm, blk in (("P1(参数块)", P1), ("P2(辅助函数)", P2_HEAD), ("P3(调用点)", P3_INS)):
        if blk.count("{") != blk.count("}"):
            print("  !! 红灯：%s 花括号不平衡 {%d} %d ⇒ 停" % (nm, blk.count("{"), blk.count("}"))); return 1

    out = s.encode("utf-8")
    io.open(SC, "wb").write(out)
    print("  ok selfexec-pre 补丁已打：字节 %d -> %d，标记 3 处，调用点在 SD1 之前 ✓" % (orig_bytes, len(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
