#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc52：把 `SET_APP_PROFILE` 成功之后的两笔"碰到别的任务"的动作变成两个独立开关（md §6.99）。

三次一手（第九十六 / 九十八 / 九十九发）：**一个窗口里第一次 `SET_APP_PROFILE` 之后整机静默复位**。
  - 第九十九发把两个混淆变量都清掉了才打的这一发：uts.sysname 已由 rc51 写回 `Linux`
    (`uname -s`=Linux，artd 不再崩溃循环)、三条 CFI 桩已写回出厂值(open/execve 对授权任务可用)，
    而且 ①`@mgr`(flags=0xf, appid=10319) 与 ②`@list`(rc=0) 都正常返回、app 活着 ——
    只有 ②b `@setprof:` 那一步之后机器没了，`/data/local/tmp/dmesg.live` 里连一行 oops 都没有。
  - ⇒ 凶手只能在 `do_set_app_profile()` 成功分支那两笔里，因为它们都不在"当前任务"里干完：
    ① `ksu_persistent_allow_list()`：`get_pid_task(find_vpid(1))` + `task_work_add(init, TWA_RESUME)`
       ⇒ 真正的 `override_creds(ksu_cred)`+`filp_open(/data/adb/ksu/.allowlist)`+`kernel_write`
       是**挂在 PID 1(init) 返回用户态时跑的**；init 死了就是 `Attempted to kill init!` ⇒ 立刻复位，
       而本机 `console=null` + pstore 空 ⇒ 事后一个字都没有(§6.97/§6.98 已经证实)。
    ② `ksu_mark_running_process()`：遍历**所有在跑的任务**写它们的 thread_info 打标。
  - ★为什么"跳过"是诚实的而不是绕过硬伤：**授权判据只看内存里那份 hash**
    (`ksu_get_app_profile()`/`allowed_for_su` 读的都是 `allow_list`)；落盘本来就由 stage 自己
    `cp allow.bin /data/adb/ksu/.allowlist` 做；打标只有走 `setresuid`/`execve` 钩子才需要，
    而我们 args=`ksu_hook_mask=0x0` 一个钩子都不挂 ⇒ 这两笔对本项目的判据零贡献。
  - 想钉死到底是哪一笔：insmod 传 `ksu_ap_persist=1` 或 `ksu_ap_mark=1`(一次只开一个)，
    AP2/AP3 那两行回执会把"挂了但没跑完"和"根本没挂"区分开。

用法：python3 patch_ksu_setprof_gate.py <KSU 源码根目录>      # 幂等
"""
import io
import sys

MARK = "KSUBEAT AP0"
PARAMS = """
/* rc52(md §6.99)：SET_APP_PROFILE 成功之后的两笔"跨任务"动作各一个开关，默认都不做。
 * 判据只依赖内存里的 allow_list，落盘由 stage 自己写文件，打标我们用不上(hook_mask=0x0)。 */
static int ksu_ap_persist;
module_param(ksu_ap_persist, int, 0444);
static int ksu_ap_mark;
module_param(ksu_ap_mark, int, 0444);
"""

OLD = """    ret = ksu_set_app_profile(&cmd.profile);
    if (!ret) {
        ksu_persistent_allow_list();
        ksu_mark_running_process();
    }
    return ret;
"""

NEW = """    pr_info("KSUBEAT AP0 set_app_profile 进入 uid=%d allow=%d ver=%d key=%.64s\\n",
            cmd.profile.curr_uid, cmd.profile.allow_su, cmd.profile.version, cmd.profile.key);
    ret = ksu_set_app_profile(&cmd.profile);
    pr_info("KSUBEAT AP1 ksu_set_app_profile 返回 ret=%d\\n", ret);
    if (!ret) {
        if (ksu_ap_persist) {
            pr_info("KSUBEAT AP2 排队挂给 init 的落盘 task_work\\n");
            ksu_persistent_allow_list();
        } else {
            pr_info("KSUBEAT AP2 跳过 init 落盘 task_work\\n");
        }
        if (ksu_ap_mark) {
            pr_info("KSUBEAT AP3 给所有在跑的任务打标\\n");
            ksu_mark_running_process();
        } else {
            pr_info("KSUBEAT AP3 跳过打标\\n");
        }
        pr_info("KSUBEAT AP4 成功分支处理完，准备返回用户态\\n");
    }
    return ret;
"""


def main():
    root = sys.argv[1].rstrip("/")
    path = root + "/supercall/dispatch.c"
    s = io.open(path, encoding="utf-8").read()
    if MARK in s:
        print("  dispatch.c 已经有 AP 回执(跳过)")
        return 0
    if OLD not in s:
        print("!! dispatch.c 里找不到 do_set_app_profile 的成功分支，别硬改")
        return 1
    s = s.replace(OLD, NEW, 1)
    # 参数定义就插在 do_set_app_profile() 之前 —— 用函数签名当锚点，比"跳过所有注释行"稳。
    ANCHOR = "static int do_set_app_profile(void __user *arg)"
    if ANCHOR not in s:
        print("!! 找不到 do_set_app_profile 的函数签名(参数定义没地方插)")
        return 1
    s = s.replace(ANCHOR, PARAMS.strip("\n") + "\n\n" + ANCHOR, 1)
    io.open(path, "w", encoding="utf-8", newline="\n").write(s)
    print("  dispatch.c 已插 AP0..AP4 + 两个开关")
    print("  校验: AP0=%d AP2=%d ksu_ap_persist=%d" % (s.count("KSUBEAT AP0"),
          s.count("KSUBEAT AP2"), s.count("module_param(ksu_ap_persist")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
