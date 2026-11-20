/* phase0c.c -- Phase 0 gate: brute-force the transaction code / token layout that
 * servicemanager accepts, looking for a reply that is NOT the generic 4-byte
 * error. Defensive research, researcher's own device.
 */
#include "binder_util.h"
#include <signal.h>

#define CTX_MGR 0u
#define SM "android.os.IServiceManager"

static struct bexp_ctx g_ctx;
static uint8_t *g_data, *g_wb, *g_rb;

static uint32_t pack4(char a, char b, char c, char d)
{
	return ((uint32_t)a << 24) | ((uint32_t)b << 16) | ((uint32_t)c << 8) | (uint32_t)d;
}

/* returns: 0 ok, negative errno. Fills reply info into *rsz, *rword, *roffs */
static int call(uint32_t code, const char *desc, const char *name,
		const uint32_t *prefix, int nprefix, size_t *reply_size,
		uint32_t *reply_word, size_t *offsets_size, int *nread)
{
	struct parcel p;
	p_reset(&p, g_data);
	for (int i = 0; i < nprefix; i++) p_u32(&p, prefix[i]);
	if (desc) p_str16(&p, desc);
	p_str16(&p, name);
	size_t data_size = p.off;

	size_t off = 0;
	uint32_t bc = BC_TRANSACTION;
	memcpy(g_wb + off, &bc, 4); off += 4;
	struct binder_transaction_data td;
	memset(&td, 0, sizeof td);
	td.target.handle = CTX_MGR;
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
	*nread = log.n;
	if (reply_size) *reply_size = log.have_reply ? log.reply_data_size : (size_t)-1;
	if (offsets_size) *offsets_size = log.have_reply ? log.reply_offsets_size : (size_t)-1;
	if (reply_word) {
		*reply_word = 0;
		if (log.have_reply && log.reply_data_size >= 4)
			memcpy(reply_word, log.reply_data, 4);
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
	if (bexp_open(&g_ctx, "/dev/binder") != 0) return 1;
	g_data = malloc(8192); g_wb = malloc(8192); g_rb = malloc(65536);

	const uint32_t pre0[] = {0};            /* policy only            */
	const uint32_t pre1[] = {0, 0xF0};      /* policy + stability      */
	const char *name = argc > 1 ? argv[1] : "package";

	printf("== code sweep 0..64, name=%s, token variants ==\n", name);
	for (int v = 0; v < 2; v++) {
		const uint32_t *pre = v ? pre1 : pre0;
		int npre = v ? 2 : 1;
		for (uint32_t code = 0; code <= 64; code++) {
			size_t rs, os; uint32_t w; int nr;
			call(code, SM, name, pre, npre, &rs, &w, &os, &nr);
			if (rs != 4 || w != 0x80000001) {
				printf("  DIFF pre=%s code=%u reply_size=%zu word=%08x offsets=%zu stream=%d\n",
				       v ? "pol+stab" : "pol", code, rs, w, os, nr);
				fflush(stdout);
			}
		}
	}
	printf("== four-char / standard codes ==\n");
	struct { const char *lbl; uint32_t code; } specials[] = {
		{"INTERFACE_TRANSACTION 1564459377", 1564459377u},
		{"PING _PNG", pack4('_', 'P', 'N', 'G')},
		{"DUMP _DMP", pack4('_', 'D', 'M', 'P')},
		{"SHELL _CMD", pack4('_', 'C', 'M', 'D')},
		{"GET_SERVICE _gSe?", pack4('_', 'g', 'S', 'e')},
		{"pack get", pack4('g', 'e', 't', 'S')},
		{"pack chk", pack4('c', 'h', 'k', 'S')},
		{"pack lst", pack4('l', 'i', 's', 't')},
	};
	for (size_t i = 0; i < sizeof specials / sizeof specials[0]; i++) {
		for (int v = 0; v < 2; v++) {
			const uint32_t *pre = v ? pre1 : pre0;
			int npre = v ? 2 : 1;
			size_t rs, os; uint32_t w; int nr;
			call(specials[i].code, SM, name, pre, npre, &rs, &w, &os, &nr);
			printf("  %-34s pre=%s code=0x%08x reply=%zd word=%08x offs=%zd stream=%d\n",
			       specials[i].lbl, v ? "pol+stab" : "pol", specials[i].code, rs, w, os, nr);
			fflush(stdout);
		}
	}
	printf("== no descriptor (raw args) code=3 ==\n");
	{
		size_t rs, os; uint32_t w; int nr;
		call(3, NULL, name, pre0, 1, &rs, &w, &os, &nr);
		printf("  reply=%zd word=%08x offs=%zd\n", rs, w, os);
	}
	printf("DONE\n");
	return 0;
}
