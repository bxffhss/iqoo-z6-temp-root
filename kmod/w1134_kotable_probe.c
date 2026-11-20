/* w1134_kotable_probe.c —— 我们 ko 的 ioctl 命令表**由编译器算出来**，不靠手数。
 * 为什么要这一份：调用点反汇编给出的是"真 ksud 发的那个 32 位命令字"，两边要对表就必须把我们表里
 *   `_IOC(dir,'K',nr,size)` / `_IOR(...,struct)` 的 **size 来自 sizeof(struct)** 那一段也算出来——
 *   手算 struct 对齐会错(本机的 GET_INFO＝size 16、GET_SULOG_FD＝size 4 就是判对错的钥匙：
 *   ksud 那边发的是 0x80104b02 而不是 0x80004b02，差的就是这 16)。
 * 用法(构建机，x86 就够——这些件里没有指针，host/aarch64 的 sizeof 相同)：
 *   gcc -I/root/k/ksu/kernel/include/uapi -I/root/k/ksu/kernel/include -o kotable kotable.c && ./kotable
 * ★只引用 supercall.h 里**自带**的 struct；app_profile.h 那几个类型在这个包含路径下是不完整类型，
 *   别去 sizeof 它(第一次就撞在这上面)。
 * 输出：每行 `NAME 0x<cmd> dir=<d> size=<s> type=0x<t> nr=<n>`；链/闸按 nr 对表。 */
#include <stdio.h>
#include <linux/ioctl.h>
#include <stdbool.h>
#include <linux/types.h>
#include "supercall.h"

#define P(x) printf("%-34s 0x%08x dir=%d size=%d type=0x%02x nr=%d\n", \
           #x, (unsigned)x, _IOC_DIR(x), _IOC_SIZE(x), _IOC_TYPE(x), _IOC_NR(x))

int main(void)
{
	printf("UAPI_VERSION=%u\n", KERNEL_SU_UAPI_VERSION);
	printf("SZ_get_info_cmd=%zu SZ_get_sulog_fd_cmd=%zu\n",
	       sizeof(struct ksu_get_info_cmd), sizeof(struct ksu_get_sulog_fd_cmd));
	P(KSU_IOCTL_GRANT_ROOT);
	P(KSU_IOCTL_GET_INFO);
	P(KSU_IOCTL_GET_INFO_LEGACY);
	P(KSU_IOCTL_REPORT_EVENT);
	P(KSU_IOCTL_SET_SEPOLICY);
	P(KSU_IOCTL_CHECK_SAFEMODE);
	P(KSU_IOCTL_GET_ALLOW_LIST);
	P(KSU_IOCTL_GET_DENY_LIST);
	P(KSU_IOCTL_NEW_GET_ALLOW_LIST);
	P(KSU_IOCTL_NEW_GET_DENY_LIST);
	P(KSU_IOCTL_UID_GRANTED_ROOT);
	P(KSU_IOCTL_UID_SHOULD_UMOUNT);
	P(KSU_IOCTL_GET_MANAGER_APPID);
	P(KSU_IOCTL_GET_APP_PROFILE);
	P(KSU_IOCTL_SET_APP_PROFILE);
	P(KSU_IOCTL_GET_FEATURE);
	P(KSU_IOCTL_SET_FEATURE);
	P(KSU_IOCTL_GET_WRAPPER_FD);
	P(KSU_IOCTL_MANAGE_MARK);
	P(KSU_IOCTL_NUKE_EXT4_SYSFS);
	P(KSU_IOCTL_ADD_TRY_UMOUNT);
	P(KSU_IOCTL_SET_INIT_PGRP);
	P(KSU_IOCTL_GET_SULOG_FD);
	P(KSU_IOCTL_DISABLE_ESCAPE_TO_ROOT);
	return 0;
}
