#!/system/bin/sh
# 去云控 — ClassFruit (classfruit.cn)
# 开机早期: 挂载 hosts、伪装属性 (此时 pm 还没就绪)

MODDIR=${0%/*}
QYK=/data/adb/qyk
. "$MODDIR/qyk.sh"

load_config

if [ "$PAUSE" = "1" ]; then
  exit 0
fi

# 跨重启的残留状态清理 (pid 可能被复用)
rm -f "$QYK/guard.pid" "$QYK/state_applied"

# 此时 /system/etc/hosts 是原始内容，留底
sed '/# ===== qyk begin =====/,/# ===== qyk end =====/d' /system/etc/hosts > "$QYK/hosts.orig" 2>/dev/null

apply_hosts
apply_props