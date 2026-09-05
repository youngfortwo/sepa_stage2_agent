# SEPA Stage2 Agent（独立扫描机部署包）

SEPA 第二阶段候选股独立定时扫描服务。部署在局域网内任意一台机器上（默认主机 `192.168.31.70:8001`），自动扫描全市场 A 股，结果存本地 SQLite 并上报主机 `stock_server`（dashboard 页面零改动）。

## 执行时机（全部由 agent\_config.json 控制，改配置即生效）

launchd 只是"哑触发器"（开机唤起 + 每 5 分钟轻量唤起一次，未到时间 <0.1s 即退出），是否执行、几点执行全部由 job 读取 `agent_config.json` 判断——**改配置文件立即生效，无需重装定时任务**：

| 字段                  | 默认值                         | 说明                           |
| ------------------- | --------------------------- | ---------------------------- |
| `server`            | `http://192.168.31.70:8001` | 主机 stock\_server 地址          |
| `run_time`          | `18:00`                     | 每日执行时间（到点后 5 分钟内开始执行）        |
| `boot_run`          | `true`                      | 开机是否立即执行（当天未执行时）             |
| `boot_force`        | `false`                     | 开机是否强制执行（忽略当天已执行标记）          |
| `check_trading_day` | `true`                      | 是否跳过非交易日（`false` = 周末节假日也执行） |
| `enabled`           | `true`                      | 总开关（`false` = 任何触发都直接退出）     |

行为矩阵：

| 场景                             | 行为             |
| ------------------------------ | -------------- |
| 到 `run_time` 且当天未执行            | 执行（5 分钟内开始）    |
| 开机且 `boot_run=true` 且当天未执行     | 立即执行           |
| 开机且 `boot_force=true`          | 强制执行（即使当天已执行过） |
| 当天已成功执行过                       | 跳过（写入标记，防重复）   |
| 非交易日且 `check_trading_day=true` | 跳过（新浪交易日历校验）   |
| `enabled=false`                | 任何触发都直接退出      |

重新部署（`./deploy.sh`）不会覆盖以上自定义字段；只有显式传 `--time` 时才更新 `run_time`。

## 架构

```
扫描机（本服务）                          主机（stock_server:8001）
launchd 哑触发（开机 + 每 5 分钟）           POST /api/sepa/stage2/upload
sepa_stage2_job.py                        ├─ 写 SQLite 历史归档
 ├─ 读 agent_config.json 判断是否执行  ──→   ├─ 原子覆写候选股 CSV
 ├─ 分批扫描（200/批，900s 超时）           └─ 覆写 rps_all.csv
 ├─ 结果写本地 SQLite（断网兜底）
 └─ HTTP 上报（失败重试 3 次）
```

## 快速部署

在扫描机上 clone 后，**一条命令都不用带参数**（默认主机 `http://192.168.31.70:8001`，装依赖 + 测连通 + 注册定时任务 + 设置定时唤醒，全自动化）：

```bash
./deploy.sh
```

主机地址变了才需要显式传参：

```bash
./deploy.sh http://新主机IP:8001          # 换主机地址
./deploy.sh --time 17:30                  # 换执行时间（默认 18:00）
```

卸载（移除定时任务与定时唤醒，本地数据保留）：

```bash
./deploy.sh --uninstall
```

部署完成即启动首次正式扫描（后台），macOS 额外设置 pmset 定时唤醒（run\_time 提前 5 分钟），防止 Mac 睡眠错过触发；若脚本无 sudo 权限会打印手动执行命令。

小批量试跑验证全链路：

```bash
./run_once.sh --total 100
```

## 常用命令

| 命令                                    | 用途                     |
| ------------------------------------- | ---------------------- |
| `./run_once.sh --total 100`           | 小批量试跑（手动跑不写标记，不影响定时任务） |
| `./run_once.sh`                       | 立即全量扫描（试跑，不写标记）        |
| `./run_once.sh --boot-force`          | 正式重跑（忽略当天已执行，完成后更新标记）  |
| `./run_once.sh --no-upload`           | 只写本地 SQLite，不上报        |
| `./run_once.sh --reupload 2026-09-05` | 网络恢复后补传指定日期本地数据（不重扫）   |

注：手动命令行参数优先于 agent\_config.json（`--force` 试跑绕过所有检查；`--boot-force` 正式重跑并更新标记）。改执行时间/开关等日常调整请编辑 `agent_config.json`（见顶部配置表）。

## 运行时文件

- `agent_config.json`（deploy.sh 自动生成）：所有执行时机配置，改完即生效

- `last_run_marker.txt`：当天已成功执行标记（自动管理）

- `.job.lock`：单实例锁（防并发扫描）

- 日志：`/tmp/sepa_stage2_job.log`（stdout）、`/tmp/sepa_stage2_job.err`（stderr）——轮询触发的"未到时间跳过"等判断也会记录在此

## 数据说明

- 本地 `sepa_stage2.db`（SQLite）：表 `stage2_candidates`，主键 `(scan_date, code)`，同日重跑自动覆盖，历史按日累积

- `financial_cache.json`（财务数据缓存，111MB）**不含在本仓库**（超 GitHub 文件大小限制），首次运行会自动从数据源逐步重建，仅影响首次扫描速度

- `industry_classification_cache.json` / `industry_map_cache.json`：行业映射缓存已随仓库附带

## 主机端要求

主机需运行改造后的 `stock_server.py`（含 `POST /api/sepa/stage2/upload` 接收接口），绑定 `0.0.0.0:8001`。可选设置环境变量 `SEPA_UPLOAD_TOKEN` 启用上报鉴权，扫描机侧用 `--token` 传入。
