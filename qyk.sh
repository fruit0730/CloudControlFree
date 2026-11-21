#!/system/bin/sh
# 去云控核心库 — ClassFruit (classfruit.cn)
# 被 post-fs-data.sh / service.sh / action.sh / uninstall.sh  source，
# 也可直接运行: sh qyk.sh {apply|restore|status}

MODDIR="${MODDIR:-${0%/*}}"
QYK=/data/adb/qyk
LOG="$QYK/qyk.log"
CHGLOG="$QYK/charge.log"
IPT="$(command -v iptables || echo /system/bin/iptables)"
IP6T="$(command -v ip6tables || echo /system/bin/ip6tables)"

log() {
  [ "$ENABLE_LOG" = "1" ] || return 0
  read up _ < /proc/uptime 2>/dev/null
  echo "[up=${up%%.*} $(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"
}

rotate_log() {
  [ -f "$LOG" ] || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null)
  [ "${sz:-0}" -gt 204800 ] && mv -f "$LOG" "$LOG.1"
  return 0
}

load_config() {
  mkdir -p "$QYK" 2>/dev/null
  ENABLE_HOSTS=1; ENABLE_DISABLE=1; ENABLE_NETCUT=1; ENABLE_CLEAN=1
  ENABLE_OTA=1; ENABLE_PROPS=1; ENABLE_AGGRESSIVE=0; ENABLE_CHARGE=1
  CHARGE_FIX=0; CHARGE_SAFE_TEMP=420
  GUARD_INTERVAL=1800; ENABLE_LOG=1; PAUSE=0
  [ -f "$QYK/config.conf" ] && . "$QYK/config.conf"
}

# 去掉注释和空行，输出有效条目
read_list() {
  [ -f "$1" ] || return 0
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$'
}

refresh_pkg_cache() {
  PKGS=$(pm list packages 2>/dev/null)
  PKGS_UID=$(pm list packages -U 2>/dev/null)
  PKGS_DIS=$(pm list packages -d 2>/dev/null)
  # 存一份包名清单给守护用: 守护不再为此调 pm(每次唤醒都很贵)
  echo "$PKGS" > "$QYK/state_pkglist.txt" 2>/dev/null
}

pkg_exists()   { echo "$PKGS" | grep -q "^package:$1$"; }
pkg_disabled() { echo "$PKGS_DIS" | grep -q "^package:$1$"; }
pkg_uid()      { echo "$PKGS_UID" | grep "^package:$1 " | sed 's/.*uid://' | head -n1; }

disable_pkgs() {
  read_list "$QYK/pkgs_disable.txt"
  [ "$ENABLE_OTA" = "1" ] && read_list "$QYK/pkgs_ota.txt"
  [ "$ENABLE_AGGRESSIVE" = "1" ] && read_list "$QYK/pkgs_aggressive.txt"
  return 0
}

netcut_pkgs() {
  read_list "$QYK/pkgs_netcut.txt"
  [ "$ENABLE_OTA" = "1" ] && read_list "$QYK/pkgs_ota.txt"
  [ "$ENABLE_AGGRESSIVE" = "1" ] && read_list "$QYK/pkgs_aggressive.txt"
  return 0
}

hosts_mounted_by_us() {
  grep " /system/etc/hosts " /proc/self/mountinfo 2>/dev/null | grep -q "hosts.merged"
}

umount_hosts() {
  hosts_mounted_by_us || return 0
  umount /system/etc/hosts 2>/dev/null || umount -l /system/etc/hosts 2>/dev/null
  return 0
}

