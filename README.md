# 去云控 · CloudControl Free

一个全功能的去云控 Magisk 模块：把厂商云控（远程配置下发、遥测上报、OTA 强推、充电限流云控）从系统里切掉，同时不制造耗电。

作者：ClassFruit · [classfruit.cn](https://classfruit.cn) · 模块 id：`qyk`

在 ColorOS Watch（OPPO Watch S / OWW221，Android 11，Magisk 27.2 Kitsune）上实测；ColorOS / OPPO / 一加 / realme / MIUI / 华为 / vivo 的包名与域名都在名单里，本机不存在的包会自动跳过。

## 功能

| 功能 | 默认 | 说明 |
|---|---|---|
| hosts 域名拦截 | 开 | 103 条云控/遥测/统计域名（`conf.*.heytapmobi.com`、`i.rus.coloros.com`、joyose、MIUI 云控、华为 GRS 等），bind 挂载，不写系统分区 |
| 云控组件断网 | 开 | iptables 按 UID REJECT，组件保留但拉不到云控规则；共享系统 UID（1000/1001）自动跳过，改由 hosts 拦截 |
| 遥测组件禁用 | 开 | 只禁无人调用的纯上报类；被其它 app 频繁调用的包**不禁用**（见"省电设计"） |
| 云控缓存清理 | 开 | 开机 `pm clear` 云控/统计组件缓存，清掉已下发的云控规则 |
| OTA 拦截 | 开 | `iota.coloros.com` + OTA CDN + `com.heytap.wearable.ota` 等；电脑端 OTA 工具不受影响 |
| 充电云控处理 | 开 | 切断 RUS（romupdate）下发通道 + 采样充电限流节点到 `charge.log`；可选限流回写（默认关，带 42℃ 闸门）。注意：**充满前降速通常是 4.46V 恒压段的物理特性，不是云控**（见下） |
| 属性伪装 | 开 | `props.conf` 默认空，状态页会列出候选属性 |
| 激进模式 | 关 | 推送/商店/云同步一起断，会影响通知与表盘下载 |
| 守护重应用 | 开 | 1800s 一轮，检查挂载/规则/禁用状态并补上；调用风暴自动回退 |
| 暂停 | — | `PAUSE=1` 开机不拦截；`Action` 按钮 = 立即重应用（幂等） |
| 卸载还原 | — | 卸载自动恢复被禁组件、删规则、卸挂载；失败记录保留并重试 |

## 安装

1. 把 `dist/` 里的 zip 用 Magisk / KernelSU / APatch 安装；
2. 重启（或在模块页点 Action 立即应用）；
3. 开机自动生效，**不需要手动点任何按钮**。

Magisk 20.4+。WebUI 需要支持 webroot 的管理器（Magisk 28+/KernelSU/APatch），不支持时用 Action 按钮或直接改配置。

## 配置

运行时配置在 `/data/adb/qyk/`，模块更新不会覆盖：

- `config.conf` — 功能开关（`ENABLE_*`、`GUARD_INTERVAL`、`PAUSE`、`CHARGE_FIX`、`CHARGE_SAFE_TEMP`）
- `pkgs_disable.txt` — 禁用名单
- `pkgs_netcut.txt` — 断网名单
- `pkgs_clean.txt` — 清理名单
- `pkgs_ota.txt` — OTA 目标
- `pkgs_aggressive.txt` — 激进模式名单
- `hosts_core.txt` / `hosts_ota.txt` / `hosts_aggressive.txt` — 拦截域名
- `charge.conf` — 充电限流节点目标值（需 `CHARGE_FIX=1`）
- `props.conf` — resetprop 属性伪装

命令行：

```sh
su -c 'sh /data/adb/modules/qyk/qyk.sh status'    # 查看状态
su -c 'sh /data/adb/modules/qyk/qyk.sh apply'     # 立即应用
su -c 'sh /data/adb/modules/qyk/qyk.sh restore'   # 临时还原（PAUSE 用）
```

## 省电设计

- **不禁用被频繁调用的统计服务**：实测禁用 `com.nearme.statistics.rom` 后其它 app 仍不停 `startService` 它，12 分钟产生 2068 条失败调用，system_server 顶到 41% 单核、瞬时电流 130~160 mA。现在这类包保持启用，改为拦死它 APK 里的真实上报/配置域名；`storm_check` 会自动回退任何引发调用风暴的禁用。
- 守护 1800s 一轮，每轮只调 1 次 `pm`，包存在性查本地清单；实测单轮 5 秒墙钟 / 30 ms system_server CPU。
- 断网用 REJECT 而非 DROP：连接立刻失败，app 不会干等 TCP 超时。
- 不持 wakelock、无 AlarmManager、无常驻进程；hosts 为一次 bind 挂载。
- 充电采样节流：数值变化才写，否则 ≥30 分钟一条。

## 充电曲线实测（OWW221，34%→73%）

10 秒采样，全程 `input_current_limit` / `charge_control_limit` 为 0：

| 区间 | 实际电流 | 速度 |
|---|---|---|
| 34–45% | ~630 mA | 2.4%/分钟 |
| 45–54% | ~500 mA | 2.2%/分钟 |
| 54–60% | ~450 mA | 1.5%/分钟 |
| 60–65% | ~380 mA | 1.4%/分钟 |
| 65–70% | ~270 mA（电压钉在 4.46V，恒压段） | 1.0%/分钟 |
| 70–73% | ~210 mA | 0.75%/分钟 |

温度 29→31→26.8℃ 回落，排除温控降速。`chg_limit=1` 只出现在每 1–3 分钟一次的 200 mA 电压采样跌落（5–10 秒），是本地 OCV 采样，顶掉它不会让恒压段变快，还可能影响电量估算。**结论：65% 之后的降速是 4.46V 恒压充电的正常物理特性，不是云控；`CHARGE_FIX` 只在确认有策略持续压低限流节点时才建议打开。**

## 卸载

Magisk 里卸载模块即自动还原（恢复禁用组件、删除 iptables 规则、卸掉 hosts 挂载）。若个别包因系统繁忙未能恢复，卸载脚本会重试三轮，仍失败则清单写到 `/data/local/tmp/qyk_unfinished.txt`。

## 构建

```sh
python build.py     # 输出 dist/qyk_CloudControlFree_v<版本>.zip
```

## 目录

```
module.prop           模块信息
customize.sh          安装脚本（配置迁移、预禁用快照）
post-fs-data.sh       早期挂 hosts / 属性
service.sh            pm 就绪后全量应用 + 守护
action.sh             按钮：立即重应用
uninstall.sh          卸载还原
qyk.sh                核心库（也被 status/apply/restore 直接调用）
config/               默认配置与名单
webroot/              WebUI
META-INF/             Magisk 安装器
```

## 免责声明

本项目仅用于学习研究与个人设备管理。修改系统行为有风险，请自行备份并承担后果；部分功能（OTA 拦截、组件禁用）会改变设备原有行为，介意勿用。请勿用于绕过任何服务条款或商业限制。

## 协议

MIT
