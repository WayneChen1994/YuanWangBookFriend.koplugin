#!/bin/sh
# 停止 KOReader（含 /var/tmp/koreader.sh 的 sh wrapper）
#
# 关键：不能只杀 reader.lua。父 shell 会继续跑完 koreader.sh，
# 最后执行 `rm -f /var/tmp/koreader.sh`（脚本末尾 428 行），
# 把新实例刚同步好的启动脚本副本删掉，导致每次启动都弹
# 「启动脚本已更新，需要完全退出 KOReader」的确认框。
#
# 也不能用 pgrep -f 'koreader.sh' / 'reader.lua' 之类的字符串匹配：
# 远程命令自身的命令行就含这些字符串，会把 SSH 会话一起杀掉。
# 所以这里逐进程读 /proc/<pid>/cmdline 做精确前缀匹配。

# 第一轮：杀 luajit reader.lua 及其父 shell
for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
    case "$c" in
        "./luajit ./reader.lua"*)
            pid=${d#/proc/}
            pp=$(awk '{print $4}' "$d/stat" 2>/dev/null)
            kill "$pid" 2>/dev/null
            if [ -n "$pp" ] && [ "$pp" != "1" ]; then
                kill "$pp" 2>/dev/null
            fi
            ;;
        "/bin/sh /var/tmp/koreader.sh"*|"/bin/sh ./koreader.sh"*)
            pid=${d#/proc/}
            kill "$pid" 2>/dev/null
            ;;
    esac
done

# 等旧实例完全退出（没退干净就拉新实例，新实例会立刻退出）
i=0
while [ $i -lt 30 ]; do
    n=0
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
        case "$c" in
            "./luajit ./reader.lua"*) n=$((n + 1)) ;;
        esac
    done
    [ "$n" = "0" ] && break
    i=$((i + 1))
    sleep 1
done
# 再等一小会儿：父 shell 收到子进程退出后会继续跑完 koreader.sh 的尾部
# （含 `rm -f /var/tmp/koreader.sh`），要等它彻底结束，之后同步的副本才不会被删掉。
sleep 2
echo "  等待退出 ${i}s"
exit 0
