#!/bin/sh
# 变异验证：证明 7f/7g/7h（备份必须含 data）与 7j/7l（不自我递归）真有牙
# 规则：只在插件副本上做，绝不碰真插件目录
set -u
KO=/mnt/us/koreader
COPY=/mnt/us/ywbf_dev/leadplugin
OTA=$COPY/ywbf/ota.lua
GOOD=/mnt/us/ywbf_dev/_ota_good.lua
RUN="cd $KO && LD_LIBRARY_PATH=$KO/libs YWBF_PLUGIN_DIR=$COPY YWBF_TEST_DIR=/mnt/us/ywbf_dev/ota_test_data $KO/luajit /mnt/us/ywbf_dev/tools/eng_check_ota.lua"

cp $OTA $GOOD

echo "########## 基线（未变异） ##########"
sh -c "$RUN > /mnt/us/ywbf_dev/_mut_base.txt 2>&1"
tail -1 /mnt/us/ywbf_dev/_mut_base.txt

echo "########## 变异 A：备份不再排除 ota_backup（应打红 7j / 7l） ##########"
sed -i 's/Ota.BACKUP_DIR_NAME, Ota.BACKUP_DIR_NAME,/Ota.STAGE_DIR_NAME, Ota.STAGE_DIR_NAME,/' $OTA
sh -c "$RUN > /mnt/us/ywbf_dev/_mut_a.txt 2>&1"
tail -1 /mnt/us/ywbf_dev/_mut_a.txt
grep FAIL /mnt/us/ywbf_dev/_mut_a.txt | head -8
cp $GOOD $OTA

echo "########## 变异 B：备份恢复成排除整个 data（应打红 7f/7g/7h） ##########"
# 分隔符用 # 不能用 %：模式里本身就有 `%s`，会被当成定界符（busybox sed 直接报 bad option）
sed -i "s#tar -czf '%s' -C '%s' #tar -czf '%s' -C '%s' --exclude=./data --exclude=data #" $OTA
grep -n "tar -czf" $OTA | head -3
sh -c "$RUN > /mnt/us/ywbf_dev/_mut_b.txt 2>&1"
tail -1 /mnt/us/ywbf_dev/_mut_b.txt
grep FAIL /mnt/us/ywbf_dev/_mut_b.txt | head -8
cp $GOOD $OTA

echo "########## 还原后复跑 ##########"
sh -c "$RUN > /mnt/us/ywbf_dev/_mut_r.txt 2>&1"
tail -1 /mnt/us/ywbf_dev/_mut_r.txt
md5sum $OTA
