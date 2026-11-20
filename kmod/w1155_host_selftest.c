/* SPDX-License-Identifier: GPL-2.0 */
/* w1155_host_selftest.c —— SET_SEPOLICY 记录层(`w1155_sepol_record.h`)的宿主自测(0 枪，x86)。
 *
 * ★为什么这段值得单独测：记录层是出货 ko 那条口**唯一能事后说话**的信道(官方 ksud 会把
 *   -EOPNOTSUPP 静默吞掉＝#236)。它一旦把拒收件也印成 STMT，下游就会把"没落地的规则"读成
 *   "交进去了"。中心那条(`why≠0 ⇒ 一行 STMT 都不给`)不是我拍的——它和第 97 发设备上内核
 *   自己印的 `rec_stmts` 逐格对得上，所以这里拿**那份一手读数**当证人(C8)。
 *
 * 用法：./w1155_host_selftest <夹具目录> <expect.txt> <腿证件 w1153_leg_shot97.out>
 * 八格：
 *   C1 解码与表对表(why/n/bad_at/max_arg 四把，11 件逐件)
 *   C2 正对照：`ok1` 整条记录＝**手抄**期望串(格式由这手抄件钉住，不靠"看着像")
 *   C3 rc_for 全表：why=0..11 的小码逐个断言(OK→PENDING、INPUT_BIG→E2BIG、其余→EINVAL)
 *   C4 拒收件零 STMT：表里 why≠0 的每件 ⇒ 记录里 STMT 行必须 0 行，且仍有一行 REC＋applied=0
 *   C5 截断有数：容量＝全文＋1 ⇒ 不截；容量＝全文 ⇒ 判出截断并明写 TRUNC(不许悄悄少打一行)
 *   C6 参数转写：合成一条流现量四种长相(>64B→截＋'~'、不可打印→'.'、len=0→'<empty>'、
 *      argc 用不到的槽→'-')，两行 STMT 都**手抄**逐字节比
 *   C7 永不谎报：每件记录都含 `applied=0` 且 rc ∈ {1,2,3}(没有任何正数路径)
 *   C8 ★跨机证人：设备那 12 格的 `rec_stmts` 必须等于宿主这里同一份字节的 STMT 行数
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "w1155_sepol_record.h"

static int fails, asserts;
#define OK(msg)                     \
	do {                        \
		printf("[OK] %s\n", msg); \
		asserts++;          \
	} while (0)
#define BAD(...)                     \
	do {                         \
		printf("[BAD] " __VA_ARGS__); \
		fails++;             \
		asserts++;           \
	} while (0)
#define CHK(cond, ...)                     \
	do {                               \
		if (!(cond))               \
			BAD(__VA_ARGS__);  \
		else                       \
			asserts++;         \
	} while (0)

static char fixbuf[70000];
static char tblbuf[400000];
static char legbuf[400000];

static long read_file(const char *path, char *buf, size_t cap)
{
	FILE *f = fopen(path, "rb");
	size_t n;

	if (!f)
		return -1;
	n = fread(buf, 1, cap - 1, f);
	fclose(f);
	if (n == 0)
		return -1; /* 空件与读不到分开：这里两者都当"未测"，调用方会红 */
	buf[n] = 0;
	return (long)n;
}

/* 表里取一个键：键前必须是一个空格(⇒ ` n=` 不会误命中 ` bad_at=` 之类) */
static long tbl(const char *row, const char *key)
{
	char pat[32];
	const char *p;

	snprintf(pat, sizeof(pat), " %s=", key);
	p = strstr(row, pat);
	if (!p)
		return -999;
	return atol(p + strlen(pat));
}

/* ★`fnv` 是 19 位无符号，可以 > 2^63-1：用 atol 取它会**饱和成 LONG_MAX**，
   于是正对照自己先错(第 97 发那把 FNV 尺两端都是无符号)。这里单独走 strtoull。 */
