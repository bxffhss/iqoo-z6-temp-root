#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc68(#125)：给 execve 改道加一条**尾串匹配 + 自再执行**的规则，默认关。

一手依据(§6.231 / §6.244，第 107、114 发)：
  官方 Manager v3.3.0 的 root 动作不是 exec `/system/bin/su`，而是 **exec APK 自带的 `libksud.so`**
  (logcat 里它自己会打 `ksud::cli: command: Module { command: List }` / `Debug { command: Su {…} }`)。
  不提权的动词能跑；**需要 su 握手那一支调 `reboot(142)`，被 app 域 seccomp 直接 SIGSYS 打死**(Permissive 同样死)。
  Manager 进程 `NoNewPrivs:0 / Seccomp:2` ⇒ 在 execve 之前把 seccomp 摘掉是可行的。

为什么这条形状比"再做一个 shim"干净：目标是 **app 自己的 native lib** ⇒ 不需要 `apk_data_file`/plain `s0`/
`execute_no_trans` 那一整套共享落点的脆弱性(#113/#114 那两格就是为共享落点付的代价)。做法是
**escape 之后原样放行它自己要 exec 的那个文件**(filename/argv/envp 全不动)。

两处必须写对的细节(都在远端真树上核过，行号按 Oct 10 那份 25,271 字节的文件)：
 ① `char path[sizeof(su_path) + 1]` 只有 16 字节，而 libksud 的真身路径
   `/data/app/~~<随机>==/me.weishu.kernelsu-<随机>==/lib/arm64/libksud.so` 有 ~110 字符 ⇒
   `strncpy_from_user(path, fn, sizeof(path))` 对它会返回 **-E2BIG**，代码在 SD2 那格就 `goto` 掉了。
   ⇒ 尾串匹配**必须在 SD2 之前**做，并且**自带一个大缓冲**，不能复用 `path`。
 ② SD1 那格先问 `ksu_is_allow_uid_for_current()`：Manager(uid 10104) 默认不在名单里 ⇒ 连路径都不会读。
   ⇒ 参数 `ksu_selfexec_uid`：给了就只认这个 uid(把 Manager 指进来)；**不给(=0)就仍要求"在 allow list 里"**，
     这样默认形状与 rc67 逐字相同，不会因为开了尾串就顺手放宽任何鉴权。

参数(全部只在 insmod 那一刻定——本 ko 的 init 里 kobject_del 了 /sys/module/kernelsu，§6.202)：
  ksu_selfexec_suffix=libksud.so   默认空串 = **关**(负对照就是不给这个参数)
  ksu_selfexec_uid=10104           默认 0 = 不额外放行任何 uid

用法：python3 patch_ksu_selfexec.py <KSU 源码根>     # 幂等：二跑检测到标记就跳过
"""
import io
import sys

M = sys.argv[1] if len(sys.argv) > 1 else "/root/k/ksu/kernel"
SC = M + "/feature/sucompat.c"

MARK = "rc68(#125) selfexec"

# ---- 锚点 1：参数块。挂在既有 ksu_ksud_path 那行 module_param_string 之后(同一个"insmod 时定"的家族) ----
A1 = 'module_param_string(ksu_ksud_path, ksu_ksud_path, sizeof(ksu_ksud_path), 0444);'

P1 = A1 + """

/* rc68(#125) selfexec：见文件头。默认全关。 */
static char ksu_selfexec_suffix[128] = "";
module_param_string(ksu_selfexec_suffix, ksu_selfexec_suffix, sizeof(ksu_selfexec_suffix), 0444);
MODULE_PARM_DESC(ksu_selfexec_suffix, "execve 尾串匹配命中 ⇒ 只 escape(清 seccomp)+换 cred，然后**原样**让它 exec 自己这个文件；空=关");

static unsigned int ksu_selfexec_uid;
module_param(ksu_selfexec_uid, uint, 0444);
MODULE_PARM_DESC(ksu_selfexec_uid, "0=只对已在 allow list 里的 uid 生效；非 0=只认这一个 uid(用来指官方 Manager)");
"""

# ---- 锚点 2：辅助函数**必须插在宿主函数之外**(插在函数体内就是非法 C，dry-run 时抓到过) ----
A2 = "static long ksu_handle_execve_sucompat_common(const char __user **filename_user,"

P2_HEAD = """/* rc68(#125) selfexec：命中尾串就返回 true。
 * ★不能复用调用者那个 `char path[sizeof(su_path)+1]`(只有 16 字节)：libksud 的真身路径 ~110 字符，
 *   `strncpy_from_user` 对它会返 -E2BIG，SD2 那格就先 goto 掉了 ⇒ 这里自带 256 字节缓冲。
 * ★uid 闸：`ksu_selfexec_uid==0` 时**仍然要求**调用者已在 allow list 里(SD1 已经查过一遍，这里再查一次
 *   是为了"参数给错也不放大权限")；给了 uid 就只认那一个。 */
static bool ksu_selfexec_hit(const char __user *fn)
{
    char sp[256];
    int n;
    size_t sl;

    if (ksu_selfexec_suffix[0] == '\\0')
        return false;

    if (ksu_selfexec_uid && current_uid().val != ksu_selfexec_uid)
        return false;
    if (!ksu_selfexec_uid && !ksu_is_allow_uid_for_current(current_uid().val))
        return false;

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

# ---- 锚点 3：调用点(在宿主函数体内，只加语句、不加定义) ----
A3 = """    addr = untagged_addr((unsigned long)*filename_user);
    fn = (const char __user *)addr;
    memset(path, 0, sizeof(path));
"""

P3_BODY = """    addr = untagged_addr((unsigned long)*filename_user);
    fn = (const char __user *)addr;

    /* rc68(#125) selfexec：命中 ⇒ 摘 seccomp(+换 cred)，然后**原样放行**这次 execve(不动 regs)。 */
    if (ksu_selfexec_hit(fn)) {
        long sre = escape_with_root_profile();

        pr_info("KSUBEAT SX1 selfexec: suffix=[%s] uid=%u pid=%d escape=%ld\\n",
                ksu_selfexec_suffix, current_uid().val, current->pid, sre);
        goto do_orig_execve;
    }

    memset(path, 0, sizeof(path));
"""

# ---- 锚点 4：escape_with_root_profile 的声明必须在上面那个函数之前可见；顺带确认它存在 ----
A4 = "escape_with_root_profile();"


def main():
    raw = io.open(SC, "rb").read()
    try:
        s = raw.decode("utf-8")            # ★严格解：解不动就**停**，不用 errors="replace"(那会把非法字节写成 U+FFFD，等于毁源码)
    except UnicodeDecodeError as e:
        print("  !! %s 不是合法 UTF-8(%s) ⇒ 停，不做有损读写" % (SC, e))
        return 2
    orig_bytes = len(raw)

    if MARK in s:
        print("  [skip] %s 已经打过 selfexec 补丁(幂等)，字节数=%d" % (SC, orig_bytes))
        return 0

    for name, a in (("A1(参数块)", A1), ("A2(宿主函数头)", A2),
                    ("A3(调用点)", A3), ("A4(escape 存在)", A4)):
        c = s.count(a)
        if c != 1:
            print("  !! 锚点 %s 命中 %d 次(必须 1 次) ⇒ **停，别硬改**" % (name, c))
            return 1

    s = s.replace(A1, P1, 1)
    s = s.replace(A2, P2_HEAD + A2, 1)     # 函数定义插在宿主函数**之外**(它前面)
    s = s.replace(A3, P3_BODY, 1)          # 调用点只加语句

    if s.count(MARK) != 3:
        print("  !! 标记数=%d(期望 3：参数块 / 辅助函数 / 调用点各一处) ⇒ 停" % s.count(MARK))
        return 1

    out = s.encode("utf-8")
    io.open(SC, "wb").write(out)
    print("  ok selfexec 补丁已打：字节 %d -> %d，标记 3 处" % (orig_bytes, len(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
