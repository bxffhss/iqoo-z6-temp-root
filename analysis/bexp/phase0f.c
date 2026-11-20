/* phase0f.c -- Phase 0 gate: AIDL-NDK string marshalling (int32 len + raw UTF-8
 * bytes, NO NUL, NO padding) for the name argument, with the interface token
 * written as [int32 policy][uint32 stability][String16 descriptor].
 * Decoded so far: reply int32 0x80000001 == STATUS_BAD_TYPE (enforceInterface /
 * leftover-data failure), 0xffffffb6 == STATUS_UNKNOWN_TRANSACTION (-EBADMSG).
 */
#include "binder_util.h"
#include <signal.h>

#define SM "android.os.IServiceManager"

static struct bexp_ctx g_ctx;
static uint8_t *g_data, *g_wb, *g_rb;

/* mode: 0 = [pol][stab16][desc][u8 name]  (u8 = len+bytes, no NUL)
 *       1 = [pol][desc][u8 name]
 *       2 = [pol][stab][desc][u8 name + NUL, padded]   (old guess)
 *       3 = [pol][desc][u16 name]
 */
static size_t build(int mode, uint32_t stab, const char *name)
{
	struct parcel p;
	p_reset(&p, g_data);
	if (mode != 1) p_i32(&p, 0);
	if (mode == 0 || mode == 2) p_u32(&p, stab);
	p_str16(&p, SM);
	if (mode == 3) {
		p_str16(&p, name);
	} else if (mode == 2) {
		p_str8(&p, name);            /* len + bytes + NUL + pad */
	} else {
		p_i32(&p, (int32_t)strlen(name));
		memcpy(p.base + p.off, name, strlen(name));
		p.off += strlen(name);
	}
	return p.off;
}

static int call(uint32_t code, int mode, uint32_t stab, const char *name,
		size_t *rs, uint32_t *w0, size_t *os, int *handle, uint32_t *otype)
{
	size_t data_size = build(mode, stab, name);
	size_t off = 0;
	uint32_t bc = BC_TRANSACTION;
	memcpy(g_wb + off, &bc, 4); off += 4;
	struct binder_transaction_data td;
	memset(&td, 0, sizeof td);
	td.target.handle = 0;
	td.code = code;
	td.flags = TF_ACCEPT_FDS;
	td.data_size = data_size;
	td.data.ptr.buffer = (binder_uintptr_t)(uintptr_t)g_data;
	memcpy(g_wb + off, &td, sizeof td); off += sizeof td;

	struct br_log log;
	memset(&log, 0, sizeof log);
	alarm(4);
	int ret = bexp_transact(&g_ctx, g_wb, off, g_rb, 65536, &log, 16);
	alarm(0);
	*rs = log.have_reply ? log.reply_data_size : (size_t)-1;
	*os = log.have_reply ? log.reply_offsets_size : (size_t)-1;
	*w0 = 0; *handle = -1; *otype = 0;
	if (log.have_reply && log.reply_data_size >= 4) memcpy(w0, log.reply_data, 4);
	if (log.have_reply && log.reply_handle_type) {
		struct flat_binder_object f;
		binder_size_t o = 0;
		memcpy(&o, log.reply_offsets + log.reply_handle_index * sizeof o, sizeof o);
		memcpy(&f, log.reply_data + o, sizeof f);
		*handle = (int)f.handle;
		*otype = log.reply_handle_type;
	}
	if (log.have_reply && log.reply_data) {
		size_t o2 = 0;
		uint32_t bc2 = BC_FREE_BUFFER;
		memcpy(g_wb + o2, &bc2, 4); o2 += 4;
		binder_uintptr_t bp = (binder_uintptr_t)(uintptr_t)log.reply_data;
		memcpy(g_wb + o2, &bp, 8); o2 += 8;
		bexp_xfer(&g_ctx, g_wb, o2, NULL, 0, NULL);
	}
	return ret;
}

int main(int argc, char **argv)
{
	const char *name = argc > 1 ? argv[1] : "package";
	if (bexp_open(&g_ctx, "/dev/binder") != 0) return 1;
	g_data = malloc(8192); g_wb = malloc(8192); g_rb = malloc(65536);
	static const uint32_t stabs[] = {0xF0, 0x78, 0x01, 0x04, 0x05, 0x0F, 0x02, 0x0A, 0x00};
	int ok = 0;
	for (uint32_t code = 1; code <= 4; code++) {
		for (int mode = 0; mode <= 3; mode++) {
			int ns = (mode == 0 || mode == 2) ? (int)(sizeof stabs/sizeof stabs[0]) : 1;
			for (int i = 0; i < ns; i++) {
				size_t rs, os; uint32_t w0, ot; int h;
				call(code, mode, stabs[i], name, &rs, &w0, &os, &h, &ot);
				int bad = (w0 == 0x80000001 || w0 == 0xffffffb6);
				printf("code=%u mode=%d stab=0x%x reply=%zd w0=%08x offs=%zd handle=%d type=%08x%s\n",
				       code, mode, (mode == 0 || mode == 2) ? stabs[i] : 0, rs, w0, os, h, ot,
				       bad ? "" : "   <<< NEW");
				fflush(stdout);
				if (!bad && os > 0) ok = 1;
			}
		}
	}
	printf("GATE: %s\n", ok ? "BR_REPLY with BINDER_TYPE_HANDLE obtained" : "no handle reply");
	return 0;
}
