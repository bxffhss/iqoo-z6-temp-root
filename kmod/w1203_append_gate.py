#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""§6.582 补最后一格：整闸结果（append 到账本末尾，作为该栏最后一条）。"""
import io
import sys

P = "kmod/ROUTE-B-OFFSET-INVERSION.md"
BODY = """- **★整闸（本栏唯一一次，干净环境）：`[OK]` 328／`[BAD]` 0／末行 `=== 离线自检闸 全绿 ===`／`W413_RC=0`，38m53s**。全量件 `kmod/w103_evidence/w413_sweep_1109-2029.txt`＝`4a018fd598f543e8e17942f18f6edfe3`（**现读 114,780 B**；★脚本自己印的 `114747 字节` 是写者先量后追加横幅，按老规矩登记时重量）；console 件 `kmod/w103_evidence/w413_sweep_1109-2040.txt`＝`c68a02d6612ce65f465818460c6531ea`（20,071 B）。关键项逐条 `[OK]`：`run_z6pack`（79 项、⑩a 读出 `kernelsu_rc78`）、`run_fdkeepalive`（35 项，1m29s）、`w415` 文档审计、3b 设备侧 suw 包指纹读回（设备 `e75cf90d` ＝台账现行前缀，且反夹具用回退位前缀必须判不符）。
- **★这一跑先被我搞坏过一次（诚实记）**：第一次启动（19:24→20:26，62 分钟未出结果）**卡在 `run_fdkeepalive` 的第 ③④⑤⑥ 局**——`$W/sw` 从 19:48 起一直在、`tick` 涨到 694 不回头。根因**不是件、是我的启动环境**：我 `env -u` 只掉了 `BASH_ENV`/`PYTHONPATH`，**漏了 rm 三件套**（`BASH_FUNC_rm%%`/`unlink%%`/`rmdir%%`）⇒ 这台机上的 `sh` 是 bash 软链、会继承那三个导出函数 ⇒ 夹具里 `case_4` 的 `rm -f "$W/sw"` 落到 WorkBuddy 的 `rm` 包装上（子进程缺 `CODEBUDDY_SAFE_DELETE_BIN_DIR`）⇒ **静默失败、开关删不掉、循环无出口**。判据：作废存证 `w413_sweep_1109-1924_KILLED_envshim.txt`＝`e8c978d5a39d5e083e0ff95d408b56c9`。★验证方式＝同一件在干净环境下**单跑 1m29s、35 项全绿**，再重跑整闸。⇒ 以后启动总闸必须写成 `env -u BASH_ENV -u 'BASH_FUNC_rm%%' -u 'BASH_FUNC_unlink%%' -u 'BASH_FUNC_rmdir%%' -u PYTHONPATH ...`（**引号不能省**，`%` 那两个字符不引起来 `unset` 也不认）。
- **★遗留（对外口径，一条不少）**：①**rc78 从未上机**（`0x1a` 的伪装面、`which su`、app 里 `su -c id` 全未测）——要一次干净 boot ＋ 一发枪，**需现场点头**；②这一版 `z6root.zip`（`2e88ced7`）**未过一键认证**；③`kmod/push_ksu.sh` 的 PC 侧默认**仍指 rc74c**（那是"已认证默认"），要打 rc78 必须显式 `KO=kmod/kernelsu_rc78.ko`——是否在认证后把"两处默认"一起升，留给认证后决定；④`/product/bin/su` 跨 boot 残留与 `10349` 的授权仍在（内核态，重启即清）。
"""

s = io.open(P, encoding="utf-8").read()
if "整闸（本栏唯一一次，干净环境）" in s:
    print("!! 已有该格")
    sys.exit(1)
if not s.endswith("\n"):
    s += "\n"
io.open(P, "w", encoding="utf-8", newline="").write(s + BODY)
print("APPENDED 整闸格")
