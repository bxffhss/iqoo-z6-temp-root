#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""repack_b8.py —— 从 rc78 备份包重建 z6root.zip（B 线形状）。
   ★为什么要有它：每次手抄那段 python 都要跟 shell 引号打架；而且反复踩过同一个坑：
     新加的件必须进 add 表，只有**旧包里存在**的才进 rep 表（放错就整件丢失 + KeyError）。
   用法：python3 kmod/repack_b8.py [--check]
"""
import os, sys, zipfile, hashlib

ROOT = r"G:/项目/Windows管理/usb/临时root"
BAK = os.path.join(ROOT, "z6root_rc78_bak.zip")
DST = os.path.join(ROOT, "z6root.zip")
TMP = os.path.join(ROOT, "z6root_tmp.zip")

# 旧包里存在的件 → 用仓库里的新版本替换
REPLACE = {
    "z6root/kernelsu.ko": "kmod/kernelsu_rc80.ko",
    "z6root/ksu_args.txt": "kmod/ksu_args.txt",
    # ★B 线必须：z6root.sh 原来在开头 `rm -f $SWITCH_FILES` 里带上了 ksu_two_profiles，
    #   一跑就把 b8_setup 写好的名单删掉（实测落盘变成单条目 Termux）。这里用改过的版本替换。
    "z6root/z6root.sh": "kmod/z6root_b8.sh",
    # ★★这条漏过一次（2026-11-13 02:1x）：`z6root.sh` 真正跑的那份 stage 是包里的 **ksu_post.sh**，
    #   而它原来是从 rc78 旧包逐字带过来的 ⇒ 这一路跑的始终是老 stage：
    #   KEEP_AUTO 不会起、ENT_* 纠正也没有 ⇒ 名单被 cp 成旧单条目。
    #   ⇒ 必须把 kmod/ksu_one_stage.sh（当前源码）作为 ksu_post.sh 打进包。
    "z6root/ksu_post.sh": "kmod/ksu_one_stage.sh",
}
# 新加的件（旧包里没有，必须走 add）
ADD = {
    "z6root/教程.txt": "kmod/pack_b8_tutorial.txt",
    "z6root/run.sh": "kmod/run.sh",
    "z6root/b8_setup.sh": "kmod/b8_setup.sh",
    "z6root/b8_mgr.sh": "kmod/b8_mgr.sh",
    "z6root/b8_keep.sh": "kmod/b8_keep.sh",
    "z6root/b8_pin.sh": "kmod/b8_pin.sh",
    "z6root/b8_verify.sh": "kmod/b8_verify.sh",
    "z6root/b8_su.sh": "kmod/b8_su.sh",
}
# 明确不要的（旧教程已移出包，留档在 kmod/）
DROP = {"z6root/MANIFEST", "z6root/教程.txt", "z6root/教程_rc78_旧版.txt"}
# 必须存在的件（缺任何一个都算构建失败）
MUST = ["z6root/kernelsu.ko", "z6root/ksu_args.txt", "z6root/教程.txt", "z6root/run.sh",
        "z6root/z6root.sh", "z6root/w450_close.sh", "z6root/w625_seedrestart.sh",
        "z6root/b8_setup.sh", "z6root/b8_keep.sh", "z6root/b8_mgr.sh",
        "z6root/b8_pin.sh", "z6root/b8_verify.sh", "z6root/b8_su.sh"]

EXPECT = {"z6root/kernelsu.ko": "98bf405273e8652cdb7fffcc3fe42dc2",
          "z6root/ksu_args.txt": "fec3d301ff5a55a19720477f01dc71d9"}


def main():
    zo = zipfile.ZipFile(BAK)
    old = {i.filename: zo.read(i.filename) for i in zo.infolist() if not i.is_dir()}
    out = []
    for name, data in old.items():
        if name in DROP:
            continue
        if name in REPLACE:
            data = open(os.path.join(ROOT, REPLACE[name]), "rb").read()
        out.append((name, data))
    for dst, src in ADD.items():
        out.append((dst, open(os.path.join(ROOT, src), "rb").read()))

    names = {n for n, _ in out}
    missing = [n for n in MUST if n not in names]
    if missing:
        print("[x] 缺件：", missing, "⇒ 停")
        return 3

    bad = []
    for n, d in out:
        if n in EXPECT:
            got = hashlib.md5(d).hexdigest()
            if got != EXPECT[n]:
                bad.append((n, got, EXPECT[n]))
    if bad:
        print("[x] 关键件 md5 不符：", bad, "⇒ 停")
        return 3

    man = "\n".join("%s %d %s" % (n.split("/", 1)[1], len(d), hashlib.md5(d).hexdigest())
                    for n, d in out) + "\n"
    out.append(("z6root/MANIFEST", man.encode()))

    with zipfile.ZipFile(TMP, "w", zipfile.ZIP_DEFLATED) as z:
        for n, d in out:
            z.writestr(n, d)
    os.replace(TMP, DST)

    z = zipfile.ZipFile(DST)
    fl = [i.filename for i in z.infolist() if not i.is_dir()]
    print("==> 已重建:", DST, os.path.getsize(DST), "字节")
    print("    成员 %d（含 MANIFEST）｜MANIFEST %d 条"
          % (len(fl), len(z.read("z6root/MANIFEST").decode().strip().splitlines())))
    for n in MUST:
        print("    %-28s %s" % (os.path.basename(n), "OK" if n in fl else "★缺"))
    print("    旧教程在包内 =", any("旧版" in n for n in fl))
    return 0


if __name__ == "__main__":
    sys.exit(main())
