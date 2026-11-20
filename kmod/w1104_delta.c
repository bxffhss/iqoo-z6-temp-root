/* w1104_delta.c — #216 A 侧：用户态离线工具，读厂商二进制 SELinux 策略 / 语义 dump / 只插 allow delta。
 *
 * 制式（与已验通的 kmod/w976_rt_public.c 完全一致，别改顺序）：
 *   sepol_policydb_create(&db)
 *   sepol_policydb_set_typevers(db, SEPOL_POLICY_KERN)   ← 必须在 sepol_policydb_read 之前
 *   sepol_policydb_read(db, pf)
 * 写：sepol_policy_file_set_fp(pf2, wf) + sepol_policydb_write(db, pf2)。
 * 这份 /sys/fs/selinux/policy 导出的头是 POLICYDB_MAGIC + "SE Linux"（不是模块制式的 0x0030364d），
 * 不声明 KERN 就解不开——w957/w975 两版都栽在这一步。
 *
 * 用到的内部结构全部来自 libsepol 3.4 **随库发行**的头（include/sepol/policydb 目录下），字段是读源码核过的：
 *   policydb_t.p_types / p_classes（symtab_t，里面有 hashtab_t table）、p_type_val_to_name /
 *   p_class_val_to_name（policydb_read 末尾 policydb_index_classes()+policydb_index_others() 填好）、
 *   class_datum_t.permissions（本类权限 symtab）+ .comdatum->permissions（common 继承的权限 symtab；
 *   class_read 只做名字绑定，**不**把 common 的权限并进本类表，所以两段都要查）、
 *   perm_datum_t.s.value ＝ 权限位掩码（不是序号），
 *   policydb_t.te_avtab（avtab_t: htable/nslot/mask/nel）+ avtab_search_node()/avtab_insert()。
 *
 * ★ 这个工具**没有** delete / neverallow / auditallow 路径，是刻意的：写动作只有两种——
 *   ①把权限位 OR 进 te_avtab 里那条 ALLOW 项(项不存在就新建)，②(11-03 #232)在类型表**尾部**加一个新类型
 *   并在按位置排的 type_attr_map 新行里置上"自票＋属性票"。撤权限、加 neverallow、动 type/class/user 表、
 *   给已有类型改名或重编号，一概不做，省得一次手滑把厂商的闸拆掉（§6.456 那次 CIL 重编拆掉 502 道闸，就是同族的错）。
 *   任何"名字解不出来 / 权限不在那个 class（含它的 common）/ 规则不是 allow|type|typeattribute"都是**硬错误 + 非零退出**，
 *   绝不静默跳过；dump 里遇到没有名字的权限位打 `?0x<hex>` 并累加 UNNAMED_BITS，也不静默。
 * ★ (11-03 #233)规则里的 `*` 一律在**写侧展开成具体三元组**：内核 ss 目录里 `wildcard` 零命中、avkey 只放具体 type 值，
 *   所以"通配"这个概念在二进制策略里根本不存在。展开数量有上限(MAXJOBS)，超了当场拒——`allow * * ...` 是具体类型数的
 *   平方(这台机 ≈1060 万)，那不叫 delta 叫把这台机压死。**属性主体不展开**：内核 `context_struct_compute_av()`
 *   (services.c:613)是拿 `type_attr_map[主体]` 的每一位当候选 key 去查表的 ⇒ 以属性值为 source 的一个节点就被该属性
 *   的每个成员命中。
 *
 * dump 行格式（4 个空格分隔字段）：source_type target_type target_class comma-sorted-perms
 *   —— 需求写的是 "source_type target_type comma-sorted-perms"，但同一个 (src,tgt) 在不同 class 下是
 *   不同的条目，不带 class 两行会撞在一起、diff 就分不开，所以多打一个 class 字段（前三段照原样）。
 */

#include <sepol/policydb.h>
#include <sepol/policydb/policydb.h>
#include <sepol/policydb/avtab.h>
#include <sepol/policydb/hashtab.h>
#include <sepol/policydb/symtab.h>

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RC_USAGE   2
#define RC_READ    3
#define RC_WRITE   4
#define RC_RULE    5

static sepol_policydb_t *spdb;
static policydb_t *P;
static char *raw_buf;          /* 输入原件的字节；libsepol 读的时候我们让缓冲一直活着 */
static long raw_len;
static unsigned long unnamed_bits;

static void die(int rc, const char *fmt, ...)
{
	va_list ap;

	fprintf(stderr, "ERROR: ");
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	fflush(stderr);
	exit(rc);
}

/* ---------------- 读 / 写 ---------------- */

static void load_policy(const char *path)
{
	FILE *f;
	sepol_policy_file_t *pf = NULL;
	int rc;

	f = fopen(path, "rb");
	if (!f)
		die(RC_READ, "open %s failed", path);
	fseek(f, 0, SEEK_END);
	raw_len = ftell(f);
	rewind(f);
	if (raw_len <= 0)
		die(RC_READ, "%s has size %ld", path, raw_len);
	raw_buf = malloc((size_t)raw_len);
	if (!raw_buf)
		die(RC_READ, "oom for %s (%ld B)", path, raw_len);
	if (fread(raw_buf, 1, (size_t)raw_len, f) != (size_t)raw_len)
		die(RC_READ, "short read %s", path);
	fclose(f);

	if (sepol_policy_file_create(&pf) < 0)
		die(RC_READ, "sepol_policy_file_create failed");
	if (sepol_policydb_create(&spdb) < 0)
		die(RC_READ, "sepol_policydb_create failed");
	rc = sepol_policydb_set_typevers(spdb, SEPOL_POLICY_KERN);
	if (rc < 0)
		die(RC_READ, "sepol_policydb_set_typevers(KERN) rc=%d", rc);
	sepol_policy_file_set_mem(pf, raw_buf, (size_t)raw_len);
	rc = sepol_policydb_read(spdb, pf);
	if (rc < 0)
		die(RC_READ, "sepol_policydb_read rc=%d on %s", rc, path);

	P = &spdb->p;
	if (P->policy_type != SEPOL_POLICY_KERN)
		die(RC_READ, "%s: policy_type=%u is not KERN", path, P->policy_type);
	if (!P->p_types.table || !P->p_classes.table)
		die(RC_READ, "%s: symtab missing", path);
	if (!P->p_type_val_to_name || !P->p_class_val_to_name)
		die(RC_READ, "%s: val_to_name tables not built by policydb_read", path);

	printf("READ path=%s size=%ld policyvers=%u types=%u classes=%u avtab_nel=%u nslot=%u\n",
	       path, raw_len, P->policyvers, P->p_types.nprim, P->p_classes.nprim,
	       P->te_avtab.nel, P->te_avtab.nslot);
}

static void write_policy(const char *path)
{
	sepol_policy_file_t *pf2 = NULL;
	FILE *wf;
	long written;
	int rc;

	wf = fopen(path, "wb");
	if (!wf)
		die(RC_WRITE, "open %s for write failed", path);
	if (sepol_policy_file_create(&pf2) < 0)
		die(RC_WRITE, "sepol_policy_file_create(2) failed");
	sepol_policy_file_set_fp(pf2, wf);
	rc = sepol_policydb_write(spdb, pf2);
	fflush(wf);
	written = ftell(wf);
	fclose(wf);
	if (rc < 0)
		die(RC_WRITE, "sepol_policydb_write rc=%d on %s", rc, path);
	if (written <= 0)
		die(RC_WRITE, "sepol_policydb_write produced %ld bytes on %s", written, path);
	printf("WROTE path=%s size=%ld (input %ld B, delta %ld B)\n",
	       path, written, raw_len, written - raw_len);
}

/* ---------------- 名字 <-> 值（解不出来一律硬错） ---------------- */

