/* SPDX-License-Identifier: GPL-2.0 */
/* w1155_sepol_record.h —— `SET_SEPOLICY` 的**待决记录**层(可移植)。
 *
 * ★为什么要单独一层：出货 ko 里的 `handle_sepolicy()` 要"解码＋留下一份事后能审计的账"，
 *   而这段渲染/返回码逻辑**必须先能在 x86 宿主上判正再上机**——第 97 发(§6.545)刚把
 *   "同一段码在 aarch64 内核与 x86 宿主上读数相同"这一格判正，所以"内核与宿主吃同一个头"
 *   现在是实测过的分工，不是我的偏好。
 * ★本头**不 include 任何头文件里的 printf**：内核侧要在 include 本头之前先带 `<linux/printk.h>`，
 *   宿主侧先带 `<stdio.h>`＋`<stdarg.h>`(两边 `*snprintf` 的返回约定一致＝"本该写出的字节数")。
 *   唯一依赖的数据结构来自 `w1151_sepolicy_core.h`(解码核心，两端同一份)。
 *
 * ★返回码口径(§344 一手：ksud 把返回值当"应用了几条"，没落地就报正数＝撒谎)：
 *   本层**永不产生正的 applied 数**。`W1155_RC_PENDING`＝"整条流解干净了，但我们手上还没有装载好的图"，
 *   由调用方翻成 `-EOPNOTSUPP`(与今天的桩一致)。官方 ksud 会把这个负值**静默吞掉**(#236)，
 *   所以 `/proc` 里这份自记信道不是装饰，是唯一能事后回答"那次交了几条、拒在哪一格"的东西。 */
#ifndef W1155_SEPOL_RECORD_H
#define W1155_SEPOL_RECORD_H

#include "w1151_sepolicy_core.h"

/* 调用方翻 errno 用的小码(这里不写 -E*，因为本头要在宿主/内核两边编) */
#define W1155_RC_PENDING 1u /* 解干净、没图 ⇒ 不谎报；调用方给 -EOPNOTSUPP */
#define W1155_RC_EINVAL  2u /* 流不合法(哪一种写在记录的 why 里) */
#define W1155_RC_E2BIG   3u /* 整条流超容量 */
#define W1155_RC_EFAULT  4u /* 从用户空间没 copy 全 */
#define W1155_RC_ENOMEM  5u /* 暂存或格子分不出来 */

#define W1155_ARGTXT_MAX 64u /* 一个参数最多原样打这么多字节，超出以 ~ 收尾 */
#define W1155_LINE_MAX  512u /* 一条 STMT 的渲染缓冲(argc≤5 × 64B ＋ 头部) */

/* ★why → 小码，一条函数搞定，且自测里对 0..11 逐个断言(不写"看着差不多"的兜底分支)。
 *   W1151_OK 走 PENDING：解干净 ≠ 应用了。 */
static unsigned int w1155_rc_for(w1151_u32 why)
{
	if (why == W1151_E_INPUT_BIG)
		return W1155_RC_E2BIG;
	if (why == W1151_OK)
		return W1155_RC_PENDING;
	return W1155_RC_EINVAL;
}

/* 追加一格：`used`＝已写出的字节，`total`＝本该写出的字节(可 > cap ⇒ 上层据此报 TRUNC)。
 *   ★满了不写但仍数一遍：截断这件事必须**留下数**，不许悄悄少打一行(§345 那条"截断要明写")。 */
static void w1155_put(char *dst, int cap, int *used, int *total, const char *fmt,
		      va_list va)
{
	char scratch[1];
	int avail, n;

	avail = (*used < cap) ? (cap - *used) : 0;
	if (avail > 1)
		n = vsnprintf(dst + *used, (size_t)avail, fmt, va);
	else
		n = vsnprintf(scratch, sizeof(scratch), fmt, va);
	if (n < 0)
		n = 0;
	*total += n;
	if (avail > 1 && n < avail - 1)
		*used += n;
	else
		*used = cap;
}

static void w1155_putf(char *dst, int cap, int *used, int *total, const char *fmt, ...)
{
	va_list va;

	va_start(va, fmt);
	w1155_put(dst, cap, used, total, fmt, va);
	va_end(va);
}

/* 把一个参数转写进 line：可打印 ASCII(0x21~0x7e)原样，其余打 '.'，超长补 '~'。
 *   ★不用 %s：参数体里的 NUL 解码核心已单独判过(ARG_HAS_NUL)，渲染层不许再引入"靠 NUL 结尾"的假设，
 *   否则记录会在最该说话的那一格少打半行。 */