apply_hosts() {
  if [ "$ENABLE_HOSTS" != "1" ]; then
    umount_hosts
    return 0
  fi
  [ -s "$QYK/hosts.orig" ] || sed '/# ===== qyk begin =====/,/# ===== qyk end =====/d' /system/etc/hosts > "$QYK/hosts.orig" 2>/dev/null
  {
    cat "$QYK/hosts.orig" 2>/dev/null
    echo
    echo "# ===== qyk begin ====="
    cat "$QYK/hosts_core.txt" 2>/dev/null
    [ "$ENABLE_OTA" = "1" ] && cat "$QYK/hosts_ota.txt" 2>/dev/null
    [ "$ENABLE_AGGRESSIVE" = "1" ] && cat "$QYK/hosts_aggressive.txt" 2>/dev/null
    echo "# ===== qyk end ====="
  } | awk '!/^#/ && NF>1 { if (!seen[$2]++) print; next } { print }' > "$QYK/hosts.merged"
  # 兜底: 合并结果必须含 localhost, 否则 app 解析不了本机回环会大面积异常
  grep -q 'localhost' "$QYK/hosts.merged" || {
    { printf '127.0.0.1 localhost\n::1 ip6-localhost\n'; cat "$QYK/hosts.merged"; } > "$QYK/hosts.tmp" && mv -f "$QYK/hosts.tmp" "$QYK/hosts.merged"
  }
  # 必须 0644 + system_file 标签，否则 app/SELinux 读不到，拦截静默失效
  chmod 0644 "$QYK/hosts.merged"
  chcon u:object_r:system_file:s0 "$QYK/hosts.merged" 2>/dev/null
  umount_hosts
  if mount -o bind "$QYK/hosts.merged" /system/etc/hosts 2>/dev/null; then
    lbl=$(ls -Z "$QYK/hosts.merged" 2>/dev/null)
    case "$lbl" in
      *system_file*) log "hosts 已挂载 ($(grep -c '^0\.0\.0\.0' "$QYK/hosts.merged") 条拦截)" ;;
      *) log "警告: hosts 已挂载但标签异常($lbl)，app 可能读不到" ;;
    esac
  else
    log "hosts 挂载失败 (mount bind 被拒绝)"
  fi
}

apply_props() {
  [ "$ENABLE_PROPS" = "1" ] || return 0
  RP="$(command -v resetprop || echo /data/adb/magisk/resetprop)"
  [ -x "$RP" ] || { log "resetprop 不可用，跳过属性"; return 0; }
  read_list "$QYK/props.conf" | while IFS='=' read -r k v; do
    [ -n "$k" ] && [ -n "$v" ] || continue
    "$RP" "$k" "$v" >/dev/null 2>&1 && log "prop $k=$v"
  done
}

# COMPONENT_ENABLED_STATE: 0=默认 1=显式启用 2=禁用 3=对用户禁用
pm_enabled_state() {
  dumpsys package "$1" 2>/dev/null | tr ' ' '\n' | grep -m1 '^enabled=' | cut -d= -f2
}

# pm 状态设置: 退避重试 + 用 dumpsys 的 enabled 值正向判定
# (不能靠 pm list -d: 这里 pm/cmd 偶发 Failed transaction, 空结果会被误判成成功)
pm_set_state() {
  d=3
  for i in 1 2 3 4; do
    case "$2" in
      enable)  pm enable "$1" >/dev/null 2>&1 ;;
      disable) pm disable-user --user 0 "$1" >/dev/null 2>&1 || pm disable "$1" >/dev/null 2>&1 ;;
    esac
    st=$(pm_enabled_state "$1")
    case "$st" in
      0|1) [ "$2" = "enable" ] && return 0 ;;
      2|3) [ "$2" = "disable" ] && return 0 ;;
    esac
    [ "$i" -lt 4 ] && sleep "$d"
    d=$((d*2))
  done
  log "pm 暂时无法设置 $1 -> $2 (enabled=${st:-查询失败})"
  return 1
}

apply_disable() {
  [ "$ENABLE_DISABLE" = "1" ] || return 0
  disable_pkgs | sort -u | while read -r p; do
    pkg_exists "$p" || continue
    # 曾因禁用引发调用风暴而回退的包, 不再禁用(只靠 hosts 拦上传)
    grep -qxF "$p" "$QYK/state_storm_backoff.txt" 2>/dev/null && continue
    if pkg_disabled "$p"; then
      # 跨重启后仍是我们关掉的（不在装机时的预禁用快照里）→ 补回记录, 保证卸载能还原
      if ! grep -qxF "$p" "$QYK/state_predisabled.txt" 2>/dev/null; then
        grep -qxF "$p" "$QYK/state_disabled.txt" 2>/dev/null || {
          echo "$p" >> "$QYK/state_disabled.txt"
          log "补记禁用状态 $p"
        }
      fi
      continue
    fi
    if pm_set_state "$p" disable; then
      echo "$p" >> "$QYK/state_disabled.txt"
      drop_pending "$p"
      log "禁用 $p"
    else
      # PM 繁忙导致失败也要记住, 守护循环会补做
      grep -qxF "$p" "$QYK/state_pending_disable.txt" 2>/dev/null || echo "$p" >> "$QYK/state_pending_disable.txt"
      log "待重试: 禁用 $p"
    fi
  done
}

