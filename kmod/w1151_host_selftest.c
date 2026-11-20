/* w1151 宿主自测(#238 部件①)：用"独立写出的编码器"造字节，喂给 w1151_sepolicy_core.h 的解码器。
 *
 * ★为什么要两边都写：编码器与解码器是从同一份 Rust 源(sepolicy.rs:653 cmd_expected_argc /
 *   :665 encode_policy_object / :679 append_atomic_statement)各自翻出来的两份实现，
 *   它们对得上才算证人；只写一份＝左手查右手(§229 那一族：判据代码自己会骗自己)。
 * ★第三个证人：F1 那 49 个字节是**手算写死**的十六进制，不来自编码器也不来自解码器。
 * ★判据形状：正对照(必须收)与变异(必须按**指定的** why 拒)成对；bad_at 也指定，
 *   因为"拒了"和"因这件物拒的"是两回事(§237 那一手)；最后给判据本身来一发反夹具。
 * 编译与跑都在构建机(x86-64 gcc)：见 kmod/w1151_sepd_build.sh 第 1 步。
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "w1151_sepolicy_core.h"

static int ASSERTS, FAILS;

#define CHK(cond, fmt, ...)                                                            \
	do {                                                                           \
		ASSERTS++;                                                             \
		if (!(cond)) {                                                         \
			FAILS++;                                                       \
			printf("[BAD] " fmt "\n", ##__VA_ARGS__);                      \
		}                                                                      \
	} while (0)

static const char *why_name(w1151_u32 w)
{
	switch (w) {
	case W1151_OK:
		return "OK";
	case W1151_E_EMPTY:
		return "EMPTY";
	case W1151_E_TRUNC_HDR:
		return "TRUNC_HDR";
	case W1151_E_UNKNOWN_CMD:
		return "UNKNOWN_CMD";
	case W1151_E_TRUNC_ARGLEN:
		return "TRUNC_ARGLEN";
	case W1151_E_ARGLEN_BIG:
		return "ARGLEN_BIG";
	case W1151_E_TRUNC_ARGBODY:
		return "TRUNC_ARGBODY";
	case W1151_E_NO_NUL:
		return "NO_NUL";
	case W1151_E_TOO_MANY:
		return "TOO_MANY";
	case W1151_E_BAD_SUBCMD:
		return "BAD_SUBCMD";
	case W1151_E_ARG_HAS_NUL:
		return "ARG_HAS_NUL";
	case W1151_E_INPUT_BIG:
		return "INPUT_BIG";
	default:
		return "?";
	}
}

/* ---- 独立编码器：逐行照 sepolicy.rs 那三支函数 ---- */
struct enc {
	w1151_u8 b[70000];
	w1151_u64 n;
};

static void e32(struct enc *e, w1151_u32 v)
{
	e->b[e->n++] = (w1151_u8)(v & 0xff);
	e->b[e->n++] = (w1151_u8)((v >> 8) & 0xff);
	e->b[e->n++] = (w1151_u8)((v >> 16) & 0xff);
	e->b[e->n++] = (w1151_u8)((v >> 24) & 0xff);
}

/* None/All 都编码成"长度 0 + 一个 NUL"；传 NULL 走这一支 */
static void earg(struct enc *e, const char *s)
{
	w1151_u32 l = s ? (w1151_u32)strlen(s) : 0u;
	w1151_u32 i;
	e32(e, l);
	for (i = 0; i < l; i++)
		e->b[e->n++] = (w1151_u8)s[i];
	e->b[e->n++] = 0;
}

static void estmt(struct enc *e, w1151_u32 cmd, w1151_u32 sub, const char **args, w1151_u32 argc)
{
	w1151_u32 i;
	e32(e, cmd);
	e32(e, sub);
	for (i = 0; i < argc; i++)
		earg(e, args[i]);
}

/* 手算每条该有多少字节：8 + Σ(4 + strlen + 1)。★不经过编码器、也不经过解码器。 */
static w1151_u64 hand_bytes(const char **args, w1151_u32 argc)
{
	w1151_u64 t = 8;
	w1151_u32 i;
	for (i = 0; i < argc; i++)
		t += 5 + (args[i] ? strlen(args[i]) : 0);
	return t;
}

static struct w1151_stmt st[5000];
static struct w1151_report rep;
static struct enc e;

