#!/usr/bin/env python3
# patch_ksu_domainfallback.py —— rc67：`setup_selinux()` 里给「域解析失败」加一条回退。
#   一手事实(§6.206/§6.207)：官方 Manager 的 App Profile 默认发 u:r:ksu:s0，本机基础策略里没这个域，
#     security_secctx_to_secid 返 -22 ⇒ transive_to_domain() 走 if(error) 分支只打日志、**不改 tsec->sid**，
#     于是「官方 UI 点一下开关」给出来的壳是 uid=0 + 满 cap + Seccomp:0，但**域还是 untrusted_app_25**，
#     能力损失可观测(读不到 /system/bin/sh 的头三字节)。
#   为什么回退放在 setup_selinux() 而不是 transive_to_domain() 里面：
#     setup_ksu_cred() 也用 transive_to_domain(KERNEL_SU_CONTEXT, ksu_cred)，
#     那个 cred 是**我们自己的内核凭据**，把它悄悄换成 shell 域是另一码事(会改内核侧行为)。
#     放在 setup_selinux 里 ⇒ **只影响 su 提权那条路**，范围最小。
#   默认开(回退到 u:r:shell:s0)，留一个 insmod 参数：ksu_domain_fallback='' 就是**负对照**(退回 rc63 行为)。
#     ★本 ko 在 init 里 kobject_del 了 /sys/module/kernelsu ⇒ 参数只在 insmod 那一刻定，运行期改不了。
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else '/root/k/ksu/kernel/selinux/selinux.c'
src = open(PATH, 'r', encoding='utf-8').read()
orig = src

# 1) 顶部加 include + 参数(锚：#include "ksu.h" 这一行，全文唯一)
ANCHOR_INC = '#include "ksu.h"\n'
assert src.count(ANCHOR_INC) == 1, '锚点 ksu.h 不是唯一/不存在'
DECL = (
    '#include "ksu.h"\n'
    '#include <linux/moduleparam.h>\n'
    '#include <linux/string.h>\n'
    '\n'
    '/* rc67：su 那条路的「域解析失败 -> 回退到这台机存在的域」。参数置空=关(负对照)。 */\n'
    'static char ksu_domain_fallback[96] = "u:r:shell:s0";\n'
    'module_param_string(ksu_domain_fallback, ksu_domain_fallback, sizeof(ksu_domain_fallback), 0444);\n'
    'MODULE_PARM_DESC(ksu_domain_fallback, "su 提权时若 profile 的域解析失败，回退到这个 SELinux 上下文；置空=不回退");\n'
)
if 'ksu_domain_fallback' not in src:
    src = src.replace(ANCHOR_INC, DECL, 1)
    print('  1) include + 参数已插入')
else:
    print('  1) 已有 ksu_domain_fallback ⇒ 跳过(幂等)')

# 2) 换掉 setup_selinux 的函数体(整块锚，唯一)
OLD_FN = (
    'void setup_selinux(const char *domain, struct cred *cred)\n'
    '{\n'
    '    if (transive_to_domain(domain, cred, false)) {\n'
    '        pr_err("transive domain failed.\\n");\n'
    '        return;\n'
    '    }\n'
    '}\n'
)
NEW_FN = (
    'void setup_selinux(const char *domain, struct cred *cred)\n'
    '{\n'
    '    if (transive_to_domain(domain, cred, false)) {\n'
    '        pr_err("transive domain failed.\\n");\n'
    '        if (!ksu_domain_fallback[0]) {\n'
    '            pr_info("DOMAIN 回退: 关(参数为空) -> 域保持原样\\n");\n'
    '            return;\n'
    '        }\n'
    '        if (strcmp(ksu_domain_fallback, domain) == 0) {\n'
    '            pr_info("DOMAIN 回退: 目标域就是它自己, 不再试\\n");\n'
    '            return;\n'
    '        }\n'
    '        if (!transive_to_domain(ksu_domain_fallback, cred, false)) {\n'
    '            pr_info("DOMAIN 回退: [%s] -> [%s] 成功\\n", domain, ksu_domain_fallback);\n'
    '            return;\n'
    '        }\n'
    '        pr_info("DOMAIN 回退也失败: [%s]\\n", ksu_domain_fallback);\n'
    '        return;\n'
    '    }\n'
    '    pr_info("DOMAIN: [%s] 一次就成, 不需要回退\\n", domain);\n'
    '}\n'
)
n = src.count(OLD_FN)
if n == 0:
    if 'DOMAIN 回退' in src:
        print('  2) 已经打过(幂等)：setup_selinux 里已有回退逻辑')
    else:
        print('[x] 找不到 setup_selinux 那一整块 ⇒ 远端文件与预期不符，停')
        sys.exit(1)
else:
    assert n == 1, 'setup_selinux 锚块出现 %d 次(不唯一)' % n
    src = src.replace(OLD_FN, NEW_FN, 1)
    print('  2) setup_selinux 已换成带回退的版本')

open(PATH, 'w', encoding='utf-8').write(src)
print('  补丁落地：%s  %d -> %d 字节' % (PATH, len(orig), len(src)))
print('  自检：ksu_domain_fallback 出现 %d 次, DOMAIN 回退 出现 %d 次, module_param_string 出现 %d 次'
      % (src.count('ksu_domain_fallback'), src.count('DOMAIN 回退'), src.count('module_param_string')))
