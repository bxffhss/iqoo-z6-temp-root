/* w1161_host_selftest.c — #238 部件③「装载门」的宿主自测(x86，0 枪)。
 * 跑的是**将来接进 ko 的那份判定**(`kmod/w1161_polgate.h`)，不是摹本。
 *   T1 两张**真·设备策略图**：长度与 FNV 必须等于第 96 发设备上自己印的 `pl_pre_len/pl_pre_sum/pl_post_*`
 *   T2 全部条件都好 ⇒ 放行(且放行那格的号/名都对照探针那张表)
 *   T3 每把闸单独扳红：期望的**号**与**名字**都写死，逐格比
 *   T4 次序：两样同时坏 ⇒ 必须是先查那把说话(逐对，不靠运气)
 *   T5 边界：恰好 32 字节的合法头必须放行(例 226：闸不许拒自己的合法输入)；31 拒
 *   T6 跨图那格＝"中途有人装载过"：用两张真图的指纹，一个武装值配另一个 ⇒ 必拒
 *   T7 上限：len==cap 放行、len==cap+1 拒
 * 用法：w1161_st <图目录> <第96发腿证件>
 */
#include <errno.h>
#include <linux/magic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "w1159_sepol_wire.h"  /* 只为复用那把 FNV(与内核/设备/宿主已经三方对过表的一把) */
#include "w1161_polgate.h"

static long g_asserts, g_fails;

#define CHK(cond, ...)          \
	do {                    \
		g_asserts++;    \
		if (!(cond)) {  \
			g_fails++; \
			printf("[BAD] "); \
			printf(__VA_ARGS__); \
			printf("\n"); \
			fflush(stdout); \
		} \
	} while (0)
#define OKF(...)               \
	do {                   \
		printf("[OK] "); \
		printf(__VA_ARGS__); \
		printf("\n");    \
		fflush(stdout);  \
	} while (0)

#define KV_MISS (~(w1151_u64)0)
static w1151_u64 kv(const char *line, const char *key)
{
	char pat[32];
	const char *p;

	snprintf(pat, sizeof(pat), "%s=", key);
	p = strstr(line, pat);
	if (!p)
		return KV_MISS;
	p += strlen(pat);
	return (w1151_u64)strtoull(p, NULL, 10);
}

static w1151_u8 *g_before, *g_after;
static w1151_u64 g_blen, g_alen;
static w1151_u64 g_pre_sum_dev, g_post_sum_dev, g_pre_len_dev, g_post_len_dev;
static int g_dev_why, g_dev_load_rc;

/* 老实的定长读法：先量文件多大，再一口一口读到等长为止，最后要求没出错且读满。 */
static int read_exact(const char *path, w1151_u8 **out, w1151_u64 *len)
{
	FILE *f;
	w1151_u8 *b;
	w1151_u64 sz = 0, got = 0;

	f = fopen(path, "rb");
	if (!f)
		return -1;
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return -1;
	}
	sz = (w1151_u64)ftell(f);
	rewind(f);
	if (sz == 0) {
		fclose(f);
		return -1;
	}
	b = malloc((size_t)sz);
	if (!b) {
		fclose(f);
		return -1;
	}
	while (got < sz) {
		size_t r = fread(b + got, 1, (size_t)(sz - got), f);
		if (r == 0)
			break;
		got += (w1151_u64)r;
	}
	if (ferror(f) || got != sz) {
		free(b);
		fclose(f);
		return -1;
	}
	fclose(f);
	*out = b;
	*len = got;
	return 0;
}

/* 读第 96 发腿证件里那几行设备自己印的数。 */
static int read_shot96(const char *path)
{
	FILE *f = fopen(path, "r");
	char line[512];

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		if (strstr(line, "post_pre_len="))
			g_pre_len_dev = kv(line, "post_pre_len");
		else if (strstr(line, "post_pre_sum="))
			g_pre_sum_dev = kv(line, "post_pre_sum");
		else if (strstr(line, "post_post_len="))
			g_post_len_dev = kv(line, "post_post_len");
		else if (strstr(line, "post_post_sum="))
			g_post_sum_dev = kv(line, "post_post_sum");
		else if (strstr(line, "post_why=") && !strstr(line, "post_which"))
			g_dev_why = (int)kv(line, "post_why");
		else if (strstr(line, "post_load_rc="))
			g_dev_load_rc = (int)kv(line, "post_load_rc");
	}
	fclose(f);
	return 0;
}

