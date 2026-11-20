#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""w733_badgetext.py —— 把 `uiautomator dump` 那份 XML 收成**一行**判据文本(第 52 发的牌子读数抽取器)。
   跑法：PYTHONUTF8=1 python kmod/w733_badgetext.py <xml路径>
   ★为什么要单独一个件：`adb shell cat` 含中文会被工具吞成 [Binary output](记忆那条)，所以只能 pull 回来本地解析；
     而解析本身必须**只认字段在场/不在场**，不数命中行数(例 174/176 那一族：抽取器一坏，六个 0 长得像"没发生")。
   ★输出永远是**一行**，读不到就写 UNREADABLE，绝不空着(空行会被当成"通过")。
"""
import io
import re
import sys

if len(sys.argv) < 2:
    print("UNREADABLE 用法: python kmod/w733_badgetext.py <xml>")
    sys.exit(2)

p = sys.argv[1]
try:
    raw = io.open(p, "rb").read()
except Exception as e:  # noqa: BLE001
    print("UNREADABLE 打不开=%s" % e)
    sys.exit(1)

if len(raw) < 200:
    print("UNREADABLE 字节=%d(uiautomator 首跑会静默不产文件，这条就是防它)" % len(raw))
    sys.exit(1)

s = raw.decode("utf-8", "replace")
texts = re.findall(r'text="([^"]*)"', s)
nonempty = [t for t in texts if t.strip()]

def has(w):
    return any(w in t for t in nonempty)

badge = "无牌子"
if has("工作中"):
    badge = "工作中"
elif has("不支持"):
    badge = "不支持"
elif has("未安装") or has("Not installed"):
    badge = "未安装"

ver = "版本无"
for t in nonempty:
    m = re.search(r"版本：?([0-9]+-[0-9]+)", t)
    if m:
        ver = m.group(1)
        break

jb = "越狱有" if has("越狱") else "越狱无"
# 页签数＝底部导航里那四个词的在场数(只当"页面完整"的旁证，不当判据)
tabs = sum(1 for w in ("首页", "超级用户", "模块", "设置") if has(w))
pkgok = 'package="me.weishu.kernelsu"' in s

print("字节=%d 节点=%d 牌子=%s %s %s 页签=%d 包在场=%s 首行文本=[%s]"
      % (len(raw), len(nonempty), badge, ver, jb, tabs, "是" if pkgok else "否",
         (nonempty[0][:18] if nonempty else "-")))
