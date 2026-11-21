#!/system/bin/sh
# 去云控 — ClassFruit (classfruit.cn)
# Magisk 模块页 Action 按钮: 只会"生效", 不会反过来停掉保护
#   临时停拦截: 把 config.conf 里 PAUSE 改 1 (或 adb: sh qyk.sh restore)

MODDIR=${0%/*}
. "$MODDIR/qyk.sh"

load_config

if [ "$PAUSE" = "1" ]; then
  { grep -v '^PAUSE=' "$QYK/config.conf" 2>/dev/null; echo "PAUSE=0"; } > "$QYK/config.conf.tmp" && mv -f "$QYK/config.conf.tmp" "$QYK/config.conf"
  echo "[去云控] 已取消暂停(PAUSE=1 -> 0)"
fi

apply_all
start_guard
echo "[去云控] 已按当前配置生效（幂等，可反复点）"
echo "提示: 开机已自动生效, 这个按钮只是让你不用重启也能立刻应用"
echo
status