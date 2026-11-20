#!/bin/bash
# 只读审计（不编译、不 punch、不改任何文件）：找"装载期因为多读一条条目而多做的事"，
# 尤其是任何**能对上 +16~30 秒这个时刻**的定时/异步成分。账=md §6.271 之后的任务 #103。
K=/root/k/ksu
echo "=== 0) 树在不在 + 这份树是不是那棵出货的树(只读比对) ==="
[ -d "$K" ] || { echo "!! 没有 $K"; exit 1; }
md5sum "$K/policy/allowlist.c" "$K/policy/profile.c" 2>/dev/null
echo "文件清单: $(ls "$K" | tr '\n' ' ')"

echo; echo "=== 1) 装载入口：谁读 .allowlist、什么时候读 ==="
grep -rn "load_all_allow_list\|allowlist_seq_show\|NEW_GET_ALLOW_LIST\|KSU_CMD_LOAD_ALLOW\|load_allow" "$K" --include=*.c --include=*.h | head -20

echo; echo "=== 2) ★全树找定时/异步成分（这是唯一能把'一次性动作'和'十几秒后死'接起来的形状） ==="
grep -rn "schedule_work\|queue_work\|queue_delayed_work\|INIT_WORK\|setup_timer\|timer_setup\|mod_timer\|add_timer\|kthread_run\|kthread_create\|schedule_timeout\|msleep\|prctl\|task_work_add" "$K" --include=*.c | grep -v "^.*:.*\*" | head -40

echo; echo "=== 3) 每条 entry 被读到时做了什么（含 profile 落地/打标） ==="
grep -n "allowlist_add_key\|allowlist_key_to\|eventfd\|ksu_event_queue\|ksu_update_sid\|set_cred_task\|ksu_set_task_cred\|uid_key\|profile.c" "$K/policy/allowlist.c" | head -30

echo; echo "=== 4) allowlist.c 的写入/保存路径（有没有把东西写回磁盘的定时器） ==="
grep -n "file\|write\|commit\|save\|sync\|delayed" "$K/policy/allowlist.c" | head -30

echo; echo "=== 5) profile.c：非 Manager 那条才会落地的东西 ==="
sed -n '1,80p' "$K/policy/profile.c"

echo; echo "=== 6) 有没有 reboot/kernel_halt/emergency_restart 形状的调用（(I) 的直接嫌疑人） ==="
grep -rn "kernel_halt\|emergency_restart\|machine_restart\|kernel_power_off\|orderly_poweroff\|ps_hold\|PS_HOLD\|restart" "$K" --include=*.c | head -20

echo; echo "=== 7) tracepoint/execve 路径里有没有对'第二个 uid'特殊处理 ==="
grep -rn "is_uid_manager\|use_default\|ksu_get_task_profile\|thief\|should_install" "$K/policy" "$K/hook" "$K/feature" --include=*.c 2>/dev/null | head -25
echo "END"
