#define _GNU_SOURCE
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <sys/syscall.h>
int main(void){
  errno = 0; long a = syscall(SYS_getuid); int ea = errno;
  errno = 0; unsigned b = getuid(); int eb = errno;
  printf("syscall(SYS_getuid)=%ld errno=%d  getuid()=%u errno=%d  SYS_getuid=%d\n",
         a, ea, b, eb, (int)SYS_getuid);
  return 0;
}
