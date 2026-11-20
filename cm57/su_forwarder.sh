#!/system/bin/sh
# z6 su forwarder — replaces the leftover static su this project once installed into
# ZeroTermux's own usr/bin. That one only ever said "连 @suwshd 失败" because the delivery
# shape runs no shd agent; the leg that does work is the ko's 改道 path, whose path string
# is /system/bin/su. Keeping a `su` on PATH means apps (and people) typing bare `su` land
# on the working chain instead of a dead socket.
exec /system/bin/su "$@"
