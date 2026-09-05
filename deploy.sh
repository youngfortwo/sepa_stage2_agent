#!/bin/bash
# SEPA Stage2 扫描机一键部署脚本（macOS / Linux 通用）
#
# 用法（在解压后的 sepa_stage2_agent 目录内执行）：
#   ./deploy.sh http://192.168.1.100:8001          # 交互式部署
#   ./deploy.sh http://192.168.1.100:8001 --install  # 非交互：装依赖+注册定时+试连
#
# 完成后：
#   - 每交易日 18:00 自动扫描并上报主机（launchd，仅 macOS）
#   - Linux 用户用 crontab（脚本末尾有提示命令）

set -euo pipefail

SERVER="${1:-}"
AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$AGENT_DIR"

# ── 颜色输出 ──
info()  { printf "\033[1;34m[deploy]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[ok]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }

# ── 1. 主机地址 ──
if [ -z "$SERVER" ]; then
  read -r -p "主机 stock_server 地址（如 http://192.168.1.100:8001）: " SERVER
fi
SERVER="${SERVER%/}"
if [ -z "$SERVER" ]; then
  warn "未提供主机地址，只完成本地配置。"
fi

# ── 2. Python 检查 ──
PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
  # macOS /usr/bin/python3 兜底
  if [ -x /usr/bin/python3 ]; then PY=/usr/bin/python3; else
    warn "未找到 python3，请先安装 Python 3.9+"; exit 1
  fi
fi
info "使用 Python: $($PY --version 2>&1) @ $(command -v "$PY")"

# ── 3. 依赖安装 ──
if [ "${2:-}" = "--install" ] || [ "${FORCE_INSTALL:-0}" = "1" ]; then
  info "安装依赖（requirements.txt）…"
  "$PY" -m pip install -q --upgrade pip >/dev/null 2>&1 || true
  "$PY" -m pip install -q -r requirements.txt
  ok "依赖安装完成"
else
  if ! "$PY" -c "import akshare, pandas, scipy, requests" >/dev/null 2>&1; then
    info "检测到缺少依赖，自动安装…"
    "$PY" -m pip install -q -r requirements.txt && ok "依赖安装完成" \
      || warn "依赖安装失败，请手动执行: $PY -m pip install -r requirements.txt"
  else
    ok "依赖已就绪"
  fi
fi

# ── 4. 写入配置文件（job 每次运行读取，改地址不用重装定时） ──
cat > agent_config.json <<EOF
{
  "server": "${SERVER}",
  "db": "sepa_stage2.db"
}
EOF
ok "配置已写入 agent_config.json → $SERVER"

# ── 5. 连通性测试 ──
if [ -n "$SERVER" ]; then
  if "$PY" - <<PYEOF
import requests, sys
try:
    r = requests.get("${SERVER}/stock_dashboard.html", timeout=5)
    sys.exit(0 if r.status_code == 200 else 1)
except Exception:
    sys.exit(1)
PYEOF
  then ok "主机连通: $SERVER"
  else warn "主机不可达（$SERVER）。请确认：1) 主机 stock_server 已启动  2) IP/端口正确  3) 同一局域网"; fi
fi

# ── 6. 注册定时任务 ──
if [ "$(uname)" = "Darwin" ]; then
  PLIST="$HOME/Library/LaunchAgents/com.stock.sepa-stage2.plist"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.stock.sepa-stage2</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(command -v "$PY")</string>
        <string>${AGENT_DIR}/sepa_stage2_job.py</string>
        <string>--server</string><string>${SERVER}</string>
    </array>
    <key>WorkingDirectory</key><string>${AGENT_DIR}</string>
    <key>StartCalendarInterval</key>
    <array>
        $(for d in 1 2 3 4 5; do
            echo "<dict><key>Weekday</key><integer>$d</integer><key>Hour</key><integer>18</integer><key>Minute</key><integer>0</integer></dict>"
          done | tr '\n' ' ')
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>NO_PROXY</key><string>*</string><key>no_proxy</key><string>*</string></dict>
    <key>StandardOutPath</key><string>/tmp/sepa_stage2_job.log</string>
    <key>StandardErrorPath</key><string>/tmp/sepa_stage2_job.err</string>
</dict>
</plist>
EOF
  launchctl unload "$PLIST" >/dev/null 2>&1 || true
  launchctl load "$PLIST"
  ok "定时任务已注册（周一~五 18:00）: $PLIST"
  info "日志: tail -f /tmp/sepa_stage2_job.log"
else
  warn "Linux 用户请自行添加 crontab（工作日 18:00）:"
  echo "    crontab -e"
  echo "    0 18 * * 1-5 cd ${AGENT_DIR} && ${PY} sepa_stage2_job.py --server ${SERVER} >> /tmp/sepa_stage2_job.log 2>&1"
fi

echo ""
ok "部署完成！"
info "立即试跑（扫描前 100 只验证全链路）:"
echo "    cd ${AGENT_DIR} && ./run_once.sh --total 100"
