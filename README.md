# SEPA Stage2 Agent（独立扫描机部署包）

SEPA 第二阶段候选股独立定时扫描服务。部署在局域网内任意一台机器上，每交易日 18:00 自动扫描全市场 A 股，结果存本地 SQLite 并上报主机 `stock_server`（dashboard 页面零改动）。

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

**一键部署**（装依赖 + 测连通 + 注册定时任务 + 设置定时唤醒，全自动化）：

```bash
./deploy.sh http://主机IP:8001
```

自定义执行时间（默认每交易日 18:00）：

```bash
./deploy.sh http://主机IP:8001 --time 17:30
```

卸载（移除定时任务与定时唤醒，本地数据保留）：

```bash
./deploy.sh --uninstall
```

到点后 launchd **自动启动扫描程序**（无需登录、无需人工干预），扫描完成自动上报主机。macOS 额外设置 pmset 定时唤醒（提前 5 分钟），防止 Mac 睡眠错过触发；若脚本无 sudo 权限会打印手动执行命令。

小批量试跑验证全链路：

```bash
./run_once.sh --total 100
```

## 常用命令

| 命令 | 用途 |
|------|------|
| `./run_once.sh --total 100` | 小批量试跑 |
| `./run_once.sh --force` | 非交易日强制全量扫描 |
| `./run_once.sh --no-upload` | 只写本地 SQLite，不上报 |
| `./run_once.sh --reupload 2026-09-05` | 网络恢复后补传指定日期本地数据（不重扫） |

## 配置

- `agent_config.json`（deploy.sh 自动生成）：主机地址等，改主机 IP 只需编辑此文件，无需重装定时任务
- 日志：`/tmp/sepa_stage2_job.log`（stdout）、`/tmp/sepa_stage2_job.err`（stderr）

## 数据说明

- 本地 `sepa_stage2.db`（SQLite）：表 `stage2_candidates`，主键 `(scan_date, code)`，同日重跑自动覆盖，历史按日累积
- `financial_cache.json`（财务数据缓存，111MB）**不含在本仓库**（超 GitHub 文件大小限制），首次运行会自动从数据源逐步重建，仅影响首次扫描速度
- `industry_classification_cache.json` / `industry_map_cache.json`：行业映射缓存已随仓库附带

## 主机端要求

主机需运行改造后的 `stock_server.py`（含 `POST /api/sepa/stage2/upload` 接收接口），绑定 `0.0.0.0:8001`。可选设置环境变量 `SEPA_UPLOAD_TOKEN` 启用上报鉴权，扫描机侧用 `--token` 传入。
