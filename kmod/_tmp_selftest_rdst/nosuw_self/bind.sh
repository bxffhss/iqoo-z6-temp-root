        log "----- ★NOSUW：bind /product/bin 归 stage(不派给 suw) -----"
        # ★§6.426：bind 的源从 /data/local/tmp/pbin 挪进 **root-only 的 /data/adb/ksu/pbin**。
        #   今晚一手：旧位置谁都能 rm -rf(普通脚本/app 都删得动) ⇒ 源被删后 bind 变 `/local/tmp/pbin//deleted`
        #   ⇒ **整层 /product/bin 在进程眼里是空目录**，而官方 Manager 的 su 只有裸串 `su`(dex 里没有任何绝对 su 路径)
        #   ⇒ 它那支 PATH 解析命中的就是这里。名字仍叫 pbin：下面那条 mountinfo 硬闸的 grep 不用改。
        NB2=/data/adb/ksu/pbin
        ML=$(grep -ac pbin /proc/self/mountinfo 2>/dev/null)
        SB2=/data/local/tmp/sustatic
        log "  前置闸一：mountinfo 里 pbin 行数=$ML  ★必须=0 才许 bind"
        log "  前置闸二：bind 的源 $SB2 字节=$(wc -c < $SB2 2>/dev/null) md5=$(md5sum $SB2 2>/dev/null | cut -c1-32)  ★必须非空(这条腿在 insmod 之后跑，源是谁推的要说得清)"
        if [ ! -s "$SB2" ]; then
            log "  [x] $SB2 不在或为空 ⇒ **不做 bind**（宁可这一格判据没测到，也不挂一个空壳进 /product/bin）"
        elif [ "${ML:-1}" = 0 ]; then
            rm -rf "$NB2"; mkdir -p "$NB2"
            cp -a /product/bin/. "$NB2/" 2>/dev/null
            cp "$SB2" "$NB2/su" 2>/dev/null
            chmod 755 "$NB2" "$NB2/su" 2>/dev/null
            mount --bind "$NB2" /product/bin
            log "  NOSUW_BIND_RC=$?  NOSUW_SU_AT_TGT=$(ls -l /product/bin/su 2>&1 | tail -1)"
            # ★§6.426 第二段：把落点副本收进 root-only 目录，再拉起**维持循环**(开关文件＝kill switch；节拍 20 秒、上限 200 次、
            #   连续 3 次修不好就 GIVEUP——§6.198 那次 fork 风暴连着敲出过 PS_HOLD，所以绝不做成 1 秒节拍)。
            cp "$SB2" /data/adb/ksu/sustatic 2>/dev/null
            : > /data/local/tmp/ksu_pbin_keep 2>/dev/null
            nohup /system/bin/sh /data/local/tmp/w774_pbin_keeper.sh >/dev/null 2>&1 &
            log "  NOSUW_KEEPER_PID=$(cat /data/local/tmp/w774_keeper.log 2>/dev/null | head -1 | cut -c1-40) 开关=$(ls -l /data/local/tmp/ksu_pbin_keep 2>&1 | cut -c1-46) rootonly源=$(ls -ld /data/adb/ksu/pbin 2>&1 | cut -c1-44)"
            log "  NOSUW_CP_N=$(ls -A $NB2 2>/dev/null | wc -l) NOSUW_HEALTH=$([ "$(/system/bin/sh -c 'echo yes' 2>&1)" = yes ] && echo OK || echo DEAD)"
            log "  挂载读回=$(grep -a pbin /proc/self/mountinfo 2>/dev/null | cut -c1-120 | tr '\n' '|')"
        else
            log "  [x] 有残留挂载($ML 行) ⇒ **不做 bind**，也不去 umount：这一发的 bind 判据按没测到算"
        fi
    fi
