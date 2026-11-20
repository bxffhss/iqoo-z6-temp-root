/* phase0b.c -- Phase 0 gate, exhaustive prefix/encoding matrix for servicemanager.
 * Defensive research on the researcher's own device. Zero kernel risk.
 */
#include "binder_util.h"
#include <signal.h>

#define CTX_MGR 0u

struct combo {
	const char *label;
	const char *desc;        /* interface descriptor, NULL -> no descriptor string */
	uint32_t code;
	int nprefix;             /* int32 words written before the descriptor string */
	uint32_t prefix[3];
	const char *name;
};

static size_t build(uint8_t *dst, const struct combo *c)
{
	struct parcel p;
	p_reset(&p, dst);
	for (int i = 0; i < c->nprefix; i++) p_u32(&p, c->prefix[i]);
	if (c->desc) p_str16(&p, c->desc);
	p_str16(&p, c->name);
	return p.off;
}

static void run(const struct combo *c)
{
	printf("\n--- %s | code=%u prefix=[", c->label, c->code);
	for (int i = 0; i < c->nprefix; i++) printf("0x%x ", c->prefix[i]);
	printf("] desc=%s name=%s\n", c->desc ? c->desc : "(none)", c->name);
	fflush(stdout);

	struct bexp_ctx ctx;
	if (bexp_open(&ctx, "/dev/binder") != 0) { printf("   open failed\n"); return; }

	uint8_t *data = malloc(4096);
	size_t data_size = build(data, c);
	uint8_t *wb = malloc(4096), *rb = malloc(65536);
	size_t off = 0;
	uint32_t bc = BC_TRANSACTION;
	memcpy(wb + off, &bc, 4); off += 4;
	struct binder_transaction_data td;
	memset(&td, 0, sizeof td);
	td.target.handle = CTX_MGR;
	td.code = c->code;
	td.flags = TF_ACCEPT_FDS;
	td.data_size = data_size;
	td.offsets_size = 0;
	td.data.ptr.buffer = (binder_uintptr_t)(uintptr_t)data;
	memcpy(wb + off, &td, sizeof td); off += sizeof td;

	struct br_log log;
	memset(&log, 0, sizeof log);
	alarm(5);
	int ret = bexp_transact(&ctx, wb, off, rb, 65536, &log, 16);
	alarm(0);
	printf("   ret=%d (%s) stream(%d):", ret, ret ? strerror(-ret) : "ok", log.n);
	for (int i = 0; i < log.n; i++) printf(" %s", br_name(log.codes[i]));
	printf("\n   reply_bytes=%d req_bytes=%zu", log.have_reply ? (int)log.reply_data_size : -1,
	       data_size);
	if (log.have_reply) {
		printf(" offsets=%zu objs:", log.reply_offsets_size);
		size_t noff = log.reply_offsets_size / sizeof(binder_size_t);
		for (size_t k = 0; k < noff; k++) {
			binder_size_t o;
			memcpy(&o, log.reply_offsets + k * sizeof o, sizeof o);
			uint32_t t = 0;
			if (o + 4 <= log.reply_data_size) memcpy(&t, log.reply_data + o, 4);
			printf(" [off=%llu type=0x%08x]", (unsigned long long)o, t);
			if (o + 24 <= log.reply_data_size) {
				struct flat_binder_object f;
				memcpy(&f, log.reply_data + o, sizeof f);
				printf(" handle=%u cookie=0x%llx", f.handle,
				       (unsigned long long)f.cookie);
			}
		}
		printf("\n   words:");
		size_t nd = log.reply_data_size < 64 ? log.reply_data_size : 64;
		for (size_t k = 0; k + 4 <= nd; k += 4) {
			uint32_t v; memcpy(&v, log.reply_data + k, 4); printf(" %08x", v);
		}
		printf("\n   type0x%08x", log.reply_handle_type);
		/* BC_FREE_BUFFER */
		size_t o2 = 0;
		uint32_t bc2 = BC_FREE_BUFFER;
		memcpy(wb + o2, &bc2, 4); o2 += 4;
		binder_uintptr_t bp = (binder_uintptr_t)(uintptr_t)log.reply_data;
		memcpy(wb + o2, &bp, 8); o2 += 8;
		bexp_xfer(&ctx, wb, o2, NULL, 0, NULL);
	}
	printf("\n");
	close(ctx.fd);
	munmap(ctx.map, ctx.map_size);
	free(data); free(wb); free(rb);
}

#define SM "android.os.IServiceManager"

int main(void)
{
	static const struct combo cs[] = {
		{ "policy0 + no stability",              SM, 3, 1, {0,0,0},        "package" },
		{ "policy0 + stability=0xF0",            SM, 3, 2, {0,0xF0,0},     "package" },
		{ "policy0 + stability=0x78",            SM, 3, 2, {0,0x78,0},     "package" },
		{ "policy0 + stability=0x00",            SM, 3, 2, {0,0x00,0},     "package" },
		{ "stability=0xF0 only (no policy)",     SM, 3, 1, {0xF0,0,0},     "package" },
		{ "policy0 + stability=0xF0, code=2",    SM, 2, 2, {0,0xF0,0},     "package" },
		{ "policy0 + stability=0xF0, code=4",    SM, 4, 2, {0,0xF0,0},     "package" },
		{ "policy0 + stability=0xF0, code=1",    SM, 1, 2, {0,0xF0,0},     "package" },
		{ "policy0 + stability=0xF0, code=5",    SM, 5, 2, {0,0xF0,0},     "package" },
		{ "policy0 + stability=0xF0, no desc",   NULL, 3, 2, {0,0xF0,0},   "package" },
		{ "policy0 + stab=0xF0, name=surfaceflinger", SM, 3, 2, {0,0xF0,0},"SurfaceFlinger" },
		{ "policy1 + stability=0xF0",            SM, 3, 2, {1,0xF0,0},     "package" },
	};
	for (size_t i = 0; i < sizeof cs / sizeof cs[0]; i++) run(&cs[i]);
	printf("\nDONE\n");
	return 0;
}
