import io
import re

P = 'kmod/w103_su.sh'
s = io.open(P, encoding='utf-8').read()
i = s.index('elif [ "$ATT" = 26 ]; then')
j = s.index('elif [ "$ATT" = 25 ]; then')
blk = s[i:j]

# ATT=26 段里所有「fire 某个 @sushd:<脚本> 之后 head 那份回执」的地方，都换成"短等 + WAITFOR 轮询"。
#   第 51 发只补了 sweep/residue 两处，其余三处是同一个 race(agent 响应时间不是常数)，一起治。
pat = re.compile(
    r'fire "(@sushd:/data/local/tmp/[A-Za-z0-9_.$-]+)" (\d+)\n'
    r'(\s*)S \'head -c 6000 (/data/local/tmp/[A-Za-z0-9_.$-]+) 2>&1\''
)


def rep(m):
    verb, wait, ind, outfile = m.group(1), m.group(2), m.group(3), m.group(4)
    return ('fire "%s" 6\n%sWAITFOR %s 40\n%sS \'head -c 6000 %s 2>&1\''
            % (verb, ind, outfile, ind, outfile))


blk2, n = pat.subn(rep, blk)
# 已经手工补过的两处(WAITFOR 紧跟 fire)别二次包裹
blk2 = blk2.replace('WAITFOR /data/local/tmp/w153_sweep.out 40\n    WAITFOR', 'WAITFOR')
s = s[:i] + blk2 + s[j:]
io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('ATT=26 里改成"轮询等文件"的处数 =', n)
