
import io,re
from collections import Counter
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_LITTLE_ENDIAN
data=io.open(r"kernel_dev_g2a88cd145def.bin","rb").read()
base=0xffffffc010080000
PAGE=0xffffffc012b18000
md=Cs(CS_ARCH_ARM64,CS_MODE_LITTLE_ENDIAN); md.detail=True
refs=[]
for off in range(0,len(data)-4,4):
    ins=int.from_bytes(data[off:off+4],"little")
    if (ins & 0x9f000000)!=0x90000000: continue
    imm=((((ins>>5)&0x7ffff)<<2)|((ins>>29)&3))
    if imm & (1<<20): imm -= (1<<21)
    if (((base+off)&~0xfff)+(imm<<12))==PAGE: refs.append(off)
c=Counter(); ex={}
for off in refs:
    code=data[off:off+16]
    its=list(md.disasm(code, base+off))
    if len(its)<2: continue
    a,b=its[0],its[1]
    m=re.search(r"#0x([0-9a-f]+)\]", b.op_str)
    key=(b.mnemonic, m.group(0) if m else b.op_str[:14], its[2].mnemonic if len(its)>2 else '')
    c[key]+=1; ex.setdefault(key, "0x%x: %s ; %s"%(base+off,a.op_str,b.op_str))
for k,n in c.most_common(14):
    print("%-40s x%-4d  例 %s" % (str(k), n, ex[k]))
print("引用点总数", len(refs))