static const char *type_name_of(uint32_t v, const char *ctx)
{
	char *s;

	if (v == 0 || v > P->p_types.nprim)
		die(RC_RULE, "%s: type value %u out of range (p_types.nprim=%u)", ctx, v, P->p_types.nprim);
	s = P->p_type_val_to_name[v - 1];
	if (!s)
		die(RC_RULE, "%s: type value %u has no name in p_type_val_to_name", ctx, v);
	return s;
}

static const char *class_name_of(uint32_t v, const char *ctx)
{
	char *s;

	if (v == 0 || v > P->p_classes.nprim)
		die(RC_RULE, "%s: class value %u out of range (p_classes.nprim=%u)", ctx, v, P->p_classes.nprim);
	s = P->p_class_val_to_name[v - 1];
	if (!s)
		die(RC_RULE, "%s: class value %u has no name in p_class_val_to_name", ctx, v);
	return s;
}

static uint32_t type_value_of(const char *name)
{
	type_datum_t *td = (type_datum_t *)hashtab_search(P->p_types.table, name);

	if (!td)
		die(RC_RULE, "unresolvable type name '%s' (not in this policy's p_types symtab)", name);
	return td->s.value;
}

static class_datum_t *class_datum_of(const char *name, uint32_t *val)
{
	class_datum_t *cd = (class_datum_t *)hashtab_search(P->p_classes.table, name);

	if (!cd)
		die(RC_RULE, "unresolvable class name '%s' (not in this policy's p_classes symtab)", name);
	if (!cd->permissions.table)
		die(RC_RULE, "class '%s' has no permission table", name);
	*val = cd->s.value;
	return cd;
}

/* 权限名 → 位掩码：先查本类 permissions symtab，再查它 common 的 permissions symtab（源码核过：
 * class_read 不把 common 的权限复制进本类表，两段都得查）。找不到 → 0，由调用方报硬错。
 *
 * ★这份厂商件里 perm_datum.s.value 存的是**序号（1 起）**，不是位掩码——现测，不是推的：
 *   capability(common cap): fowner=4 setpcap=9 sys_boot=23 setfcap=32
 *   file(common file):      ioctl=1 write=3 create=4 relabelfrom=8 append=10 map=11 execute=13
 *   dir own:               add_name=26 remove_name=27 reparent=28 search=29 rmdir=30（common 占了 1..25，序号接着排）
 *   与内核 classmap 的声明顺序逐个对齐 ⇒ 真正的访问向量位是 `1u << (value - 1)`。
 *   （binder 类里 set_context_mgr=0x3 这种"两个位都置着"的值就是这条规则的现形：它按位解释根本不成立。）
 */
static uint32_t perm_bit_of(class_datum_t *cd, const char *clsname, const char *perm)
{
	perm_datum_t *pd = (perm_datum_t *)hashtab_search(cd->permissions.table, perm);

	if (!pd && cd->comdatum && cd->comdatum->permissions.table)
		pd = (perm_datum_t *)hashtab_search(cd->comdatum->permissions.table, perm);
	if (!pd)
		return 0;
	if (pd->s.value == 0 || pd->s.value > 32)
		die(RC_RULE, "class '%s': permission '%s' carries ordinal %u which has no bit in a 32-bit access vector",
		    clsname, perm, pd->s.value);
	return 1u << (pd->s.value - 1);
}

/* 权限位写 `*` 时的展开：这个类**自己定义的**＋它的 common 里的全部权限。
 *   与 checkpolicy/CIL 的口径一致(不是"32 位全 1"——那个会把厂商没定义的位也放开)。
 *   计数一起打出来，方便判据侧核"这条规则放开了几格"。 */
struct permacx { uint32_t bits; unsigned long n; };

static int perm_or_cb(hashtab_key_t key, hashtab_datum_t datum, void *ptr)
{
	struct permacx *c = ptr;
	perm_datum_t *pd = (perm_datum_t *)datum;

	if (pd->s.value == 0 || pd->s.value > 32)
		die(RC_RULE, "permission '%s' carries ordinal %u which has no bit in a 32-bit access vector",
		    (char *)key, pd->s.value);
	c->bits |= 1u << (pd->s.value - 1);
	c->n++;
	return 0;
}

static uint32_t all_perm_bits_of(class_datum_t *cd, const char *clsname, unsigned long *np)
{
	struct permacx c;

	memset(&c, 0, sizeof(c));
	if (!cd->permissions.table)
		die(RC_RULE, "class '%s' has no permission table to expand '*'", clsname);
	if (hashtab_map(cd->permissions.table, perm_or_cb, &c))
		die(RC_RULE, "hashtab_map over class '%s' permissions failed", clsname);
	if (cd->comdatum && cd->comdatum->permissions.table &&
	    hashtab_map(cd->comdatum->permissions.table, perm_or_cb, &c))
		die(RC_RULE, "hashtab_map over class '%s' common permissions failed", clsname);
	if (c.bits == 0)
		die(RC_RULE, "class '%s': '*' expanded to zero permission bits — 那等于我什么都没开，不能算过了", clsname);
	*np = c.n;
	return c.bits;
}

/* `*` 在主体/客体那一侧展开成"这份表里每一个具体类型"。
 *   ★只取 flavor==TYPE_TYPE：属性值不进这个集合(而且**属性主体的规则本来就不用展开**——内核
 *     `context_struct_compute_av()` 是拿 `type_attr_map[主体]` 的每一位当候选 key 去查表的，
 *     一个以属性值为 source 的节点就会被该属性的每个成员命中；11-03 现读 services.c:613)。
 *   用 value 走 `type_val_to_struct` 而不是走符号表 ⇒ 同一个值的第二个名字(alias)不会被算两遍。 */
static int collect_primary_types(uint32_t *out, int max)
{
	uint32_t i;
	int n = 0;

	for (i = 1; i <= P->p_types.nprim; i++) {
		type_datum_t *td = (type_datum_t *)P->type_val_to_struct[i - 1];

		if (!td)
			die(RC_RULE, "collect_primary_types: value %u has no datum", i);
		if (td->flavor != TYPE_TYPE)
			continue;
		if (n >= max)
			die(RC_RULE, "collect_primary_types: 超过 %d 个具体类型，超出我为通配展开准备的数组", max);
		out[n++] = i;
	}
	return n;
}

/* ---------------- dump ---------------- */

#define MAXPERMS 64
static char *lines[MAXPERMS * 2048];   /* 上限 13 万行，实际用量远小于此，超了就 die */
static size_t nlines;

typedef struct {
	const char *bit_name[32];
	int built;
} perm_names;

static perm_names *pn_cache;

static void collect_perm_names(hashtab_t h, uint32_t classv, const char *cls, const char *which)
{
	unsigned int s;
	hashtab_ptr_t node;

	for (s = 0; s < h->size; s++) {
		for (node = h->htable[s]; node; node = node->next) {
			perm_datum_t *pd = (perm_datum_t *)node->datum;
			const char *nm = (const char *)node->key;
			uint32_t v = pd->s.value;
			int b = 0;

			if (v == 0 || v > 32)
				die(RC_READ, "class %s: permission '%s' in %s has ordinal %u outside 1..32 — no bit for it",
				    cls, nm, which, v);
			b = (int)v - 1;          /* ★ value 存的是 1 起序号 ⇒ 位 = 1<<(value-1) */
			if (pn_cache[classv - 1].bit_name[b] &&
			    strcmp(pn_cache[classv - 1].bit_name[b], nm) != 0)
				die(RC_READ, "class %s: bit 0x%x claimed by both '%s' and '%s'",
				    cls, v, pn_cache[classv - 1].bit_name[b], nm);
			pn_cache[classv - 1].bit_name[b] = nm;
		}
	}
}

