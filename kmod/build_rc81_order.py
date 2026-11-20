#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc81_order 构建：把"是不是 su"的判定提到"允不允许"之前（单变量）。
   依据（账本）：decline 段速率 >~1 次/秒 ⇒ 13~20s 硬复位；0.2 次/秒 ⇒ 活过 1384s（§6.605/6g）。
   现状：sucompat.c:283 先跑 ksu_is_allow_uid_for_current()，:296 才读文件名
        ⇒ **每一次 execve**（不管是不是 su）都进 decline 段，38 次/秒 全由无关 execve 贡献。
   本脚本只做：备份 → 在 filename_user 判空之后、允许判定之前**插入**一段名字预判 → 编译 → 拉 ko → 还原源码。
   ★不改任何既有行；不碰交付件 rc80；失败自动从备份还原。
用法：python3 build_rc81_order.py [--apply]
"""
import sys, hashlib, base64, posixpath
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")
REMOTE = "/root/k/ksu/kernel/feature/sucompat.c"
BASE_MD5 = "0a305171e7b5b1bb338862ee9639e974"
BACKUP = "/tmp/sucompat_orig_rc81.c"
MDIR = "/root/k/ksu/kernel"
KDIR = "/root/k/nothing_sm7325_v_mr"
LOG = "/home/lucy/rc81_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_HOME = "/home/lucy/kernelsu_rc81_order.ko"
LOCAL_KO = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_rc81_order.ko"
APPLY = "--apply" in sys.argv

ANCHOR = """    if (!ksu_is_allow_uid_for_current(current_uid().val)) {
        /* \u2605\u8fd9\u6761\u5c31\u662f uid 2000 \u7684\u6b7b\u5211"""

INSERT = """    /* \u2605rc81_order\uff1a\u628a"\u662f\u4e0d\u662f su"\u63d0\u5230"\u5141\u4e0d\u5141\u8bb8"\u4e4b\u524d\u3002
     *   \u8d26\u672c\u5df2\u8bc1\uff1adecline \u6bb5 >~1 \u6b21/\u79d2 \u5c31\u5728 13~20 s \u5185\u786c\u590d\u4f4d\uff0c0.2 \u6b21/\u79d2 \u6d3b\u8fc7 1384 s\u3002
     *   \u539f\u987a\u5e8f\u5bf9**\u6bcf\u4e00\u6b21 execve** \u90fd\u5148\u8dd1\u5141\u8bb8\u5224\u5b9a \u21d2 38 \u6b21/\u79d2 \u5168\u662f\u65e0\u5173 execve \u8d21\u732e\u7684\u3002
     *   \u51b3\u7b56\u7b49\u4ef7\uff1a\u4e0d\u662f su \u7684 execve \u4e24\u6761\u987a\u5e8f\u90fd\u843d orig\uff1b\u662f su \u7684\u5224\u5b9a\u4e00\u5b57\u672a\u6539\u3002
     *   \u4ee3\u4ef7\uff1a\u6bcf\u6b21 execve \u591a\u4e00\u6b21 15 \u5b57\u8282\u7684 strncpy_from_user\uff08\u539f\u6765\u4e5f\u6709\uff0c\u53ea\u662f\u6392\u5728\u540e\u9762\uff09\u3002 */
    {
        unsigned long rc81_addr = untagged_addr((unsigned long)*filename_user);
        long rc81_ret;

        memset(path, 0, sizeof(path));
        rc81_ret = strncpy_from_user(path, (const char __user *)rc81_addr, sizeof(path));
        if (rc81_ret < 0)
            goto do_orig_execve;
        if (likely(memcmp(path, su_path, sizeof(su_path))))
            goto do_orig_execve;
    }

"""

def md5b(b):
    return hashlib.md5(b).hexdigest()

def exec_upload(target, raw):
    b64 = base64.b64encode(raw).decode()
    chunks = [b64[i:i + 900] for i in range(0, len(b64), 900)] or [""]
    cmds = ["mkdir -p %s" % posixpath.dirname(target), ": > %s.b64" % target]
    for c in chunks:
        cmds.append("printf %%s %s >> %s.b64" % (c, target))
    cmds += ["base64 -d %s.b64 > %s" % (target, target), "rm -f %s.b64" % target, "md5sum %s" % target]
    res = api.exec("\n".join(cmds), timeout=180)
    if res.exit_code != 0:
        raise RuntimeError("upload rc=%s %s" % (res.exit_code, res.stderr[:300]))
    got = res.stdout.split()[0] if res.stdout.split() else ""
    if got != md5b(raw):
        raise RuntimeError("upload md5 不符 got=%s" % got)
    return got

print("==> ping:", "ok" if api.ping() else "FAIL")

# 1) 备份 + 基线校验
bk = api.exec("cp -f %s %s && md5sum %s" % (REMOTE, BACKUP, BACKUP), timeout=120)
print("==> 备份:", bk.stdout.strip(), "rc=", bk.exit_code)
if BASE_MD5 not in bk.stdout:
    print("[x] 远端基线 md5 不是 %s ⇒ 停（别在未知基线上改）" % BASE_MD5)
    sys.exit(3)

# 2) 取原文
orig = api.exec("cat %s" % REMOTE, timeout=120).stdout
if orig.count(ANCHOR) != 1:
    print("[x] 锚点出现 %d 次（要求 1）⇒ 停" % orig.count(ANCHOR))
    sys.exit(3)
new = orig.replace(ANCHOR, INSERT + ANCHOR, 1)
print("==> 原文 %d 字节 → 新文 %d 字节（+%d）" % (len(orig.encode()), len(new.encode()),
                                                 len(new.encode()) - len(orig.encode())))

if not APPLY:
    open(r"G:/项目/Windows管理/usb/临时root/kmod/rc81_sucompat_preview.c", "w", encoding="utf-8").write(new)
    print("==> 预览模式：已写 kmod/rc81_sucompat_preview.c，未上传、未编译")
    sys.exit(0)

# 3) 上传 + diff
got = exec_upload(REMOTE, new.encode())
print("==> 已写入远端 md5=%s" % got)
d = api.exec("diff -u %s %s; echo DIFF_RC=$?" % (BACKUP, REMOTE), timeout=120)
print("==> diff:\n" + d.stdout)
adds = [l for l in d.stdout.splitlines() if l.startswith("+") and not l.startswith("+++")]
dels = [l for l in d.stdout.splitlines() if l.startswith("-") and not l.startswith("---")]
print("==> 新增行=%d 删除行=%d（删除必须为 0）" % (len(adds), len(dels)))
if dels:
    api.exec("cp -f %s %s && echo RESTORED" % (BACKUP, REMOTE), timeout=120)
    print("!! 有删除行 ⇒ 已还原，停")
    sys.exit(2)

# 4) 编译
make = ("cd %s && make -C %s M=%s src=%s CONFIG_KSU=m ARCH=arm64 "
        "CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar "
        "NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip "
        'KCFLAGS="-include /home/lucy/ksu_compat54.h" '
        "modules -j32 > %s 2>&1; echo EXITCODE=$?") % (KDIR, KDIR, MDIR, MDIR, LOG)
print("==> 编译中 ...")
br = api.exec(make, timeout=900)
print("==> build rc:", br.exit_code, "timed_out:", br.timed_out, br.stdout.strip()[-40:])
log = api.read(LOG)
ll = log.splitlines()
we = [l for l in ll if "error:" in l or "warning:" in l]
print("==> 日志行数 %d，error/warning %d" % (len(ll), len(we)))
for w in we[:15]:
    print("   ", w)
for ln in ll[-12:]:
    print("   ", ln)

# 5) 拉 ko
cpk = api.exec("cp -f %s %s && ls -l %s" % (KO_REMOTE, KO_HOME, KO_HOME), timeout=120)
print("==> ko cp:", cpk.stdout.strip())
data = api.read_bytes("kernelsu_rc81_order.ko")
print("==> 拉回字节=%d md5=%s" % (len(data), md5b(data)))
if len(data) > 100000:
    open(LOCAL_KO, "wb").write(data)
    print("==> 已写:", LOCAL_KO)
else:
    print("!! 尺寸异常，未写入")

# 6) 无条件还原远端源码并复证
rb = api.exec("cp -f %s %s && md5sum %s" % (BACKUP, REMOTE, REMOTE), timeout=120)
print("==> 还原:", rb.stdout.strip())
print("==> 还原复证:", "OK" if BASE_MD5 in rb.stdout else "★不 OK，人工处理")
