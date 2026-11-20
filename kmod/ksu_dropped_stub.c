// SPDX-License-Identifier: GPL-2.0
/* 路线 B 的降级桩 —— 被剔掉的原实现(selinux/sepolicy.c、selinux/rules.c)依赖 6.x 的
 * SELinux SS 内部结构(filename_trans_key / filename_trans_datum.stypes / sidtab /
 * selinux_state.policy)，本树 5.4 里不存在。依据与决策见 kmod/ROUTE-B-OFFSET-INVERSION.md §6.6/§6.7。
 *
 * ★保守返回：注入类**不谎报成功**(-EOPNOTSUPP)；规则应用类什么都不做。
 * ★签名必须逐字对齐 kernel/selinux/selinux.h:32/34：
 *     void apply_kernelsu_rules();
 *     int  handle_sepolicy(void __user *user_data, u64 data_len);
 *   上一版我把 handle_sepolicy 写成三参 —— 因为这个文件不 include selinux.h，编译器不会报错，
 *   链接也不查类型 ⇒ 一个静默的 ABI 错。教训：**桩必须 include 它要实现的那个头**，
 *   让编译器替你核对签名。 */
#include <linux/err.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include "selinux.h"

void apply_kernelsu_rules(void)
{
	/* 6.x 版会往策略里塞 allow 规则；5.4 这条路不通 ⇒ 什么都不做。
	 * 影响面 = KSU 的"自定义 sepolicy 规则"特性，不参与 uid/cap 授权路径。 */
}

int handle_sepolicy(void __user *user_data, u64 data_len)
{
	return -EOPNOTSUPP;
}