drop_pending() {
  [ -f "$QYK/state_pending_disable.txt" ] || return 0
  grep -vxF "$1" "$QYK/state_pending_disable.txt" > "$QYK/p.tmp" 2>/dev/null
  mv -f "$QYK/p.tmp" "$QYK/state_pending_disable.txt" 2>/dev/null || rm -f "$QYK/p.tmp"
}

# 名单里删掉的包要恢复启用, 否则改了配置也不生效
prune_stale_disables() {
  [ -f "$QYK/state_disabled.txt" ] || return 0
  want=$(disable_pkgs | sort -u)
  sort -u "$QYK/state_disabled.txt" -o "$QYK/state_disabled.txt" 2>/dev/null
  while read -r p; do
    [ -n "$p" ] || continue
    echo "$want" | grep -qxF "$p" && continue
    if pm_set_state "$p" enable; then
      log "名单已移除, 恢复启用 $p"
      grep -vxF "$p" "$QYK/state_disabled.txt" > "$QYK/p.tmp" 2>/dev/null
      mv -f "$QYK/p.tmp" "$QYK/state_disabled.txt" 2>/dev/null || rm -f "$QYK/p.tmp"
    fi
  done < "$QYK/state_disabled.txt"
}

# 禁用后若别的 app 疯狂 startService 它, 会把 system_server/logd 顶满并耗电
# 实测: 禁 com.nearme.statistics.rom 后 12 分钟 2068 条 "Unable to start service"
# 检测到风暴就自动回退成"保持启用 + 只拦域名"
storm_check() {
  [ -f "$QYK/state_disabled.txt" ] || return 0
  logcat -d -t 3000 > "$QYK/lc.tmp" 2>/dev/null || return 0
  while read -r p; do
    [ -n "$p" ] || continue
    n=$(grep -c "cmp=$p/" "$QYK/lc.tmp" 2>/dev/null)
    [ "${n:-0}" -gt 30 ] || continue
    if pm_set_state "$p" enable; then
      echo "$p" >> "$QYK/state_storm_backoff.txt"
      grep -vxF "$p" "$QYK/state_disabled.txt" > "$QYK/p.tmp" 2>/dev/null
      mv -f "$QYK/p.tmp" "$QYK/state_disabled.txt" 2>/dev/null || rm -f "$QYK/p.tmp"
      log "调用风暴回退: $p 已恢复启用($n 条失败调用), 改为只拦域名"
    fi
  done < "$QYK/state_disabled.txt"
  rm -f "$QYK/lc.tmp"
}

netcut_rules() {
  T="$1"
  case "$T" in
    *ip6*) rej="icmp6-adm-prohibited" ;;
    *)     rej="icmp-port-unreachable" ;;
  esac
  "$T" -t filter -N qyk_out 2>/dev/null
  "$T" -t filter -F qyk_out 2>/dev/null
  "$T" -t filter -C OUTPUT -j qyk_out 2>/dev/null || "$T" -t filter -I OUTPUT 1 -j qyk_out 2>/dev/null
  uids=""
  for p in $(netcut_pkgs | sort -u); do
    pkg_exists "$p" || continue
    u=$(pkg_uid "$p")
    [ -n "$u" ] || continue
    # 系统/共享 UID(如 1000) 会连累 system_server 等核心服务，绝不整 UID 断网
    if [ "$u" -lt 10000 ] 2>/dev/null; then
      [ "$T" = "$IPT" ] && log "netcut 跳过 $p (共享系统 uid=$u，改由 hosts 拦截)"
      continue
    fi
    uids="$uids $u"
  done
  n=0
  for u in $(echo "$uids" | tr ' ' '\n' | sort -un | grep -v '^$'); do
    # REJECT 让连接立刻失败; DROP 会让 app 干等到超时, 更费电
    if "$T" -t filter -A qyk_out -m owner --uid-owner "$u" -j REJECT --reject-with "$rej" 2>/dev/null; then
      n=$((n+1))
    elif "$T" -t filter -A qyk_out -m owner --uid-owner "$u" -j DROP 2>/dev/null; then
      n=$((n+1))
    fi
  done
  echo "$n"
}

