/* w1159_host_selftest.c — #241：`SET_SEPOLICY` 用户态那一头的宿主自测(x86，0 枪)。
 *
 * 跑的是**将来上机的那份码**(kmod/w1159_sepol_wire.h 连它带的 w1151 核心、w1155 记录层)，不是摹本。
 *   S1 线格式的 ABI(16 字节、data 在 +8、命令字、逐字节填出来的载荷)
 *   S2 cmd→argc 的第二证人(手抄 kmod/uapi/supercall.h:63-67 那七行注释，不是再抄一遍 Rust)
 *   S3 12 行 × 期望表(＝我的**模型**)
 *   S4 12 行 × 第 97 发设备证件 rec_*(＝aarch64 内核自己印的**证人**)
 *   S5 读文件的四种收场＋两把尺的边界(含"超容量时一个字节都不许进 buf")
 *   S6 发/不发那道门的双向
 *   S7 打印出来的记录与视图同一份数(格式即接口) ＋ S8 干净流的 rc 口径
 * 用法：w1159_st <夹具目录> <期望表> <第97发证件目录>
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "w1159_sepol_wire.h"

static char g_fixdir[512]; /* run_case 之外还要用一次(§S7 的"同一份字节两回读") */
static long g_asserts, g_fails;
static w1151_u8 *g_buf;
static char *g_rec;
static struct w1151_stmt *g_st;

#define CHK(cond, ...)        \
	do {                  \
		g_asserts++;  \
		if (!(cond)) { \
			g_fails++; \
			printf("[BAD] "); \
			printf(__VA_ARGS__); \
			printf("\n"); \
			fflush(stdout); \
		} \
	} while (0)

#define OKF(...)             \
	do {                 \
		printf("[OK] "); \
		printf(__VA_ARGS__); \
		printf("\n"); \
		fflush(stdout); \
	} while (0)

/* ★取数一律拿"前导空格＋键名＋="锚住：`n=` 这种两字符的键不锚就会命中别处的子串。
 *   没找到返回哨兵全 1，让调用方的等值断言红，而不是悄悄给 0。 */
#define KV_MISS (~(w1151_u64)0)

static w1151_u64 kv(const char *line, const char *key)
{
	char pat[24];
	const char *p;

	snprintf(pat, sizeof(pat), " %s=", key);
	p = strstr(line, pat);
	if (!p)
		return KV_MISS;
	p += strlen(pat);
	/* ★19 位的 fnv/sum 用 atol 会饱和成 LONG_MAX(例 235)⇒ 一律 strtoull。 */
	return (w1151_u64)strtoull(p, NULL, 10);
}

struct row {
	char name[32];
	char file[64];
	w1151_u64 bytes, fnv, slots, why, n, bad_at, max_arg, lenmatch;
};

/* 期望表的一行(形如 `ok1 file=ok1.bin bytes=49 md5=.. fnv=.. slots=4369 why=0 n=1 bad_at=0
 * max_arg=10 lenmatch=1`)抄进 row。★这里的键名是表里的拼法(fnv=)，证件那行叫 sum=。 */
static int row_from_tbl(const char *line, struct row *r)
{
	const char *p;
	size_t i = 0;

	memset(r, 0, sizeof(*r));
	while (line[i] && line[i] != ' ' && i + 1 < sizeof(r->name)) {
		r->name[i] = line[i];
		i++;
	}
	if (i == 0)
		return -1;
	r->bytes = kv(line, "bytes");
	r->fnv = kv(line, "fnv");
	r->slots = kv(line, "slots");
	r->why = kv(line, "why");
	r->n = kv(line, "n");
	r->bad_at = kv(line, "bad_at");
	r->max_arg = kv(line, "max_arg");
	r->lenmatch = kv(line, "lenmatch");
	p = strstr(line, " file=");
	if (!p)
		return -1;
	p += 6;
	i = 0;
	while (p[i] && p[i] != ' ' && i + 1 < sizeof(r->file)) {
		r->file[i] = p[i];
		i++;
	}
	r->file[i] = 0;
	return 0;
}

