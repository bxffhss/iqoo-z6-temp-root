#!/usr/bin/env python3
"""apk_cert.py —— 从 APK 的 APK Signing Block 里取签名证书并算 SHA-256。

为什么要自己解：这台机器只有 JRE 8，没有 apksigner；而"官方 Manager 能不能被我们 ko 认"
完全取决于**证书哈希**(我们 ko 的 is_manager() 走的是 `ksu_manager_appid == uid % 100000`，
而那个 appid 是加载名单时按 APK 签名块里证书的 SHA-256 认出来的) ⇒ 必须拿到一手数字。

做法：按规范定位签名块(Android CTS / ApkVerifier.java)
    block = [u64 size][ID-value pairs][u64 size][16B magic "APK Sig Block 42"]  紧贴在中央目录之前
    pair  = [u64 len][u32 id][len-4 字节 value]
    v2 id = 0x7109871a   v3 id = 0xf05368c0
然后**在 v2/v3 的 value 里扫 DER 证书**(`30 82 …`)并要求长度自洽 + 内部有可打印字符串。
(先试过按 length-prefixed sequence 一层层走，实测嵌套层数与文档不完全一致 ⇒ 扫 DER 更稳。)

验证方式(双向)：两份官方 APK 必须给出**同一个**哈希；我们自己签的 suw.apk 必须给出**不同**的。
"""
import hashlib
import re
import struct
import sys

MAGIC = b"APK Sig Block 42"
SCHEME_IDS = {0x7109871A: "v2", 0xF05368C0: "v3", 0x1B93AD61: "v3.1", 0x42726577: "v4"}


def signing_pairs(data):
    eocd = data.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise ValueError("找不到 EOCD")
    cd = struct.unpack_from("<I", data, eocd + 16)[0]
    if data[cd - 16:cd] != MAGIC:
        raise ValueError("中央目录前不是 APK Sig Block magic(这份没带 v2/v3 签名块)")
    blk = struct.unpack_from("<Q", data, cd - 24)[0]
    off = cd - 8 - blk + 8
    pairs = {}
    while off + 12 <= cd - 24:
        ln = struct.unpack_from("<Q", data, off)[0]
        pid = struct.unpack_from("<I", data, off + 8)[0]
        pairs[pid] = data[off + 12:off + 8 + ln]
        off += 8 + ln
    return pairs


def looks_like_cert(b):
    if len(b) < 200 or b[0] != 0x30 or b[1] != 0x82:
        return False
    if struct.unpack_from(">H", b, 2)[0] + 4 != len(b):
        return False
    txt = "".join(chr(c) if 32 <= c < 127 else "." for c in b)
    return len(re.findall(r"[A-Za-z0-9 .:/=-]{6,}", txt)) >= 3


def certs(path):
    data = open(path, "rb").read()
    pairs = signing_pairs(data)
    out = {}
    for pid, name in SCHEME_IDS.items():
        v = pairs.get(pid)
        if not v or name == "v4":       # v4 里没有证书
            continue
        o = 0
        while True:
            o = v.find(b"\x30\x82", o)
            if o < 0:
                break
            n = struct.unpack_from(">H", v, o + 2)[0]
            cand = v[o:o + 4 + n]
            if looks_like_cert(cand):
                out[hashlib.sha256(cand).hexdigest()] = name
            o += 2
    return out


def main(argv):
    res = []
    for p in argv:
        try:
            c = certs(p)
        except Exception as e:
            print("%-52s  !! %s" % (p.split("/")[-1][:50], e))
            c = {}
        res.append((p, c))
        print("%-52s  %s" % (p.split("/")[-1][:50], " ".join(sorted(h[:16] for h in c)) or "无"))
        for h, scheme in sorted(c.items()):
            print("      %s  [%s]" % (h, scheme))
    if len(res) >= 2 and res[0][1] and res[1][1]:
        a, b = set(res[0][1]), set(res[1][1])
        print("\n前两份交集: %s" % (sorted(a & b) or "空"))
    if len(res) >= 3:
        a, c = set(res[0][1]), set(res[2][1])
        print("负对照(第 1 份 vs 第 3 份)交集: %s   %s" % (
            sorted(a & c) or "空", "OK(不同 key)" if not (a & c) else "!! 相同 key"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