apply_netcut() {
  if [ "$ENABLE_NETCUT" != "1" ]; then
    restore_netcut
    return 0
  fi
  n4=$(netcut_rules "$IPT")
  n6=$(netcut_rules "$IP6T")
  if [ "${n4:-0}" = "0" ] && [ "${n6:-0}" = "0" ]; then
    log "netcut: 没有可用规则 (无目标包或内核不支持 owner match)"
  else
    log "netcut 生效: IPv4=$n4 IPv6=$n6 个 UID"
  fi
}

restore_netcut() {
  for T in "$IPT" "$IP6T"; do
    "$T" -t filter -D OUTPUT -j qyk_out 2>/dev/null
    "$T" -t filter -F qyk_out 2>/dev/null
    "$T" -t filter -X qyk_out 2>/dev/null
  done
  return 0
}

apply_clean() {
  [ "$ENABLE_CLEAN" = "1" ] || return 0
  read_list "$QYK/pkgs_clean.txt" | while read -r p; do
    pkg_exists "$p" || continue
    pm clear "$p" >/dev/null 2>&1 && log "清理云控缓存 $p"
  done
}

# 断掉已建立的连接，让云控组件带着新规则重启
stop_cloud_apps() {
  for p in $(netcut_pkgs | sort -u); do
    pkg_exists "$p" || continue
    am force-stop "$p" >/dev/null 2>&1
  done
}

# 充电限流节点: 只恢复到 charge.conf 里记录的"满速充电时实测值"
charge_fields() {
  B=/sys/class/power_supply/battery
  printf 'cap=%s%% temp=%s status=%s mA=%s ccc=%s/%s in_lim=%s chg_lim=%s ccl=%s' \
    "$(cat $B/capacity 2>/dev/null)" "$(cat $B/temp 2>/dev/null)" \
    "$(cat $B/status 2>/dev/null)" "$(cat $B/current_now 2>/dev/null)" \
    "$(cat $B/constant_charge_current 2>/dev/null)" "$(cat $B/constant_charge_current_max 2>/dev/null)" \
    "$(cat $B/input_current_limit 2>/dev/null)" "$(cat $B/chg_limit 2>/dev/null)" \
    "$(cat $B/charge_control_limit 2>/dev/null)"
}

charge_sample() {
  printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$(charge_fields)"
}

apply_charge() {
  [ "$ENABLE_CHARGE" = "1" ] || return 0
  if [ "$CHARGE_FIX" = "1" ]; then
    btemp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    if [ -n "$btemp" ] && [ "$btemp" -ge "${CHARGE_SAFE_TEMP:-420}" ] 2>/dev/null; then
      log "充电限流回写跳过: 电池 ${btemp}(0.1°C) 超闸门，让路给热保护"
    else
      read_list "$QYK/charge.conf" | while IFS='=' read -r node val; do
        [ -f "$node" ] || continue
        [ -n "$val" ] || continue
        cur=$(cat "$node" 2>/dev/null)
        [ "$cur" = "$val" ] && continue
        if echo "$val" > "$node" 2>/dev/null; then
          log "充电限流还原 $node: $cur -> $val"
        else
          log "充电限流写入失败 $node (只读或 SELinux 拒绝)"
        fi
      done
    fi
  fi
  # 采样节流: 数值有变化才记, 否则最多每 30 分钟一条(少唤醒少写闪存)
  f=$(charge_fields)
  now=$(date +%s)
  lastt=$(cat "$QYK/charge.last_time" 2>/dev/null)
  if [ "$f" != "$(cat "$QYK/charge.last" 2>/dev/null)" ] || [ $((now - ${lastt:-0})) -ge 1800 ]; then
    printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$f" >> "$CHGLOG" 2>/dev/null
    echo "$f" > "$QYK/charge.last" 2>/dev/null
    echo "$now" > "$QYK/charge.last_time" 2>/dev/null
    sz=$(cat "$CHGLOG" 2>/dev/null | wc -c)
    if [ "${sz:-0}" -gt 102400 ]; then
      tail -n 400 "$CHGLOG" > "$CHGLOG.tmp" && mv -f "$CHGLOG.tmp" "$CHGLOG"
    fi
  fi
  return 0
}

