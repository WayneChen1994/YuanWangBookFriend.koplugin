#!/bin/sh
# 重启 KPW4 上的 KOReader（加载新插件代码）
# 用法： ./tools/restart_koreader.sh [设备IP] [端口]
#
# 注意：必须用 setsid 脱离当前 SSH 会话，否则 KOReader 会在 SSH 连接断开时
#       收到信号并自行退出（表现为启动到 "Applying patch" 后 teardown）。
set -e

HOST="${1:-192.168.3.89}"
PORT="${2:-2222}"
KEY="$HOME/.ssh/id_ywbf_kpw4"

SSH_CMD="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $PORT root@$HOST"

# 先清 /var：32M tmpfs 一旦写满，KOReader 启动脚本会 cp 失败，
# eips 也无法刷新屏幕，表现为「设备卡死、点屏幕没反应」。
# /var/tmp/*.raw 是 framebuffer 快照，随时可再生，删掉安全。
echo "==> 检查 /var 空间"
$SSH_CMD "used=\$(df /var | tail -1 | awk '{print \$5}' | tr -d '%'); \
  echo \"  /var 已用 \${used}%\"; \
  if [ \"\${used}\" -ge 90 ]; then
    echo '  空间不足，清理 framebuffer 快照';
    rm -f /var/tmp/*.raw;
    df -h /var | tail -1;
  fi"

echo "==> 停止现有 KOReader"
# 必须连 /var/tmp/koreader.sh 的 sh wrapper 一起杀掉，详见 tools/stop_koreader.sh 的注释。
# 用独立脚本而不是内联命令：字符串匹配（pgrep -f 'koreader.sh'）会匹配到 SSH 会话自身。
$SSH_CMD "mkdir -p /mnt/us/ywbf_dev" && cat tools/stop_koreader.sh | $SSH_CMD "cat > /mnt/us/ywbf_dev/stop_koreader.sh" && $SSH_CMD "sh /mnt/us/ywbf_dev/stop_koreader.sh"

echo "==> 同步启动脚本副本"
# KOReader 启动时会比对 /var/tmp/koreader.sh 与 /mnt/us/koreader/koreader.sh 的 md5，
# 不一致就弹「启动脚本已更新，需要完全退出」的确认框（reader.lua:isStartupScriptUpToDate）。
# /var 满导致 cp 写残缺时必然触发，这里主动同步并校验，避免每次启动都要手动点掉。
$SSH_CMD "cp -f /mnt/us/koreader/koreader.sh /var/tmp/koreader.sh && chmod 777 /var/tmp/koreader.sh; \
  a=\$(md5sum /var/tmp/koreader.sh 2>/dev/null | cut -d' ' -f1); \
  b=\$(md5sum /mnt/us/koreader/koreader.sh 2>/dev/null | cut -d' ' -f1); \
  if [ \"\$a\" = \"\$b\" ] && [ -n \"\$a\" ]; then echo '  副本一致，不会弹更新提示'; \
  else echo \"  !! 副本不一致 (\$a vs \$b)，仍可能弹窗\"; fi"

echo "==> 启动 KOReader"
# 若上一步 SSH 断了（KOReader 退出会连带停掉它自己的 dropbear），这里会失败，
# 需要你先在设备上手动点 KOReader 图标，再重跑本脚本完成同步与重启。
$SSH_CMD "cd /mnt/us/koreader && (setsid nohup ./koreader.sh > /mnt/us/ywbf_dev/koreader_out.log 2>&1 < /dev/null &)"

echo "==> 等待插件初始化…"
sleep 40
$SSH_CMD "echo \"  插件初始化次数: \$(grep -c 'YWBF: plugin initialized' /mnt/us/koreader/crash.log)\"; \
  echo \"  KOReader 进程: \$(ps | grep -c '[r]eader.lua')\"; \
  if [ -f /var/tmp/koreader.sh ]; then \
    a=\$(md5sum /var/tmp/koreader.sh | cut -d' ' -f1); \
    b=\$(md5sum /mnt/us/koreader/koreader.sh | cut -d' ' -f1); \
    [ \"\$a\" = \"\$b\" ] && echo '  启动脚本副本：一致（不会弹更新提示）' || echo '  启动脚本副本：不一致（会弹更新提示）'; \
  else echo '  启动脚本副本：缺失（会弹更新提示）'; fi" \
  || echo "!! SSH 不可达：dropbear 由 KOReader 的 SSH 插件提供，KOReader 停了 SSH 也就断了。
   请在设备上手动点 KOReader 图标启动（SSH 会自动恢复），然后再执行本脚本查看状态。"
