/* binder_util.h - minimal raw /dev/binder client helpers (defensive research)
 * SPDX-purpose: Phase 0 parcel-encoding gate test + Phase 2 bounded UAF-window probe.
 */
#ifndef BINDER_UTIL_H
#define BINDER_UTIL_H

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#include <linux/android/binder.h>

#define BEXP_VM_SIZE (1024 * 1024 - 2 * 4096)

struct bexp_ctx {
	int fd;
	void *map;         /* PROT_READ mmap of the binder accept buffer */
	size_t map_size;
	uint8_t *wbuf;     /* write command stream lives inside map */
	uint8_t *rbuf;     /* read stream lives inside map */
};

static const char *br_name(uint32_t c)
{
	switch (c) {
	case BR_NOOP: return "BR_NOOP";
	case BR_TRANSACTION: return "BR_TRANSACTION";
	case BR_REPLY: return "BR_REPLY";
	case BR_ACQUIRE_RESULT: return "BR_ACQUIRE_RESULT";
	case BR_DEAD_REPLY: return "BR_DEAD_REPLY";
	case BR_TRANSACTION_COMPLETE: return "BR_TRANSACTION_COMPLETE";
	case BR_FAILED_REPLY: return "BR_FAILED_REPLY";
	case BR_DEAD_BINDER: return "BR_DEAD_BINDER";
	case BR_CLEAR_DEATH_NOTIFICATION_DONE: return "BR_CLEAR_DEATH_NOTIFICATION_DONE";
	case BR_FINISHED: return "BR_FINISHED";
	case BR_SPAWN_LOOPER: return "BR_SPAWN_LOOPER";
	case BR_TRANSACTION_SEC_CTX: return "BR_TRANSACTION_SEC_CTX";
	case BR_INCREFS: return "BR_INCREFS";
	case BR_ACQUIRE: return "BR_ACQUIRE";
	case BR_RELEASE: return "BR_RELEASE";
	case BR_DECREFS: return "BR_DECREFS";
	default: return "BR_?";
	}
}

static int bexp_open(struct bexp_ctx *c, const char *dev)
{
	memset(c, 0, sizeof(*c));
	c->fd = open(dev, O_RDWR);
	if (c->fd < 0) { fprintf(stderr, "open %s: %s\n", dev, strerror(errno)); return -1; }
	c->map_size = BEXP_VM_SIZE;
	/* binder only accepts PROT_READ here (PROT_WRITE => EPERM on this device) */
	c->map = mmap(NULL, c->map_size, PROT_READ, MAP_PRIVATE | MAP_NORESERVE, c->fd, 0);
	if (c->map == MAP_FAILED) { fprintf(stderr, "mmap: %s\n", strerror(errno)); return -1; }
	return 0;
}

/* ---- parcel writers (little endian, 4-byte aligned) ---- */
struct parcel {
	uint8_t *base;
	size_t off;
};

static void p_reset(struct parcel *p, uint8_t *base) { p->base = base; p->off = 0; }

static void p_u32(struct parcel *p, uint32_t v)
{
	memcpy(p->base + p->off, &v, 4);
	p->off += 4;
}

static void p_i32(struct parcel *p, int32_t v) { p_u32(p, (uint32_t)v); }

/* String16: int32 charcount, then charcount+1 UTF-16LE units (NUL terminated),
 * padded so that the total field size is a multiple of 4 (charcount+1 is even
 * for a NUL-terminated UTF-16 string, so 4 + (n+1)*2 is already 4-aligned when
 * (n+1) is even, i.e. n odd -- otherwise libbinder pads to 4; we pad always). */
static void p_str16(struct parcel *p, const char *s)
{
	size_t n = strlen(s);
	uint32_t units = (uint32_t)n + 1;   /* include terminating NUL unit */
	size_t bytes = (size_t)units * 2;
	p_i32(p, (int32_t)n);
	for (size_t i = 0; i < n; i++) {
		uint16_t u = (uint16_t)(unsigned char)s[i];
		memcpy(p->base + p->off, &u, 2);
		p->off += 2;
	}
	uint16_t nul = 0;
	memcpy(p->base + p->off, &nul, 2);
	p->off += 2;
	/* bytes written for the string = bytes; pad to 8-byte boundary as libbinder
	 * aligns objects; for plain strings libbinder aligns to 4 */
	while (p->off % 4) { p->base[p->off++] = 0; }
	(void)bytes;
}

/* UTF-8 (AIDL NDK std::string style) string: int32 byte length, bytes, NUL,
 * padded to a 4-byte boundary. */
static void p_str8(struct parcel *p, const char *s)
{
	size_t n = strlen(s);
	p_i32(p, (int32_t)n);
	memcpy(p->base + p->off, s, n);
	p->off += n;
	p->base[p->off++] = 0;
	while (p->off % 4) p->base[p->off++] = 0;
}

/* write a binder_size_t offset entry into the offsets array */
static void p_off(struct parcel *p, uint64_t off)
{
	binder_size_t o = (binder_size_t)off;
	memcpy(p->base + p->off, &o, sizeof(o));
	p->off += sizeof(o);
}

static void p_u64(struct parcel *p, uint64_t v)
{
	memcpy(p->base + p->off, &v, 8);
	p->off += 8;
}

static void p_pad8(struct parcel *p) { while (p->off % 8) p->base[p->off++] = 0; }

