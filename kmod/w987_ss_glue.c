// SPDX-License-Identifier: GPL-2.0
/* w987_ss_glue.c —— #216-B：SS 子集编进模块时**必须补的三块**。
 *
 * 背景（一手：kmod/w985_ssport_build.sh 第 3 版，产物 w985_probe.ko 未解析 27 条，其中 7 条不在
 * Module.symvers 里）：我们把构建树 `security/selinux/ss/{policydb,avtab,ebitmap,hashtab,symtab,
 * conditional,mls}.c` 编进模块，这几个 .c 引用了**同目录之外**(ss/services.c)的三个函数，
 * 而 services.c 太大(5.4k 行)且引用全局 `selinux_state` ⇒ 不能整个搬进来。
 *
 * ★为什么不"照抄 services.c 的那三个函数"而写响亮的桩：
 *   三条引用点逐个回看了调用链，**都不在"读→插→写→交回设备装载"这条路上**：
 *   - `context_add_hash`   ← 唯一调用者 ss/policydb.c:876，在 **policydb_load_isids()** 的
 *                            OCON_ISID 循环里；那个函数只被设备自己的 security_load_policy() 调
 *                            (它在自己那份 vmlinux 里)，我们这边**一次都不调**。
 *   - `services_compute_xperms_drivers`  /  `_decision`  ← AV/xperms **计算**路径
 *                            (context_struct_compute_av / cond_compute_xperms)，同样是设备的事。
 *   ⇒ 桩的作用只是**让模块能链接**；万一将来有人把调用链接进来，`WARN` 会在 dmesg 里留下响亮的
 *     证据，而不是静默给出"没算出来的 xperms"(那形状＝倾向拒绝＝fail-closed)。
 * ★这条纪律＝本仓老规矩："保守返回，绝不谎报成功"。
 */
#include <linux/kernel.h>
#include <linux/printk.h>
#include <linux/err.h>

#include "security.h"
#include "ss/policydb.h"
#include "ss/avtab.h"
#include "ss/services.h"	/* ★让编译器核对这三个原型(本仓老规矩：签名不凭印象) */

int context_add_hash(struct policydb *policydb, struct context *context)
{
	WARN(1, "w987: context_add_hash 被调到了(设计外) ⇒ 请回看是谁把 sidtab/isids 链进来的\n");
	return -EOPNOTSUPP;
}

void services_compute_xperms_drivers(struct extended_perms *xperms,
				     struct avtab_node *node)
{
	WARN(1, "w987: services_compute_xperms_drivers 被调到了(设计外)，本次不填 xperms\n");
}

void services_compute_xperms_decision(struct extended_perms_decision *xpermd,
				      struct avtab_node *node)
{
	WARN(1, "w987: services_compute_xperms_decision 被调到了(设计外)，本次不改 xpermd\n");
}
/* ★MODULE_LICENSE 只在 probe.c 里写一次(同一模块两处写＝modpost 报重复) */
