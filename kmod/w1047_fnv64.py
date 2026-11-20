#!/usr/bin/env python3
# w1047_fnv64.py —— 算文件的 FNV-1a 64，两个种子各印一份(键名固定，链里用 sed 取数)。
#   与内核侧同一把尺：`w986_polround.c:236` 与 `w1140_polload.c` 的 fnv64 就是这个 19 位种子那条。
# ★为什么印两个种子：标准 FNV-1a 64 的偏移基是 **20 位** `14695981039346656037`，而内核源码里写的是
#   **19 位** `1469598103934665603`(少一位)——拿哪把当证人必须先说清，否则两边的数怎么比都不等。
# ★11-05 修的一处仪器坑：这文件原本在 Windows GBK 控制台上直接 **UnicodeEncodeError 崩掉**
#   (输出里那个 `⇒`)——链拿到的就是"空读数"，而空读数与"算出来是 0"长得一模一样。⇒ 输出全 ASCII 键。
# ★末行那条历史值(旧证)只在比对 #219 那两发时才有意义，已改成"必须显式要 --ref 才印"，默认不印。
import sys

M = (1 << 64) - 1
SRC_SEED = 1469598103934665603      # 内核那两份 fnv64 用的
STD_BASE = 14695981039346656037      # 标准 FNV-1a 64 偏移基
PRIME = 1099511628211


def fnv(data, seed):
    h = seed
    for b in data:
        h = ((h ^ b) * PRIME) & M
    return h


args = [a for a in sys.argv[1:] if not a.startswith('--')]
if not args:
    print('usage: w1047_fnv64.py [--ref] <file> [<file2> ...]')
    sys.exit(2)
REF = '--ref' in sys.argv
for p in args:
    with open(p, 'rb') as f:
        data = f.read()
    print('FNV64_FILE=%s BYTES=%d' % (p, len(data)))
    print('FNV64_SRC_SEED=%d' % fnv(data, SRC_SEED))
    print('FNV64_STD_BASE=%d' % fnv(data, STD_BASE))
    if REF:
        # 历史对照值(11-01 那两发活设备上内核现印的 rt_sum_pre)，只对 #219 那两个输入可比
        print('FNV64_HIST_ref_rt_sum_pre=5457979107816203493')