/* 一个"全条件都好"的请求，图用 before。 */
static void good_req(struct w1161_req *r, const w1151_u8 *img, w1151_u64 len, w1151_u64 armed)
{
	memset(r, 0, sizeof(*r));
	r->key_ok = 1;
	r->syms_ok = 1;
	r->have_img = 1;
	r->fault = 0;
	r->len = len;
	r->cap = 64u * 1024u * 1024u;
	r->magic_want = SELINUX_MAGIC;
	r->taglen_want = (w1151_u32)(sizeof("SE Linux") - 1); /* ★不是写死的 8，是从串本身推的 */
	r->head = img;
	r->readpol_ok = 1;
	r->armed = 1;
	r->armed_sum = armed;
	r->live_sum = armed;
}

static const char *whyname(int why)
{
	return w1161_why_name(why);
}

static void cell(const char *tag, struct w1161_req *r, int want, int changed)
{
	int got = w1161_gate(r);

	(void)changed;
	CHK(got == want, "%s 期望拒在 %d(%s)，实际 %d(%s)\n", tag, want, whyname(want), got,
	    whyname(got));
	if (got != want)
		printf("      %s 的号与探针那张表对不上 ⇒ 这张表分了家就是判据分了家\n", tag);
}

/* ===== T1 ===== */
static void t1_real_images(const char *dir)
{
	char p[512];
	w1151_u64 fb, fa;

	snprintf(p, sizeof(p), "%s/pol.before", dir);
	CHK(read_exact(p, &g_before, &g_blen) == 0, "T1 读不到 %s(%s)⇒ 后面全没测\n", p,
	    strerror(errno));
	snprintf(p, sizeof(p), "%s/pol.after", dir);
	CHK(read_exact(p, &g_after, &g_alen) == 0, "T1 读不到 %s(%s)⇒ 后面全没测\n", p,
	    strerror(errno));
	if (!g_before || !g_after)
		return;
	fb = w1159_fnv64(g_before, g_blen);
	fa = w1159_fnv64(g_after, g_alen);
	/* ★这四条是这一栏最硬的证人：数不是我写的，是那一发设备自己印出来的。 */
	CHK(g_blen == g_pre_len_dev, "T1 before 长度 我=%llu 设备印的 pl_pre_len=%llu\n", g_blen,
	    g_pre_len_dev);
	CHK(g_alen == g_post_len_dev, "T1 after 长度 我=%llu 设备印的 pl_post_len=%llu\n", g_alen,
	    g_post_len_dev);
	CHK(fb == g_pre_sum_dev, "T1 before 的 FNV 我=%llu 设备印的 pl_pre_sum=%llu\n", fb,
	    g_pre_sum_dev);
	CHK(fa == g_post_sum_dev, "T1 after 的 FNV 我=%llu 设备印的 pl_post_sum=%llu\n", fa,
	    g_post_sum_dev);
	/* 头四个字段：魔数/串长/串体/版本号 */
	CHK(w1161_le32(g_before) == SELINUX_MAGIC, "T1 before 的魔数=0x%08x 而 linux/magic.h 的 SELINUX_MAGIC=0x%08x\n",
	    w1161_le32(g_before), (unsigned)SELINUX_MAGIC);
	CHK(w1161_le32(g_before + W1161_STRLEN_OFF) == (w1151_u32)(sizeof("SE Linux") - 1),
	    "T1 before 的串长=%u\n", (unsigned)w1161_le32(g_before + W1161_STRLEN_OFF));
	CHK(memcmp(g_before + 8, "SE Linux", 8) == 0, "T1 before 的串体不是 \"SE Linux\"\n");
	/* ★版本号用**门自己那支笔**读(`w1161_policyvers`)，不在自测里另算一遍：
	 *   以后若那支笔的偏移写错，这里就该红，而不是只有内核那侧发现。 */
	{
		struct w1161_req hv;

		good_req(&hv, g_before, g_blen, g_pre_sum_dev);
		OKF("T1 两张真图：长度与 FNV 都＝第 96 发设备自己印的(pl_pre_sum=%llu pl_post_sum=%llu)；头三样现读 magic=0x%08x taglen=%u vers=%u",
		    g_pre_sum_dev, g_post_sum_dev, (unsigned)w1161_magic(&hv),
		    (unsigned)w1161_taglen(&hv), (unsigned)w1161_policyvers(&hv));
	}
	/* ★探针当年那一路的读数：它 why=0 且 load_rc=0 ⇒ "这张头被内核的 SELINUX_MAGIC 认过" 不是我的推断 */
	CHK(g_dev_why == W1161_OK, "T1 第 96 发证件里 pl_why=%d(该 0)⇒ 那张图当年没被这道门拒过\n",
	    g_dev_why);
	CHK(g_dev_load_rc == 0, "T1 第 96 发证件里 pl_load_rc=%d(该 0)\n", g_dev_load_rc);
}

