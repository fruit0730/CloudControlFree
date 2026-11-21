#!/system/bin/sh
# 去云控 — ClassFruit (classfruit.cn)
# late_start: 系统服务一起来就应用(不等 boot_completed, 尽量缩云控窗口) + 启动守护

MODDIR=${0%/*}
. "$MODDIR/qyk.sh"

load_config

if [ "$PAUSE" = "1" ]; then
  log "PAUSE=1, 本次开机不拦截"
  exit 0
fi

# pm 可用即动手 (最多等 60 秒)
i=0
until pm list packages -U 2>/dev/null | grep -q package; do
  sleep 2
  i=$((i+1))
  [ "$i" -gt 30 ] && break
done

apply_all
start_guard