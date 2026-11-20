// SPDX-License-Identifier: GPL-2.0
/* 编译探针：只把 SS 子集的关键入口**引用**一遍，逼链接器把它们都拉进来。
 * 不注册任何钩子、不写任何策略、init 直接返回 -EAGAIN(模块自动卸载)。 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/stddef.h>
#include "security.h"
#include "ss/policydb.h"
#include "ss/avtab.h"
#include "ss/ebitmap.h"
#include "ss/mls_types.h"

/* avtab.c:658 有定义但**没有任何头声明它**(in-tree 是靠 services.c 里的 extern 原语)
 * ⇒ 不声明就调＝隐式声明＝kbuild 直接 error。这里按定义逐字补声明。 */
void __init avtab_cache_init(void);

static int __init wp_init(void)
{
	struct policydb *db = kzalloc(sizeof(*db), GFP_KERNEL);
	struct avtab_key key = { };
	struct avtab_datum dat = { };
	struct avtab_node *n;
	int rc;

	if (!db)
		return -ENOMEM;

	pr_info("W985 sizeof(policydb)=%zu sizeof(avtab_key)=%zu sizeof(avtab_node)=%zu off.te_avtab=%zu off.p_types=%zu\n",
		sizeof(struct policydb), sizeof(struct avtab_key), sizeof(struct avtab_node),
		offsetof(struct policydb, te_avtab), offsetof(struct policydb, p_types));

	/* 插入要走真路径：先建我们自己的 avtab_node slab，再 init/alloc 哈希，然后插一条。
	 * ★上一版这里直接对 htable==NULL 的 avtab 调 insert ⇒ 一旦真上机就是空指针；探针不该有那种雷。 */
	avtab_cache_init();
	rc = avtab_init(&db->te_avtab);
	if (!rc)
		rc = avtab_alloc(&db->te_avtab, 16);
	pr_info("W985 avtab init/alloc rc=%d\n", rc);
	if (!rc) {
		key.source_type = 1;
		key.target_type = 2;
		key.target_class = 3;
		key.specified = AVTAB_ALLOWED;
		dat.u.data = 0x1234;
		n = avtab_insert_nonunique(&db->te_avtab, &key, &dat);
		pr_info("W985 insert n=%ps nel=%u (判据：n 非空且 nel=1)\n", n, db->te_avtab.nel);
	}
	pr_info("W985 refs: rd=%ps wr=%ps de=%ps ins=%ps eb=%ps\n",
		policydb_read, policydb_write, policydb_destroy,
		avtab_insert_nonunique, ebitmap_set_bit);
	avtab_destroy(&db->te_avtab);
	kfree(db);
	return -EAGAIN;	/* ★判据要求：这个探针模块**故意不常驻**，insmod 一定失败并自动回滚 */
}

static void __exit wp_exit(void) { pr_info("W985 exit\n"); }

module_init(wp_init);
module_exit(wp_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("w985 SS-subset compile probe (no policy write)");
