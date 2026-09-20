#!/bin/sh
# OTA 变异驱动。
#
# 规矩：变异**只**作用在插件副本（mutplugin）上，真插件一个字节都不动。
# 每条变异跑完当场判定：
#   MUTAPPLY-FAIL = 变异没打上（这条不算数，必须修）
#   RED           = 测试红了（这条变异被抓住了，正是要的结果）
#   GREEN         = 测试还是全绿 —— 说明缺一条能抓住它的断言
#   CRASH         = 脚本崩了（也算被抓住，但要在报告里说明）
#
# 用法：sh /mnt/us/ywbf_dev/tools/mut_ota.sh

PLUGIN=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin
MUT=/mnt/us/ywbf_dev/mutplugin
TOOLS=/mnt/us/ywbf_dev/tools
OUT=/mnt/us/ywbf_dev/_mut_ota.txt
TDIR=/mnt/us/ywbf_dev/tmp_mut

: > "$OUT"

for id in L1 L2 L3 L4 L5 L6 L7 L8 L9 L10 L11 L12 L13 L14 \
          W1 W2 W3 W4 W5 W6 W7 W8 W9 W10 W11 W12 W13 W14 L15 L16 ; do

    rm -rf "$MUT"
    cp -r "$PLUGIN" "$MUT" || { echo "$id  COPY-FAIL" >> "$OUT"; continue; }

    cd /mnt/us/koreader || exit 1

    if ! LD_LIBRARY_PATH=/mnt/us/koreader/libs YWBF_PLUGIN_DIR="$MUT" \
         YWBF_TEST_DIR="$TDIR" \
         ./luajit "$TOOLS/eng_mut_ota.lua" "$id" "$MUT" >> "$OUT" 2>&1 ; then
        echo "$id  MUTAPPLY-FAIL" >> "$OUT"
        continue
    fi

    LD_LIBRARY_PATH=/mnt/us/koreader/libs YWBF_PLUGIN_DIR="$MUT" \
        YWBF_TEST_DIR="$TDIR" \
        ./luajit "$TOOLS/eng_check_ota.lua" > "$TDIR.log" 2>&1

    summary=$(grep '^=== 合计' "$TDIR.log" | tail -1)
    if [ -z "$summary" ]; then
        echo "$id  CRASH  $(tail -1 "$TDIR.log")" >> "$OUT"
    else
        case "$summary" in
            *" 0 失败"*) echo "$id  GREEN   $summary" >> "$OUT" ;;
            *)           echo "$id  RED     $summary" >> "$OUT"
                         grep '  FAIL  ' "$TDIR.log" | head -6 >> "$OUT" ;;
        esac
    fi
done

rm -rf "$MUT"
echo "=== 变异跑完 ===" >> "$OUT"
