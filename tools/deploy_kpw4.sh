#!/bin/sh
# 部署插件到 KPW4（开发环境）
# 用法： ./tools/deploy_kpw4.sh [设备IP] [端口]
# 说明：通过 SSH 把插件目录整体推送到 KPW4 的 koreader/plugins 下，覆盖旧版本。
#       已配置免密登录（~/.ssh/id_ywbf_kpw4）。
set -e

HOST="${1:-192.168.3.89}"
PORT="${2:-2222}"
KEY="$HOME/.ssh/id_ywbf_kpw4"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)/YuanWangBookFriend.koplugin"
REMOTE_PLUGINS="/mnt/us/koreader/plugins"

if [ ! -d "$SRC_DIR" ]; then
  echo "找不到插件目录：$SRC_DIR" >&2
  exit 1
fi

SSH_CMD="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $PORT root@$HOST"

# 备份目录必须**每次唯一**。
# 事故复盘：原来固定用 /mnt/us/ywbf_dev/data_backup，两个人（或两个 agent）同时部署时，
# 后一次的 `rm -rf data_backup` 会把前一次刚挪过去的 data/ 连带删掉，
# 最后 mv 不到东西 → 插件的 data/ 整体丢失（API Key、缓存、历史一起没）。
# 用时间戳+PID 命名就不会互相踩；成功后也不删，留作回滚点。
BACKUP="/mnt/us/ywbf_dev/data_backup_$(date +%Y%m%d_%H%M%S)_$$"

echo "==> 保护用户数据（data/ 含 API Key、缓存、历史）"
$SSH_CMD "cd $REMOTE_PLUGINS && mkdir -p $BACKUP && \
  if [ -d YuanWangBookFriend.koplugin/data ]; then \
    cp -a YuanWangBookFriend.koplugin/data/. $BACKUP/ && echo '  已备份 data/ 到 $BACKUP'; \
  else echo '  无旧 data/'; fi"

echo "==> 推送 $SRC_DIR -> $HOST:$REMOTE_PLUGINS/YuanWangBookFriend.koplugin"
tar -cf - -C "$(dirname "$SRC_DIR")" "$(basename "$SRC_DIR")" \
  | $SSH_CMD "cd $REMOTE_PLUGINS && rm -rf YuanWangBookFriend.koplugin && tar -xf - && ls YuanWangBookFriend.koplugin"

echo "==> 还原用户数据"
$SSH_CMD "cd $REMOTE_PLUGINS && rm -rf YuanWangBookFriend.koplugin/data && \
  mkdir -p YuanWangBookFriend.koplugin/data && \
  cp -a $BACKUP/. YuanWangBookFriend.koplugin/data/ && \
  ls YuanWangBookFriend.koplugin/data"

# 还原后必须自查：data/ 里没有 settings.json 就是出事了（Key 丢了用户会一脸懵）。
# 与其让用户重启后才发现"未配置 API Key"，不如当场失败并把备份路径报出来。
echo "==> 校验 data/ 已还原"
if ! $SSH_CMD "test -s $REMOTE_PLUGINS/YuanWangBookFriend.koplugin/data/settings.json"; then
  echo "" >&2
  echo "!!!!!! 部署失败：data/ 没有还原成功，API Key 可能已丢失 !!!!!!" >&2
  echo "备份还在设备上：$BACKUP" >&2
  echo "手动恢复：" >&2
  echo "  mkdir -p $REMOTE_PLUGINS/YuanWangBookFriend.koplugin/data" >&2
  echo "  cp -a $BACKUP/. $REMOTE_PLUGINS/YuanWangBookFriend.koplugin/data/" >&2
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
  exit 1
fi
echo "  data/settings.json 存在，备份保留在 $BACKUP"

echo "==> 部署完成。请在设备上重启 KOReader 使插件生效（长按菜单或退出后重新进入）。"