apply_all() {
  rotate_log
  load_config
  refresh_pkg_cache
  apply_hosts
  apply_props
  apply_disable
  prune_stale_disables
  apply_netcut
  apply_clean
  apply_charge
  stop_cloud_apps
  storm_check
  date > "$QYK/state_applied"
  log "===== 应用完成 ====="
}

guard_check() {
  load_config
  # 还原/卸载进行中不要跟 restore 抢着改 enabled 状态
  [ -f "$QYK/paused" ] && return 0
  hosts_mounted_by_us || apply_hosts
  if [ "$ENABLE_NETCUT" = "1" ]; then
    "$IPT" -t filter -S qyk_out >/dev/null 2>&1 || { refresh_pkg_cache; apply_netcut; }
  fi
  apply_charge
  [ "$ENABLE_DISABLE" = "1" ] || return 0
  # 省电: 一轮只调一次 pm, 包是否存在查本地清单, PM 无响应就本轮不动
  DIS=$(pm list packages -d 2>/dev/null)
  [ -n "$DIS" ] || return 0
  for f in state_disabled.txt state_pending_disable.txt; do
    [ -f "$QYK/$f" ] || continue
    while read -r p; do
      [ -n "$p" ] || continue
      grep -qxF "package:$p" "$QYK/state_pkglist.txt" 2>/dev/null || continue
      echo "$DIS" | grep -qxF "package:$p" && { drop_pending "$p"; continue; }
      if pm_set_state "$p" disable; then
        drop_pending "$p"
        grep -qxF "$p" "$QYK/state_disabled.txt" 2>/dev/null || echo "$p" >> "$QYK/state_disabled.txt"
        log "守护: 补做禁用 $p"
      fi
    done < "$QYK/$f"
  done
}

start_guard() {
  [ "${GUARD_INTERVAL:-0}" -gt 0 ] 2>/dev/null || return 0
  pgrep -f qyk_guard >/dev/null 2>&1 && return 0
  # setsid + qyk_guard 标记: 既不吊住调用它的会话, 也方便精确清理
  setsid sh -c "qyk_guard=1; MODDIR=$MODDIR; . $MODDIR/qyk.sh; load_config; echo \$\$ > $QYK/guard.pid; while true; do sleep $GUARD_INTERVAL; guard_check; done" >/dev/null 2>&1 </dev/null &
  sleep 1
  log "守护已启动 pid=$(cat "$QYK/guard.pid" 2>/dev/null) 间隔=${GUARD_INTERVAL}s"
}

stop_guard() {
  for pid in $(pgrep -f qyk_guard 2>/dev/null) $(cat "$QYK/guard.pid" 2>/dev/null); do
    # pid 会被回收复用, 必须先核对 cmdline: 曾因误杀 su 守护进程导致整轮 pm 调用失败
    [ -r "/proc/$pid/cmdline" ] || continue
    case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
      *qyk_guard*) kill -9 "$pid" 2>/dev/null ;;
    esac
  done
  rm -f "$QYK/guard.pid"
  return 0
}