static void build_perm_names(uint32_t classv, const char *cls)
{
	class_datum_t *cd;

	if (pn_cache[classv - 1].built)
		return;
	pn_cache[classv - 1].built = 1;
	cd = (classv >= 1 && classv <= P->p_classes.nprim) ? P->class_val_to_struct[classv - 1] : NULL;
	if (!cd)
		die(RC_READ, "class value %u ('%s') has no class_val_to_struct entry", classv, cls);
	collect_perm_names(cd->permissions.table, classv, cls, "own permissions");
	if (cd->comdatum && cd->comdatum->permissions.table)
		collect_perm_names(cd->comdatum->permissions.table, classv, cls, "common permissions");
}

static int cmp_str(const void *a, const void *b)
{
	return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void add_line(char *s)
{
	if (nlines >= sizeof(lines) / sizeof(lines[0]))
		die(RC_READ, "dump overflow: more than %zu lines — traversal assumption wrong",
		    sizeof(lines) / sizeof(lines[0]));
	lines[nlines++] = s;
}

static void dump_policy(const char *outpath)
{
	avtab_t *h = &P->te_avtab;
	unsigned int slot;
	unsigned long total = 0, nonallow = 0, allow = 0, with_xperms = 0;
	size_t i;
	FILE *of;

	if (!h->htable || h->nslot == 0)
		die(RC_READ, "te_avtab is not populated (htable=%p nslot=%u)", (void *)h->htable, h->nslot);
	pn_cache = calloc(P->p_classes.nprim ? P->p_classes.nprim : 1, sizeof(perm_names));
	if (!pn_cache)
		die(RC_READ, "oom for perm cache");

	for (slot = 0; slot < h->nslot; slot++) {
		avtab_ptr_t node;

		for (node = h->htable[slot]; node; node = node->next) {
			const char *sn, *tn, *cn;
			char *line, *p;
			const char *got[MAXPERMS];
			int ngot = 0;
			int b;
			uint32_t data;

			total++;
			if (!(node->key.specified & AVTAB_ALLOWED)) {
				nonallow++;
				if (node->datum.xperms)
					with_xperms++;
				continue;
			}
			if (node->datum.xperms)
				die(RC_READ, "node with AVTAB_ALLOWED also carries xperms (src=%u tgt=%u class=%u) — format I do not model",
				    node->key.source_type, node->key.target_type, node->key.target_class);
			allow++;
			if (node->key.source_type != node->key.target_type &&
			    node->key.target_type == 0)
				die(RC_READ, "node with target_type 0 (src=%u class=%u)",
				    node->key.source_type, node->key.target_class);
			sn = type_name_of(node->key.source_type, "avtab node");
			tn = type_name_of(node->key.target_type, "avtab node");
			cn = class_name_of(node->key.target_class, "avtab node");
			build_perm_names(node->key.target_class, cn);
			data = node->datum.data;
			for (b = 0; b < 32; b++) {
				if (!(data & (1u << b)))
					continue;
				char *unk;

				if (pn_cache[node->key.target_class - 1].bit_name[b]) {
					got[ngot++] = pn_cache[node->key.target_class - 1].bit_name[b];
					continue;
				}
				/* 该类（含它的 common）里没有这个名字的位：打 ?0x<hex> 并计数，不静默 */
				unnamed_bits++;
				unk = malloc(16);
				if (!unk)
					die(RC_READ, "oom for unnamed perm token");
				sprintf(unk, "?0x%08x", (unsigned)(1u << b));
				got[ngot++] = unk;
			}
			if (ngot > 1)
				qsort(got, ngot, sizeof(got[0]), cmp_str);
			line = malloc(512);
			if (!line)
				die(RC_READ, "oom for dump line");
			p = line;
			p += sprintf(p, "%s %s %s", sn, tn, cn);
			*p++ = ' ';
			for (b = 0; b < ngot; b++) {
				if (b)
					*p++ = ',';
				strcpy(p, got[b]);
				p += strlen(got[b]);
			}
			*p = 0;
			if (ngot == 0) {   /* 权限掩码为 0 的 ALLOW 项：照样打出来（空权限段），不静默丢 */
				char *z = malloc(512);
				if (!z)
					die(RC_READ, "oom");
				sprintf(z, "%s %s %s -", sn, tn, cn);
				free(line);
				line = z;
			}
			add_line(line);
		}
	}

	if (total != h->nel)
		die(RC_READ, "traversal is wrong: visited %lu nodes but avtab.nel says %u", total, h->nel);

	qsort(lines, nlines, sizeof(lines[0]), cmp_str);

	of = fopen(outpath, "wb");
	if (!of)
		die(RC_WRITE, "open %s for write failed", outpath);
	for (i = 0; i < nlines; i++)
		fprintf(of, "%s\n", lines[i]);
	fprintf(of, "DUMP_NODES=%lu\n", allow);
	fprintf(of, "DUMP_TYPES=%u\n", P->p_types.nprim);
	fprintf(of, "DUMP_CLASSES=%u\n", P->p_classes.nprim);
	fprintf(of, "UNNAMED_BITS=%lu\n", unnamed_bits);
	fprintf(of, "DUMP_AVTAB_NEL=%u\n", h->nel);
	fprintf(of, "DUMP_AVTAB_VISITED=%lu\n", total);
	fprintf(of, "DUMP_AVTAB_NONALLOW=%lu\n", nonallow);
	fprintf(of, "DUMP_AVTAB_XPERMS=%lu\n", with_xperms);
	fprintf(of, "DUMP_POLICYVERS=%u\n", P->policyvers);
	fclose(of);
	printf("DUMP out=%s lines=%zu DUMP_NODES=%lu DUMP_TYPES=%u DUMP_CLASSES=%u UNNAMED_BITS=%lu "
	       "AVTAB_NEL=%u NONALLOW=%lu XPERMS=%lu\n",
	       outpath, nlines, allow, P->p_types.nprim, P->p_classes.nprim, unnamed_bits,
	       h->nel, nonallow, with_xperms);
}

/* ---------------- delta（只插，allow-only） ---------------- */

/* rules.txt 的实际内容不止三条 allow：文件里还有一段中文说明，其中 7 行**不是**注释行
 * （"## 三条不许越过的线" 的 1./2./3. 和验收清单的 "- " 那几行）。所以解析器按"行首是不是
 * 已知 TE 关键字"来认规则：
 *   - 关键字是 allow            → 正常插
 *   - 关键字是别的 TE 规则名     → 硬错（没有 delete/neverallow 路径）
 *   - 行里有 ';' 却认不出关键字 → 硬错（怕把一条我读不懂的规则当废话跳过）
 *   - 其余（纯说明文字）        → 计数 SKIPPED_NONRULE，不误当规则
 */
/* ---------------- #232：往类型表**尾部**插新类型（社区模块 sepolicy.rule 的 `type`/`typeattribute`） ----------------
 * 三条一手形状读数(11-03，都是这台机厂商件现测，不是按印象写的)：
 *   ①`types` 模式：3645 条里 primary=3265／attrib=380／alias=0，**每条 bounds=0**、`td->types` 全空；
 *   ②`tmap` 模式：**3645/3645 行都带自票**(self=1)，往返后仍 3645/3645 且逐行差 0；
 *   ③value 空间**稠密**：1..3645 每格都有名有实体、且槽里的值就等于槽号+1；符号表条数=3646 比 nprim 多 1，
 *     多出来的是"同一个值的第二个名字"(alias 形状)——现测，见 check_type_table 打的 TYPE_SECOND_NAME 行。
 * 写侧机制(libsepol 3.4 src/write.c:1207 `type_write`)：内核制式每条只写 名字长／**显式 value**／properties／bounds，
 *   `td->types` **只在 modular 制式才写** ⇒ 属性关系唯一的载体就是紧随符号表那段**按位置**排的 type_attr_map
 *   (write.c:2408 `for i < p->p_types.nprim`)。⇒ 插新类型的正确形状 = 尾部加一格 value=nprim+1、bounds=0、
 *   primary=1、flavor=TYPE_TYPE，并在 type_attr_map 的新行里置上"自票 + 各属性票"，别的表示一概不碰。
 * ★这张表是"位置"的，所以每加一条都要同步 nprim／两张 ebitmap 数组／索引数组，错一格就整表漂移；
 *   插之前/插之后各跑一次 check_type_table() 当场复证"1..nprim 稠密＋无值出界"，不靠我相信自己的代码。 */

#define MAXTYPEDECL 32
#define MAXATTRPER 8
typedef struct {
	char name[64];
	char attrs[MAXATTRPER][64];
	int nattr;
	int is_attr_cmd;      /* 1=typeattribute(给已有的类型补票) 0=type(声明一个新类型) */
	int applied;
} typedecl_t;

static typedecl_t tdecls[MAXTYPEDECL];
static int ntdecls;
static int types_added;
static unsigned long skipped_total;

static type_datum_t *type_lookup(const char *name)
{
	return (type_datum_t *)hashtab_search(P->p_types.table, name);
}

/* 符号表走查：数条数，并把"同一个值挂了第二个名字"和"值落在 1..nprim 之外"两类异常**点名**。
 *   11-03 第一次跑这一步就在厂商件上抓到 hashtab=3646 而 nprim=3645 —— 多的那条是 alias 形状，不是插坏的；
 *   所以这里只报数字不 die，die 留给"1..nprim 有洞/错位"那种真会让按位置段整表漂移的形状。 */
struct typewalk {
	unsigned long n;        /* 符号表条数 */
	unsigned long dup;      /* 同值第二名 */
	unsigned long oob;      /* 值落在 1..nprim 之外 */
	unsigned char *seen;    /* 按 value 记"这个值已经有名字了" */
};

static int odd_type_cb(hashtab_key_t key, hashtab_datum_t datum, void *ptr)
{
	type_datum_t *td = (type_datum_t *)datum;
	struct typewalk *w = ptr;

	w->n++;
	if (td->s.value >= 1 && td->s.value <= P->p_types.nprim) {
		if (w->seen && w->seen[td->s.value - 1]) {
			w->dup++;
			if (w->dup <= 12)
				printf("TYPE_SECOND_NAME value=%u name=%s primary=%u flavor=%u bounds=%u\n",
				       td->s.value, (char *)key, td->primary, td->flavor, td->bounds);
		} else if (w->seen) {
			w->seen[td->s.value - 1] = 1;
		}
		return 0;
	}
	printf("TYPE_ODD %s value=%u primary=%u flavor=%u bounds=%u\n",
	       (char *)key, td->s.value, td->primary, td->flavor, td->bounds);
	w->oob++;
	return 0;
}

/* 插完之后的当场复证：value 必须稠密(1..nprim 每格都有名有实体)，且符号表条数必须等于 nprim
 *   ——段头的"条数"和 ATAR 段的"行数"都按 nprim 走，两者不齐内核读的时候就是 -EINVAL。 */
static void check_type_table(const char *when)
{
	uint32_t i;
	struct typewalk w;

	memset(&w, 0, sizeof(w));
	w.seen = calloc(P->p_types.nprim, 1);
	for (i = 1; i <= P->p_types.nprim; i++) {
		if (!P->p_type_val_to_name[i - 1] || !P->type_val_to_struct[i - 1])
			die(RC_RULE, "%s: type value %u has no name/struct (表有洞，我不能在这样的表上接着写)", when, i);
		if (((type_datum_t *)P->type_val_to_struct[i - 1])->s.value != i)
			die(RC_RULE, "%s: value/name 表错位(槽 %u 里躺着 value=%u) ⇒ 位置性段会整表漂移，硬停", when, i,
			    ((type_datum_t *)P->type_val_to_struct[i - 1])->s.value);
	}
	if (hashtab_map(P->p_types.table, odd_type_cb, &w))
		die(RC_RULE, "%s: hashtab_map 数条数失败", when);
	printf("TABLE %s nprim=%u symtab_entries=%lu 同值第二名=%lu 值出界=%lu\n",
	       when, P->p_types.nprim, w.n, w.dup, w.oob);
	free(w.seen);
	if (w.n < (unsigned long)P->p_types.nprim)
		die(RC_RULE, "%s: 符号表条数(%lu)比 nprim(%u)还少 ⇒ 有名无值的洞，写出去内核必拒", when, w.n,
		    P->p_types.nprim);
	if (w.oob)
		die(RC_RULE, "%s: 有 %lu 条类型的值不在 1..nprim 内 ⇒ 按位置排的段会错位，硬停", when, w.oob);
}

static type_datum_t *insert_type(const char *name)
{
	type_datum_t *td;
	char *key;
	uint32_t v;
	ebitmap_t *grown;
	ebitmap_t *grown_attr;

	if (type_lookup(name))
		die(RC_RULE, "type '%s' 已在这份策略里(值=%u) ⇒ 我只插全新的名字，不静默改别人的定义",
		    name, type_lookup(name)->s.value);
	if (P->p_types.nprim >= 0xFFFE)
		die(RC_RULE, "类型值空间快满了(nprim=%u)：avtab 键是 16 位，再加会截断", P->p_types.nprim);

	td = calloc(1, sizeof(*td));
	key = strdup(name);
	if (!td || !key)
		die(RC_RULE, "oom inserting type '%s'", name);
	v = P->p_types.nprim + 1;
	td->s.value = v;
	td->primary = 1;                 /* 读数①：普通类型 primary=1 */
	td->flavor = TYPE_TYPE;
	td->bounds = 0;                  /* 读数①：这份厂商件 3645 条**全部** bounds=0 ⇒ 新条照同一形状 */
	ebitmap_init(&td->types);        /* 读数①：内核制式里这条不写出去，留空才是"和别人一样" */
	if (hashtab_insert(P->p_types.table, key, td)) {
		free(key);
		free(td);
		die(RC_RULE, "hashtab_insert type '%s' failed(重名或 oom)", name);
	}
	P->p_types.nprim++;

	/* 两张按位置对的表各扩一格；realloc 后新格必须先清零再 ebitmap_init(否则里面是垃圾指针) */
	grown = realloc(P->type_attr_map, (size_t)P->p_types.nprim * sizeof(ebitmap_t));
	if (!grown)
		die(RC_RULE, "realloc type_attr_map 失败");
	P->type_attr_map = grown;
	memset(&P->type_attr_map[v - 1], 0, sizeof(ebitmap_t));
	ebitmap_init(&P->type_attr_map[v - 1]);
	if (P->attr_type_map) {
		grown_attr = realloc(P->attr_type_map, (size_t)P->p_types.nprim * sizeof(ebitmap_t));
		if (!grown_attr)
			die(RC_RULE, "realloc attr_type_map 失败");
		P->attr_type_map = grown_attr;
		memset(&P->attr_type_map[v - 1], 0, sizeof(ebitmap_t));
		ebitmap_init(&P->attr_type_map[v - 1]);
	}
	/* 名字/实体索引数组走库自己的路重算(它按 datum->s.value 落位，正是"显式 value"那套)  */
	if (policydb_index_others(NULL, P, 0))
		die(RC_RULE, "policydb_index_others 失败(扩表后重算索引)");

	/* 读数②：全表每行都带自票 ⇒ 新行也带，别让它是唯一一行没有的 */
	if (ebitmap_set_bit(&P->type_attr_map[v - 1], v - 1, 1))
		die(RC_RULE, "set self bit for '%s'", name);
	types_added++;
	printf("TYPE_INSERTED %s value=%u\n", name, v);
	return td;
}

static void add_type_attrs(type_datum_t *td, typedecl_t *d, const char *kind)
{
	int j;

	for (j = 0; j < d->nattr; j++) {
		type_datum_t *ad = type_lookup(d->attrs[j]);

		if (!ad)
			die(RC_RULE, "%s '%s': attribute '%s' 不在这份策略里 ⇒ 我不替厂商凭空造属性(这台机就没有 nsfs 那一类，见 §6.520)",
			    kind, d->name, d->attrs[j]);
		if (ad->flavor != TYPE_ATTRIB)
			die(RC_RULE, "%s '%s': '%s' 存在但 flavor=%u 不是属性 ⇒ 拒绝把类型当属性用",
			    kind, d->name, d->attrs[j], ad->flavor);
		if (ebitmap_set_bit(&P->type_attr_map[td->s.value - 1], ad->s.value - 1, 1))
			die(RC_RULE, "set bit %u in type_attr_map[%u] failed", ad->s.value - 1, td->s.value - 1);
		if (P->attr_type_map &&
		    ebitmap_set_bit(&P->attr_type_map[ad->s.value - 1], td->s.value - 1, 1))
			die(RC_RULE, "set reverse bit failed");
		printf("ATTR_ADDED %s <- %s (type value=%u, attr value=%u)\n", d->attrs[j], d->name,
		       td->s.value, ad->s.value);
	}
}

/* 两遍扫完之后、解 allow 之前落表：这样 allow 里引用的新名字才解得开 */
static void apply_types(void)
{
	int i;

	if (!ntdecls)
		return;
	check_type_table("插之前");
	for (i = 0; i < ntdecls; i++) {
		typedecl_t *d = &tdecls[i];
		type_datum_t *td;

		if (d->is_attr_cmd) {
			td = type_lookup(d->name);
			if (!td)
				die(RC_RULE, "typeattribute '%s' 指名的是个不在表里的类型；我只给它**已有**的类型补票", d->name);
			d->applied = 1;
			printf("TYPEATTR %s value=%u nattr=%d\n", d->name, td->s.value, d->nattr);
		} else {
			td = insert_type(d->name);
			d->applied = 1;
		}
		add_type_attrs(td, d, d->is_attr_cmd ? "typeattribute" : "type");
	}
	check_type_table("插之后");
	printf("TYPES_ADDED=%d DECLS=%d\n", types_added, ntdecls);
}

static const char *TE_KEYWORDS[] = {
	"allow", "auditallow", "dontaudit", "neverallow",
	"type", "typealias", "typeattribute", "typetransition", "type_transition",
	"type_change", "type_member", "roleallow", "role_transition",
	"attribute", "attrinclude", "attrexclude", "constraint", "validatetrans",
	"mlsconstrain", "range_transition", "filename_trans", "permissive", NULL
};

#define MAXRULES 64
typedef struct {
	uint32_t src, tgt, cls, bits;
	char sname[64], tname[64], cname[64];
	int is_self;
	int src_wild, tgt_wild;   /* 1＝这一侧写的是 `*`：内核 ss 里 wildcard 零命中 ⇒ 只能在写侧展开成具体三元组 */
	int all_perms;            /* 1＝权限位写的是 `*`：展开成这个类(含它的 common)定义的全部权限 */
} rule_t;

static rule_t rules[MAXRULES];
static int nrules;

/* 通配规则展开后的具体工作项(一条规则 → 很多个 (src,tgt) 对)。上限是**刻意**的：
 *   厂商件 3265 个 primary 类型 ⇒ 一条 `allow * X file *` ≈ 3,265 项；`allow * * ...` 是 3265²≈10.6M ⇒ 必须当场拒，
 *   而不是让 avtab 涨到装载那一刻把这台机压死。数字本身要打进制证(见 apply_delta 末尾的 WILD/JOBS 行)。 */
#define MAXJOBS 60000
struct job {
	rule_t *r;
	uint32_t src, tgt;
};
static struct job jobs[MAXJOBS];
static int njobs;

static int line_is_rule_keyword(const char *tok)
{
	int i;

	for (i = 0; TE_KEYWORDS[i]; i++)
		if (!strcmp(tok, TE_KEYWORDS[i]))
			return 1;
	return 0;
}

/* 从 sp 当前位置继续切，收 `type NAME attr1,attr2` / `typeattribute NAME attr1,attr2` 的名字与属性 */
static void collect_type_decl(const char *kw, char **sp, size_t lineno)
{
	typedecl_t *d;
	char *tok;

	if (ntdecls >= MAXTYPEDECL)
		die(RC_RULE, "rules file line %zu: too many type/typeattribute declarations (>%d)",
		    lineno, MAXTYPEDECL);
	d = &tdecls[ntdecls];
	memset(d, 0, sizeof(*d));
	d->is_attr_cmd = !strcmp(kw, "typeattribute");
	tok = strtok_r(NULL, " \t,;{}()", sp);
	if (!tok)
		die(RC_RULE, "rules file line %zu: '%s' 后面没有名字(形如 `%s NAME attr1,attr2`)", lineno, kw, kw);
	if (strlen(tok) >= sizeof(d->name))
		die(RC_RULE, "rules file line %zu: type name '%s' too long", lineno, tok);
	strcpy(d->name, tok);
	while ((tok = strtok_r(NULL, " \t,;{}()", sp)) != NULL) {
		if (!*tok)
			continue;
		if (d->nattr >= MAXATTRPER)
			die(RC_RULE, "rules file line %zu: type '%s' lists more than %d attributes",
			    lineno, d->name, MAXATTRPER);
		if (strlen(tok) >= sizeof(d->attrs[0]))
			die(RC_RULE, "rules file line %zu: attribute name '%s' too long", lineno, tok);
		strcpy(d->attrs[d->nattr++], tok);
	}
	ntdecls++;
	printf("DECL_PARSED %s %s nattr=%d\n", kw, d->name, d->nattr);
}

/* 扫一遍 rules 文本。want_decls=1 只收类型声明(第一遍)；=0 只收 allow(第二遍，此时新类型已在表里)。
 * ★分两遍是**必需**的：allow 行可能引用同一份文件里刚声明的新类型，一遍扫到底就会死在"名字解不出来"。 */
static void scan_rules(char *text, int want_decls)
{
	char *save = NULL, *ln;
	size_t lineno = 0;

	for (ln = strtok_r(text, "\n", &save); ln; ln = strtok_r(NULL, "\n", &save)) {
		char *hp, *t, *sp = NULL, *first, *kw;
		char *srcn, *tgn, *clsn, *pk;
		size_t L;
		rule_t *r;
		uint32_t cv, bits;
		class_datum_t *cd;

		lineno++;
		if (ln[strlen(ln) - 1] == '\r')
			ln[strlen(ln) - 1] = 0;
		hp = strchr(ln, '#');
		if (hp)
			*hp = 0;
		L = strlen(ln);
		while (L && isspace((unsigned char)ln[L - 1]))
			ln[--L] = 0;
		t = ln;
		while (*t && isspace((unsigned char)*t))
			t++;
		if (!*t)
			continue;                       /* 空行/整行注释 */
		first = strtok_r(t, " \t", &sp);
		kw = malloc(strlen(first) + 1);
		if (!kw)
			die(RC_RULE, "oom");
		strcpy(kw, first);                      /* first 会被后面的 strtok_r 冲掉，先存 */
		if (!line_is_rule_keyword(kw)) {
			if (strchr(ln, ';'))
				die(RC_RULE, "rules file line %zu: statement starts with '%s' which is not a TE keyword "
				    "but the line contains ';' — refusing to silently skip a possible rule",
				    lineno, kw);
			if (!want_decls)
				skipped_total++;
			free(kw);
			continue;
		}
		if (!strcmp(kw, "type") || !strcmp(kw, "typeattribute")) {
			if (want_decls)
				collect_type_decl(kw, &sp, lineno);
			free(kw);
			continue;
		}
		if (strcmp(kw, "allow")) {
			if (!want_decls)
				die(RC_RULE, "rules file line %zu: rule kind '%s' is not 'allow'/'type'/'typeattribute' — "
				    "this tool is insert-only and deliberately has no delete/neverallow path", lineno, kw);
			if (strchr(ln, ';'))
				die(RC_RULE, "rules file line %zu: kind '%s' 不在我实现的两遍里(第一遍只认 type/typeattribute)；"
				    "不许静默跳过一条带分号的语句", lineno, kw);
			free(kw);
			continue;
		}
		if (want_decls) {
			free(kw);
			continue;
		}
		free(kw);

		if (nrules >= MAXRULES)
			die(RC_RULE, "too many rules (>%d)", MAXRULES);
		r = &rules[nrules];
		memset(r, 0, sizeof(*r));

		srcn = strtok_r(NULL, " \t", &sp);
		tgn = strtok_r(NULL, " \t{;", &sp);
		/* "self:capability" 这种 src:tgt:class 写法：token 里可能带 ':' */
		if (tgn && strchr(tgn, ':')) {
			char *colon = strchr(tgn, ':');
			*colon = 0;
			clsn = colon + 1;
			if (!*clsn)
				die(RC_RULE, "rules file line %zu: empty class after ':'", lineno);
		} else {
			clsn = strtok_r(NULL, " \t{;", &sp);
		}
		if (!srcn || !tgn || !clsn)
			die(RC_RULE, "rules file line %zu: expected 'allow src tgt:class perms ;'", lineno);
		if (strlen(srcn) >= sizeof(r->sname) || strlen(tgn) >= sizeof(r->tname) ||
		    strlen(clsn) >= sizeof(r->cname))
			die(RC_RULE, "rules file line %zu: name too long", lineno);
		strcpy(r->sname, srcn);
		strcpy(r->cname, clsn);
		r->is_self = !strcmp(tgn, "self");
		r->src_wild = !strcmp(srcn, "*");
		r->tgt_wild = !strcmp(tgn, "*");
		if (r->src_wild && r->tgt_wild)
			die(RC_RULE, "rules file line %zu: `allow * * ...` 我不接——两侧都是通配＝具体类型数的平方(这台机 ≈1060 万)个 avtab 节点，"
			    "这个尺寸不是\"策略 delta\"是把这台机压死；要放开两侧请写清楚是谁", lineno);
		if (r->is_self && r->src_wild)
			die(RC_RULE, "rules file line %zu: `allow * self:...` 没有意义(self 指的是源自己)", lineno);
		strcpy(r->tname, r->is_self ? srcn : tgn);

		r->src = r->src_wild ? 0 : type_value_of(srcn);
		r->tgt = r->is_self ? r->src : (r->tgt_wild ? 0 : type_value_of(tgn));
		if (r->is_self)
			sprintf(r->tname, "%s", srcn);  /* self ⇒ 目标类型 = 源类型 */
		if (!r->src_wild && strcmp(type_name_of(r->src, "rule src"), r->sname))
			die(RC_RULE, "internal: resolved src name '%s' != table name '%s'",
			    r->sname, type_name_of(r->src, "rule src"));
		cd = class_datum_of(clsn, &cv);
		r->cls = cv;

		bits = 0;
		{
			int nperm = 0;

			for (pk = strtok_r(NULL, " \t{};", &sp); pk; pk = strtok_r(NULL, " \t{};", &sp)) {
				uint32_t bit;

				if (!strcmp(pk, "*")) {
					unsigned long np_all = 0;

					if (nperm)
						die(RC_RULE, "rules file line %zu: '*' 和具名权限混在一起写(%s %s:%s) ⇒ 我不猜你要哪个子集",
						    lineno, r->sname, r->tname, clsn);
					bits = all_perm_bits_of(cd, clsn, &np_all);
					r->all_perms = 1;
					printf("PERM_STAR line %zu class=%s 展开=%lu 个权限 bits=0x%08x\n",
					       lineno, clsn, np_all, bits);
					nperm = 1;
					continue;
				}
				bit = perm_bit_of(cd, clsn, pk);
				if (bit == 0)
					die(RC_RULE, "rules file line %zu: permission '%s' is not defined in class '%s' "
					    "(neither its own permissions nor its common '%s')",
					    lineno, pk, clsn, cd->comkey ? cd->comkey : "(none)");
				if (bits & bit)
					die(RC_RULE, "rules file line %zu: permission '%s' listed twice in class '%s'",
					    lineno, pk, clsn);
				bits |= bit;
				nperm++;
			}
			if (nperm == 0)
				die(RC_RULE, "rules file line %zu: no permissions given for class '%s'", lineno, clsn);
		}
		r->bits = bits;
		nrules++;
	}
}

/* 读文件 → 第一遍(类型声明) → 插表 → 第二遍(allow)。两遍都要在**同一份原文**上跑，所以文本留着。 */
static void parse_rules(const char *path)
{
	FILE *f = fopen(path, "rb");
	char *text, *c1, *c2;
	long tl;

	if (!f)
		die(RC_RULE, "open rules file %s failed", path);
	fseek(f, 0, SEEK_END);
	tl = ftell(f);
	rewind(f);
	text = malloc((size_t)tl + 1);
	if (!text)
		die(RC_RULE, "oom for rules file");
	if (fread(text, 1, (size_t)tl, f) != (size_t)tl)
		die(RC_RULE, "short read of rules file");
	fclose(f);
	text[tl] = 0;

	c1 = malloc((size_t)tl + 1);
	c2 = malloc((size_t)tl + 1);
	if (!c1 || !c2)
		die(RC_RULE, "oom for the second pass over the rules file");
	memcpy(c1, text, (size_t)tl + 1);
	scan_rules(c1, 1);
	free(c1);
	apply_types();
	memcpy(c2, text, (size_t)tl + 1);
	scan_rules(c2, 0);
	free(c2);
	free(text);
	printf("RULES_PARSED=%d SKIPPED_NONRULE=%lu TYPE_DECLS=%d TYPES_ADDED=%d file=%s\n",
	       nrules, skipped_total, ntdecls, types_added, path);
	if (nrules == 0 && types_added == 0)
		die(RC_RULE, "no allow rule and no new type in %s — 空 delta 我不写文件，免得把\"没内容\"读成\"内容被拒\"", path);
}

static uint32_t wild_universe[8192];
static int wild_universe_n = -1;
static int wild_rules;

/* 把每条规则摊成具体的工作项(通配那侧换成每个具体类型)。★这一步必须在 apply_types() 之后跑，
 *   否则刚声明的新类型不在 `*` 的集合里——那正好是社区规则想要的反面(它们的顺序就是"先 type 再 allow *")。 */
static void build_jobs(void)
{
	int i;

	for (i = 0; i < nrules; i++) {
		rule_t *r = &rules[i];
		long long s_cnt = 1, t_cnt = 1;
		int a, b;

		if (r->src_wild || r->tgt_wild) {
			wild_rules++;
			if (wild_universe_n < 0) {
				wild_universe_n = collect_primary_types(wild_universe,
									(int)(sizeof(wild_universe) / sizeof(wild_universe[0])));
				printf("WILD_UNIVERSE primary_types=%d nprim=%u (只取 flavor=TYPE_TYPE；属性主体不需要展开)\n",
				       wild_universe_n, P->p_types.nprim);
			}
			s_cnt = r->src_wild ? wild_universe_n : 1;
			t_cnt = r->tgt_wild ? wild_universe_n : 1;
		}
		if (njobs + s_cnt * t_cnt > MAXJOBS)
			die(RC_RULE, "rule %d (`allow %s %s:%s`) 要再摊 %lld 项，超过我为通配展开准备的上限 %d ⇒ 我不写这种尺寸的 delta；"
			    "要放开\"所有域\"请写属性名(一个节点就够，机制见 services.c:613)",
			    i + 1, r->sname, r->tname, r->cname, s_cnt * t_cnt, MAXJOBS);
		printf("WILD_PLAN rule=%d %s %s:%s%s 展开=%lld 项\n", i + 1, r->sname, r->tname, r->cname,
		       r->all_perms ? " perms*" : "", s_cnt * t_cnt);
		for (a = 0; a < (int)s_cnt; a++) {
			for (b = 0; b < (int)t_cnt; b++) {
				jobs[njobs].r = r;
				jobs[njobs].src = r->src_wild ? wild_universe[a] : r->src;
				jobs[njobs].tgt = r->tgt_wild ? wild_universe[b] : r->tgt;
				njobs++;
			}
		}
	}
	printf("JOBS=%d from RULES=%d\n", njobs, nrules);
}

static void apply_delta(void)
{
	int i;
	int inserted = 0, merged = 0, verified = 0;

	build_jobs();
	for (i = 0; i < njobs; i++) {
		struct job *jb = &jobs[i];
		rule_t *r = jb->r;
		avtab_key_t k;
		avtab_datum_t d;
		avtab_ptr_t node;
		const char *action;
		int rc;

		memset(&k, 0, sizeof(k));
		k.source_type = (uint16_t)jb->src;
		k.target_type = (uint16_t)jb->tgt;
		k.target_class = (uint16_t)r->cls;
		k.specified = AVTAB_ALLOWED;
		if (k.source_type != jb->src || k.target_type != jb->tgt || k.target_class != r->cls)
			die(RC_RULE, "JOB %d: id %u/%u exceeds the 16-bit avtab key field — this policy is too big "
			    "for the layout I am writing", i + 1, jb->src, jb->tgt);

		node = avtab_search_node(&P->te_avtab, &k);
		if (node) {
			node->datum.data |= r->bits;      /* 只 OR，绝不 &~ ：不可能削掉任何已有权限 */
			action = "merged";
			merged++;
		} else {
			memset(&d, 0, sizeof(d));
			d.data = r->bits;
			d.xperms = NULL;
			rc = avtab_insert(&P->te_avtab, &k, &d);
			if (rc)
				die(RC_RULE, "JOB %d: avtab_insert rc=%d (=%s)", i + 1, rc,
				    rc == SEPOL_EEXIST ? "EEXIST: an ALLOW node already exists but search missed it" :
				    rc == SEPOL_ENOMEM ? "ENOMEM" : "unexpected");
			action = "added";
			inserted++;
		}
		/* ★非通配那批逐条印(它是"我要开哪几扇门"的清单)；通配展开那批只印前 3 条＋计数，
		 *   免得一份 1.9 万行的证件把关键行淹掉(证件也要能被读完)。 */
		if (!r->src_wild && !r->tgt_wild)
			printf("RULE %d src=%s/%u tgt=%s/%u class=%s/%u bits=0x%08x action=%s\n",
			       i + 1, r->sname, jb->src, r->tname, jb->tgt, r->cname, r->cls, r->bits, action);
		else if (i < 3)
			printf("WILDJOB %d src=%s/%u tgt=%s/%u class=%s bits=0x%08x action=%s (只印前 3 条)\n",
			       i + 1, r->sname, jb->src, r->tname, jb->tgt, r->cname, r->bits, action);
	}

	/* 回读自查：摊完之后**每个工作项**再搜一遍表，确认每条的位都在那个节点里（写之前先证自己真写进表了）
	 *   ★通配展开也一样要过这把尺——"我算出来 3265 项"和"表里真有 3265 项带着这些位"是两件事。 */
	for (i = 0; i < njobs; i++) {
		struct job *jb = &jobs[i];
		rule_t *r = jb->r;
		avtab_key_t k;
		avtab_ptr_t node;

		memset(&k, 0, sizeof(k));
		k.source_type = (uint16_t)jb->src;
		k.target_type = (uint16_t)jb->tgt;
		k.target_class = (uint16_t)r->cls;
		k.specified = AVTAB_ALLOWED;
		node = avtab_search_node(&P->te_avtab, &k);
		if (!node)
			die(RC_RULE, "VERIFY JOB %d: node vanished from te_avtab after insert", i + 1);
		if ((node->datum.data & r->bits) != r->bits)
			die(RC_RULE, "VERIFY JOB %d: node holds 0x%08x which lacks my bits 0x%08x",
			    i + 1, node->datum.data, r->bits);
		verified++;
	}
	printf("INSERTED=%d MERGED=%d VERIFIED=%d JOBS=%d RULES_IN_FILE=%d WILD_RULES=%d\n",
	       inserted, merged, verified, njobs, nrules, wild_rules);
}

/* perms <in.pol> <class> [<class2> ...] — 把这个类的 (权限名, 表里存的 value) 全打出来。
 * 存在的理由：这份厂商件 binder 类的 set_context_mgr 存的是 0x3（不是单个位），
 * 我要先看清厂商的 value 到底是"位掩码"还是"序号"，再决定 dump 怎么解码，不能猜。 */
static void print_class_perms(const char *cls)
{
	uint32_t cv = 0;
	class_datum_t *cd = class_datum_of(cls, &cv);
	hashtab_t t;
	unsigned int s;
	int n = 0;

	printf("CLASS %s value=%u nprim=%u comkey=%s commonnprim=%u\n",
	       cls, cv, cd->permissions.nprim, cd->comkey ? cd->comkey : "(none)",
	       cd->comdatum ? cd->comdatum->permissions.nprim : 0);
	t = cd->permissions.table;
	for (s = 0; s < t->size; s++) {
		hashtab_ptr_t node;

		for (node = t->htable[s]; node; node = node->next) {
			perm_datum_t *pd = (perm_datum_t *)node->datum;

			printf("PERM own %-22s ordinal=%u bit=%u\n",
			       (char *)node->key, pd->s.value, pd->s.value ? pd->s.value - 1 : 99);
			n++;
		}
	}
	if (cd->comdatum && cd->comdatum->permissions.table) {
		t = cd->comdatum->permissions.table;
		for (s = 0; s < t->size; s++) {
			hashtab_ptr_t node;

			for (node = t->htable[s]; node; node = node->next) {
				perm_datum_t *pd = (perm_datum_t *)node->datum;

				printf("PERM com %-22s ordinal=%u bit=%u\n",
				       (char *)node->key, pd->s.value, pd->s.value ? pd->s.value - 1 : 99);
				n++;
			}
		}
	}
	printf("CLASS_TOTAL %s perms=%d\n", cls, n);
}

/* 只读模式：把类型表每条的"形状"打出来，给"要不要插新类型"这件事当凭据。
 *   ★为什么需要：内核的 `type_read` 每条都读一个**显式的 value**（5.4.281 的 `ss/policydb.c:1444` 那族），
 *     属性关系不在类型条目里、而在符号表之后的一段 `type_attr_map[i]`（每类型一条 ebitmap，内核 `:2510` 读）
 *     ⇒ 想知道"往表尾加一个类型会不会把别人重编号"，得先看厂商这份的 value/bounds/flavor 长什么样，
 *     而不是按我对 CIL 的印象猜。这个模式不做任何修改。 */
static void dump_types(const char *outpath, int head_tail)
{
	FILE *of = stdout;
	uint32_t i;
	unsigned long n_primary = 0, n_attrib = 0, n_alias = 0, other = 0;
	unsigned long b_self = 0, b_other = 0;
	unsigned long nomap = 0, mism = 0;

	if (outpath && strcmp(outpath, "-") != 0) {
		of = fopen(outpath, "wb");
		if (!of)
			die(RC_WRITE, "open %s failed", outpath);
	}
	for (i = 1; i <= P->p_types.nprim; i++) {
		type_datum_t *t = (type_datum_t *)P->type_val_to_struct[i - 1];
		const char *nm = P->p_type_val_to_name[i - 1];
		unsigned long ta_bits = 0, ty_bits = 0;
		ebitmap_node_t *en;
		unsigned int e;

		if (!t || !nm) {
			fprintf(of, "TYPE %u GAP (val_to_struct/val_to_name 有空位)\n", i);
			other++;
			continue;
		}
		if (t->flavor == TYPE_ATTRIB) n_attrib++;
		else if (t->flavor == TYPE_TYPE) n_primary++;
		else if (t->flavor == TYPE_ALIAS) n_alias++;
		else other++;
		if (t->bounds == t->s.value) b_self++; else b_other++;
		if (i - 1 < P->p_types.nprim && P->type_attr_map) {
			ebitmap_for_each_bit(&P->type_attr_map[i - 1], en, e) {
				if (ebitmap_node_get_bit(en, e)) ta_bits++;
			}
		} else nomap++;
		ebitmap_for_each_bit(&t->types, en, e) {
			if (ebitmap_node_get_bit(en, e)) ty_bits++;
		}
		/* 两种表示应当一致：条目自带的 types(它属于哪些属性) vs 全表的 type_attr_map[i]
		 * 后者含"自己那一票"(内核读的时候补的 degenerate self bit)，所以只比"去掉自票"的数 */
		if (ta_bits && ty_bits + 1 != ta_bits) mism++;
		if (i <= (unsigned)head_tail || i > P->p_types.nprim - (unsigned)head_tail)
			fprintf(of, "TYPE %u name=%s flavor=%u primary=%u bounds=%u types_bits=%lu ta_bits=%lu\n",
				i, nm, t->flavor, t->primary, t->bounds, ty_bits, ta_bits);
	}
	fprintf(of, "TYPES_TOTAL=%u primary=%lu attrib=%lu alias=%lu other=%lu bounds_self=%lu bounds_other=%lu nomap=%lu 两种表示不符=%lu\n",
		P->p_types.nprim, n_primary, n_attrib, n_alias, other, b_self, b_other, nomap, mism);
	if (of != stdout) fclose(of);
}

/* 只读模式：把"value → 名字 → 它属于哪些属性"整张表打出来，用来验**往返前后逐条相同**。
 *   ★为什么单独立这一格(11-03)：内核读符号表时每条**自带 value**(`type_read` 里 `typdatum->value = buf[1]`)，
 *     但紧随其后的那段属性映射(`policydb.c:2510` 的 `for i<nprim: ebitmap_read(type_attr_map[i])`)是**按位置**对的；
 *     libsepol 写的时候也是按位置(`write.c` 的 `for i<nprim: ebitmap_write(&p->type_attr_map[i])`)。
 *     ⇒ 只要"符号表写出的次序"不等于 value 升序，整张属性映射就会**集体错位**——
 *     而这种错位**不会**出现在 avtab 三元组差分里(93/94 的判据看不到它)，却会让执法态下"谁属于哪个域/文件类型"全乱。
 *     所以往返必须单独比这张表。本模式不做任何修改。 */
static void dump_type_attr_map(const char *outpath)
{
	FILE *of = stdout;
	uint32_t i;

	if (outpath && strcmp(outpath, "-") != 0) {
		of = fopen(outpath, "wb");
		if (!of)
			die(RC_WRITE, "open %s failed", outpath);
	}
	if (!P->type_attr_map)
		die(RC_READ, "p->type_attr_map 是空的(这份策略没带 ATAR 段？)");
	for (i = 1; i <= P->p_types.nprim; i++) {
		ebitmap_t *m = &P->type_attr_map[i - 1];
		ebitmap_node_t *en;
		unsigned int e;
		int first = 1, selfbit = 0, nattr = 0;

		/* ★先量这一格：这份内存表里"自己那一票"到底在不在(11-03 现测，不按印象写)。
		 *   它决定插新类型时新行要不要置自票——照现有行的约定办，不自作主张。 */
		selfbit = ebitmap_get_bit(m, i - 1);
		fprintf(of, "TMAP %u %s self=%d", i,
			P->p_type_val_to_name[i - 1] ? P->p_type_val_to_name[i - 1] : "(null)", selfbit);
		ebitmap_for_each_bit(m, en, e) {
			if (!ebitmap_node_get_bit(en, e))
				continue;
			if (e + 1 == i)
				continue;            /* 自票单列在 self= 里，不进 ATTR 表 */
			nattr++;
			fprintf(of, " %s%s", first ? "ATTR=" : ",",
				e < P->p_types.nprim && P->p_type_val_to_name[e] ? P->p_type_val_to_name[e] : "?");
			first = 0;
		}
		if (first)
			fprintf(of, " ATTR=");
		fprintf(of, " N=%d\n", nattr);
	}
	fprintf(of, "TMAP_TOTAL=%u\n", P->p_types.nprim);
	if (of != stdout)
		fclose(of);
}

static void usage(const char *me)
{
	fprintf(stderr,
		"usage: %s rt    <in.pol> <out.pol>\n"
		"       %s delta <in.pol> <out.pol> <rules.txt>\n"
		"       %s dump  <in.pol> <out.txt>\n"
		"       %s types <in.pol> [out.txt] [head_tail]\n"
		"       %s tmap  <in.pol> <out.txt>\n"
		"       %s perms <in.pol> <class> [class2 ...]\n", me, me, me, me, me, me);
}

int main(int argc, char **argv)
{
	if (argc < 4) {
		usage(argv[0]);
		return RC_USAGE;
	}
	if (!strcmp(argv[1], "rt")) {
		if (argc != 4) {
			usage(argv[0]);
			return RC_USAGE;
		}
		load_policy(argv[2]);
		write_policy(argv[3]);
		return 0;
	}
	if (!strcmp(argv[1], "types")) {
		if (argc > 5) {
			usage(argv[0]);
			return RC_USAGE;
		}
		load_policy(argv[2]);
		dump_types(argc > 3 ? argv[3] : "-", argc > 4 ? atoi(argv[4]) : 6);
		return 0;
	}
	if (!strcmp(argv[1], "tmap")) {
		if (argc != 4) {
			usage(argv[0]);
			return RC_USAGE;
		}
		load_policy(argv[2]);
		dump_type_attr_map(argv[3]);
		return 0;
	}
	if (!strcmp(argv[1], "dump")) {
		if (argc != 4) {
			usage(argv[0]);
			return RC_USAGE;
		}
		load_policy(argv[2]);
		dump_policy(argv[3]);
		return 0;
	}
	if (!strcmp(argv[1], "delta")) {
		if (argc != 5) {
			usage(argv[0]);
			return RC_USAGE;
		}
		load_policy(argv[2]);
		parse_rules(argv[4]);
		apply_delta();
		write_policy(argv[3]);
		return 0;
	}
	if (!strcmp(argv[1], "perms")) {
		int i;

		if (argc < 4) {
			usage(argv[0]);
			return RC_USAGE;
		}
		load_policy(argv[2]);
		for (i = 3; i < argc; i++)
			print_class_perms(argv[i]);
		return 0;
	}
	usage(argv[0]);
	return RC_USAGE;
}
