# SEPA Stage2 Agent（独立扫描机部署包）

SEPA 第二阶段候选股独立定时扫描服务。部署在局域网内任意一台机器上（默认主机 `192.168.31.70:8001`），每交易日自动扫描全市场 A 股，结果存本地 SQLite 并上报主机 `stock_server`（dashboard 页面零改动）。

## 执行时机

| 触发点                    | 行为                |
| ---------------------- | ----------------- |
| 开机 / 部署完成              | 立即执行当天扫描          |
| 每交易日 18:00             | 定时执行              |
| 当天已成功执行过               | 自动跳过（不重复扫描）       |
| 非交易日                   | 自动跳过（新浪交易日历校验）    |
| 开机 + `boot_force=true` | 强制重新扫描（忽略当天已执行标记） |

即：**每天保证成功执行一次**——开机先跑，跑过 18 点不再跑；18 点前没跑过则 18 点跑。重启开机自动补跑当天任务。手动 `run_once.sh` 不写"已执行"标记，不会顶掉 18:00 定时任务。

**开机强制模式**（每次开机都重新扫描，适合担心标记过旧/数据不全的场景）：

```bash
./deploy.sh --boot-force    # 部署时开启
```

或直接编辑 `agent_config.json` 把 `boot_force` 改为 `true`（无需重装定时任务）。注意：18:00 定时触发始终去重，只有开机启动才受此开关控制。

## 架构

```
扫描机（本服务）                          主机（stock_server:8001）
launchd/cron 每交易日 18:00               POST /api/sepa/stage2/upload
sepa_stage2_job.py                        ├─ 写 SQLite 历史归档
 ├─ 分批扫描（200/批，900s 超时）    ──→   ├─ 原子覆写候选股 CSV
 ├─ 结果写本地 SQLite（断网兜底）          └─ 覆写 rps_all.csv
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

部署完成即开始首次扫描（开机/部署后自动执行），macOS 额外设置 pmset 定时唤醒（提前 5 分钟），防止 Mac 睡眠错过触发；若脚本无 sudo 权限会打印手动执行命令。

小批量试跑验证全链路：

```bash
./run_once.sh --total 100
```

## 常用命令

| 命令                                    | 用途                     |
| ------------------------------------- | ---------------------- |
| `./run_once.sh --total 100`           | 小批量试跑（手动跑不写标记，不影响定时任务） |
| `./run_once.sh`                       | 立即全量扫描（自动跳过非交易日/已执行检查） |
| `./run_once.sh --no-upload`           | 只写本地 SQLite，不上报        |
| `./run_once.sh --reupload 2026-09-05` | 网络恢复后补传指定日期本地数据（不重扫）   |

## 配置

- `agent_config.json`（deploy.sh 自动生成）：主机地址等，改主机 IP 只需编辑此文件，无需重装定时任务

- `last_run_marker.txt`：当天已成功执行标记（自动管理），删除它 + `--force` 可强制重跑当天任务

- 日志：`/tmp/sepa_stage2_job.log`（stdout）、`/tmp/sepa_stage2_job.err`（stderr）

## 数据说明

- 本地 `sepa_stage2.db`（SQLite）：表 `stage2_candidates`，主键 `(scan_date, code)`，同日重跑自动覆盖，历史按日累积

- `financial_cache.json`（财务数据缓存，111MB）**不含在本仓库**（超 GitHub 文件大小限制），首次运行会自动从数据源逐步重建，仅影响首次扫描速度

- `industry_classification_cache.json` / `industry_map_cache.json`：行业映射缓存已随仓库附带

## 主机端要求

主机需运行改造后的 `stock_server.py`（含 `POST /api/sepa/stage2/upload` 接收接口），绑定 `0.0.0.0:8001`。可选设置环境变量 `SEPA_UPLOAD_TOKEN` 启用上报鉴权，扫描机侧用 `--token` 传入。