static void w1155_arg_text(char *line, int cap, int *used, int *total,
			   const w1151_u8 *buf, w1151_u32 off, w1151_u32 len)
{
	w1151_u32 i, show = len;
	char c[2];

	if (show > W1155_ARGTXT_MAX)
		show = W1155_ARGTXT_MAX;
	for (i = 0; i < show; i++) {
		w1151_u8 b = buf[off + i];

		c[0] = (b >= 0x21 && b <= 0x7e) ? (char)b : '.';
		c[1] = 0;
		w1155_putf(line, cap, used, total, "%s", c);
	}
	if (len > show)
		w1155_putf(line, cap, used, total, "~");
}

/* 渲染整条记录：一行 REC ＋(仅当整条流解干净)每条语句一行 STMT。
 *   返回"本该写出的字节数"(>= cap 即被截)；*trunc 非 0 表示确实被截。
 *   ★`why != OK` 时**一行 STMT 都不给**：那时 rep->n 只是"解到第几条"的痕迹，
 *   写进记录会被下游当成"交进去的规则"(§345 定的口径)。 */
static int w1155_render(char *dst, int cap, int *trunc, w1151_u64 seq,
			w1151_u64 calls, const w1151_u8 *buf, w1151_u64 len,
			w1151_u64 sum, const struct w1151_stmt *st,
			const struct w1151_report *rep, int lenmatch)
{
	w1151_u32 i, k;
	int used = 0, total = 0, ltrunc = 0;

	w1155_putf(dst, cap, &used, &total,
		   "REC seq=%llu calls=%llu bytes=%llu sum=%llu why=%u n=%u bad_at=%llu max_arg=%u lenmatch=%d applied=0 rc=%u\n",
		   (unsigned long long)seq, (unsigned long long)calls,
		   (unsigned long long)len, (unsigned long long)sum, rep->why,
		   rep->n, (unsigned long long)rep->bad_at, rep->max_arg_len,
		   lenmatch, w1155_rc_for(rep->why));
	if (rep->why == W1151_OK) {
		for (i = 0; i < rep->n; i++) {
			char line[W1155_LINE_MAX];
			int lu = 0, lt = 0;

			w1155_putf(line, (int)sizeof(line), &lu, &lt,
				   "STMT %u cmd=%u sub=%u argc=%u", i, st[i].cmd,
				   st[i].subcmd, st[i].argc);
			/* ★五个槽位**全打**，没这个槽位打 '-'：`len=0` 是 ksud 的 None/All(线上同形)，
			   `0xffffffff` 是"这条语句根本不收这么多参数"——记录里必须分得开这两种'空'。 */
			for (k = 0; k < W1151_ARGC_MAX; k++) {
				w1155_putf(line, (int)sizeof(line), &lu, &lt, " a%u=",
					   k);
				if (st[i].arg[k].len == 0xffffffffu)
					w1155_putf(line, (int)sizeof(line), &lu, &lt,
						   "-"); /* 这一格没有(argc 用不到) */
				else if (st[i].arg[k].len == 0)
					w1155_putf(line, (int)sizeof(line), &lu, &lt,
						   "<empty>"); /* None/All 在线上同形 */
				else
					w1155_arg_text(line, (int)sizeof(line), &lu,
						       &lt, buf, st[i].arg[k].off,
						       st[i].arg[k].len);
			}
			w1155_putf(line, (int)sizeof(line), &lu, &lt, "\n");
			if (lu >= (int)sizeof(line))
				ltrunc = 1; /* ★单条 STMT 自己也塞爆了 ⇒ 必须留数，不许悄悄少打一行 */
			w1155_putf(dst, cap, &used, &total, "%s", line);
		}
	}
	/* ★TRUNC 标记必须**保证看得见**：上面的追加器在满缓冲里是"只数不写"的，
	   所以这里强制占尾——保留前 cap-64 字节，最后一格留给标记行。
	   从中间切掉半行是可以接受的：`*trunc` 才是判据，这行只是给人看的证人。 */
	if (total >= cap || ltrunc) {
		int keep = cap - 64;

		if (keep > 0) {
			dst[keep] = 0;
			snprintf(dst + keep, (size_t)(cap - keep),
				 "\nTRUNC cap=%d line_trunc=%d\n", cap, ltrunc);
			used = keep;
		}
	}
	if (trunc)
		*trunc = (total >= cap || ltrunc) ? 1 : 0;
	return total;
}

#endif /* W1155_SEPOL_RECORD_H */
