import io
import re

P = 'kmod/w103_su.sh'
s = io.open(P, encoding='utf-8').read()
acts = 0

# ---- 1) DEVOK 定义(放在 fire() 之前) ----
anchor1 = "fire() {   # fire <动词> <等多久>"
assert s.count(anchor1) == 1, 'fire() 锚点不唯一'
devok_def = '''DEVOK() {   # ★第 44 发的教训：post 等待中途设备被 HARD_RESET(ro.boot.bootreason=HARD_RESET/PS_HOLD)，
            #   之后每条 adb 只返回 "device '…' not found"，而我用 `tr -dc 0-9` 从**错误文本**里抠数字
            #   当 uid ⇒ 日志打出 `目标 uid=104225003`(那是**序列号**里的数字!)，整发带着假参数在空气里
            #   跑完全部步骤还"跑完了"。⇒ 参数只能从**成功回执**里按形状取；设备不在就当场停。
    D=$(S 'echo PFOK-$(cat /proc/uptime)' | tr -d '\\r\\n')
    case "$D" in
      PFOK-*) return 0 ;;
    esac
    echo "[x] 设备不在线(读到 [$D]) ⇒ 立刻停；不带错误文本往下拼参数"; exit 8
}

'''
s = s.replace(anchor1, devok_def + anchor1, 1)
acts += 1

# ---- 2) uid 必须按形状从成功回执里取 ----
old2 = """    TU=$(S 'cat /data/local/tmp/w132_tuid.txt 2>/dev/null' | tr -dc '0-9')
    [ -n "$TU" ] || { echo "[x] uid 反查没出单行纯数字 ⇒ 后面全不打(第 43 发就是带假 uid 打完整发)"; exit 6; }"""
assert s.count(old2) == 1, 'uid 锚点不唯一'
new2 = """    DEVOK
    TURAW=$(S 'cat /data/local/tmp/w132_tuid.txt 2>/dev/null' | tr -d '\\r\\n')
    TU=$(printf '%s' "$TURAW" | grep -oE '^[0-9]{3,6}$')
    [ -n "$TU" ] || { echo "[x] w132_tuid.txt 不是 3~6 位纯数字：[$TURAW] ⇒ 后面全不打"
                      echo "    (第 43 发：grep 命中两行拼成 1066710817；第 44 发：设备掉线后读到的是 adb 的错误文本)"
                      exit 6; }"""
s = s.replace(old2, new2, 1)
acts += 1

# ---- 3) 推送后复验落地(以前 PUSH 把失败吞成静默) + 输出限长(防自喂式灌爆磁盘) ----
old3 = '''    echo "  工具: ksuctl87=[$(S \'md5sum /data/local/tmp/ksuctl87 2>&1 | cut -c1-32\')] runner=[$(S "md5sum $RUN 2>&1 | cut -c1-32")] agent=[$(S \'pidof shd\')]"'''
assert s.count(old3) == 1, '工具行锚点不唯一'
new3 = old3 + '''
    DEVOK
    MISS=$(S "ls /data/local/tmp/ksuctl87 /data/local/tmp/sustatic /data/local/tmp/w135_fix.sh /data/local/tmp/w135_off.sh /data/local/tmp/w147_dom.sh $DOM2 $RUN /data/local/tmp/w148_uid.sh 2>&1 | grep -c 'No such file'")
    [ "${MISS:-x}" = "0" ] || { echo "[x] 有 $MISS 个载荷没落到设备上 ⇒ 停(PUSH 的失败以前是静默的)"; exit 9; }
    echo "    载荷全部落地(8/8)"'''
s = s.replace(old3, new3, 1)
acts += 1

# ---- 4) 每一组触发前重新 preflight；所有设备侧 cat 一律限长 ----
#      第 45 发：w148_uid.sh 自己 `exec >L` 又 `cat L` ⇒ 文件自我喂到 12.4GB，
#      驱动 `S 'cat L'` 把它整份灌进主机日志(11.9GB)把 G 盘写满。
#      脚本本身已修；这里再加一道**驱动侧上限**，任何一侧再犯也不至于炸盘。
pat = re.compile(r'^(\s*)S \'cat (/data/local/tmp/[^\s\']+) 2>&1\'$', re.M)
cnt = [0]
def repl(m):
    cnt[0] += 1
    return "%sS 'head -c 6000 %s 2>&1'" % (m.group(1), m.group(2))
s2 = pat.sub(repl, s)
acts += cnt[0]

# 只动 ATT=25 那段里的这些 cat：用范围检查确认没有误改别处(别的档也限长是好事，但要知道改了几处)
for anchor in [
    '    echo "  (a1) 负对照',
    '    echo "  (a2) 正判据',
    '    echo "  (b) 撤名单',
]:
    i = s2.find(anchor)
    assert i >= 0, '触发锚点找不到: ' + anchor
    j = s2.index('\n', i)
    s2 = s2[:j+1] + '    DEVOK\n' + s2[j+1:]
    acts += 1

io.open(P, 'w', encoding='utf-8', newline='\n').write(s2)
print('补丁动作数 =', acts, '(含设备侧 cat 限长 %d 处)' % cnt[0])
