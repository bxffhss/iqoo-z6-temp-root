#include <sepol/policydb.h>
#include <sepol/policydb/policydb.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
int main(int argc,char**argv){
  FILE*f=fopen(argv[1],"rb"); fseek(f,0,SEEK_END); long n=ftell(f); rewind(f);
  char*b=malloc(n); fread(b,1,n,f); fclose(f);
  unsigned magic,vers,modver; memcpy(&magic,b,4); memcpy(&vers,b+4,4); memcpy(&modver,b+8,4);
  printf("magic=0x%08x policyvers=%u module_version=%u bytes=%ld\n",magic,vers,modver,n);
  printf("offsets: symtab@12=%u classes=%u types=%u roles=%u nums=%u bbs=%u strs=%u\n",
     *(unsigned*)(b+12),*(unsigned*)(b+16),*(unsigned*)(b+20),*(unsigned*)(b+24),
     *(unsigned*)(b+28),*(unsigned*)(b+32),*(unsigned*)(b+36));
  policydb_t db; memset(&db,0,sizeof db); policydb_init(&db);
  policy_file_t pf; memset(&pf,0,sizeof pf);
  pf.type=PF_USE_MEMORY; pf.data=b; pf.len=0; pf.size=n;
  int rc=policydb_read(&db,&pf,1);          // verbose=1 ⇒ 真错误信息
  printf("policydb_read rc=%d  (读后 policyvers=%u mls=%d types=%u)\n",rc,db.policyvers,db.mls,db.p_types.nprim);
  return rc<0?3:0;
}
