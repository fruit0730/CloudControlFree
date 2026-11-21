#!/system/bin/sh
# 去云控 — ClassFruit (classfruit.cn)
# 卸载模块时自动还原全部改动

MODDIR=${0%/*}
. "$MODDIR/qyk.sh"

# PM 在这类小内存设备上会偶发无响应, 多试几轮
n=1
while [ "$n" -le 3 ]; do
  restore_all
  [ -z "$RESTORE_FAIL" ] && break
  sleep 8
  n=$((n+1))
done

if [ -n "$RESTORE_FAIL" ]; then
  printf '%s\n' $RESTORE_FAIL > /data/local/tmp/qyk_unfinished.txt
  echo "[去云控] 这些没能恢复启用(PM 无响应): $RESTORE_FAIL"
  echo "        清单已存 /data/local/tmp/qyk_unfinished.txt, 手动执行: pm enable <包名>"
fi
rm -rf /data/adb/qyk