/* 跑一把并把读数印成一行证件 */
static void run(const char *name, const w1151_u8 *buf, w1151_u64 len, w1151_u32 out_max,
		w1151_u32 want_why, w1151_u32 want_n, w1151_u64 want_at)
{
	int rc = w1151_decode_stream(buf, len, st, out_max, &rep);
	w1151_u32 got = (rc == 0) ? W1151_OK : rep.why;
	CHK(got == want_why, "%s：想拒成 %s，实际是 %s", name, why_name(want_why), why_name(got));
	CHK(rep.n == want_n, "%s：条数 n=%u 应为 %u", name, rep.n, want_n);
	if (want_why != W1151_OK && want_at != (w1151_u64)-1)
		CHK(rep.bad_at == want_at, "%s：出事偏移=%llu 应为 %llu", name,
		    (unsigned long long)rep.bad_at, (unsigned long long)want_at);
	/* ★收下的每一条都再过一道"长度自洽"：从解出来的 (argc, 每个参数的 len) 反推整条流应有
	 *   多少字节，必须与喂进去的字节数**正好相等**。它查的是框架(off-by-one、argc 数错、
	 *   把 len0 当成 4 而不是 5)而不是内容，跟上面那些 CASE 是两把独立的尺。 */
	if (got == W1151_OK) {
		w1151_u64 back = w1151_expect_bytes(st, rep.n);
		CHK(back == len, "%s：解出来的 %u 条反推 %llu 字节，喂进去的是 %llu", name, rep.n,
		    (unsigned long long)back, (unsigned long long)len);
	}
	printf("CASE %-20s rc=%d why=%-2u(%-13s) n=%-4u bytes=%-6llu bad_at=%-5llu want=%s\n", name,
	       rc, rep.why, why_name(rep.why), rep.n, (unsigned long long)len,
	       (unsigned long long)rep.bad_at, why_name(want_why));
}

