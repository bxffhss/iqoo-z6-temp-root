/* ndkcheck.c -- control experiment: use the device's own libbinder_ndk to perform
 * a correctly-encoded getService/checkService from uid=2000.
 * If this returns a binder, our hand-rolled parcel encoding (not our identity)
 * is what servicemanager rejects. If it returns null, the rejection is identity
 * based (SELinux / vendor policy) and no encoding will help.
 */
#include <android/binder_libbinder.h>
#include <android/binder_manager.h>
#include <android/binder_ibinder.h>
#include <android/binder_parcel.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	const char *name = argc > 1 ? argv[1] : "package";
	printf("pid=%d uid=%d ctx=", getpid(), getuid());
	FILE *f = fopen("/proc/self/attr/current", "r");
	char buf[128] = {0};
	if (f) { if (fgets(buf, sizeof buf, f)) {} fclose(f); }
	printf("%s\n", buf);

	AIBinder *b = AServiceManager_checkService(name);
	printf("AServiceManager_checkService(%s) -> %p\n", name, (void *)b);
	if (b) {
		int32_t st = AIBinder_getHandle(b);
		printf("  handle=%d status=%d\n", st, AIBinder_getDebugNameForBinder(b) ? 0 : -1);
		printf("  AIBinder_getDebugName=%s\n", AIBinder_getDebugNameForBinder(b) ?: "?");

	}
	b = AServiceManager_waitAndFetchDefaultService(name, nullptr, nullptr);
	printf("waitAndFetchDefaultService -> %p\n", (void *)b);
	return 0;
}
