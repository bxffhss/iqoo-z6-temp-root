#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""apk_v2_cert.py —— 算 APK 的 **v2 签名证书 SHA256**，用来和 ko 里写死的 KSU_EXPECTED_HASH 比对。
   为什么必须这么算：KernelSU 的 `is_manager_apk()` 读的是 APK Signing Block 里 v2 scheme 的
   第一张证书 DER（不是 v1 的 CERT.RSA、也不是"整个 APK 的 sha256"）⇒ 只有算这个值才可比。
用法：python kmod/apk_v2_cert.py <apk> [<apk> ...]
"""
import sys, struct, hashlib


def read_apk_sign_block(data: bytes) -> bytes:
    # 1) EOCD：从尾部找 \x50\x4b\x05\x06
    i = data.rfind(b"\x50\x4b\x05\x06")
    if i < 0:
        raise SystemExit("找不到 EOCD（不是 zip？）")
    cd_off = struct.unpack_from("<I", data, i + 16)[0]
    # 2) APK Signing Block 紧贴在 CD 之前：末尾 16 字节 magic + 前置 8 字节 size
    magic = b"APK Sig Block 42"
    if data[cd_off - 16:cd_off] != magic:
        raise SystemExit("没有 APK Signing Block（未做 v2 签名？）")
    size = struct.unpack_from("<Q", data, cd_off - 24)[0]
    start = cd_off - 8 - size
    return data[start:cd_off - 8]


def v2_cert(sign_block: bytes) -> bytes:
    # 段格式：[uint64 len][ (uint32 id, value) ... ][uint64 len]
    p = 8
    end = len(sign_block) - 8
    while p < end:
        plen = struct.unpack_from("<Q", sign_block, p)[0]
        p += 8
        pid = struct.unpack_from("<I", sign_block, p)[0]
        val = sign_block[p + 4:p + plen]
        p += plen
        if pid == 0x7109871A:  # APK Signature Scheme v2
            return _first_cert(val)
    raise SystemExit("没有 v2 scheme 块（可能只有 v3/v4）")


def _lp(buf, off):
    """读一个 uint32 长度前缀的片段，返回 (payload, next_off)。"""
    n = struct.unpack_from("<I", buf, off)[0]
    return buf[off + 4:off + 4 + n], off + 4 + n


def _first_cert(v2: bytes) -> bytes:
    signers, _ = _lp(v2, 0)                    # signers（sequence）
    signer, _ = _lp(signers, 0)                # 第一个 signer
    signed_data, off = _lp(signer, 0)
    _sigs, off = _lp(signer, off)              # signatures
    _pk, _off = _lp(signer, off)               # public key
    _digests, o2 = _lp(signed_data, 0)         # digests
    certs, _o3 = _lp(signed_data, o2)          # certificates
    cert, _ = _lp(certs, 0)                    # 第一张证书 DER
    return cert


def main(paths):
    for p in paths:
        try:
            data = open(p, "rb").read()
            blk = read_apk_sign_block(data)
            der = v2_cert(blk)
            print("%-46s v2cert_sha256=%s  (der %d B)" %
                  (p.split("/")[-1].split("\\")[-1], hashlib.sha256(der).hexdigest(), len(der)))
        except SystemExit as e:
            print("%-46s ★失败: %s" % (p, e))
        except Exception as e:
            print("%-46s ★异常: %r" % (p, e))


if __name__ == "__main__":
    main(sys.argv[1:])
