/* phase0d.c -- Phase 0 gate: find the parcel layout that makes servicemanager
 * return a real handle. Tries UTF-16 vs UTF-8 string marshalling and the
 * optional stability int32, over transaction codes 0..20.
 */
#include "binder_util.h"
#include <signal.h>

#define CTX_MGR 0u
#define SM "android.os.IServiceManager"
#define NAME "package"

static struct bexp_ctx g_ctx;
static uint8_t *g_data, *g_wb, *g_rb;

static size_t build(const char *spec, const char *desc, const char *name)
{
	struct parcel p;
	p_reset(&p, g_data);
	for (const char *s = spec; *s; s++) {
		switch (*s) {
		case '0': p_u32(&p, 0); break;
		case 'F': p_u32(&p, 0xF0); break;      /* Stability::UNSPECIFIED */
		case '7': p_u32(&p, 0x78); break;      /* Stability::UNVERSIONED */
		case 'U': p_str16(&p, desc ? desc : ""); break;   /* utf16 descriptor */
		case 'N': p_str16(&p, name); break;               /* utf16 name       */
		case 'u': {                                      /* utf8 descriptor  */
			p_str8(&p, desc ? desc : "");
			break;
		}
		case 'a': {                                      /* utf8 name        */
			p_str8(&p, name);
			break;
		}
		}
	}
	return p.off;
}

/* returns reply info; *interesting set if reply looks like a binder/handle */
static int call(uint32_t code, const char *spec, size_t *rs, uint32_t *w0,
		uint32_t *w1, size_t *os, uint32_t *objtype, uint32_t *fbo_handle)
{
	size_t data_size = build(spec, SM, NAME);
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
	*rs = log.have_reply ? log.reply_data_size : (size_t)-1;
	*os = log.have_reply ? log.reply_offsets_size : (size_t)-1;
	*w0 = *w1 = 0; *objtype = 0; *fbo_handle = 0;
	if (log.have_reply && log.reply_data) {
		if (log.reply_data_size >= 4) memcpy(w0, log.reply_data, 4);
		if (log.reply_data_size >= 8) memcpy(w1, log.reply_data + 4, 4);
		if (log.reply_handle_type) {
			*objtype = log.reply_handle_type;
			struct flat_binder_object f;
			binder_size_t o;
			memcpy(&o, log.reply_offsets + log.reply_handle_index * sizeof o, sizeof o);
			memcpy(&f, log.reply_data + o, sizeof f);
			*fbo_handle = f.handle;
		}
		size_t o2 = 0;
		uint32_t bc2 = BC_FREE_BUFFER;
		memcpy(g_wb + o2, &bc2, 4); o2 += 4;
		binder_uintptr_t bp = (binder_uintptr_t)(uintptr_t)log.reply_data;
		memcpy(g_wb + o2, &bp, 8); o2 += 8;
		bexp_xfer(&g_ctx, g_wb, o2, NULL, 0, NULL);
	}
	return ret;
}

int main(void)
{
	if (bexp_open(&g_ctx, "/dev/binder") != 0) return 1;
	g_data = malloc(8192); g_wb = malloc(8192); g_rb = malloc(65536);

	static const char *specs[] = {
		"0UN",   /* pol + utf16 desc + utf16 name        */
		"0FUN",  /* pol + stab + utf16 desc + utf16 name */
		"07UN",
		"0Ua",   /* utf16 desc + utf8 name               */
		"0FUa",
		"0ua",   /* utf8 desc + utf8 name                */
		"0Fua",
		"0uN",   /* utf8 desc + utf16 name               */
		"0FuN",
		"N",     /* name only                            */
		"a",     /* utf8 name only                       */
		"0N",    /* pol + utf16 name (no desc)           */
		"0a",
		"UN",    /* desc + name, no pol                  */
		"uN",
	};
	uint32_t codes[] = {0, 1, 2, 3, 4, 5, 6, 7, 8};
	int found = 0;
	for (size_t s = 0; s < sizeof specs / sizeof specs[0]; s++) {
		for (size_t ci = 0; ci < sizeof codes / sizeof codes[0]; ci++) {
			size_t rs, os; uint32_t w0, w1, ot, fh;
			int ret = call(codes[ci], specs[s], &rs, &w0, &w1, &os, &ot, &fh);
			int interesting = (rs > 4) || (os > 0) ||
				      (w0 != 0x80000001 && w0 != 0xffffffb6);
			printf("%-6s code=%u ret=%d reply=%zd w0=%08x w1=%08x offs=%zd type=%08x handle=%u%s\n",
			       specs[s], codes[ci], ret, rs, w0, w1, os, ot, fh,
			       interesting ? "   <<< INTERESTING" : "");
			fflush(stdout);
			if (os > 0 || rs > 4) found = 1;
		}
	}
	printf("RESULT: %s\n", found ? "non-trivial reply seen" : "all trivial");
	return 0;
}