/* ===== T2/T3/T4 ===== */
static void t2_t4(void)
{
	struct w1161_req r;
	w1151_u8 small[W1161_HDR_MIN + 8];
	w1151_u64 i;

	if (!g_before)
		return;
	good_req(&r, g_before, g_blen, g_pre_sum_dev);
	cell("T2 全条件都好", &r, W1161_OK, 0);

	/* ★这里还顺手断言一件事：这道门对**两张真图**都说"放行"，但它们彼此不同 ⇒
	 *   真正把"是不是从这份活策略派生"这件事拦下来的不是头，是 armed/live 那一步(T6)。 */
	good_req(&r, g_after, g_alen, g_post_sum_dev);
	cell("T2b 另一张真图同样放行", &r, W1161_OK, 0);

	/* T3：每把闸单独扳红 */
	good_req(&r, g_before, g_blen, g_pre_sum_dev);
	r.key_ok = 0;
	cell("T3 钥匙坏", &r, W1161_NOKEY, 1);
	r.key_ok = 1;
	r.syms_ok = 0;
	cell("T3 符号没解全", &r, W1161_SYM, 1);
	r.syms_ok = 1;
	r.have_img = 0;
	cell("T3 没交图", &r, W1161_NOIMG, 1);
	r.have_img = 1;
	r.len = 0;
	cell("T3 零长也算没图", &r, W1161_NOIMG, 1);
	r.len = g_blen;
	r.fault = 1;
	cell("T3 缓冲被 copy_from_user 弄脏过(并入 NOIMG＝探针 :236 的形状)", &r, W1161_NOIMG, 1);
	r.fault = 0;
	r.len = W1161_HDR_MIN - 1;
	cell("T3 头不够", &r, W1161_TOOSMALL, 1);
	r.len = g_blen;
	r.cap = g_blen - 1;
	cell("T3 超上限", &r, W1161_TOOLONG, 1);
	r.cap = 64u * 1024u * 1024u;
	r.magic_want = SELINUX_MAGIC + 1u;
	cell("T3 魔数不对", &r, W1161_BADMAGIC, 1);
	r.magic_want = SELINUX_MAGIC;
	r.taglen_want = 9u;
	cell("T3 串长字段不对", &r, W1161_BADSTR, 1);
	r.taglen_want = (w1151_u32)(sizeof("SE Linux") - 1);
	r.readpol_ok = 0;
	cell("T3 读活策略这一步红了(甲尺读不到)", &r, W1161_READPOL, 1);
	r.readpol_ok = 1;
	r.armed = 0;
	cell("T3 没武装", &r, W1161_ARMMISMATCH, 1);
	r.armed = 1;
	r.live_sum = g_post_sum_dev;
	r.armed_sum = g_pre_sum_dev;
	cell("T3 武装值与当下不符", &r, W1161_ARMMISMATCH, 1);

	/* T4：次序——两样同时坏，必须是先查的那把说话 */
	good_req(&r, g_before, g_blen, g_pre_sum_dev);
	r.key_ok = 0;
	r.magic_want = SELINUX_MAGIC + 1u;
	cell("T4 钥匙＋魔数同时坏 ⇒ 报钥匙", &r, W1161_NOKEY, 1);
	r.key_ok = 1;
	r.magic_want = SELINUX_MAGIC;
	r.len = 4;
	r.readpol_ok = 0;
	cell("T4 头不够＋读活策略坏 ⇒ 报头不够", &r, W1161_TOOSMALL, 1);
	r.len = g_blen;
	r.readpol_ok = 1;
	r.magic_want = SELINUX_MAGIC + 1u;
	r.armed = 0;
	cell("T4 魔数坏＋没武装 ⇒ 报魔数", &r, W1161_BADMAGIC, 1);
	r.magic_want = SELINUX_MAGIC;
	r.armed = 1;
	r.armed_sum = 1;
	r.live_sum = 2;
	r.readpol_ok = 0;
	cell("T4 读活策略坏＋指纹不符 ⇒ 报读活策略(没数就没得比)", &r, W1161_READPOL, 1);

	/* 合成头也要能过(不靠真图)：证明闸看的是**头**，不是"这张图我认得" */
	for (i = 0; i < sizeof(small); i++)
		small[i] = 0;
	small[0] = (unsigned char)(SELINUX_MAGIC & 0xffu);
	small[1] = (unsigned char)((SELINUX_MAGIC >> 8) & 0xffu);
	small[2] = (unsigned char)((SELINUX_MAGIC >> 16) & 0xffu);
	small[3] = (unsigned char)((SELINUX_MAGIC >> 24) & 0xffu);
	small[4] = 8;
	memcpy(small + 8, "SE Linux", 8);
	good_req(&r, small, W1161_HDR_MIN, 7u);
	cell("T5 恰好 32 字节的合法合成头 ⇒ 必须放行(闸不许拒自己的合法输入)", &r, W1161_OK, 1);
	r.len = W1161_HDR_MIN - 1;
	cell("T5 31 字节 ⇒ 拒", &r, W1161_TOOSMALL, 1);
	r.len = W1161_HDR_MIN;
	small[0] ^= 0xffu;
	cell("T5 头里第一位被改 ⇒ 拒在魔数(不是别处)", &r, W1161_BADMAGIC, 1);
}

