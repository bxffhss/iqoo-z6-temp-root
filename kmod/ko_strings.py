#!/usr/bin/env python3
"""ko_strings.py —— 在一个 .ko 里按正则刮 .rodata/.text 里的可打印串，用来回答
   "我们这份 ko 认 Manager 到底比不比证书哈希"这类**不该靠猜**的问题。
   用法：python kmod/ko_strings.py kmod/kernelsu_54_rc59.ko
"""
import re
import sys

GROUPS = [
    (rb"weishu|kernelsu|packages\.list|allow\.bin|/data/adb", "包名/路径"),
    (rb"^[0-9a-fA-F]{32,}$", "疑似硬编码哈希(32+ 位 hex)"),
    (rb"(?i)manager", "manager 相关"),
    (rb"(?i)expected|signature|cert|apk|sign", "签名校验相关"),
    (rb"(?i)sha256|hash", "哈希相关"),
    # ★决定性的一条：内核里若出现 APK Signing Block 的 magic，就说明这份 ko **真的在解 APK 签名块**
    #   (即按证书认 Manager)；没有就说明它只看包名/uid。
    (rb"APK Sig Block|apk_sig|0x7109871a|Brew", "APK 签名块 magic(是否真解签名)"),
]


def main(path):
    d = open(path, "rb").read()
    ss = set(re.findall(rb"[ -~]{6,}", d))
    print("== %s  (%d 字节, %d 个可打印串)" % (path, len(d), len(ss)))
    for pat, label in GROUPS:
        hits = sorted(x.decode("utf8", "replace") for x in ss if re.search(pat, x))
        print("--- %s: %d 条" % (label, len(hits)))
        for h in hits[:24]:
            print("   ", h[:130])


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "kmod/kernelsu_54_rc59.ko")