/* ---- ioctl helpers ---- */
static int bexp_xfer(struct bexp_ctx *c, void *write, size_t write_size,
		     void *read, size_t read_size, size_t *read_consumed)
{
	struct binder_write_read bwr;
	memset(&bwr, 0, sizeof(bwr));
	bwr.write_buffer = (uintptr_t)write;
	bwr.write_size = write_size;
	bwr.read_buffer = (uintptr_t)read;
	bwr.read_size = read_size;
	int ret;
	do {
		ret = ioctl(c->fd, BINDER_WRITE_READ, &bwr);
	} while (ret < 0 && errno == EINTR);
	if (read_consumed) *read_consumed = (size_t)bwr.read_consumed;
	if (ret < 0) return -errno;
	return 0;
}

/* Send one synchronous (or one-way) transaction. Returns 0 on success of the
 * ioctl; fills a simple log of the BR stream. */
struct br_log {
	uint32_t codes[64];
	int n;
	/* BR_REPLY details */
	int have_reply;
	size_t reply_data_size;
	size_t reply_offsets_size;
	uint8_t *reply_data;
	uint8_t *reply_offsets;
	uint32_t reply_handle_type;   /* first binder object type found in reply */
	int reply_handle_index;
};

static void blog_add(struct br_log *l, uint32_t c)
{
	if (l->n < (int)(sizeof(l->codes)/sizeof(l->codes[0]))) l->codes[l->n++] = c;
}

/* parse a read stream produced by binder_thread_read */
static void bexp_parse_read(struct bexp_ctx *c, uint8_t *buf, size_t consumed, struct br_log *l)
{
	size_t i = 0;
	while (i + 4 <= consumed) {
		uint32_t tr;
		memcpy(&tr, buf + i, 4);
		i += 4;
		blog_add(l, tr);
		switch (tr) {
		case BR_TRANSACTION:
		case BR_TRANSACTION_SEC_CTX: {
			struct binder_transaction_data td;
			memcpy(&td, buf + i, sizeof(td));
			i += sizeof(td);
			if (tr == BR_TRANSACTION_SEC_CTX)
				i += sizeof(binder_uintptr_t);
			break;
		}
		case BR_REPLY: {
			struct binder_transaction_data td;
			memcpy(&td, buf + i, sizeof(td));
			i += sizeof(td);
			l->have_reply = 1;
			l->reply_data_size = (size_t)td.data_size;
			l->reply_offsets_size = (size_t)td.offsets_size;
			l->reply_data = (uint8_t *)(uintptr_t)td.data.ptr.buffer;
			l->reply_offsets = (uint8_t *)(uintptr_t)td.data.ptr.offsets;
			l->reply_handle_type = 0;
			l->reply_handle_index = -1;
			if (l->reply_data && l->reply_data >= (uint8_t *)c->map &&
			    l->reply_data < (uint8_t *)c->map + c->map_size) {
				size_t noff = l->reply_offsets_size / sizeof(binder_size_t);
				for (size_t k = 0; k < noff; k++) {
					binder_size_t off;
					memcpy(&off, l->reply_offsets + k * sizeof(off), sizeof(off));
					uint32_t type = 0;
					if (off + 4 <= l->reply_data_size)
						memcpy(&type, l->reply_data + off, 4);
					if (type == BINDER_TYPE_HANDLE ||
					    type == BINDER_TYPE_WEAK_HANDLE ||
					    type == BINDER_TYPE_BINDER ||
					    type == BINDER_TYPE_FD) {
						l->reply_handle_type = type;
						l->reply_handle_index = (int)k;
						break;
					}
				}
			}
			break;
		}
		case BR_ACQUIRE_RESULT:
			i += 4;
			break;
		case BR_DEAD_REPLY:
		case BR_TRANSACTION_COMPLETE:
		case BR_NOOP:
		case BR_SPAWN_LOOPER:
		case BR_FINISHED:
			break;
		case BR_INCREFS:
		case BR_ACQUIRE:
		case BR_RELEASE:
		case BR_DECREFS:
			i += 2 * sizeof(binder_uintptr_t);
			break;
		case BR_DEAD_BINDER:
			i += sizeof(binder_uintptr_t);
			break;
		default:
			/* unknown: stop to avoid drifting */
			return;
		}
	}
}

/* Send a command stream, then drain the reply stream until a terminal BR code.
 * Accumulates every BR code seen into the log. Returns 0 when a terminal/reply
 * code was observed, -ETIMEDOUT if the read budget ran out, else -errno. */
static int bexp_transact(struct bexp_ctx *c, void *write, size_t write_size,
			 uint8_t *read, size_t read_size, struct br_log *l,
			 int max_reads)
{
	size_t consumed;
	int ret = bexp_xfer(c, write, write_size, read, read_size, &consumed);
	if (ret < 0) return ret;
	bexp_parse_read(c, read, consumed, l);
	for (int i = 0; i < max_reads; i++) {
		uint32_t last = l->n ? l->codes[l->n - 1] : 0;
		if (last == BR_REPLY || last == BR_DEAD_REPLY ||
		    last == BR_FAILED_REPLY)
			return 0;
		int r = bexp_xfer(c, NULL, 0, read, read_size, &consumed);
		if (r < 0) return r;
		bexp_parse_read(c, read, consumed, l);
	}
	return -ETIMEDOUT;
}

#endif /* BINDER_UTIL_H */
