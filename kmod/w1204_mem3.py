#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""追加"续十"：整闸结果 + 环境教训（引号与 sh=bash 继承导函数）。"""
import io
import sys

P = ".workbuddy/memory/2026-11-09.md"
BODY = """
## 20:2x–21:0x（续十）整闸全绿；★踩到一个会白烧一小时的坑：**漏 `env -u` 掉 rm 三件套 ⇒ 夹具的 rm 静默失效**

- **结果**：`bash kmod/w413_selftest_sweep.sh` **`[OK]` 328／`[BAD]` 0／`=== 离线自检闸 全绿 ===`／`W413_RC=0`**，38m53s。全量件 `kmod/w103_evidence/w413_sweep_1109-2029.txt`＝`4a018fd5…`（**现读 114,780 B**；脚本自印的 114747 是写者自量，别登记那个）。关键项：`run_z6pack`（⑩a 读出 `kernelsu_rc78`）、`run_fdkeepalive`（35 项／1m29s）、`w415`、3b 设备 suw 指纹读回（`e75cf90d` ＋ 反夹具）。
- **★坑（重要，写进铁律级）**：第一次跑卡了 62 分钟没结果。根因**不是件**，是我启动命令只写了 `env -u BASH_ENV -u PYTHONPATH`，**漏了 `-u 'BASH_FUNC_rm%%' -u 'BASH_FUNC_unlink%%' -u 'BASH_FUNC_rmdir%%'`**。
  - 传导链：WorkBuddy 在环境里**导出**了 `rm`/`unlink`/`rmdir` 三个 bash 函数（内容＝`${CODEBUDDY_SAFE_DELETE_BIN_DIR}/rm "$@"`）；这台机的 `sh` 是 **bash 的软链**，子进程会继承这三个导出函数；夹具 `case_4` 要 `rm -f "$W/sw"` 来关循环 ⇒ 落到那个包装上、而子进程里 `CODEBUDDY_SAFE_DELETE_BIN_DIR` 不在 ⇒ **静默失败 ⇒ 开关删不掉 ⇒ 循环无出口**（`tick` 涨到 694、每 tick 3.3 秒，日志被 `ZG_FALLBACK` 刷 725 行）。
  - **两个细节**：①`env -u` 的变量名**必须加引号**（`'BASH_FUNC_rm%%'`），`%` 不引起来连 `unset` 都不认；②**只 `unset` 不够**——那些是**导出**变量，只要父进程还有就会被重新导入；判据＝`env | grep -c BASH_FUNC` 必须 **0**，且 `env -u … bash -c 'type -t rm'` 必须回 `file`（不是 `function`）。
  - **验证方式**：同一件在干净环境下**单跑 1m29s、35 项全绿**，再重跑整闸 ⇒ 才能证明"卡的是环境不是件"。
- **作废存证**：`kmod/w103_evidence/w413_sweep_1109-1924_KILLED_envshim.txt`＝`e8c978d5…`（改名标注，别当有效凭据）。
- **状态**：设备仍零接触（枪数 9、`load` 7、窗口还是 16:04 那个）；**rc78 一次没上机**，要一次干净 boot ＋ 一发枪，**需现场点头**。
"""

s = io.open(P, encoding="utf-8").read()
if "续十" in s:
    print("!! 已有续十")
    sys.exit(1)
if not s.endswith("\n"):
    s += "\n"
io.open(P, "w", encoding="utf-8", newline="").write(s + BODY.lstrip("\n"))
print("APPENDED 续十")
