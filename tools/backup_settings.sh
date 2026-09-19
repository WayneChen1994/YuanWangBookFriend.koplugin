#!/bin/sh
# 备份设备上的插件配置（SimpleUI / KOReader 全局设置 / 远望书友数据）
# 用法： ./tools/backup_settings.sh [设备IP] [端口]
#
# 背景：强制断电会让正在写入的配置文件被截断（SimpleUI 的 sui_settings.lua
#       就吃过这个亏）。定期跑一次，出问题能拉回来。
set -e

HOST="${1:-192.168.3.89}"
PORT="${2:-2222}"
KEY="$HOME/.ssh/id_ywbf_kpw4"

SSH_CMD="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $PORT root@$HOST"
STAMP=$(date +%Y%m%d_%H%M%S)
DEST="/mnt/us/ywbf_dev/settings_backup/$STAMP"

echo "==> 备份到设备 $DEST"
$SSH_CMD "mkdir -p $DEST && \
  cp -a /mnt/us/koreader/settings/simpleui $DEST/simpleui 2>/dev/null || true; \
  cp -a /mnt/us/koreader/settings.reader.lua $DEST/ 2>/dev/null || true; \
  cp -a /mnt/us/koreader/plugins/YuanWangBookFriend.koplugin/data $DEST/ywbf_data 2>/dev/null || true; \
  du -sh $DEST; ls -R $DEST | head -20"

echo "==> 完成。恢复到设备时用："
echo "    ssh ... \"cp -a $DEST/simpleui/. /mnt/us/koreader/settings/simpleui/\""
