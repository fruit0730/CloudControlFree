#!/system/bin/sh
# 去云控安装脚本 — ClassFruit (classfruit.cn)
# Magisk 安装环境提供: MODPATH / ui_print / set_perm_recursive / set_perm

ui_print "***********************************"
ui_print "   去云控 · CloudControl Free"
ui_print "   by ClassFruit — classfruit.cn"
ui_print "***********************************"
ui_print "- 设备: $(getprop ro.product.model) / Android $(getprop ro.build.version.release)"

QYK=/data/adb/qyk
mkdir -p "$QYK"

for f in "$MODPATH"/config/*; do
  b=${f##*/}
  if [ -f "$QYK/$b" ]; then
    ui_print "- 保留已有配置: $b"
  else
    cp "$f" "$QYK/$b"
  fi
done

# 升级时把新增的配置项补进现有 config.conf (不覆盖用户已改的值)
grep -E '^[A-Z_]+=' "$MODPATH/config/config.conf" | while IFS='=' read -r k v; do
  if ! grep -q "^$k=" "$QYK/config.conf" 2>/dev/null; then
    echo "$k=$v" >> "$QYK/config.conf"
    ui_print "- 新增配置项: $k"
  fi
done

sed '/# ===== qyk begin =====/,/# ===== qyk end =====/d' /system/etc/hosts > "$QYK/hosts.orig" 2>/dev/null

# 快照: 装机前就已经处于禁用状态的包 (不是本模块干的, 卸载/还原时不去动它们)
if [ ! -f "$QYK/state_predisabled.txt" ]; then
  DIS=$(pm list packages -d 2>/dev/null)
  : > "$QYK/state_predisabled.txt"
  for lf in pkgs_disable.txt pkgs_ota.txt pkgs_aggressive.txt; do
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$QYK/$lf" 2>/dev/null | grep -v '^$' | while read -r p; do
      echo "$DIS" | grep -qF -x "package:$p" && echo "$p" >> "$QYK/state_predisabled.txt"
    done
  done
  ui_print "- 装机前已禁用: $(wc -l < "$QYK/state_predisabled.txt") 个 (卸载时不接管)"
fi

ui_print "- 本机检测到的云控/遥测组件:"
pm list packages 2>/dev/null | sed 's/^package://' | grep -E 'cosa|deepthinker|metis|joyose|athena|aiunit|sceneservice|powermonitor|statistics|onetrace|romupdate|wearable\.ota|heytap\.mcs|powerkeeper|systemAdSolution|analytics' | while read -r p; do
  ui_print "    $p"
done

set_perm_recursive "$MODPATH" 0 0 0755 0644
for s in qyk.sh post-fs-data.sh service.sh action.sh uninstall.sh customize.sh; do
  set_perm "$MODPATH/$s" 0 0 0755
done

ui_print "-----------------------------------"
ui_print "- 配置目录: /data/adb/qyk"
ui_print "    config.conf      功能开关"
ui_print "    pkgs_*.txt       包名名单(可增删)"
ui_print "    hosts_*.txt      拦截域名(可增删)"
ui_print "    charge.conf      充电限流节点目标值"
ui_print "    props.conf       属性伪装(默认空)"
ui_print "- 开机自动生效(service 里 pm 一就绪就应用), 无需手动点任何东西"
ui_print "- Action 按钮 = 立即重应用配置(幂等, 不会反向停掉拦截)"
ui_print "- 临时停拦截: config.conf 里 PAUSE=1; 或 adb 执行 sh qyk.sh restore"
ui_print "- 卸载模块自动还原全部改动"
ui_print "! 激进模式(推送/商店/云同步)默认关闭"
ui_print "! 如需开启: config.conf 里 ENABLE_AGGRESSIVE=1"
ui_print "***********************************"