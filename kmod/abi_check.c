/* abi_check.c — 编译期判定"这棵构建树的 struct 布局 == 设备上真机量到的那套"
 *
 * 全部数字都来自 2026-09-30 的真机一手观测(kmod/PLAN.md §7)：
 *   struct module : sizeof=960, name@24, init@392, exit@888   (从厂商 -qgki .ko 的
 *                   .gnu.linkonce.this_module 段与其中的 ABS64 重定位量出)
 *   struct kprobe : sizeof=136, addr@40, symbol_name@48        (从 vfcs-misc-core.ko 的
 *                   memset(0,0x88) + stp xzr,x8,[sp,#0x28] 量出；且真机 register_kprobe
 *                   返回 0 并解析出与离线 kallsyms 逐字节吻合的地址 ⇒ 这两个偏移是对的)
 *
 * 用法(在 hermes-remote 上，树已 make prepare 完)：bash kmod/remote_abi_check.sh
 * **编得过 = 这棵树可以拿来编 KSU**；编不过 = BUILD_BUG_ON 直接把"哪一条、实际值多少"打进
 * 编译错误里 ⇒ 说明厂商改过结构体，只能继续手搓模块，别硬编 KSU。
 *
 * 注意 BUILD_BUG_ON 在 5.4 是 `((void)sizeof(char[1-2*!!(c)]))`，**不能放文件作用域**，
 * 所以全部塞进 init 函数里(编译期照样生效，函数体 __init 会被丢弃但我们只要它编过)。
 */
#include <linux/build_bug.h>
#include <linux/err.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/stddef.h>

/* ★不要用 BUILD_BUG_ON：5.4 在 __OPTIMIZE__ 分支走 __compiletime_assert +
 * __attribute__((error))，**clang 不诊断**（2026-09-30 实测：把两条互相矛盾的断言
 * 一起编，全部"通过"）。这里用负长度数组 typedef —— 任何编译器都是硬错误。 */
#define CHK(name, cond) typedef char __chk_##name[(cond) ? 1 : -1]

CHK(mod_size,      sizeof(struct module) == 960);
CHK(mod_name_off,  offsetof(struct module, name) == 24);
CHK(mod_init_off,  offsetof(struct module, init) == 392);
CHK(mod_exit_off,  offsetof(struct module, exit) == 888);
CHK(kp_size,       sizeof(struct kprobe) == 136);
CHK(kp_addr_off,   offsetof(struct kprobe, addr) == 40);
CHK(kp_sym_off,    offsetof(struct kprobe, symbol_name) == 48);
CHK(have_modules,  IS_ENABLED(CONFIG_MODULES));
CHK(have_kprobes,  IS_ENABLED(CONFIG_KPROBES));
CHK(have_modver,   IS_ENABLED(CONFIG_MODVERSIONS));
/* 这条专门盯本次踩到的坑：CFI 被 olddefconfig 丢掉 ⇒ struct module 少 64 字节 */
CHK(have_cfi,      IS_ENABLED(CONFIG_CFI_CLANG));

static int __init abi_check_init(void) { return -EAGAIN; }

static void __exit abi_check_exit(void) {}

module_init(abi_check_init);
module_exit(abi_check_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("compile-time ABI match check against the device");
