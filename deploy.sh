#!/bin/bash
# SEPA Stage2 扫描机一键部署脚本（macOS / Linux 通用）
#
# 【一键部署】一条命令完成所有事（装依赖 → 测连通 → 注册定时任务 → 设置定时唤醒）：
#   ./deploy.sh http://192.168.1.100:8001
#
# 【自定义执行时间】默认每交易日 18:00，可用 --time 修改：
#   ./deploy.sh http://192.168.1.100:8001 --time 17:30
#
# 【卸载】移除定时任务与定时唤醒：
#   ./deploy.sh --uninstall
#
# 到点后 launchd 自动拉起 sepa_stage2_job.py（无需人工干预、无需登录 GUI），
# 扫描完成自动上报主机。节假日由脚本内交易日历二次校验，自动跳过。

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$AGENT_DIR"

# ── 颜色输出 ──
info()  { printf "\033[1;34m[deploy]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[ok]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }

# ── 参数解析 ──
SERVER="http://192.168.31.70:8001"; RUN_TIME="18:00"; UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --server)    SERVER="$2"; shift 2 ;;
    --time)      RUN_TIME="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,2\}//' | head -16; exit 0 ;;
    *)
      # 位置参数 = 主机地址
      if [[ "$1" == http* ]]; then SERVER="${1%/}"; shift; else
        warn "未知参数: $1"; exit 1
      fi ;;
  esac
done

HOUR="${RUN_TIME%%:*}"; MINUTE="${RUN_TIME##*:}"
if ! [[ "$RUN_TIME" =~ ^[0-9]{1,2}:[0-9]{1,2}$ ]]; then
  warn "时间格式错误: $RUN_TIME（应为 HH:MM，如 17:30）"; exit 1
fi
# 先转十进制再格式化（bash 3.2 的 printf/test 不认 "09" 这类前导零字符串）
HOUR_N=$((10#$HOUR)); MINUTE_N=$((10#$MINUTE))
if [ "$HOUR_N" -gt 23 ] || [ "$MINUTE_N" -gt 59 ]; then
  warn "时间超出范围: $RUN_TIME"; exit 1
fi
HOUR=$(printf '%02d' "$HOUR_N"); MINUTE=$(printf '%02d' "$MINUTE_N")

# ── 卸载模式 ──
if [ "$UNINSTALL" -eq 1 ]; then
  info "卸载 SEPA Stage2 定时任务…"
  if [ "$(uname)" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/com.stock.sepa-stage2.plist"
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    # 撤销定时唤醒（仅当设置了 pmset 且有 sudo 权限时）
    if sudo -n pmset -g repeat >/dev/null 2>&1; then
      sudo -n pmset repeat cancel >/dev/null 2>&1 || true
      ok "已撤销定时唤醒"
    else
      info "如需撤销定时唤醒，手动执行: sudo pmset repeat cancel"
    fi
    ok "已移除 launchd 定时任务"
  else
    warn "Linux 用户请手动 crontab -e 删除对应行"
  fi
  ok "卸载完成（本地数据 sepa_stage2.db 保留）"
  exit 0
fi

if [ -z "$SERVER" ]; then
  warn "缺少主机地址（默认 http://192.168.31.70:8001）"; exit 1
fi

# ── Python 检查 ──
PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
  if [ -x /usr/bin/python3 ]; then PY=/usr/bin/python3; else
    warn "未找到 python3，请先安装 Python 3.9+"; exit 1
  fi
fi
info "使用 Python: $($PY --version 2>&1) @ $(command -v "$PY")"

# ── 依赖安装（缺失才装，幂等） ──
if ! "$PY" -c "import akshare, pandas, scipy, requests" >/dev/null 2>&1; then
  info "安装依赖…"
  "$PY" -m pip install -q -r requirements.txt \
    && ok "依赖安装完成" \
    || { warn "依赖安装失败，请手动: $PY -m pip install -r requirements.txt"; exit 1; }
else
  ok "依赖已就绪"
fi

# ── 写入配置（改主机地址无需重装定时任务） ──
cat > agent_config.json <<EOF
{
  "server": "${SERVER}",
  "db": "sepa_stage2.db"
}
EOF
ok "配置写入 agent_config.json → $SERVER"

# ── 连通性测试 ──
if "$PY" - <<PYEOF
import requests, sys
try:
    sys.exit(0 if requests.get("${SERVER}/stock_dashboard.html", timeout=5).status_code == 200 else 1)
except Exception:
    sys.exit(1)
PYEOF
then ok "主机连通: $SERVER"
else warn "主机不可达（$SERVER）。请确认主机 stock_server 已启动、IP 正确、同一局域网"
fi

# ── 注册定时任务 ──
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
    <key>RunAtLoad</key><true/>
    <key>StartCalendarInterval</key>
    <array>
        $(for d in 1 2 3 4 5; do
            echo "<dict><key>Weekday</key><integer>$d</integer><key>Hour</key><integer>${HOUR_N}</integer><key>Minute</key><integer>${MINUTE_N}</integer></dict>"
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
  ok "定时任务已注册（launchd）："
  ok "  · 每周一~周五 ${HOUR}:${MINUTE} 自动执行"
  ok "  · 开机/部署完成后立即执行（当天已执行过则自动跳过）"

  # ── 定时唤醒：防止睡眠/关机错过触发 ──
  # 唤醒时间 = 执行时间提前 5 分钟
  WAKE_M=$((10#$MINUTE - 5)); WAKE_H=$((10#$HOUR))
  if [ "$WAKE_M" -lt 0 ]; then WAKE_M=$((WAKE_M + 60)); WAKE_H=$((WAKE_H - 1)); fi
  if [ "$WAKE_H" -lt 0 ]; then WAKE_H=23; fi
  WAKE_STR="$(printf '%02d:%02d' "$WAKE_H" "$WAKE_M")"
  if sudo -n pmset repeat wakeorpoweron MTWRF "$WAKE_STR" >/dev/null 2>&1; then
    ok "定时唤醒已设置：周一~周五 ${WAKE_STR}（防睡眠错过）"
  else
    info "设置定时唤醒需要管理员密码（防止 Mac 睡眠错过 ${HOUR}:${MINUTE}），请手动执行："
    echo "    sudo pmset repeat wakeorpoweron MTWRF ${WAKE_STR}"
  fi
  info "日志: tail -f /tmp/sepa_stage2_job.log"
else
  warn "Linux 用户请自行添加 crontab（18:00 定时 + 开机执行，脚本内自动去重）："
  echo "    (crontab -l 2>/dev/null; echo '${MINUTE} ${HOUR} * * 1-5 cd ${AGENT_DIR} && ${PY} sepa_stage2_job.py >> /tmp/sepa_stage2_job.log 2>&1'; echo '@reboot cd ${AGENT_DIR} && ${PY} sepa_stage2_job.py >> /tmp/sepa_stage2_job.log 2>&1') | crontab -"
fi

echo ""
ok "部署完成！部署后立即开始首次扫描，此后每交易日 ${HOUR}:${MINUTE} 自动执行。"
ok "当天已执行过会自动跳过（--force 强制重跑），重启开机也会补跑当天任务。"
info "小批量试跑验证全链路（前 100 只）:"
echo "    ./run_once.sh --total 100"
