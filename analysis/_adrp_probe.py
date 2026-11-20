
import io,re
data=io.open(r"kernel_dev_g2a88cd145def.bin","rb").read()
base=0xffffffc010080000
pages={0xffffffc01222b000:"security_hook_heads",0xffffffc012b18000:"selinux_state",0xffffffc01292d000:"init_uts_ns",0xffffffc01210f000:"linux_banner"}
from collections import defaultdict
hits=defaultdict(list)
for off in range(0,len(data)-4,4):
    ins=int.from_bytes(data[off:off+4],"little")
    if (ins & 0x9f000000)!=0x90000000: continue
    imm=((((ins>>5)&0x7ffff)<<2)|((ins>>29)&3))
    if imm & (1<<20): imm -= (1<<21)
    ad=(((base+off)&~0xfff)+(imm<<12))
    if ad in pages: hits[pages[ad]].append(base+off)
for name in pages.values():
    h=hits[name]
    print("%-22s 引用 %4d 处  例如 %s" % (name, len(h), ["0x%x"%a for a in h[:3]]))
