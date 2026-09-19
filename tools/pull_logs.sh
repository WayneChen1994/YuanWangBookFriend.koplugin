#!/bin/sh
# 拉取 KPW4 上的 KOReader 日志（crash.log 尾部）
# 用法： ./tools/pull_logs.sh [行数] [设备IP] [端口]
set -e

LINES="${1:-200}"
HOST="${2:-192.168.3.89}"
PORT="${3:-2222}"
KEY="$HOME/.ssh/id_ywbf_kpw4"

ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -p "$PORT" "root@$HOST" "tail -n $LINES /mnt/us/koreader/crash.log"
