/* uhid_try.c — 探测 /dev/uhid 可接受的 (事件类型, 写长度) 组合  §CZ
 * 目的: 找出 UHID_CREATE2 被 EINVAL 拒绝的真实原因(写尺寸? 结构布局? 描述符?)
 */
#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#define EVMAX 8192
static unsigned char ev[EVMAX];

static void wr32(int o, uint32_t v) { memcpy(ev + o, &v, 4); }
static void wr16(int o, uint16_t v) { memcpy(ev + o, &v, 2); }

/* 与 uhid_mt.c 相同的描述符 */
static unsigned char desc[] = {
    0x05,0x0D, 0x09,0x04, 0xA1,0x01,
    0x09,0x55, 0x15,0x00, 0x26,0xFF,0x00, 0x75,0x08, 0x95,0x01, 0xB1,0x02,
    0x85,0x01, 0x09,0x51, 0x15,0x00, 0x26,0xFF,0x00, 0x75,0x08, 0x95,0xFF, 0x81,0x02,
    0xC0
};

static int try_create2(int wsize) {
    int fd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (fd < 0) return -1;
    memset(ev, 0, EVMAX);
    wr32(0, 12);                     /* UHID_CREATE2 */
    strcpy((char *)(ev + 4), "uhid_try");
    strcpy((char *)(ev + 132), "virt-0");
    wr16(260, sizeof(desc));         /* rd_size */
    wr16(262, 0x0003);
    wr32(264, 0x1234); wr32(268, 0x5678); wr32(272, 1);
    memcpy(ev + 280, desc, sizeof(desc));
    errno = 0;
    ssize_t w = write(fd, ev, wsize);
    int e = errno;
    printf("  CREATE2  size=%-5d -> ret=%-3zd errno=%d%s\n", wsize, w, e,
           (w >= 0) ? "   <== 接受!" : "");
    close(fd);
    return (w >= 0) ? wsize : -1;
}

static int try_legacy(int wsize) {
    int fd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (fd < 0) return -1;
    memset(ev, 0, EVMAX);
    wr32(0, 0);                      /* __UHID_LEGACY_CREATE */
    strcpy((char *)(ev + 4), "uhid_try2");
    strcpy((char *)(ev + 132), "virt-0");
    /* legacy: rd_data 是【用户指针】: name@4(128) phys@132(64) uniq@196(64)
                rd_data(u64)@260  rd_size@268  bus@270  vendor@272 product@276
                version@280 country@284   => 288 */
    uint64_t p = (uint64_t)(uintptr_t)desc;
    memcpy(ev + 260, &p, 8);
    wr16(268, sizeof(desc));
    wr16(270, 0x0003);
    wr32(272, 0x1234); wr32(276, 0x5678); wr32(280, 1);
    errno = 0;
    ssize_t w = write(fd, ev, wsize);
    int e = errno;
    printf("  LEGACY  size=%-5d -> ret=%-3zd errno=%d%s\n", wsize, w, e,
           (w >= 0) ? "   <== 接受!" : "");
    close(fd);
    return (w >= 0) ? wsize : -1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== /dev/uhid 写尺寸探测 ===\n");
    printf("libc sizeof(期望的 create2 事件)= %zu  (内核侧疑似 4380)\n\n",
           4 + 276 + 4096);

    int sizes[] = { 4380, 4376, 4372, 4096, 1095, 1024, 512, 300, 288, 284, 256, 128, 64 };
    printf("-- UHID_CREATE2 --\n");
    for (unsigned i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++)
        if (try_create2(sizes[i]) >= 0) break;

    printf("\n-- 传统 CREATE(0) --\n");
    for (unsigned i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++)
        if (try_legacy(sizes[i]) >= 0) break;

    printf("\n-- 空调用对照: 只发 DESTROY(1) --\n");
    {
        int fd = open("/dev/uhid", O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            memset(ev, 0, EVMAX); wr32(0, 1);
            for (unsigned i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++) {
                errno = 0; ssize_t w = write(fd, ev, sizes[i]);
                printf("  DESTROY size=%-5d -> ret=%-3zd errno=%d\n", sizes[i], w, errno);
                if (w >= 0) break;
            }
            close(fd);
        }
    }

    printf("\n-- 枚举 /sys/class/input (替代不可读的 /proc/bus/input/devices) --\n");
    system("ls /sys/class/input 2>&1 | tr '\\n' ' '; echo");
    system("ls -l /dev/input 2>&1 | head -20");
    printf("\n=== 完成 ===\n");
    return 0;
}
