/* phase0.c -- Phase 0 gate: obtain a genuine BR_REPLY from servicemanager.
 * Defensive research on the researcher's own device. Zero kernel risk.
 */
#include "binder_util.h"
#include <signal.h>

#define SM_DESC      "android.os.IServiceManager"
#define SM_DESC_ALT  "android.os.IServicemanager"
#define CTX_MGR      0u

struct combo {
	const char *desc;      /* interface token descriptor (NULL = no token) */
	uint32_t code;         /* transaction code */
	const char *name;      /* service name argument */
	int32_t policy;        /* interface-token policy int32 */
	const char *label;
};

static uint8_t *build_parcel(uint8_t *dst, const struct combo *c, size_t *sz)
{
	struct parcel p;
	p_reset(&p, dst);
	if (c->desc) {
		p_i32(&p, c->policy);          /* interface token policy word */
		p_str16(&p, c->desc);          /* String16(descriptor)        */
	}
	p_str16(&p, c->name);                  /* String16("package")         */
	*sz = p.off;
	return dst;
}

static void run_combo(const struct combo *c)
{
	struct bexp_ctx ctx;
	printf("\n--- combo: %s | desc=%s code=%u name=%s policy=%d\n",
	       c->label, c->desc ? c->desc : "(none)", c->code, c->name, c->policy);
	fflush(stdout);
	if (bexp_open(&ctx, "/dev/binder") != 0) { printf("   open/mmap failed\n"); return; }

	uint8_t *data = malloc(4096);
	size_t data_size = 0;
	build_parcel(data, c, &data_size);

	uint8_t *wb = malloc(4096);
	uint8_t *rb = malloc(65536);
	size_t off = 0;
	uint32_t bc = BC_TRANSACTION;   /* _IOW('c',0,...) */
	memcpy(wb + off, &bc, 4); off += 4;
	struct binder_transaction_data td;
	memset(&td, 0, sizeof(td));
	td.target.handle = CTX_MGR;
	td.cookie = 0;
	td.code = c->code;
	td.flags = TF_ACCEPT_FDS;       /* no TF_ONE_WAY -> synchronous */
	td.data_size = data_size;
	td.offsets_size = 0;
	td.data.ptr.buffer = (binder_uintptr_t)(uintptr_t)data;
	td.data.ptr.offsets = 0;
	memcpy(wb + off, &td, sizeof(td)); off += sizeof(td);

	alarm(5);                       /* watchdog: a hung wait means no reply */
	struct br_log log;
	memset(&log, 0, sizeof(log));
	int ret = bexp_transact(&ctx, wb, off, rb, 65536, &log, 8);
	alarm(0);
	printf("   transact ret=%d (%s)\n", ret, ret ? strerror(-ret) : "ok");

	printf("   BR stream (%d):", log.n);
	for (int i = 0; i < log.n; i++) printf(" %s(0x%x)", br_name(log.codes[i]), log.codes[i]);
	printf("\n");
	if (log.have_reply) {
		printf("   BR_REPLY data_size=%zu offsets_size=%zu objects:",
		       log.reply_data_size, log.reply_offsets_size);
		size_t noff = log.reply_offsets_size / sizeof(binder_size_t);
		for (size_t k = 0; k < noff; k++) {
			binder_size_t o;
			memcpy(&o, log.reply_offsets + k * sizeof(o), sizeof(o));
			uint32_t t = 0;
			if (o + 4 <= log.reply_data_size) memcpy(&t, log.reply_data + o, 4);
			printf(" [off=%llu type=0x%08x]", (unsigned long long)o, t);
			if (o + 24 <= log.reply_data_size) {
				struct flat_binder_object fbo;
				memcpy(&fbo, log.reply_data + o, sizeof(fbo));
				printf(" handle=%u cookie=0x%llx", fbo.handle,
				       (unsigned long long)fbo.cookie);
			}
		}
		printf("\n   -> reply object type 0x%08x (%s)\n", log.reply_handle_type,
		       log.reply_handle_type == BINDER_TYPE_HANDLE ? "BINDER_TYPE_HANDLE" :
		       log.reply_handle_type == BINDER_TYPE_BINDER ? "BINDER_TYPE_BINDER" :
		       log.reply_handle_type == BINDER_TYPE_FD ? "BINDER_TYPE_FD" : "none");
		/* dump first bytes of the reply parcel */
		printf("   reply hexdump:");
		size_t nd = log.reply_data_size < 40 ? log.reply_data_size : 40;
		for (size_t k = 0; k + 4 <= nd; k += 4) {
			uint32_t v; memcpy(&v, log.reply_data + k, 4);
			printf(" %08x", v);
		}
		printf("\n");
		/* release the reply buffer properly */
		size_t o2 = 0;
		uint32_t bc2 = BC_FREE_BUFFER;
		memcpy(wb + o2, &bc2, 4); o2 += 4;
		binder_uintptr_t bp = (binder_uintptr_t)(uintptr_t)log.reply_data;
		memcpy(wb + o2, &bp, 8); o2 += 8;
		bexp_xfer(&ctx, wb, o2, NULL, 0, NULL);
	} else {
		/* dump raw first words for diagnosis */
		printf("   raw rx words:");
		for (size_t k = 0; k + 4 <= 64; k += 4) {
			uint32_t v; memcpy(&v, rb + k, 4); printf(" %08x", v);
		}
		printf("\n");
	}
	close(ctx.fd);
	munmap(ctx.map, ctx.map_size);
	free(data); free(wb); free(rb);
}

int main(void)
{
	printf("sizeof(binder_transaction_data)=%zu sizeof(flat_binder_object)=%zu "
	       "sizeof(binder_size_t)=%zu\n",
	       sizeof(struct binder_transaction_data), sizeof(struct flat_binder_object),
	       sizeof(binder_size_t));
	printf("BINDER_VERSION:");
	struct bexp_ctx t;
	if (bexp_open(&t, "/dev/binder") == 0) {
		struct binder_version v; memset(&v, 0, sizeof v);
		int r = ioctl(t.fd, BINDER_VERSION, &v);
		printf(" ret=%d protocol_version=%d\n", r, v.protocol_version);
		close(t.fd); munmap(t.map, t.map_size);
	}

	static const struct combo combos[] = {
		{ SM_DESC,     3, "package", 0, "checkService(desc,token pol=0)" },
		{ SM_DESC,     3, "package", 1, "checkService(desc,token pol=1)" },
		{ SM_DESC,     2, "package", 0, "getService(desc)" },
		{ SM_DESC,     1, "package", 0, "code1(desc)" },
		{ SM_DESC,     4, "package", 0, "code4(desc)" },
		{ SM_DESC_ALT, 3, "package", 0, "checkService(alt-desc)" },
		{ NULL,        3, "package", 0, "checkService(NO interface token)" },
		{ SM_DESC,     1, "package", 0, "PING_TRANSACTION on handle 0 (no token expected)" },
	};
	for (size_t i = 0; i < sizeof(combos)/sizeof(combos[0]); i++)
		run_combo(&combos[i]);
	printf("\nDONE\n");
	return 0;
}
