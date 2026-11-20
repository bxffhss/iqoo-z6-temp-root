# -*- coding: utf-8 -*-
"""#192 专属自测：静态 su 的参数契约。**0 枪**(不 insmod、不开窗)——解析腿排在所有会失败的腿之前，
#   所以 uid=2000 在真件(已 push 的 cm57/sustatic_v5 → /data/local/tmp/suv5)上就能双向验收。
#   每一格都给"期望里必须出现/必须不出现"两组断言(例 174：判据必须双向)，负对照＝
#   ⑧ `-Z <值>` 的那个子参数**必须被吃掉**、不能被当成载荷；⑮ `su -c id` 在没有窗时必须**仍然失败**
#   (这条才是"我一步提权判定都没放宽"的证人，只看解析打印不算)。"""
import subprocess, sys, re

import os
DEV = os.environ.get("SUW_DEV", "/data/local/tmp/suv5")


def sh(remote, t=40):
    """★stderr 必须并进来：那两条"没授权"的证人话本来就打在 stderr 上，
    只看 stdout 会把"没输出"当成"被挡住"——那是例 174/181① 那一族(空读数不是结论)。"""
    env = dict(os.environ)
    env["MSYS_NO_PATHCONV"] = "1"      # ★Git Bash 会把 /data/local/tmp/... 重写成本机路径并谎报成功(环境坑第一条)；闸要自己带这个免疫
    p = subprocess.run(["adb", "shell", remote], capture_output=True, text=True, timeout=t, env=env)
    return ((p.stdout or "") + (p.stderr or "")).replace("\r", "")


def case(name, args, must, mustnot, via_dump=True):
    cmd = (DEV + " --suw-args " + args) if via_dump else (DEV + " " + args)
    out = sh(cmd)
    ok = all(m in out for m in must) and all(m not in out for m in mustnot)
    print("%-4s %s" % ("[OK]" if ok else "[x]", name))
    print("       argv=[%s]" % args)
    for line in out.strip().split("\n")[:5]:
        print("       | " + line[:150])
    if not ok:
        print("       期望出现=%s 期望不出现=%s" % (must, mustnot))
    return ok

# ★被测的是哪一支，必须自己报出来：上一次这里默认指 suv5，我差点把"v5 的行为"读成"v6 的行为"
#   (同形产物并档那一族，例 182)。可选 SUW_EXPECT_MD5＝再钉一道"我测的确实是这一份"。
_md5 = sh("md5sum " + DEV + " 2>&1").strip()
print("被测件 DEV=%s" % DEV)
print("       设备侧 md5: %s" % _md5)
_exp = os.environ.get("SUW_EXPECT_MD5", "")
if _exp and _exp not in _md5:
    print("[x] DEV 的 md5 与期望(%s)不符 ⇒ 未测，别读结论" % _exp)
    sys.exit(2)

r = []
r.append(case("1 只问版本(-v)", "-v", ["version=1", "plan=print-version-and-exit"], ["elevate+"]))
r.append(case("2 只问版本(--version)", "--version", ["version=1"], []))
r.append(case("3 mount-master+载荷", "-M -c id", ["cmd=id", "SUWNOOP -M", "plan=elevate+sh -c <cmd>"], ["SUWUNKNOWN"]))
r.append(case("4 前导 uid", "1000 -c pm", ["req_uid=1000", "cmd=pm", "SUWREQUID"], []))
r.append(case("5 root 当 uid", "root -c id", ["req_uid=0", "cmd=id"], []))
r.append(case("6 裸 su=交互", "", ["plan=elevate+sh(interactive)", "cmd=<none>"], []))
r.append(case("7 -c 没有载荷(负)", "-c", ["bad=-c 后面没有载荷"], ["plan=elevate+sh -c"]))
r.append(case("8 -Z 的值必须被吃(负对照)", "-Z u:r:foo:s0 -c id", ["cmd=id", "SUWNOOP -Z"], ["cmd=u:r:foo:s0"]))
r.append(case("9 认不出的选项不报错", "--bogus -c id", ["SUWUNKNOWN --bogus", "cmd=id"], ["bad=-c"]))
r.append(case("10 多条 no-op 一起给", "-m -w -l -c id", ["SUWNOOP -m", "SUWNOOP -w", "SUWNOOP -l", "cmd=id"], []))
r.append(case("11 非选项当脚本", "/data/local/tmp/x.sh", ["script=/data/local/tmp/x.sh", "plan=elevate+sh <script>"], []))
r.append(case("12 载荷后面的选项不抢 cmd", "-c id -M", ["cmd=id", "SUWNOOP -M"], ["cmd=-M"]))
r.append(case("13 -s 的值必须被吃", "-s /system/bin/sh -c id", ["cmd=id", "SUWNOOP -s"], ["cmd=/system/bin/sh"]))
# v6(#210)：`su <uid> <command...>` 是 AOSP su 的形状(`su 0 chown ...`)——旧形状把 `id` 当脚本文件，
#   一手＝§6.451 的 `sh: id: No such file or directory`。这两格是"补上的那一格"的期望值。
r.append(case("17 uid 前缀+单词命令", "0 id", ["req_uid=0", "cmd=id", "joined=1", "plan=elevate+sh -c <cmd>"], ["script=id"]))
r.append(case("18 uid 前缀+多词命令(拼一条)", "0 ls -l /data/local/tmp/kd", ["req_uid=0", "cmd=ls -l /data/local/tmp/kd", "joined=3"], ["script=<bad>"]))
# 负对照：没有前导 uid 时**不许**把非选项升格成命令——旧"脚本文件"形状交付腿还在用(=case 11 的另一面)
r.append(case("19 无 uid 时非选项仍走脚本(负对照)", "/data/local/tmp/y.sh extra", ["script=/data/local/tmp/y.sh", "cmd=<none>", "plan=elevate+sh <script>"], ["req_uid=0"]))

# ⑭ 真跑 `-v`：应当直接回版本串、rc=0，且**不该**去碰驱动 fd／agent(那两条报错一条都不许出现)
out = sh(DEV + " -v")
ok = ("suw-su" in out and "@" + "suwshd" not in out and "既没有" not in out)
print("%-4s 14 真跑 su -v 早退(不碰提权那条链)" % ("[OK]" if ok else "[x]"))
print("       | " + out.strip().replace("\n", " | ")[:170])
r.append(ok)

# ⑮ 真跑 `su -c id`：**必须仍然失败**(没窗＝没授权通道)——这条是"参数契约没把闸门放宽"的证人
out = sh(DEV + " -c id")
ok = ("uid=0" not in out) and ("提权失败" in out or "既没有" in out or "agent 拒绝" in out)
print("%-4s 15 真跑 su -c id 在没有窗时仍被挡(负对照)" % ("[OK]" if ok else "[x]"))
print("       | " + out.strip().replace("\n", " | ")[:170])
r.append(ok)

# ⑯ 旧的 --suw-dump 形状不能被改坏(交付文案里有别的腿在用它)
out = sh(DEV + " --suw-dump")
ok = out.startswith("su(suw) uid=2000")
print("%-4s 16 --suw-dump 未回归" % ("[OK]" if ok else "[x]"))
print("       | " + out.strip()[:150])
r.append(ok)

print("\n合计 %d 格，通过 %d 格" % (len(r), sum(1 for x in r if x)))
sys.exit(0 if all(r) else 1)
