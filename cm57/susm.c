/* susm.c —— **不碰 supercall fd、不发 reboot()** 的 su 触发器（md §6.47）。
 *
 * 为什么要有这个东西：第二十四/二十五发设备都是"体面关机"死的
 * (`sd 0:0:0:0: [sda] Synchronizing SCSI cache` = device_shutdown)，
 * 死点紧贴 `drive_fd()` 那 **四次真 reboot(0xDEADBEEF,0xCAFEBABE,...)**，
 * 而 su 链路自己的判据(SD4 与 SU/X 系列)一条都没来得及印 ⇒ 必须先把这个变量从危险步骤里摘掉。
 *
 * 而"打标"其实不需要 fd：本树 `__NR_setresuid = 147`，正是 `ksu_hook_mask` bit0 挂的那个号
 * （`hook/setuid_hook.c: ksu_handle_setresuid()` 里 `if (ksu_is_allow_uid_for_current(new_uid))
 *   ksu_set_task_tracepoint_flag(current);`）⇒ 一个进程只要 **setresuid 到名单里的 uid**，
 * 内核自己就把它打标；随后 `execve("/system/bin/su")` 就会被 sys_enter 改道到调度器。
 * 这条路径同时也是**真实 app 拿到 su 的形状**，比手工 `MANAGE_MARK` 更贴近目标形态。
 *
 * 判据全走 stderr(无缓冲)：stdout 会被 execve 换掉映像而丢掉缓冲。
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/syscall.h>

int main(int argc, char **argv)
{
	uid_t uid = argc > 1 ? (uid_t)strtoul(argv[1], NULL, 0) : 10284;
	char *cmd = argc > 2 ? argv[2] : "id";
	long r;

	fprintf(stderr, "susm: 起点 uid=%u euid=%u gid=%u 目标 uid=%u\n",
		getuid(), geteuid(), getgid(), uid);

	/* 1) ★第二十六发的教训：`setresuid(-1, uid, -1)` 只改 euid，**ruid 仍然是 0**，
	 *    而内核 hook 喂给 `ksu_handle_setresuid()` 的是 `current_uid()` = **ruid** ⇒
	 *    走的是 else 分支 ⇒ 不但没打标，反而把继承来的标**清掉**了 ⇒ execve 不被改道 ⇒ ENOENT。
	 *    所以三个槽位都要写成目标 uid（gid 同理，且 setresgid 要放在 setresuid 之前：
	 *    bit0 只挂在 147 上，setresuid 必须**最后**执行，这样打标不会被后续动作冲掉）。 */
	r = syscall(SYS_setresgid, (int)uid, (int)uid, (int)uid);
	fprintf(stderr, "susm: setresgid(%u,%u,%u) 返回 %ld errno=%d(%s) gid=%u\n",
		uid, uid, uid, r, errno, strerror(errno), getgid());
	fflush(stderr);
	r = syscall(SYS_setresuid, (int)uid, (int)uid, (int)uid);
	fprintf(stderr, "susm: setresuid(%u,%u,%u) 返回 %ld errno=%d(%s) uid=%u euid=%u\n"
	                "      ★uid(ruid) 必须是 %u，内核才认为这个进程=名单里的 uid\n",
		uid, uid, uid, r, errno, strerror(errno), getuid(), geteuid(), uid);
	if (r != 0) {
		r = syscall(SYS_setuid, (int)uid);
		fprintf(stderr, "susm: 兜底 setuid(%u) 返回 %ld errno=%d(%s) uid=%u\n"
		                "      ★注意 setuid 是 146，hook 在 147 ⇒ 这条路不会打标\n",
			uid, r, errno, strerror(errno), getuid());
	}
	fflush(stderr);

	char *av[] = { (char *)"/system/bin/su", (char *)"-c", cmd, NULL };
	char *ev[] = { (char *)"PATH=/system/bin:/system/xbin:/vendor/bin", (char *)"HOME=/tmp", NULL };
	execve("/system/bin/su", av, ev);
	fprintf(stderr, "susm: execve(/system/bin/su) 失败 errno=%d(%s) "
	                "← 2=没被拦截(真文件不存在), 38=被调度器判死, 0 不会到这行=被改写执行了 ksud\n",
		errno, strerror(errno));
	fflush(stderr);
	return 126;
}
