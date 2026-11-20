/* w1159 — #241：`SET_SEPOLICY` 的**用户态那一头**(读文件 → 本地预解 → 决定发不发 → 填 ioctl 载荷)。
 *
 * ★为什么单开一份头，不直接写进 cm57/ksuctl.c：ksuctl.c 编出来是 aarch64 静态二进制，只有设备上
 *   跑得动；而这一段是"线格式"唯一的用户态出口，必须能在 x86 宿主上拿**同一份源码**自测
 *   (kmod/w1159_host_selftest.c)——"编得过"不等于"读对了字节"(§345/§348 立的规矩)。
 * ★这里不碰 ioctl、不碰 errno、不碰 KSU 的 fd ⇒ 窗口外、执法态、基线态都能随手跑。
 * ★本地预解只是**证人**不是**闸门**：解得再难看也照样允许发(要判的是内核怎么看这批字节，不是我看)。
 *   唯一拦着不发的是"文件根本没读全"——那时交出去的是半条流，只会得到一个骗人的 errno。 */
#ifndef W1159_SEPOL_WIRE_H
#define W1159_SEPOL_WIRE_H

#include <stdarg.h>
#include <stddef.h>  /* offsetof：S1 那条"data 在 +8"的断言要用，不引就退化成隐式函数声明 */
#include <stdint.h>
#include <stdbool.h> /* uapi/app_profile.h 里裸写 `bool`——NDK 那侧是 ksuctl.c 自己引的，宿主这侧得由本头引 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "w1151_sepolicy_core.h"
#include "w1155_sepol_record.h"
#include "uapi/supercall.h"

/* ★默认格子数与第 97 发那次 insmod 的 pd_slots 同值：跨机对表时"宿主 4369 / 内核 4369"
 *   必须是同一个数，不然 E_TOO_MANY 那一格两边判的不是同一件事。 */
#define W1159_SLOTS 4369u
#define W1159_REC_CAP 65536

/* 读文件的四种收场。★只有 OK 才允许往下走到 ioctl。 */
#define W1159_F_OK 0
#define W1159_F_OPEN 1   /* 打不开/没这个文件(stat 就输了) */
#define W1159_F_BIG 2    /* 比 cap 大 ⇒ 一个字节都不往 buf 里放 */
#define W1159_F_SHORT 3  /* 读到的和 stat 说的不等(流在动／或者根本不是定长文件) */

/* 与内核那两份同一个 FNV-1a 64(19 位种子)。★这条不是装饰：第 97 发设备内核自己印的
 *   `sum=` 就是拿它当"两边吃的是同一批字节"的证人，种子或次序错一位那个数就对不上。 */
static w1151_u64 w1159_fnv64(const w1151_u8 *b, w1151_u64 n)
{
	w1151_u64 h = 1469598103934665603ull;
	w1151_u64 i;

	for (i = 0; i < n; i++) {
		h ^= (w1151_u64)b[i];
		h *= 1099511628211ull;
	}
	return h;
}

struct w1159_load {
	int code;	/* W1159_F_* */
	w1151_u64 want;	/* 读之前 stat 说的字节数 */
	w1151_u64 got;	/* 真正进 buf 的字节数 */
	w1151_u64 fnv;	/* 只对 buf 里这 got 个字节算 */
};

/* 整条流进 buf，或者什么都不进。
 * ★上限用 `> cap` 而不是 `>= cap`：解码器自己也是 `len > W1151_IN_MAX` 才判 E_INPUT_BIG，
 *   两把尺的边界必须同形——否则 cap 那一格用户态放行、内核拒，就成了"两边读数不一样"的假案。 */
static int w1159_load_file(const char *path, w1151_u8 *buf, w1151_u64 cap,
			   struct w1159_load *out)
{
	struct stat sb;
	FILE *f;
	w1151_u64 got = 0;