static unsigned long long tbl_u64(const char *row, const char *key)
{
	char pat[32];
	const char *p;

	snprintf(pat, sizeof(pat), " %s=", key);
	p = strstr(row, pat);
	if (!p)
		return 0;
	return strtoull(p + strlen(pat), NULL, 10);
}

static long leg_rec_stmts(const char *name)
{
	char pat[64];
	const char *p;

	snprintf(pat, sizeof(pat), "CASE %s ", name);
	p = strstr(legbuf, pat);
	if (!p)
		return -999;
	p = strstr(p, " rec_stmts=");
	if (!p)
		return -999;
	return atol(p + strlen(" rec_stmts="));
}

static int count_lines(const char *s, const char *prefix)
{
	int n = 0;
	const char *p = s;

	while ((p = strstr(p, prefix)) != NULL) {
		if (p == s || p[-1] == '\n')
			n++;
		p += strlen(prefix);
	}
	return n;
}

static unsigned long long fnv_of(const w1151_u8 *b, w1151_u64 len)
{
	w1151_u64 h = 1469598103934665603ull, i;

	for (i = 0; i < len; i++) {
		h ^= b[i];
		h *= 1099511628211ull;
	}
	return h;
}

/* —— 合成流的小编码器(与四把来源同一线格式：u32 cmd | u32 sub | 每参 u32 len＋字节＋NUL) —— */
static void put32(char *b, unsigned v)
{
	b[0] = (char)(v & 0xff);
	b[1] = (char)((v >> 8) & 0xff);
	b[2] = (char)((v >> 16) & 0xff);
	b[3] = (char)((v >> 24) & 0xff);
}

static size_t enc_arg(char *b, const char *s, size_t n)
{
	put32(b, (unsigned)n);
	memcpy(b + 4, s, n);
	b[4 + n] = 0;
	return 4 + n + 1;
}

static size_t enc_stmt(char *b, unsigned cmd, unsigned sub, const char *const *args,
		       unsigned nargs)
{
	size_t p = 0;
	unsigned i;

	put32(b + p, cmd);
	p += 4;
	put32(b + p, sub);
	p += 4;
	for (i = 0; i < nargs; i++)
		p += enc_arg(b + p, args[i], strlen(args[i]));
	return p;
}

static const char *CASES[] = { "ok1",     "ok3",     "ok9",     "ok600",  "bad_cmd",
			       "bad_sub", "bad_nul", "bad_inner", "bad_len",
			       "bad_hdr", "bad_tail" };
#define NCASE ((int)(sizeof(CASES) / sizeof(CASES[0])))

/* ★格子数取 4369＝第 97 发设备上那一组用的同一个数：`ok600` 要 600 格才解得开，
   用 512 会在第 512 格判 TOO_MANY ⇒ 那不是被测红，是我给的格子不够。 */
#define SLOTS 4369u
static struct w1151_stmt st[SLOTS];
static struct w1151_report rep;
static char rec[65536];