/* ===== T6/T7 ===== */
static void t6_t7(void)
{
	struct w1161_req r;

	if (!g_before || !g_after)
		return;
	/* ★T6 是真场景：武装之后**别处装载过策略**(腿自己写 /sys/fs/selinux/load 也算)，
	 *   两个指纹都是设备印过的数，不是我编的。 */
	good_req(&r, g_after, g_alen, g_post_sum_dev);
	r.armed_sum = g_pre_sum_dev; /* 武装在 before 那份上，图却是 after 那一份 */
	cell("T6 武装在旧图、放行时已是新图 ⇒ 必拒", &r, W1161_ARMMISMATCH, 1);
	good_req(&r, g_after, g_alen, g_post_sum_dev);
	cell("T6 反过来配对了就放行(同一把尺的两个方向)", &r, W1161_OK, 1);
	/* ★两个指纹相等但图不相等，这道门**看不见**——它拦的是"中途活策略变了"，不是"图变了"。
	 *   这条如实写在这里，免得以后把 T6 读成"派生关系已证"。 */

	good_req(&r, g_before, g_blen, g_pre_sum_dev);
	r.cap = g_blen;
	cell("T7 恰好等于上限 ⇒ 放行", &r, W1161_OK, 1);
	r.cap = g_blen - 1;
	cell("T7 上限差一个字节 ⇒ 拒", &r, W1161_TOOLONG, 1);
	OKF("T6/T7 跨图那格与上限边界都过了：武装用的指纹来自设备印的 pl_pre_sum=%llu，当下重读到的是 pl_post_sum=%llu，两数不同⇒必拒(这条拦的是『中途活策略变了』，不是『图变了』)",
	    g_pre_sum_dev, g_post_sum_dev);
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "用法: %s <图目录(pol.before/pol.after)> <第96发腿证件>\n", argv[0]);
		return 2;
	}
	CHK(read_shot96(argv[2]) == 0, "main 读不到第 96 发腿证件 %s ⇒ 证人缺席，这一跑不算\n",
	    argv[2]);
	CHK(g_pre_sum_dev != KV_MISS && g_post_sum_dev != KV_MISS,
	    "main 从证件里没抓到 pre_sum/post_sum(键名或格式变了？)\n");
	t1_real_images(argv[1]);
	t2_t4();
	t6_t7();
	printf("SUM asserts=%ld fails=%ld\n", g_asserts, g_fails);
	printf("VERDICT=%s%s 装载门的判定：真图两把指纹对表＋逐闸扳红＋次序逐对＋边界与上限\n",
	       g_fails == 0 ? "w1161_pass" : "w1161_fail", g_fails == 0 ? " PASS" : " FAIL");
	free(g_before);
	free(g_after);
	return g_fails == 0 ? 0 : 1;
}
