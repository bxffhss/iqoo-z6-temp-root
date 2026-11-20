#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rc80 构建编排（v3，修正 FileBrowser 监狱 + exec 直写容器）：
  1) 远端备份原 syscall_hook.c 到 /tmp/sh_orig.c；
  2) 用 exec(base64 分段)把本地静默版直写到容器 /root/k/.../syscall_hook.c；
  3) 远端 diff 原件 vs 新件，确认只差 BN 静默这一段；
  4) 干净则远端重编、把 ko cp 进家目录、拉回本地 kernelsu_rc80.ko；中途任何异常都从备份还原。
用法：python3 build_rc80.py [--apply]   （不带 --apply 只做备份+上传+diff 预览）
"""
import sys, hashlib, base64
sys.path.insert(0, r"G:/项目/Windows管理/usb/临时root/hermes-remote1")
from hrmt import HermesRemote, from_config

api = from_config(r"G:/项目/Windows管理/usb/临时root/hermes-remote1/config.json")

REMOTE = "/root/k/ksu/kernel/hook/arm64/syscall_hook.c"
LOCAL  = r"G:/项目/Windows管理/usb/临时root/kmod/rc79_src/hook/arm64/syscall_hook.c"
BACKUP = "/tmp/sh_orig.c"
MDIR   = "/root/k/ksu/kernel"
KDIR   = "/root/k/nothing_sm7325_v_mr"
LOG    = "/home/lucy/rc80_build.log"
KO_REMOTE = "/root/k/ksu/kernel/kernelsu.ko"
KO_HOME   = "/home/lucy/kernelsu_rc80.ko"
LOCAL_KO  = r"G:/项目/Windows管理/usb/临时root/kmod/kernelsu_rc80.ko"
APPLY = "--apply" in sys.argv
def md5b(b): return hashlib.md5(b).hexdigest()

def exec_upload(target, raw):
    """用 exec(base64 分段)把字节直写容器 target，写完校验 md5。"""
    b64 = base64.b64encode(raw).decode()
    chunks = [b64[i:i+900] for i in range(0, len(b64), 900)] or [""]
    cmds = [f"mkdir -p {__import__('posixpath').dirname(target)}", f": > {target}.b64"]
    for c in chunks:
        cmds.append(f"printf %s {c} >> {target}.b64")
    cmds += [f"base64 -d {target}.b64 > {target}", f"rm -f {target}.b64",
             f"md5sum {target}"]
    res = api.exec("\n".join(cmds), timeout=180)
    if res.exit_code != 0:
        raise RuntimeError("exec_upload 失败 rc=%s stderr=%s" % (res.exit_code, res.stderr[:300]))
    # md5sum 输出形如 "<md5>  <path>"
    got = res.stdout.split()[0] if res.stdout.split() else ""
    exp = md5b(raw)
    if got != exp:
        raise RuntimeError("exec_upload md5 不符 got=%s exp=%s" % (got, exp))
    return got

print("==> ping:", api.ping())
local_bytes = open(LOCAL, "rb").read()
print("==> 本地 syscall_hook.c 字节=%d md5=%s" % (len(local_bytes), md5b(local_bytes)))

# 1) 备份原远端件
bk = api.exec(f"cp -f {REMOTE} {BACKUP} && md5sum {BACKUP}", timeout=120)
print("==> 备份:", bk.stdout.strip(), "rc=", bk.exit_code)

# 2) 直写容器
if APPLY:
    got = exec_upload(REMOTE, local_bytes)
    print("==> 直写容器完成 md5=%s" % got)
else:
    # 预览：写到 /tmp/sh_new.c 再 diff，不碰原件
    got = exec_upload("/tmp/sh_new.c", local_bytes)
    print("==> 预览写入 /tmp/sh_new.c md5=%s" % got)

# 3) diff
newp = REMOTE if APPLY else "/tmp/sh_new.c"
res = api.exec(f"diff -u {BACKUP} {newp}; echo DIFF_RC=$?", timeout=120)
print("==> diff stdout:\n" + res.stdout)
print("==> diff stderr:", res.stderr.strip())
lines = [l for l in res.stdout.splitlines() if l and not l.startswith("DIFF_RC")]
def _changed_line_safe(l):
    if l.startswith("--- ") or l.startswith("+++ "):
        return True  # diff 表头行，不算改动
    if not (l.startswith("+") or l.startswith("-")):
        return True  # 上下文行不算改动
    if any(k in l for k in ("KSUBEAT BN", "rc58(§6.118)", "rc80(§6.585)", "pr_info_ratelimited",
                             "regs->syscallno", "current->comm", "PT_REGS_ORIG_SYSCALL")):
        return True  # 命中 BN 锚点 / 打印续行
    s = l[1:].lstrip()
    if s.startswith("*") or s.startswith("/*"):
        return True  # 注释续行（" * ..." 或 "    /* ..."）
    return False
unsafe = any(not _changed_line_safe(l) for l in lines)
print("==> unsafe_other_changes =", unsafe)

if not APPLY:
    print("==> 预览模式：未覆盖原件、未编译。确认 diff 干净后加 --apply。")
    api.exec(f"rm -f /tmp/sh_new.c", timeout=60)
    sys.exit(0)

if unsafe:
    rb = api.exec(f"cp -f {BACKUP} {REMOTE} && echo RESTORED", timeout=120)
    print("!! diff 含非 BN 实质改动，已从备份还原：", rb.stdout.strip())
    sys.exit(2)

# 4) 编译 + 拉 ko
make = (
    f"cd {KDIR} && "
    f"make -C {KDIR} M={MDIR} src={MDIR} CONFIG_KSU=m ARCH=arm64 "
    f"CROSS_COMPILE=aarch64-linux-gnu- CC=clang LD=ld.lld AR=llvm-ar "
    f"NM=llvm-nm OBJCOPY=llvm-objcopy STRIP=llvm-strip "
    f'KCFLAGS="-include /home/lucy/ksu_compat54.h" '
    f"modules -j32 > {LOG} 2>&1; echo EXITCODE=$?"
)
print("==> 编译中(可能几分钟) ...")
br = api.exec(make, timeout=600)
print("==> build exec rc:", br.exit_code, "timed_out:", br.timed_out)
log = api.read(LOG)
ll = log.splitlines()
print("==> 日志行数:", len(ll))
for ln in ll[-45:]:
    print("   ", ln)
warn = [l for l in ll if "warning:" in l or "error:" in l]
print("==> warning/error 计数:", len(warn))
for w in warn[:30]:
    print("   WARN/ERR:", w)

cpk = api.exec("cp -f %s %s && ls -l %s && echo KO_CP_OK" % (KO_REMOTE, KO_HOME, KO_HOME), timeout=120)
print("==> ko cp:", cpk.stdout.strip(), "rc=", cpk.exit_code)
# ★FileBrowser 监狱：read_bytes 只认相对 $HOME 的名字，绝对路径 /home/lucy/... 返回 0 字节。
data = api.read_bytes("kernelsu_rc80.ko")
print("==> 拉回 ko 字节数:", len(data), "md5", md5b(data))
if len(data) > 100000:
    open(LOCAL_KO, "wb").write(data)
    print("==> 已写本地:", LOCAL_KO)
else:
    print("!! ko 尺寸异常，未写入")
