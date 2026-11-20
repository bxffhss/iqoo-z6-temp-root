/* dev_sysv.c — 测试 shell 域 SysV msgget/msgsnd/msgrcv 可用性 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <sys/msg.h>

struct m { long type; char data[144]; };

int main(void){
    int q = msgget(IPC_PRIVATE, 0666 | IPC_CREAT);
    printf("msgget=%d errno=%d\n", q, errno);
    if (q < 0) return 1;
    struct m a; memset(&a,0,sizeof a); a.type=1; memset(a.data,'A',144);
    int r = msgsnd(q, &a, 144, IPC_NOWAIT);
    printf("msgsnd=%d errno=%d\n", r, errno);
    struct m b; memset(&b,0,sizeof b);
    r = msgrcv(q, &b, 144, 1, IPC_NOWAIT | MSG_NOERROR);
    printf("msgrcv=%d errno=%d data0=%c\n", r, errno, b.data[0]);
    msgctl(q, IPC_RMID, 0);
    printf("OK\n");
    return 0;
}