int main(void)
{
	const char *a_allow[] = { "shell", "su", "file", "entrypoint" };
	char longbuf[1024];
	w1151_u64 hb, i;

	printf("W1151 begin\n");
	if (sizeof(w1151_u32) != 4 || sizeof(w1151_u64) != 8) {
		printf("VERDICT=w1151_FAIL 原因=这台机器的 unsigned int/long long 不是 4/8 字节(%zu/%zu)\n",
		       sizeof(w1151_u32), sizeof(w1151_u64));
		return 2;
	}
	printf("TYPES u32=%zu u64=%zu stmt=%zu argmax=%u inmax=%llu\n", sizeof(w1151_u32),
	       sizeof(w1151_u64), sizeof(struct w1151_stmt), W1151_ARG_MAX,
	       (unsigned long long)W1151_IN_MAX);

	/* ====== 1) 正对照 ====== */

	/* F1 单条 allow：编码器给的字节必须与手算 49 个十六进制逐字节相同(第三证人) */
	static const w1151_u8 F1[49] = {
		0x01, 0x00, 0x00, 0x00,  0x01, 0x00, 0x00, 0x00,             /* cmd=1 sub=1  */
		0x05, 0x00, 0x00, 0x00,  's',  'h',  'e',  'l',  'l',  0x00, /* "shell"      */
		0x02, 0x00, 0x00, 0x00,  's',  'u',  0x00,                   /* "su"         */
		0x04, 0x00, 0x00, 0x00,  'f',  'i',  'l',  'e',  0x00,       /* "file"       */
		0x0a, 0x00, 0x00, 0x00,  'e',  'n',  't',  'r',  'y',  'p',  /* "entrypoint" */
		'o',  'i',  'n',  't',  0x00
	};
	e.n = 0;
	estmt(&e, 1, 1, a_allow, 4);
	hb = hand_bytes(a_allow, 4);
	CHK(e.n == 49, "F1：编码器给了 %llu 字节，手算/写死都是 49", (unsigned long long)e.n);
	CHK(hb == 49, "F1：手算给了 %llu，写死的证人是 49 ⇒ 我自己记错格式了",
	    (unsigned long long)hb);
	CHK(memcmp(e.b, F1, 49) == 0, "F1：编码结果与手算十六进制不一致(第三证人红)");
	printf("F1 encoder=%llu hand=%llu literal=49 memcmp=%d\n", (unsigned long long)e.n,
	       (unsigned long long)hb, memcmp(e.b, F1, 49));
	run("F1_allow", e.b, 49, 8, W1151_OK, 1, (w1151_u64)-1);
	CHK(st[0].cmd == 1 && st[0].subcmd == 1 && st[0].argc == 4,
	    "F1：头解错 cmd=%u sub=%u argc=%u", st[0].cmd, st[0].subcmd, st[0].argc);
	CHK(st[0].arg[0].len == 5 && st[0].arg[0].off == 12 &&
		!memcmp(e.b + st[0].arg[0].off, "shell", 5),
	    "F1：arg0 off=%u len=%u 不是 (12,5,shell)", st[0].arg[0].off, st[0].arg[0].len);
	CHK(st[0].arg[3].len == 10 && !memcmp(e.b + st[0].arg[3].off, "entrypoint", 10),
	    "F1：arg3 off=%u len=%u 不是 entrypoint", st[0].arg[3].off, st[0].arg[3].len);
	/* 空槽标记必须与"合法的 None/All(len 0)"分得开——上机后读账的人最容易在这一格混掉 */
	CHK(st[0].arg[4].len == 0xffffffffu, "F1：第 5 槽没标成'这条没这个槽位'(len=%x)，会和 None 混",
	    st[0].arg[4].len);
	CHK(rep.max_arg_len == 10, "F1：量到的最长参数=%u 应为 10", rep.max_arg_len);

	/* F2 三条混排，其中 type_transition 的对象槽是 None(len 0)——它容易被当成"截断"而误拒 */
	{
		const char *t1[] = { "su", "shell", "process", "transition" };
		const char *t2[] = { "runas_app", "system_data_file", "dir", "shell", NULL };
		const char *t3[] = { "/sys/fs/selinux", "/boot", "u:object_r:selinuxfs:s0" };
		e.n = 0;
		estmt(&e, 1, 1, t1, 4);
		estmt(&e, 7, 0, t2, 5);
		estmt(&e, 9, 0, t3, 3);
		hb = hand_bytes(t1, 4) + hand_bytes(t2, 5) + hand_bytes(t3, 3);
		CHK(e.n == hb, "F2：编码器 %llu != 手算 %llu ⇒ 编码器和算式对不上(先别查解码器)",
		    (unsigned long long)e.n, (unsigned long long)hb);
		run("F2_three", e.b, e.n, 8, W1151_OK, 3, (w1151_u64)-1);
		CHK(st[1].argc == 5 && st[1].arg[4].len == 0,
		    "F2：第 2 条的对象槽该是 len0(None/All)，实际 len=%u", st[1].arg[4].len);
		CHK(st[2].arg[0].len == 15 && !memcmp(e.b + st[2].arg[0].off, "/sys/fs/selinux", 15),
		    "F2：genfscon 的 fs_name 解错(len=%u)", st[2].arg[0].len);
	}

	/* F3 九种 cmd 各一条：argc 表是整件事的地基，逐条正对照 */
	{
		const char *p1[] = { "s", "t", "c", "p" };
		const char *p2[] = { "s", "t", "c", "ioctl", "0x8912" };
		const char *p3[] = { "su" };
		const char *p4[] = { "my_type", "domainattribute" };
		const char *p7[] = { "s", "t", "c", "d", "objname" };
		const char *p9[] = { "selinuxfs", "/x", "u:object_r:t:s0" };
		static const w1151_u32 want_argc[] = { 4, 5, 1, 2, 2, 1, 5, 4, 3 };
		w1151_u32 k;
		e.n = 0;
		estmt(&e, 1, 1, p1, 4);
		estmt(&e, 2, 1, p2, 5);
		estmt(&e, 3, 1, p3, 1);
		estmt(&e, 4, 0, p4, 2);
		estmt(&e, 5, 0, p4, 2);
		estmt(&e, 6, 0, p3, 1);
		estmt(&e, 7, 0, p7, 5);
		estmt(&e, 8, 1, p1, 4);
		estmt(&e, 9, 0, p9, 3);
		run("F3_all9cmd", e.b, e.n, 64, W1151_OK, 9, (w1151_u64)-1);
		for (k = 0; k < 9; k++) {
			CHK(st[k].argc == want_argc[k], "F3：第 %u 条 cmd=%u 的 argc 解成 %u(表里 %u)",
			    k, st[k].cmd, st[k].argc, want_argc[k]);
			CHK(w1151_cmd_argc(k + 1) == want_argc[k], "F3：cmd=%u 的表给 %u，写死的是 %u",
			    k + 1, w1151_cmd_argc(k + 1), want_argc[k]);
		}
		printf("F3 argc=%u,%u,%u,%u,%u,%u,%u,%u,%u n=%u bytes=%llu\n", st[0].argc, st[1].argc,
		       st[2].argc, st[3].argc, st[4].argc, st[5].argc, st[6].argc, st[7].argc,
		       st[8].argc, rep.n, (unsigned long long)e.n);
	}

	/* F4 subcmd 取值域：每个能取的值都收，取不了的按 cmd 拒(别把"只认 1..4"写成"只认 1") */
	{
		const char *p[] = { "s", "t", "c", "p" };
		w1151_u32 k;
		for (k = 1; k <= 4; k++) {
			e.n = 0;
			estmt(&e, 1, k, p, 4);
			run("F4_cmd1_sub", e.b, e.n, 2, W1151_OK, 1, (w1151_u64)-1);
		}
		e.n = 0;
		estmt(&e, 1, 5, p, 4);
		run("F4_cmd1_sub5", e.b, e.n, 2, W1151_E_BAD_SUBCMD, 0, 4);
		CHK(w1151_subcmd_ok(4, 0) && !w1151_subcmd_ok(4, 1), "F4：cmd4 的 subcmd 域不是'只有 0'");
		CHK(w1151_subcmd_ok(3, 1) && w1151_subcmd_ok(3, 2) && !w1151_subcmd_ok(3, 3),
		    "F4：cmd3 的 subcmd 域不是 1..2");
		CHK(w1151_subcmd_ok(8, 1) && w1151_subcmd_ok(8, 2) && !w1151_subcmd_ok(8, 3),
		    "F4：cmd8 的 subcmd 域不是 1..2");
		CHK(w1151_subcmd_ok(2, 3) && !w1151_subcmd_ok(2, 4), "F4：cmd2 的 subcmd 域不是 1..3");
		CHK(w1151_subcmd_ok(7, 0) && !w1151_subcmd_ok(7, 1), "F4：cmd7 的 subcmd 域不是'只有 0'");
		CHK(w1151_subcmd_ok(9, 0) && !w1151_subcmd_ok(9, 1), "F4：cmd9 的 subcmd 域不是'只有 0'");
	}

	/* F5 单参数边界：正好 256 收、257 拒(两头都要有) */
	memset(longbuf, 'x', sizeof(longbuf) - 1);
	longbuf[sizeof(longbuf) - 1] = 0;
	{
		const char *p[4];
		p[0] = "s";
		p[1] = "t";
		p[2] = "c";
		longbuf[256] = 0;
		p[3] = longbuf;
		e.n = 0;
		estmt(&e, 1, 1, p, 4);
		run("F5_arg_exactly256", e.b, e.n, 2, W1151_OK, 1, (w1151_u64)-1);
		CHK(rep.max_arg_len == 256, "F5：量到的最长参数=%u 应为 256", rep.max_arg_len);
		/* 换 300 那一头：得先把 256 那个 NUL 填回 'x'，不然 strlen 仍是 256(夹具会自己骗自己) */
		longbuf[256] = 'x';
		longbuf[300] = 0;
		CHK(strlen(longbuf) == 300, "F5：夹具坏了(想要的 300 得到 %zu)", strlen(longbuf));
		e.n = 0;
		estmt(&e, 1, 1, p, 4);
		/* 第三个参数(s,t,c,长参数)的长度字段落在偏移 26 */
		run("F5_arg_300_reject", e.b, e.n, 2, W1151_E_ARGLEN_BIG, 0, 26);
	}

	/* F6 条数边界：格子够＝收，格子差一条＝拒在第 N+1 条的起点 */
	{
		const char *p[] = { "su" }; /* 每条 8+5+2=15 字节 */
		w1151_u32 k;
		e.n = 0;
		for (k = 0; k < 600; k++)
			estmt(&e, 6, 0, p, 1);
		CHK(e.n == 600 * 15, "F6：600 条 ×15 应为 9000，编码器给了 %llu",
		    (unsigned long long)e.n);
		run("F6_600_enough", e.b, e.n, 1024, W1151_OK, 600, (w1151_u64)-1);
		run("F6_600_too_many", e.b, e.n, 512, W1151_E_TOO_MANY, 512, 512 * 15);
	}

	/* F7 总量边界：W1151_IN_MAX 之内收、之外拒(两头) */
	{
		static w1151_u8 big[70000];
		const char *p[] = { "su" };
		w1151_u64 one;
		e.n = 0;
		estmt(&e, 6, 0, p, 1);
		one = e.n; /* 15 */
		for (i = 0; i < (W1151_IN_MAX / one) * one; i++)
			big[i] = e.b[i % one];
		run("F7_at_in_max", big, (W1151_IN_MAX / one) * one, 5000, W1151_OK,
		    (w1151_u32)((W1151_IN_MAX / one)), (w1151_u64)-1);
		for (i = 0; i < one; i++)
			big[(W1151_IN_MAX / one) * one + i] = e.b[i];
		run("F7_over_in_max", big, (W1151_IN_MAX / one) * one + one, 5000, W1151_E_INPUT_BIG, 0,
		    W1151_IN_MAX);
		printf("F7 in_max=%llu 之内=%llu 之外=%llu\n", (unsigned long long)W1151_IN_MAX,
		       (unsigned long long)((W1151_IN_MAX / one) * one),
		       (unsigned long long)((W1151_IN_MAX / one) * one + one));
	}

	/* ====== 2) 变异：每条都要按指定的 why 拒、且指出指定的偏移 ====== */
	{
		w1151_u8 m[80];
		w1151_u8 t[80];

		e.n = 0;
		estmt(&e, 1, 1, a_allow, 4);
		memcpy(m, e.b, 49);

		run("M1_empty", m, 0, 8, W1151_E_EMPTY, 0, 0);
		run("M2_short_hdr", m, 4, 8, W1151_E_TRUNC_HDR, 0, 0);
		/* M2b：尾巴多一个字节 ⇒ 拒在"下一条的头凑不满"(这条同时现量了 pos==len 是不变量，
		 *      而不是什么独立的"没吃完"检查——那条走不进去，已删) */
		m[49] = 0x7f;
		run("M2b_stray_tail", m, 50, 8, W1151_E_TRUNC_HDR, 1, 49);
		m[49] = 0;

		memcpy(t, m, 49);
		t[0] = 10;
		run("M3_cmd_10", t, 49, 8, W1151_E_UNKNOWN_CMD, 0, 0);
		memcpy(t, m, 49);
		t[0] = 0;
		run("M3b_cmd_0", t, 49, 8, W1151_E_UNKNOWN_CMD, 0, 0);

		memcpy(t, m, 49);
		t[4] = 7;
		run("M4_sub_7", t, 49, 8, W1151_E_BAD_SUBCMD, 0, 4);

		run("M5_arglen_field_short", m, 11, 8, W1151_E_TRUNC_ARGLEN, 0, 8);

		memcpy(t, m, 49);
		t[18] = t[19] = t[20] = t[21] = 0xff; /* 第二个参数的长度字段 */
		run("M6_arglen_ffff", t, 49, 8, W1151_E_ARGLEN_BIG, 0, 18);

		memcpy(t, m, 49);
		t[8] = 40; /* 第一个参数说它有 40 字节 */
		run("M7_body_short", t, 49, 8, W1151_E_TRUNC_ARGBODY, 0, 12);

		memcpy(t, m, 49);
		t[17] = 'z'; /* 收尾那个 NUL 改掉 */
		run("M8_no_nul", t, 49, 8, W1151_E_NO_NUL, 0, 17);

		memcpy(t, m, 49);
		t[14] = 0; /* 参数体中间来一个 NUL：收尾仍是 0，所以只能靠这一把尺 */
		run("M9_inner_nul", t, 49, 8, W1151_E_ARG_HAS_NUL, 0, 14);
	}

	/* 差分变异(#293 那一手)：同一份码，改**一个**字节就得从收变拒。
	 * 反面对照——把 t[14] 从 0 换回 'e' 必须又收回来，证明上一行不是恒拒。 */
	{
		w1151_u8 t[64];
		memcpy(t, e.b, 49);
		t[14] = 'e';
		run("D1_revert_to_ok", t, 49, 8, W1151_OK, 1, (w1151_u64)-1);
	}

	/* ====== 3) 判据自己的反夹具：[BAD] 计数必须会动 ====== */
	{
		int before = FAILS, saved = ASSERTS;
		int df, da;
		CHK(1 == 2, "这条【应当】出现：SELFTOOTH_MARK 证明 [BAD] 计数不是恒 0");
		/* ★增量要在下一条 CHK 把自己也算进去**之前**取：CHK 是先 ASSERTS++ 再判条件的，
		 *   第一版我把"这一条自己"写进了期望值，结果反夹具自己红了(仪器把正件判成不合格)。 */
		df = FAILS - before;
		da = ASSERTS - saved;
		CHK(df == 1 && da == 1, "反夹具只让计数动了 fail+%d assert+%d(两条都应为 1) ⇒ 这把尺在骗人",
		    df, da);
		printf("SELF_TOOTH fail_delta=%d assert_delta=%d\n", df, da);
		FAILS = before; /* 撤回这一条故意的，它不算被测的账 */
	}

	printf("SUM asserts=%d fails=%d\n", ASSERTS, FAILS);
	CHK(ASSERTS >= 60, "断言只有 %d 条(少于 60) ⇒ 这一轮没真跑，不许当绿", ASSERTS);
	printf("VERDICT=%s\n", FAILS == 0 ? "w1151_pass" : "w1151_FAIL");
	return FAILS == 0 ? 0 : 1;
}
