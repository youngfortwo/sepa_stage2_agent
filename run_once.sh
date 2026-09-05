#!/bin/bash
# 手动运行一次扫描（透传所有参数给 sepa_stage2_job.py）
# 常用：
#   ./run_once.sh --total 100        # 小批量试跑
#   ./run_once.sh --force             # 非交易日强制全量
#   ./run_once.sh --reupload 2026-09-05  # 补传指定日期本地数据
set -euo pipefail
cd "$(dirname "$0")"

PY="${PYTHON:-python3}"

# 从 agent_config.json 读主机地址（deploy.sh 写入），命令行 --server 优先
SERVER="$("$PY" -c "
import json, sys
try:
    print(json.load(open('agent_config.json')).get('server', ''))
except Exception:
    print('')" 2>/dev/null || true)"

ARGS=("$@")
if [ -n "$SERVER" ] && ! printf '%s\n' "${ARGS[@]:-}" 2>/dev/null | grep -q '^--server$'; then
  ARGS=(--server "$SERVER" "${ARGS[@]}")
fi
# 手动运行总是执行（跳过"当天已执行/非交易日"检查；--reupload 模式不受影响）
if ! printf '%s\n' "${ARGS[@]:-}" 2>/dev/null | grep -q '^--force$'; then
  ARGS=(--force "${ARGS[@]}")
fi

exec "$PY" sepa_stage2_job.py "${ARGS[@]}"
