/* phase0e.c -- Phase 0 gate, last variant family: the AIDL-NDK interface-token
 * "stability" int32 written between the strict-mode policy word and the
 * String16 descriptor.
 */
#include "binder_util.h"
#include <signal.h>

#define SM "android.os.IServiceManager"

static struct bexp_ctx g_ctx;
static uint8_t *g_data, *g_wb, *g_rb;

static int call(uint32_t code, uint32_t stab, int have_stab, const char *name,
		size_t *rs, uint32_t *w0, size_t *os)
{
	struct parcel p;
	p_reset(&p, g_data);
	p_i32(&p, 0);                     /* strict-mode policy word */
	if (have_stab) p_u32(&p, stab);   /* AIDL-NDK stability word */
	p_str16(&p, SM);
	p_str16(&p, name);
	size_t data_size = p.off;

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
	*w0 = 0;
	if (log.have_reply && log.reply_data_size >= 4) memcpy(w0, log.reply_data, 4);
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
	const char *dev = argc > 1 ? argv[1] : "/dev/binder";
	const char *name = argc > 2 ? argv[2] : "package";
	if (bexp_open(&g_ctx, dev) != 0) return 1;
	g_data = malloc(8192); g_wb = malloc(8192); g_rb = malloc(65536);
	printf("dev=%s name=%s\n", dev, name);

	static const uint32_t stabs[] = {0x00,0x01,0x02,0x03,0x04,0x06,0x07,0x08,
					 0x0A,0x0C,0x0E,0x0F,0x78,0xF0,0x780,0x1F0,
					 0x80,0x100,0x1000};
	for (uint32_t code = 1; code <= 4; code++) {
		for (size_t i = 0; i < sizeof stabs / sizeof stabs[0]; i++) {
			size_t rs, os; uint32_t w0;
			call(code, stabs[i], 1, name, &rs, &w0, &os);
			if (rs != 4 || (w0 != 0x80000001 && w0 != 0xffffffb6))
				printf("  code=%u stab=0x%x reply=%zd w0=%08x offs=%zd  <<< DIFF\n",
				       code, stabs[i], rs, w0, os);
			fflush(stdout);
		}
		size_t rs, os; uint32_t w0;
		call(code, 0, 0, name, &rs, &w0, &os);
		printf(" code=%u no-stab reply=%zd w0=%08x offs=%zd\n", code, rs, w0, os);
		fflush(stdout);
	}
	printf("sweep done\n");
	return 0;
}
