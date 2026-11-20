#define __BIONIC_DEPRECATED_PAGE_SIZE_MACRO
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
struct sq_off { uint32_t head,tail,mask,entries,flags,dropped,array,resv[3]; };
struct cq_off { uint32_t head,tail,mask,entries,overflow,cqes,flags,resv; };
struct iur_p { uint32_t sq_entries,cq_entries,flags,stc,sti,feat,wfd,resv[10]; struct sq_off so; struct cq_off co; };
int main(void){
    struct iur_p p; memset(&p,0,sizeof(p));
    long fd=syscall(425,4,&p);
    printf("fd=%ld errno=%d\n",fd,errno);
    unsigned char*b=(unsigned char*)&p;
    for(int i=0;i<140;i++){if(i%16==0)printf("\n[%02d]",i);printf(" %02x",b[i]);}
    printf("\n\nsq_off: head=%u tail=%u mask=%u entries=%u flags=%u dropped=%u array=%u\n",
        p.so.head,p.so.tail,p.so.mask,p.so.entries,p.so.flags,p.so.dropped,p.so.array);
    printf("cq_off: head=%u tail=%u mask=%u entries=%u overflow=%u cqes=%u\n",
        p.co.head,p.co.tail,p.co.mask,p.co.entries,p.co.overflow,p.co.cqes);
    return 0;
}
