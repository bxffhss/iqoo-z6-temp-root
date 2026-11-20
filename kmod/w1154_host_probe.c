/* w1154 —— 拿**同一份核心**(w1151_sepolicy_core.h)在 x86 宿主上读那些夹具文件，
 * 印出与设备腿同格式的读数(why/n/bad_at/max_arg/lenmatch/fnv)。
 * 为什么要有它：第 97 发有一格(设备 max_arg=5，期望表 max_arg=0)被判成"读数与期望不符"。
 * 但那把"期望"是我用 Python 算的第三方模型，不是被测本身。要分清"跨架构真的不一致"与
 * "我的期望表算错了一格"，唯一的硬办法＝让**同一份 C 码**在两种机器上读**同一批字节**。
 * 用法：w1154_host_probe <夹具目录>   ⇒ 11 格(pd_slots 用默认 4369)＋变体格 ok9@8，共 12 行 PROBE。
 * fnv 那一列就是设备腿里 in_fnv 的同一把尺(19 位种子的 FNV-1a 64) ⇒ 两端的字节是不是同一批，看它。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "w1151_sepolicy_core.h"

#define HOST_SLOTS 4369u

static struct w1151_stmt st[5000];
static struct w1151_report rep;

static unsigned long long fnv64(const w1151_u8 *b, w1151_u64 n)
{
	unsigned long long h = 1469598103934665603ULL; /* 内核那个 19 位种子(不是标准 20 位偏移基) */
	w1151_u64 i;

	for (i = 0; i < n; i++)
		h = (h ^ b[i]) * 1099511628211ULL;
	return h;
}

static w1151_u8 buf[W1151_IN_MAX + 4096];

/* 跑一格；slots 是"给多少个语句格子"，与腿里那一次 insmod 的参数同义。
 * ★label 与 fname 分开：变体那一格(label=ok9s8)读的还是 ok9.bin —— 期望表里也是 file=ok9.bin。 */
static void one(const char *label, const char *fname, const char *dir, w1151_u32 slots)
{
	char path[512];
	FILE *f;
	size_t got;
	int rc;

	snprintf(path, sizeof(path), "%s/%s", dir, fname);
	f = fopen(path, "rb");
	if (!f) {
		printf("PROBE %s MISSING=%s (这一格未测，不算通过)\n", label, path);
		return;
	}
	got = fread(buf, 1, sizeof(buf), f);
	fclose(f);
	rc = w1151_decode_stream(buf, (w1151_u64)got, st, slots, &rep);
	printf("PROBE %s slots=%u bytes=%zu fnv=%llu why=%u n=%u bad_at=%llu max_arg=%u lenmatch=%d\n",
	       label, slots, got, fnv64(buf, (w1151_u64)got), (rc == 0) ? W1151_OK : rep.why, rep.n,
	       rep.bad_at, rep.max_arg_len,
	       (rc == 0 && w1151_expect_bytes(st, rep.n) == (w1151_u64)got) ? 1 : 0);
}

int main(int argc, char **argv)
{
	static const char *names[] = { "ok1", "ok3", "ok9", "ok600", "bad_cmd", "bad_sub", "bad_nul",
		"bad_inner", "bad_len", "bad_hdr", "bad_tail" };
	size_t i, n = sizeof(names) / sizeof(names[0]);

	if (argc < 2) {
		printf("用法：w1154_host_probe <夹具目录>\n");
		return 2;
	}
	printf("HOST begin sizeof_u32=%zu sizeof_u64=%zu stmt=%zu argmax=%u inmax=%llu\n",
	       sizeof(w1151_u32), sizeof(w1151_u64), sizeof(struct w1151_stmt), W1151_ARG_MAX,
	       (unsigned long long)W1151_IN_MAX);
	for (i = 0; i < n; i++)
		{ char fn[64]; snprintf(fn, sizeof(fn), "%s.bin", names[i]); one(names[i], fn, argv[1], HOST_SLOTS); }
	one("ok9s8", "ok9.bin", argv[1], 8u); /* 变体：同一份 ok9 字节，只给 8 个格子 ⇒ TOO_MANY */
	printf("HOST end\n");
	return 0;
}