	memset(out, 0, sizeof(*out));
	if (stat(path, &sb) != 0) {
		out->code = W1159_F_OPEN;
		return out->code;
	}
	out->want = (w1151_u64)sb.st_size;
	if (out->want > cap) {
		out->code = W1159_F_BIG; /* ★这里必须一个字节都不读 */
		return out->code;
	}
	f = fopen(path, "rb");
	if (!f) {
		out->code = W1159_F_OPEN;
		return out->code;
	}
	while (!feof(f)) {
		size_t r = fread(buf + got, 1, (size_t)(cap - got), f);
		if (r == 0)
			break;
		got += (w1151_u64)r;
		if (got >= cap)
			break; /* 上面已按 st_size 拦过；这里是"st_size 撒谎"时的硬顶 */
	}
	out->code = ferror(f) ? W1159_F_SHORT : W1159_F_OK;
	fclose(f);
	out->got = got;
	if (out->code == W1159_F_OK && got != out->want)
		out->code = W1159_F_SHORT; /* procfs 那类 st_size 说 0 而读得出字节的，就落在这一格 */
	out->fnv = w1159_fnv64(buf, got);
	return out->code;
}

struct w1159_view {
	struct w1151_report rep;
	w1151_u64 fnv;
	w1151_u64 expect; /* w1151_expect_bytes 那条**独立算式**给的"该有多少字节" */
	int lenmatch;
	int rec_total;  /* 记录本该写出的字节数 */
	int rec_trunc;
};

/* 解一遍 + 渲染一份记录，两个都给调用方当证人用。
 * ★`st` 由调用方分配(W1159_SLOTS 个格子≈227 KB，别压在栈上)，`slots` 传进来是为了
 *   能复现"格子比语句少"那一格(ok9s8：设备用 pd_slots=8 解同一份字节得到 why=8)。 */
static int w1159_preview(const w1151_u8 *buf, w1151_u64 len, w1151_u32 slots,
			 struct w1151_stmt *st, char *rec, int rec_cap,
			 w1151_u64 seq, w1151_u64 calls, struct w1159_view *v)
{
	int dec;

	dec = w1151_decode_stream(buf, len, st, slots, &v->rep);
	v->fnv = w1159_fnv64(buf, len);
	v->expect = w1151_expect_bytes(st, v->rep.n);
	/* 与设备那份探针同一把尺(w1151_sepd_probe.c:113)：解干净 **且** 算式等于实际长度才算自洽。
	 * 单看"等"会把拒收件(前 n 条凑巧加得出来)读成正。 */
	v->lenmatch = (dec == 0 && v->expect == len) ? 1 : 0;
	v->rec_trunc = 0;
	v->rec_total = w1155_render(rec, rec_cap, &v->rec_trunc, seq, calls, buf, len,
				   v->fnv, st, &v->rep, v->lenmatch);
	return dec;
}

/* 发不发的决定(抽出来是因为这条门必须在宿主自测里双向测到，不能只靠肉眼读 ksuctl.c)。
 * ★不看解码结果：解码是**我的模型**，模型红不该改变"让内核自己看一眼"这件事(#241 的全部目的)。 */
#define W1159_DRY 0
#define W1159_FIRE 1

static int w1159_gate(int want_send, int load_code)
{
	if (load_code != W1159_F_OK)
		return W1159_DRY;
	return want_send ? W1159_FIRE : W1159_DRY;
}

/* 填那条 ioctl 的载荷。★data 是**用户态指针本身**当 64 位整数交进去
 *   (dispatch.c:156 `handle_sepolicy((void __user *)cmd.data, cmd.data_len)`)，
 *   填成偏移/内核地址都不会有编译错误，只会得到一个查不出原因的 EFAULT。 */
static void w1159_fill_cmd(struct ksu_set_sepolicy_cmd *c, const void *data,
			   w1151_u64 len)
{
	memset(c, 0, sizeof(*c));
	c->data_len = (__u64)len;
	/* ★往 `__u64` 转，不往 `__aligned_u64` 转：后者是 `__u64 __attribute__((aligned(8)))`，
	 *   当强转类型写时 clang 报 "-Wignored-attributes(属性被丢掉)"——一个真会出现的警告，
	 *   留着它就会把"这份件干净"这句证词打折。 */
	c->data = (__u64)(uintptr_t)data;
}

#endif /* W1159_SEPOL_WIRE_H */