restore_all() {
  load_config
  touch "$QYK/paused" 2>/dev/null
  stop_guard
  refresh_pkg_cache
  RESTORE_FAIL=""
  if [ -f "$QYK/state_disabled.txt" ]; then
    sort -u "$QYK/state_disabled.txt" -o "$QYK/state_pending.txt" 2>/dev/null || cp "$QYK/state_disabled.txt" "$QYK/state_pending.txt"
    while read -r p; do
      [ -n "$p" ] || continue
      if pm_set_state "$p" enable; then
        log "恢复启用 $p"
      else
        RESTORE_FAIL="$RESTORE_FAIL $p"
        log "恢复启用失败 $p (PM 无响应)"
      fi
    done < "$QYK/state_pending.txt"
    rm -f "$QYK/state_pending.txt"
    if [ -n "$RESTORE_FAIL" ]; then
      # 再复验一遍: 并发/PM 滞后可能让实际状态滞后变好
      sleep 3
      still=""
      for p in $RESTORE_FAIL; do
        case "$(pm_enabled_state "$p")" in
          0|1) log "复验: $p 其实已恢复" ;;
          *) still="$still $p" ;;
        esac
      done
      RESTORE_FAIL="$still"
    fi
    if [ -n "$RESTORE_FAIL" ]; then
      printf '%s\n' $RESTORE_FAIL > "$QYK/state_disabled.txt"
      log "警告: 未能恢复:$RESTORE_FAIL (记录已保留)"
    else
      rm -f "$QYK/state_disabled.txt"
    fi
  fi
  restore_netcut
  umount_hosts
  rm -f "$QYK/state_applied" "$QYK/state_pending_disable.txt" "$QYK/paused"
  [ -n "$RESTORE_FAIL" ] && log "===== 部分还原 =====" || log "===== 已还原 ====="
  return 0
}

status() {
  load_config
  echo "== 去云控 qyk · ClassFruit (classfruit.cn) =="
  echo "开关: hosts=$ENABLE_HOSTS 禁用=$ENABLE_DISABLE 断网=$ENABLE_NETCUT 清理=$ENABLE_CLEAN OTA=$ENABLE_OTA 属性=$ENABLE_PROPS 充电=$ENABLE_CHARGE(回写=$CHARGE_FIX 闸门=${CHARGE_SAFE_TEMP}) 激进=$ENABLE_AGGRESSIVE 守护=${GUARD_INTERVAL}s 暂停=$PAUSE"
  if hosts_mounted_by_us; then
    echo "hosts: 已挂载 ($(grep -c '^0\.0\.0\.0' "$QYK/hosts.merged" 2>/dev/null) 条拦截)"
  else
    echo "hosts: 未挂载"
  fi
  r=$("$IPT" -t filter -S qyk_out 2>/dev/null | grep -cE 'DROP|REJECT')
  echo "netcut: ${r:-0} 条拦截规则 (IPv4)"
  if pgrep -f qyk_guard >/dev/null 2>&1; then
    echo "守护: 运行中 pid=$(pgrep -f qyk_guard | tr '\n' ' ')"
  else
    echo "守护: 未运行"
  fi
  if [ -f "$QYK/state_disabled.txt" ]; then
    echo "本模块禁用: $(sort -u "$QYK/state_disabled.txt" 2>/dev/null | wc -l) 个包"
  else
    echo "本模块禁用: 0 个包 (若显示已拦截但这里为 0, 说明是重启前就禁好的)"
  fi
  echo "装机前已被禁用(不接管): $(cat "$QYK/state_predisabled.txt" 2>/dev/null | wc -l)"
  echo "因 PM 无响应待重试: $(cat "$QYK/state_pending_disable.txt" 2>/dev/null | wc -l)"
  echo "调用风暴已回退(只拦域名): $(cat "$QYK/state_storm_backoff.txt" 2>/dev/null | tr '\n' ' ')"
  echo "-- 充电限流节点 --"
  charge_sample
  [ -f "$CHGLOG" ] && tail -n 3 "$CHGLOG"
  echo "-- 候选云控属性(确认后可填入 props.conf) --"
  getprop 2>/dev/null | grep -iE 'joyose|cloud|deepthinker|cosa|\.rus|qos' | head -n 20
  echo "-- 最近日志 --"
  tail -n 15 "$LOG" 2>/dev/null
}

if [ "${0##*/}" = "qyk.sh" ]; then
  case "${1:-}" in
    apply)   apply_all; start_guard; status ;;
    restore)
      restore_all
      if [ -n "$RESTORE_FAIL" ]; then
        echo "[去云控] 部分还原: 以下未能恢复:$RESTORE_FAIL"
        echo "         记录已保留, 稍后可再跑一次 restore"
      else
        echo "[去云控] 已还原"
      fi ;;
    status)  status ;;
    *) echo "用法: sh qyk.sh {apply|restore|status}" ;;
  esac
fi