/* 第 97 发设备证件：<证件目录>/rec_<名字> 的第一行形如
 *   PD v1 calls=0 why=0 n=1 bytes=49 bad_at=0 max_arg=10 lenmatch=1 sum=9728300112910051928 slots=4369
 * ★它是内核 scnprintf 出来的(pd_decode()，w1151_sepd_probe.c:117)，从设备上 pull 回来归档的。 */
static int dev_from_rec(const char *dir, const char *name, struct row *d)
{
	char path[256], line[512];
	FILE *f;

	memset(d, 0, sizeof(*d));
	snprintf(path, sizeof(path), "%s/rec_%s", dir, name);
	f = fopen(path, "r");
	if (!f)
		return -1;
	if (!fgets(line, sizeof(line), f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	if (strncmp(line, "PD v1 ", 6) != 0)
		return -1;
	d->why = kv(line, "why");
	d->n = kv(line, "n");
	d->bytes = kv(line, "bytes");
	d->bad_at = kv(line, "bad_at");
	d->max_arg = kv(line, "max_arg");
	d->lenmatch = kv(line, "lenmatch");
	d->fnv = kv(line, "sum");
	d->slots = kv(line, "slots");
	return 0;
}

/* 读文件 → 预解。code!=OK 时读数不作数(调用方自己看 code)。 */
static void run_case(const struct row *r, w1151_u32 slots, struct w1159_load *ld,
		     struct w1159_view *v, int *dec)
{
	char path[640];

	memset(ld, 0, sizeof(*ld));
	memset(v, 0, sizeof(*v));
	*dec = -7;
	snprintf(path, sizeof(path), "%s/%s", g_fixdir, r->file);
	ld->code = w1159_load_file(path, g_buf, W1151_IN_MAX, ld);
	if (ld->code != W1159_F_OK)
		return;
	*dec = w1159_preview(g_buf, ld->got, slots, g_st, g_rec, W1159_REC_CAP, 0, 0, v);
}

static void cmp_keys(const char *tag, const char *name, const struct w1159_view *v,
		     w1151_u64 got_bytes, const struct row *want)
{
	CHK(v->rep.why == (w1151_u32)want->why, "%s %s why 我=%u 对面=%llu\n", tag, name,
	    v->rep.why, want->why);
	CHK(v->rep.n == (w1151_u32)want->n, "%s %s n 我=%u 对面=%llu\n", tag, name, v->rep.n,
	    want->n);
	CHK(v->rep.bad_at == want->bad_at, "%s %s bad_at 我=%llu 对面=%llu\n", tag, name,
	    v->rep.bad_at, want->bad_at);
	CHK(v->rep.max_arg_len == (w1151_u32)want->max_arg, "%s %s max_arg 我=%u 对面=%llu\n",
	    tag, name, v->rep.max_arg_len, want->max_arg);
	CHK(v->lenmatch == (int)want->lenmatch, "%s %s lenmatch 我=%d 对面=%llu\n", tag, name,
	    v->lenmatch, want->lenmatch);
	CHK(v->fnv == want->fnv, "%s %s fnv 我=%llu 对面=%llu\n", tag, name, v->fnv, want->fnv);
	CHK(got_bytes == want->bytes, "%s %s 我喂了 %llu 字节，对面=%llu\n", tag, name, got_bytes,
	    want->bytes);
}

/* ===== S1 ===== */
static void s1_wire_abi(void)
{
	struct ksu_set_sepolicy_cmd c;
	unsigned char raw[sizeof(c)], exp[sizeof(c)];
	w1151_u64 len = 0x2bull;
	/* ★拿一个**明显不是真地址**的魔数当 data：fill_cmd 只做整数转换、不 deref，
	 *   而用它才能查出"填成偏移/段内相对"这类不会有任何编译错误的 ABI 错。 */
	const void *fake = (const void *)(uintptr_t)0x1122334455667788ull;
	w1151_u64 fv = (w1151_u64)(uintptr_t)fake;
	size_t i, first = (size_t)-1;

	CHK(sizeof(c) == 16, "S1 ksu_set_sepolicy_cmd=%zu 字节(两个 u64⇒该 16)\n", sizeof(c));
	CHK(offsetof(struct ksu_set_sepolicy_cmd, data) == 8,
	    "S1 data 在 +8(实=%zu)：内核按 +8 读那个指针，这里错一位就只有个查不出原因的 EFAULT\n",
	    offsetof(struct ksu_set_sepolicy_cmd, data));
	/* 命令字手抄自 _IOC 的编码：dir=READ|WRITE=3 ⇒ 3<<30 | size 0<<16 | 'K'(0x4b)<<8 | 4 */
	CHK(KSU_IOCTL_SET_SEPOLICY == 0xc0004b04u,
	    "S1 SET_SEPOLICY 命令字=0x%08x 手抄编码=0xc0004b04\n",
	    (unsigned)KSU_IOCTL_SET_SEPOLICY);

	w1159_fill_cmd(&c, fake, len);
	memcpy(raw, &c, sizeof(raw));
	memset(exp, 0, sizeof(exp));
	for (i = 0; i < 8; i++) {
		exp[i] = (unsigned char)((len >> (8 * i)) & 0xffull);
		exp[8 + i] = (unsigned char)((fv >> (8 * i)) & 0xffull);
	}
	for (i = 0; i < sizeof(raw); i++)
		if (raw[i] != exp[i]) {
			first = i;
			break;
		}
	CHK(first == (size_t)-1, "S1 填出来的 16 字节与手抄的小端不一致：字节 %zu 我=%02x 期望=%02x\n",
	    first == (size_t)-1 ? 0 : first, first == (size_t)-1 ? 0 : raw[first],
	    first == (size_t)-1 ? 0 : exp[first]);
	OKF("S1 线格式 ABI：16 字节／data 在 +8／命令字 0xc0004b04／逐字节填法全对");
}

/* ===== S2 ===== */
static void s2_second_witness(void)
{
	/* ★手抄 kmod/uapi/supercall.h:63-67 那七行注释(内核自己发的那份头)，不是再抄一遍 Rust：
	 *   两处独立来源对不上，就说明我某一处抄错了。索引＝cmd，0＝不认得。 */
	static const w1151_u32 doc[10] = { 0, 4, 5, 1, 2, 2, 1, 5, 4, 3 };
	w1151_u32 cmd, diff = 0;

	for (cmd = 0; cmd < 10; cmd++) {
		w1151_u32 got = w1151_cmd_argc(cmd);
		CHK(got == doc[cmd], "S2 cmd=%u argc 核心=%u uapi 注释=%u\n", cmd, got, doc[cmd]);
		if (got != doc[cmd])
			diff++;
	}
	OKF("S2 cmd→argc 与内核头里的注释逐格对表(10 格%s)", diff ? "★有差" : "，全等");
}

/* ===== S3(模型) ＋ S4(设备证人) ===== */
static void s3_s4_tables(const char *tblpath, const char *recdir)
{
	FILE *f;
	char line[1024];
	int rows = 0, a_bad = 0, d_bad = 0, no_dev = 0;

	f = fopen(tblpath, "r");
	if (!f) {
		CHK(0, "S3 打不开期望表 %s(%s)\n", tblpath, strerror(errno));
		return;
	}
	while (fgets(line, sizeof(line), f)) {
		struct row r, d;
		struct w1159_load ld;
		struct w1159_view v;
		int dec;

		if (line[0] == '#' || line[0] == '\n' || line[0] == ' ')
			continue;
		if (row_from_tbl(line, &r))
			continue;
		rows++;
		run_case(&r, (w1151_u32)r.slots, &ld, &v, &dec);
		if (ld.code != W1159_F_OK) {
			CHK(0, "S3 %s 读文件 code=%d want=%llu got=%llu(表里 bytes=%llu)\n",
			    r.name, ld.code, ld.want, ld.got, r.bytes);
			a_bad++;
			continue;
		}
		/* ①模型：期望表(它自己在第 97 发之后已被设备的读数纠正过，见 §347) */
		cmp_keys("S3", r.name, &v, ld.got, &r);
		if (v.rep.why != (w1151_u32)r.why || v.fnv != r.fnv)
			a_bad++;

		/* ②证人：第 97 发设备上内核自己印的那一行 */
		if (dev_from_rec(recdir, r.name, &d)) {
			CHK(0, "S4 %s 没有设备证件 rec_%s ⇒ 这一格没有证人\n", r.name, r.name);
			no_dev++;
			continue;
		}
		cmp_keys("S4", r.name, &v, ld.got, &d);
		/* ★格子数两边必须同值：`slots` 决定了 E_TOO_MANY 在哪一格翻，不同值就不是同一件事 */
		CHK(d.slots == r.slots, "S4 %s 设备 pd_slots=%llu 表里 slots=%llu\n", r.name,
		    d.slots, r.slots);
		CHK(dec == 0 || v.rep.why != W1151_OK, "S4 %s 解码返回值=%d 却 why=0 ⇒ 核的口径分了\n",
		    r.name, dec);
		if (v.rep.why != (w1151_u32)d.why || v.fnv != d.fnv)
			d_bad++;
	}
	fclose(f);
	CHK(rows == 12, "S3 期望表数到 %d 行(该 12 行；行数变了＝喂的是另一张表)\n", rows);
	CHK(no_dev == 0, "S4 缺证人 %d 格\n", no_dev);
	OKF("S3 对期望表(模型)红=%d；S4 对设备证件(证人)红=%d；两者都数了 12 格", a_bad, d_bad);
}

/* ===== S5 ===== */
static int wr_file(const char *path, size_t n)
{
	FILE *f = fopen(path, "wb");
	size_t i;

	if (!f)
		return -1;
	for (i = 0; i < n; i++)
		if (fputc((int)(i & 0xff), f) == EOF) {
			fclose(f);
			return -1;
		}
	fclose(f);
	return 0;
}

static void s5_file_shapes(void)
{
	struct w1159_load ld;
	struct w1159_view v;
	int code, dec;

	code = w1159_load_file("./w1159_no_such_file.bin", g_buf, W1151_IN_MAX, &ld);
	CHK(code == W1159_F_OPEN && ld.code == W1159_F_OPEN, "S5 不存在的路径 code=%d(该 %d)\n",
	    code, W1159_F_OPEN);
	CHK(ld.got == 0, "S5 打不开却 got=%llu\n", ld.got);

	if (wr_file("w1159_empty.bin", 0) == 0) {
		code = w1159_load_file("w1159_empty.bin", g_buf, W1151_IN_MAX, &ld);
		CHK(code == W1159_F_OK && ld.want == 0 && ld.got == 0,
		    "S5 空文件 code=%d want=%llu got=%llu\n", code, ld.want, ld.got);
		/* ★空流的 FNV＝种子本身，不是 0：这个数一变，"两边吃同一批字节"那把尺就作废。 */
		CHK(ld.fnv == 1469598103934665603ull, "S5 空流 fnv=%llu 不等于种子\n", ld.fnv);
		dec = w1159_preview(g_buf, 0, W1159_SLOTS, g_st, g_rec, W1159_REC_CAP, 0, 0, &v);
		CHK(v.rep.why == W1151_E_EMPTY && v.rep.n == 0 && v.lenmatch == 0,
		    "S5 空流该判 E_EMPTY(%u)，我解出 why=%u n=%u lenmatch=%d\n", W1151_E_EMPTY,
		    v.rep.why, v.rep.n, v.lenmatch);
		(void)dec;
		unlink("w1159_empty.bin");
	} else
		CHK(0, "S5 造不出空文件 ⇒ 那格没测\n");

	/* 边界：恰好 cap 该放行——解码器的尺也是 >cap 才拒(两把尺边界不同形就会造出"两边读数不一样"的假案) */
	if (wr_file("w1159_cap.bin", (size_t)W1151_IN_MAX) == 0) {
		code = w1159_load_file("w1159_cap.bin", g_buf, W1151_IN_MAX, &ld);
		CHK(code == W1159_F_OK && ld.got == W1151_IN_MAX,
		    "S5 恰好 cap=%llu 字节 code=%d got=%llu\n", W1151_IN_MAX, code, ld.got);
		/* ★放行不等于干净：0..cap 是一堆不认识的字节，必须落到"拒"而不是崩或假正 */
		dec = w1159_preview(g_buf, ld.got, W1159_SLOTS, g_st, g_rec, W1159_REC_CAP, 0, 0,
				    &v);
		CHK(dec != 0 && v.rep.why != W1151_OK, "S5 cap 字节垃圾流被判干净了(dec=%d)\n", dec);
		unlink("w1159_cap.bin");
	} else
		CHK(0, "S5 造不出 64K 文件 ⇒ 边界那格没测\n");

	/* 超容量：拒，而且一个字节都不许进 buf(半个流交上去只会得到一个骗人的 errno) */
	memset(g_buf, 0xaa, 4096);
	if (wr_file("w1159_big.bin", (size_t)W1151_IN_MAX + 1) == 0) {
		code = w1159_load_file("w1159_big.bin", g_buf, W1151_IN_MAX, &ld);
		CHK(code == W1159_F_BIG && ld.code == W1159_F_BIG,
		    "S5 超容量 code=%d(该 %d) want=%llu\n", code, W1159_F_BIG, ld.want);
		CHK(ld.got == 0, "S5 超容量却 got=%llu ⇒ 拒了还把半个流留在 buf 里\n", ld.got);
		CHK(g_buf[0] == 0xaa && g_buf[4095] == 0xaa,
		    "S5 超容量动了 buf(g[0]=%02x g[4095]=%02x)\n", g_buf[0], g_buf[4095]);
		unlink("w1159_big.bin");
	} else
		CHK(0, "S5 造不出超限文件 ⇒ 那格没测\n");

	/* st_size 撒谎那一类(procfs 说 0 而读得出字节)必须落到 SHORT，不能被当成"合法的 0 字节流" */
	code = w1159_load_file("/proc/self/status", g_buf, W1151_IN_MAX, &ld);
	CHK(code == W1159_F_SHORT && ld.want == 0 && ld.got > 0,
	    "S5 /proc/self/status code=%d want=%llu got=%llu\n", code, ld.want, ld.got);
	OKF("S5 读文件四种收场＋两把尺的边界＋超容量不留半个流＋procfs 不当成空流");
}

/* ===== S6 ===== */
static void s6_gate(void)
{
	CHK(w1159_gate(0, W1159_F_OK) == W1159_DRY, "S6 没给 --send 却判定要发(%d)\n",
	    w1159_gate(0, W1159_F_OK));
	CHK(w1159_gate(1, W1159_F_OK) == W1159_FIRE, "S6 给了 --send 却判定不发(%d)\n",
	    w1159_gate(1, W1159_F_OK));
	CHK(w1159_gate(1, W1159_F_OPEN) == W1159_DRY, "S6 读不到还发(%d)\n",
	    w1159_gate(1, W1159_F_OPEN));
	CHK(w1159_gate(1, W1159_F_BIG) == W1159_DRY, "S6 超容量还发(%d)\n",
	    w1159_gate(1, W1159_F_BIG));
	CHK(w1159_gate(1, W1159_F_SHORT) == W1159_DRY, "S6 半个流还发(%d)\n",
	    w1159_gate(1, W1159_F_SHORT));
	/* ★反向对照：门**不看**解码结果——模型红不该改变"让内核自己看一眼"这件事(#241 的全部目的)。
	 *   这条断言是给"以后有人顺手把 why 也加进门里"准备的牙。 */
	CHK(w1159_gate(1, W1159_F_OK) == W1159_FIRE,
	    "S6 流读全了、解得再难看也该发(门里混进了模型判据？)");
	OKF("S6 门：默认不发＋读失败一律不发，且解码结果不参与这道门");
}

/* ===== S7 ＋ S8 ===== */
static void s7_s8_record(void)
{
	struct row r;
	struct w1159_load ld;
	struct w1159_view v;
	char want[256];
	int dec, nl;

	memset(&r, 0, sizeof(r));
	strcpy(r.name, "ok1");
	strcpy(r.file, "ok1.bin");
	run_case(&r, W1159_SLOTS, &ld, &v, &dec);
	CHK(ld.code == W1159_F_OK && ld.got == 49, "S7 ok1 code=%d got=%llu\n", ld.code, ld.got);

	/* ★打印出来的那一行必须用**同一个视图**里的数(格式即接口：参数顺序错了，
	 *   记录会一字不差地漂亮，只是数在撒谎)。 */
	nl = snprintf(want, sizeof(want),
		      "REC seq=0 calls=0 bytes=%llu sum=%llu why=%u n=%u bad_at=%llu max_arg=%u lenmatch=%d applied=0 rc=%u\n",
		      ld.got, v.fnv, v.rep.why, v.rep.n, v.rep.bad_at, v.rep.max_arg_len,
		      v.lenmatch, w1155_rc_for(v.rep.why));
	CHK(nl > 0 && (int)strlen(g_rec) >= nl && strncmp(g_rec, want, (size_t)nl) == 0,
	    "S7 记录首行与视图里的数不一致：\n      该是 %s      实是 %.*s", want, nl > 0 ? nl : 60,
	    g_rec);
	CHK(v.rec_total == (int)strlen(g_rec) && v.rec_trunc == 0,
	    "S7 记录返回 %d 而实写 %d(trunc=%d)\n", v.rec_total, (int)strlen(g_rec), v.rec_trunc);
	CHK(strstr(g_rec, "applied=0 rc=1") != NULL,
	    "S8 干净流却没写 applied=0 rc=1(不谎报那条口径)：首行=%s", g_rec);
	OKF("S7 记录与视图同源(首行逐字节＝视图里的数)＋S8 干净流 applied=0 rc=1");
}

int main(int argc, char **argv)
{
	long a0, f0;

	if (argc < 4) {
		fprintf(stderr, "用法: %s <夹具目录> <期望表> <第97发证件目录>\n", argv[0]);
		return 2;
	}
	snprintf(g_fixdir, sizeof(g_fixdir), "%s", argv[1]);
	g_buf = malloc(W1151_IN_MAX);
	g_rec = malloc(W1159_REC_CAP + 1);
	g_st = malloc(W1159_SLOTS * sizeof(*g_st));
	if (!g_buf || !g_rec || !g_st) {
		printf("[BAD] 内存没分出来(buf=%p rec=%p st=%p)\n", (void *)g_buf, (void *)g_rec,
		       (void *)g_st);
		return 1;
	}
	memset(g_buf, 0, W1151_IN_MAX);
	g_rec[W1159_REC_CAP] = 0;

	s1_wire_abi();
	s2_second_witness();
	s3_s4_tables(argv[2], argv[3]);
	s5_file_shapes();
	s6_gate();
	s7_s8_record();

	a0 = g_asserts;
	f0 = g_fails;
	printf("SUM asserts=%ld fails=%ld\n", a0, f0);
	printf("VERDICT=%s 用户态那一头：ABI＋argc 第二证人＋12 格双向对表(模型/设备)＋四种读形状＋门的双向\n",
	       f0 == 0 ? "w1159_pass" : "w1159_fail");
	free(g_buf);
	free(g_rec);
	free(g_st);
	return f0 == 0 ? 0 : 1;
}
