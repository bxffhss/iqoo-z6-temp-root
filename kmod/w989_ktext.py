#!/usr/bin/env python3
# w989_ktext.py —— 从**设备自己的内核 Image** 里按 vaddr 抠出函数前若干条指令，交给远端 llvm-mc 反汇编。
# 为什么做这个：#216-B2 的模块要用函数指针**间接调用** security_read_policy / security_load_policy，
#   参数个数与顺序只能信"这台机真跑的那份代码"，不能信构建树的头(那是 Nothing 的树)，更不能信主线印象。
# 映射：**一手核过**——设备 kallsyms 里 `_head` 与 `_text` 是**同一个 vaddr**(ffffffc010080000)，
#   ⇒ 原始 Image 文件的第 0 字节就是 `_head`/`_text`，TEXT_OFF 应为 **0**（我第一版照抄"Image 头里
#   text_offset=0x80000"那条常识，套错了对象：那是**加载**偏移，不是文件内偏移；用 0x80000 抠出来的
#   第一条是 `ret`(d65f03c0)＝前一个函数的尾巴，一眼假）。
import sys, struct

IMG = r"analysis/kernel_dev_g2a88cd145def.bin"
TEXT_VADDR = 0xFFFFFFC010080000
TEXT_OFF = 0x0

def off_of(vaddr):
    return TEXT_OFF + (vaddr - TEXT_VADDR)

def main():
    syms = {
        "security_read_policy":  0xFFFFFFC0107BEDB0,
        "security_load_policy":  0xFFFFFFC0107BC260,
        "security_context_to_sid": 0xFFFFFFC0107BB8E8,
    }
    if len(sys.argv) > 1 and sys.argv[1] == "hex":
        data = open(IMG, "rb").read()
        print("# 镜像 %d 字节；head text_offset=0x%x" % (
            len(data), struct.unpack("<Q", data[8:16])[0]))
        for name, va in syms.items():
            o = off_of(va)
            chunk = data[o:o+64]
            print("%s %s %d %d" % (name, "0x%016x" % va, o, len(chunk)))
            # llvm-mc 的 -disassemble 吃 "每行一个 4 字节小端 word 的 hex"
            for i in range(0, len(chunk), 4):
                print("%02x%02x%02x%02x" % (chunk[i+3], chunk[i+2], chunk[i+1], chunk[i]))
        return
    # 默认只打印映射，自检用
    print("text_offset =", struct.unpack("<Q", open(IMG, "rb").read(16)[8:16])[0])
    for name, va in syms.items():
        print("%-26s vaddr=0x%016x -> file_off=0x%x (%d)" % (name, va, off_of(va), off_of(va)))

main()