int main(int argc, char **argv)
{
	char path[512], row[256], exp[2048];
	long i, len, why, n, got_stmts;
	int trunc;

	if (argc < 4) {
		printf("[BAD] 用法：<夹具目录> <expect.txt> <腿证件> ⇒ 三个输入缺一个都不算跑过\n");
		return 2;
	}
	if (read_file(argv[2], tblbuf, sizeof(tblbuf)) < 0) {
		printf("[BAD] 期望表读不到：%s\n", argv[2]);
		return 2;
	}
	if (read_file(argv[3], legbuf, sizeof(legbuf)) < 0) {
		printf("[BAD] 腿证件读不到：%s ⇒ C8 那把一手证人没有\n", argv[3]);
		return 2;
	}

	/* ===== C1 ＋ C4 ＋ C7 ＋ C8：11 件逐件 ===== */
	for (i = 0; i < NCASE; i++) {
		const char *rowp;
		long want_stmts;
		int total;

		snprintf(path, sizeof(path), "%s/%s.bin", argv[1], CASES[i]);
		len = read_file(path, fixbuf, sizeof(fixbuf));
		if (len < 0) {
			BAD("%s 读不到(%s) ⇒ 这一格未测\n", CASES[i], path);
			continue;
		}
		snprintf(row, sizeof(row), "%s ", CASES[i]);
		rowp = strstr(tblbuf, row);
		if (!rowp) {
			BAD("表里没有 %s 这一行 ⇒ 夹具与表不同源\n", CASES[i]);
			continue;
		}
		why = tbl(rowp, "why");
		n = tbl(rowp, "n");

		memset(&rep, 0, sizeof(rep));
		if (w1151_decode_stream((const w1151_u8 *)fixbuf, (w1151_u64)len, st,
					SLOTS, &rep) != 0) {
			/* 解码核心的返回值就是"拒没拒"，这里不另立标准 */
		}
		CHK((long)rep.why == why, "%s why=%u 而表=%ld ⇒ 核心与表不同源\n",
		    CASES[i], rep.why, why);
		CHK((long)rep.n == n, "%s n=%u 而表=%ld\n", CASES[i], rep.n, n);
		CHK((long)rep.bad_at == tbl(rowp, "bad_at"), "%s bad_at=%llu 而表=%ld\n",
		    CASES[i], (unsigned long long)rep.bad_at, tbl(rowp, "bad_at"));
		CHK((long)rep.max_arg_len == tbl(rowp, "max_arg"),
		    "%s max_arg=%u 而表=%ld\n", CASES[i], rep.max_arg_len,
		    tbl(rowp, "max_arg"));

		memset(rec, 0, sizeof(rec));
		trunc = 0;
		total = w1155_render(rec, sizeof(rec), &trunc, 1, 1,
				     (const w1151_u8 *)fixbuf, (w1151_u64)len,
				     fnv_of((const w1151_u8 *)fixbuf, (w1151_u64)len), st,
				     &rep, 1);
		(void)total;
		got_stmts = count_lines(rec, "STMT ");
		CHK(strstr(rec, "applied=0") != NULL,
		    "%s 的记录里没有 applied=0(这条口不许谎报)\n", CASES[i]);
		CHK(strstr(rec, "rc=1") || strstr(rec, "rc=2") || strstr(rec, "rc=3"),
		    "%s 的 rc 不在 {1,2,3} 里 ⇒ 冒出一条没人认领的返回码\n", CASES[i]);
		if (why != 0) {
			CHK(got_stmts == 0, "%s 是拒收件却印了 %ld 行 STMT\n", CASES[i],
			    got_stmts);
			CHK(count_lines(rec, "REC ") == 1, "%s 拒收件连 REC 都没一行\n",
			    CASES[i]);
		} else {
			CHK(got_stmts == n, "%s 收下了却印 %ld 行(应 %ld)\n", CASES[i],
			    got_stmts, n);
		}
		CHK(trunc == 0, "%s 在 8K 缓冲里被截断了 ⇒ 记录缓冲要给小\n", CASES[i]);
		want_stmts = leg_rec_stmts(CASES[i]);
		CHK(want_stmts == got_stmts,
		    "%s 的 STMT 行数 宿主=%ld 设备(那发内核自己印)=%ld ⇒ 记录层跨机不一致\n",
		    CASES[i], got_stmts, want_stmts);
	}
	OK("C1＋C4＋C7＋C8 十一件逐格过(解码＝表；拒收件零 STMT；applied=0；行数＝设备那手读数)");

	/* ===== C2 正对照：ok1 整条记录＝手抄件 ===== */
	snprintf(path, sizeof(path), "%s/ok1.bin", argv[1]);
	len = read_file(path, fixbuf, sizeof(fixbuf));
	if (len < 0) {
		BAD("C2 读不到 ok1.bin ⇒ 未测\n");
	} else {
		unsigned long long fv = tbl_u64(strstr(tblbuf, "ok1 "), "fnv");

		memset(&rep, 0, sizeof(rep));
		w1151_decode_stream((const w1151_u8 *)fixbuf, (w1151_u64)len, st,
				    SLOTS, &rep);
		CHK(rep.why == W1151_OK, "C2 ok1 应该整条解干净(why=%u)\n", rep.why);
		CHK((long)fv == (long)fnv_of((const w1151_u8 *)fixbuf, (w1151_u64)len),
		    "C2 我这把 FNV 与表里的 fnv 不同源(表=%llu) ⇒ 后面的 sum 证人作废\n", fv);
		snprintf(exp, sizeof(exp),
			 "REC seq=7 calls=3 bytes=49 sum=%llu why=0 n=1 bad_at=0 max_arg=10 lenmatch=1 applied=0 rc=1\n"
			 "STMT 0 cmd=1 sub=1 argc=4 a0=shell a1=su a2=file a3=entrypoint a4=-\n",
			 fv);
		memset(rec, 0, sizeof(rec));
		trunc = 0;
		w1155_render(rec, sizeof(rec), &trunc, 7, 3,
			     (const w1151_u8 *)fixbuf, (w1151_u64)len, (unsigned long long)fv,
			     st, &rep, 1);
		CHK(trunc == 0, "C2 正对照不该截断(trunc=%d)\n", trunc);
		CHK(strcmp(rec, exp) == 0, "C2 ok1 记录不等于手抄件：\n  实得[%s]\n  期望[%s]\n",
		    rec, exp);
		if (strcmp(rec, exp) == 0)
			OK("C2 正对照：整条记录与手抄件逐字节相同(四个参数原文＋第 5 槽 '-')");
	}

	/* ===== C3 rc_for 全表 ===== */
	{
		static const unsigned int want[12] = { 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3 };
		unsigned int w;

		for (w = 0; w <= 11; w++)
			CHK(w1155_rc_for(w) == want[w],
			    "C3 why=%u 给出 rc=%u 而期望=%u\n", w, w1155_rc_for(w), want[w]);
		OK("C3 rc_for 全表 0..11 逐个对上：OK→PENDING、INPUT_BIG→E2BIG、其余→EINVAL");
	}

	/* ===== C5 截断有数 ===== */
	{
		static char big[70000], big2[70000];
		long full;
		int t1 = -1, t2 = -1, n1, cap;

		snprintf(path, sizeof(path), "%s/ok3.bin", argv[1]);
		len = read_file(path, fixbuf, sizeof(fixbuf));
		if (len < 0) {
			BAD("C5 读不到 ok3.bin ⇒ 未测\n");
		} else {
			memset(&rep, 0, sizeof(rep));
			w1151_decode_stream((const w1151_u8 *)fixbuf, (w1151_u64)len, st,
					    SLOTS, &rep);
			memset(big, 0, sizeof(big));
			n1 = w1155_render(big, sizeof(big), &t1, 1, 1,
					  (const w1151_u8 *)fixbuf, (w1151_u64)len, 1, st,
					  &rep, 1);
			CHK(t1 == 0 && n1 == (int)strlen(big),
			    "C5 宽松容量下返回 %d 而实写 %d(trunc=%d) ⇒ 返回值不是『本该写出的字节数』\n",
			    n1, (int)strlen(big), t1);
			full = n1;
			cap = (int)full; /* 少一个 NUL 位 ⇒ 该判截断 */
			memset(big2, 0, sizeof(big2));
			w1155_render(big2, cap, &t2, 1, 1, (const w1151_u8 *)fixbuf,
				     (w1151_u64)len, 1, st, &rep, 1);
			CHK(t2 == 1, "C5 容量＝全文时没判出截断(trunc=%d)\n", t2);
			CHK(strstr(big2, "TRUNC cap=") != NULL, "C5 截断了却没留下 TRUNC 行\n");
			memset(big2, 0, sizeof(big2));
			w1155_render(big2, (int)full + 1, &t2, 1, 1,
				     (const w1151_u8 *)fixbuf, (w1151_u64)len, 1, st, &rep,
				     1);
			CHK(t2 == 0 && strcmp(big2, big) == 0,
			    "C5 容量＝全文＋1 却没完整写出(trunc=%d) ⇒ 边界多算了一格\n", t2);
			if (t1 == 0 && n1 == (int)strlen(big))
				OK("C5 截断有数：满容量不截、少一格就明写 TRUNC(不悄悄少打一行)");
		}
	}

	/* ===== C6 参数转写：合成流现量四种长相，两行 STMT 都手抄 ===== */
	{
		static char sb[2048];
		static char long70[80];
		const char *a2[2];
		const char *a5[5];
		size_t p = 0;
		unsigned long long fv2;

		memset(long70, 'y', 70);
		long70[70] = 0; /* 恰 70 字节：>64 ⇒ 该转写成 64 个 y ＋ '~' */
		a2[0] = "z6_new_t";
		a2[1] = "z6_new_t";
		a5[0] = long70;		/* >64 字节 ⇒ 截到 64 再补 '~' */
		a5[1] = "b\x01" "c";	/* 不可打印 ⇒ '.' */
		a5[2] = "";		/* len=0 ⇒ None/All 在线上同形 */
		a5[3] = "d";
		a5[4] = "e";
		p += enc_stmt(sb + p, 4, 0, a2, 2); /* TYPE：argc=2 ⇒ 后三槽 '-' */
		p += enc_stmt(sb + p, 7, 0, a5, 5); /* NAME_TRANSITION：argc=5 全给 */
		memset(&rep, 0, sizeof(rep));
		CHK(w1151_decode_stream((const w1151_u8 *)sb, (w1151_u64)p, st,
					SLOTS, &rep) == 0,
		    "C6 合成流本该解干净(why=%u bad_at=%llu)\n", rep.why,
		    (unsigned long long)rep.bad_at);
		CHK(rep.why == W1151_OK && rep.n == 2, "C6 合成流 why=%u n=%u 而期望 0/2\n",
		    rep.why, rep.n);
		CHK(w1151_expect_bytes(st, rep.n) == (w1151_u64)p,
		    "C6 合成流的字节数自己都对不上(expect=%llu 实=%zu) ⇒ 编码器或核心记错了线格式\n",
		    (unsigned long long)w1151_expect_bytes(st, rep.n), p);
		fv2 = fnv_of((const w1151_u8 *)sb, (w1151_u64)p);
		memset(rec, 0, sizeof(rec));
		trunc = 0;
		w1155_render(rec, sizeof(rec), &trunc, 4, 9, (const w1151_u8 *)sb,
			     (w1151_u64)p, fv2, st, &rep, 1);
		{
			char head[512], l1[96], tail[64], want[1800];
			char long64[80];

			memset(long64, 'y', sizeof(long64) - 1);
			long64[64] = 0; /* 前 64 个 y，后面以 '~' 收尾 */
			snprintf(head, sizeof(head),
				 "REC seq=4 calls=9 bytes=%zu sum=%llu why=0 n=2 bad_at=0 max_arg=70 lenmatch=1 applied=0 rc=1\n",
				 p, fv2);
			snprintf(l1, sizeof(l1),
				 "STMT 0 cmd=4 sub=0 argc=2 a0=z6_new_t a1=z6_new_t a2=- a3=- a4=-\n");
			snprintf(tail, sizeof(tail), "STMT 1 cmd=7 sub=0 argc=5 ");
			snprintf(want, sizeof(want), "%s%s%sa0=%s~ a1=b.c a2=<empty> a3=d a4=e\n",
				 head, l1, tail, long64);
			CHK(strcmp(rec, want) == 0,
			    "C6 转写不等于手抄件：\n  实得[%s]\n  期望[%s]\n", rec, want);
			if (strcmp(rec, want) == 0)
				OK("C6 四种长相逐个现量：>64B→截＋'~'、\\x01→'.'、len=0→'<empty>'、空槽→'-'");
		}
	}

	printf("SUM asserts=%d fails=%d\n", asserts, fails);
	printf(fails == 0 ? "VERDICT=w1155_pass\n" : "VERDICT=w1155_FAIL\n");
	return fails == 0 ? 0 : 1;
}
