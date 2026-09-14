#!/bin/bash
# SEPA Stage2 扫描机一键部署脚本（macOS / Linux 通用）
#
# 【一键部署】一条命令完成所有事（装依赖 → 测连通 → 注册定时任务 → 设置定时唤醒）：
#   ./deploy.sh http://192.168.1.100:8001
#
# 【执行时机全部由 agent_config.json 控制】launchd 只是"哑触发器"（开机 + 每 5 分钟
#   唤起一次 job.py），是否执行/几点执行全部由 job.py 读配置决定——改配置立即生效：
#     run_time / boot_run / boot_force / check_trading_day / enabled
#
# 【自定义执行时间】默认 18:00，可用 --time 修改（写入配置的 run_time）：
#   ./deploy.sh http://192.168.1.100:8001 --time 17:30
#
# 【卸载】移除定时任务与定时唤醒：
#   ./deploy.sh --uninstall
#
# 重新部署不会覆盖用户在 agent_config.json 里的自定义字段（--time 显式传入时才更新
# run_time）。节假日跳过由 job 内交易日历校验（可用 check_trading_day=false 关闭）。

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$AGENT_DIR"

# ── 颜色输出 ──
info()  { printf "\033[1;34m[deploy]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[ok]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }

# ── 参数解析 ──
SERVER="http://192.168.31.70:8001"; RUN_TIME="18:00"; TIME_SET=0; UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --server)    SERVER="$2"; shift 2 ;;
    --time)      RUN_TIME="$2"; TIME_SET=1; shift 2 ;;
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
  warn "时间格式错误: ${RUN_TIME}（应为 HH:MM，如 17:30）"; exit 1
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
    QPLIST="$HOME/Library/LaunchAgents/com.stock.sepa-stage2-query.plist"
    launchctl unload "$QPLIST" >/dev/null 2>&1 || true
    rm -f "$QPLIST"
    OPLIST="$HOME/Library/LaunchAgents/com.stock.oversold.plist"
    launchctl unload "$OPLIST" >/dev/null 2>&1 || true
    rm -f "$OPLIST"
    ok "已移除 launchd 定时任务与查询服务"
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

# ── 停止正在运行的旧实例 ──
# 场景：正在运行的定时扫描（全量约 30-60 分钟）或手动 run_once.sh 触发的扫描
# 还在跑时重新部署——结尾的首次扫描会因单实例锁直接退出、新代码不生效。
# 连子进程一起清（job → scanner → _scan_worker），避免孤儿进程继续写批次文件。
# 顺序：先 TERM 优雅停，2 秒后仍存活的 -9 强杀（TERM 后 flock 自动释放）。
stop_old_processes() {
  local pats=("sepa_stage2_job[.]py" "oversold_job[.]py" "sepa_stage2_scanner[.]py" "oversold_rebound_scanner[.]py" "_scan_worker[.]py" "sepa_query_server[.]py")
  local stopped=0 p
  for p in "${pats[@]}"; do
    if pgrep -f "$p" >/dev/null 2>&1; then
      pkill -f "$p" 2>/dev/null || true
      stopped=1
      ok "已发送停止信号: $p"
    fi
  done
  if [ "$stopped" -eq 1 ]; then
    sleep 2
    # 兜底强杀（TERM 后仍未退出的），并清理 scanner 孤儿派生的 caffeinate 断言
    # （caffeinate -w 绑定 job PID，job 退出即自动释放，无需单独处理）
    for p in "${pats[@]}"; do
      pkill -9 -f "$p" 2>/dev/null || true
    done
    ok "旧进程已清理"
  else
    info "无正在运行的旧进程"
  fi
}
stop_old_processes

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

# ── 写入配置（执行时机全部由 agent_config.json 控制，改配置即生效，无需重装定时任务；
#     重新部署时用户已自定义的字段不会被覆盖，--time 显式传入时才更新 run_time） ──
"$PY" - <<PYEOF
import json
from pathlib import Path

p = Path("agent_config.json")
cfg = {}
if p.exists():
    try:
        cfg = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        cfg = {}
cfg["server"] = "${SERVER}"
cfg["db"] = "sepa_stage2.db"
if ${TIME_SET}:
    cfg["run_time"] = "${HOUR}:${MINUTE}"           # 显式传 --time：更新执行时间
else:
    cfg.setdefault("run_time", "${HOUR}:${MINUTE}") # 已有配置不覆盖
cfg.setdefault("boot_run", True)          # 开机立即执行（当天未执行时）
cfg.setdefault("boot_force", False)       # 开机强制执行（忽略当天已执行标记）
cfg.setdefault("check_trading_day", True) # false = 周末节假日也执行
cfg.setdefault("enabled", True)           # 总开关（false = 任何触发都直接退出）
cfg.setdefault("query_port", 8010)        # 查询服务端口（主机从本机拉数据用）
p.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("[ok] agent_config.json:", json.dumps(cfg, ensure_ascii=False))
PYEOF

# ── 读回配置中的实际 run_time（日志显示/定时唤醒以用户配置为准，而非脚本默认值）──
ACTUAL_RUN_TIME=$("$PY" -c "import json; print(json.load(open('agent_config.json')).get('run_time', ''))" 2>/dev/null || echo "")
if [ -n "$ACTUAL_RUN_TIME" ] && [[ "$ACTUAL_RUN_TIME" =~ ^[0-9]{1,2}:[0-9]{1,2}$ ]]; then
  RUN_TIME="$ACTUAL_RUN_TIME"
  HOUR="${RUN_TIME%%:*}"; MINUTE="${RUN_TIME##*:}"
  HOUR=$(printf '%02d' $((10#$HOUR))); MINUTE=$(printf '%02d' $((10#$MINUTE)))
  ok "实际生效 run_time=${HOUR}:${MINUTE}（来自 agent_config.json，launchd 每次唤起时读取）"
else
  warn "agent_config.json 中 run_time 无效或缺失: '${ACTUAL_RUN_TIME}'，日志与唤醒时间使用脚本默认 ${HOUR}:${MINUTE}"
fi

# ── 连通性测试 ──
if "$PY" - <<PYEOF
import requests, sys
try:
    sys.exit(0 if requests.get("${SERVER}/stock_dashboard.html", timeout=5).status_code == 200 else 1)
except Exception:
    sys.exit(1)
PYEOF
then ok "主机连通: $SERVER"
else warn "主机不可达（${SERVER}）。请确认主机 stock_server 已启动、IP 正确、同一局域网"
fi

# ── 注册定时任务（launchd 只是"哑触发器"：开机唤起 + 每 5 分钟唤起；
#     执行时间/是否执行等全部由 agent_config.json 控制，改配置即生效） ──
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
    </array>
    <key>WorkingDirectory</key><string>${AGENT_DIR}</string>
    <key>RunAtLoad</key><true/>
    <key>StartCalendarInterval</key>
    <array>
        $(for m in 0 5 10 15 20 25 30 35 40 45 50 55; do
            echo "<dict><key>Minute</key><integer>$m</integer></dict>"
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
  ok "定时任务已注册（launchd 哑触发器：开机 + 每 5 分钟唤起）"
  ok "  · 执行时间等全部由 agent_config.json 控制（当前 run_time=${HOUR}:${MINUTE}），改配置即生效"

  # ── 超跌反弹定时任务（与 SEPA Stage2 共用 run_time，各自独立 job/表/上报接口）──
  OPLIST="$HOME/Library/LaunchAgents/com.stock.oversold.plist"
  cat > "$OPLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.stock.oversold</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(command -v "$PY")</string>
        <string>${AGENT_DIR}/oversold_job.py</string>
    </array>
    <key>WorkingDirectory</key><string>${AGENT_DIR}</string>
    <key>RunAtLoad</key><true/>
    <key>StartCalendarInterval</key>
    <array>
        $(for m in 0 5 10 15 20 25 30 35 40 45 50 55; do
            echo "<dict><key>Minute</key><integer>$m</integer></dict>"
          done | tr '\n' ' ')
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>NO_PROXY</key><string>*</string><key>no_proxy</key><string>*</string></dict>
    <key>StandardOutPath</key><string>/tmp/oversold_job.log</string>
    <key>StandardErrorPath</key><string>/tmp/oversold_job.err</string>
</dict>
</plist>
EOF
  launchctl unload "$OPLIST" >/dev/null 2>&1 || true
  launchctl load "$OPLIST"
  ok "超跌反弹定时任务已注册（com.stock.oversold，共用 run_time=${HOUR}:${MINUTE}）"

  # ── 定时唤醒：防止睡眠/关机错过触发 ──
  # 唤醒时间 = 执行时间提前 5 分钟；每天唤醒（周几执行由 check_trading_day 配置决定）
  WAKE_M=$((10#$MINUTE - 5)); WAKE_H=$((10#$HOUR))
  if [ "$WAKE_M" -lt 0 ]; then WAKE_M=$((WAKE_M + 60)); WAKE_H=$((WAKE_H - 1)); fi
  if [ "$WAKE_H" -lt 0 ]; then WAKE_H=23; fi
  WAKE_STR="$(printf '%02d:%02d' "$WAKE_H" "$WAKE_M")"
  if sudo -n pmset repeat wakeorpoweron MTWRFSU "$WAKE_STR" >/dev/null 2>&1; then
    ok "定时唤醒已设置：每天 ${WAKE_STR}（防睡眠错过）"
  else
    info "设置定时唤醒需要管理员密码（防止 Mac 睡眠错过 ${HOUR}:${MINUTE}），请手动执行："
    echo "    sudo pmset repeat wakeorpoweron MTWRFSU ${WAKE_STR}"
  fi
  info "日志: tail -f /tmp/sepa_stage2_job.log"

  # ── 查询服务（常驻）：主机可随时从本机拉取 SQLite 数据 ──
  QPLIST="$HOME/Library/LaunchAgents/com.stock.sepa-stage2-query.plist"
  cat > "$QPLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.stock.sepa-stage2-query</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(command -v "$PY")</string>
        <string>${AGENT_DIR}/sepa_query_server.py</string>
    </array>
    <key>WorkingDirectory</key><string>${AGENT_DIR}</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>EnvironmentVariables</key>
    <dict><key>NO_PROXY</key><string>*</string><key>no_proxy</key><string>*</string></dict>
    <key>StandardOutPath</key><string>/tmp/sepa_query_server.log</string>
    <key>StandardErrorPath</key><string>/tmp/sepa_query_server.err</string>
</dict>
</plist>
EOF
  launchctl unload "$QPLIST" >/dev/null 2>&1 || true
  launchctl load "$QPLIST"
  sleep 1
  QUERY_PORT="$("$PY" -c "import json; print(json.load(open('agent_config.json')).get('query_port', 8010))" 2>/dev/null || echo 8010)"
  if curl -fs -m 3 "http://127.0.0.1:${QUERY_PORT}/ping" >/dev/null 2>&1; then
    ok "查询服务已常驻: http://$(ipconfig getifaddr en0 2>/dev/null || echo 本机IP):${QUERY_PORT}（主机可拉取本机数据）"
  else
    warn "查询服务已注册但未响应（端口 ${QUERY_PORT}），查看: tail -f /tmp/sepa_query_server.err"
  fi
else
  warn "Linux 用户请自行添加 crontab（每 5 分钟唤起，执行时机由 agent_config.json 控制）："
  echo "    (crontab -l 2>/dev/null | grep -v sepa_stage2_job; echo '*/5 * * * * cd ${AGENT_DIR} && ${PY} sepa_stage2_job.py >> /tmp/sepa_stage2_job.log 2>&1') | crontab -"
  # 查询服务：nohup 常驻（如需开机自启建议注册 systemd user service）
  pgrep -f sepa_query_server.py >/dev/null 2>&1 || nohup "$PY" sepa_query_server.py >> /tmp/sepa_query_server.log 2>&1 &
  ok "查询服务已启动: http://本机IP:8010"
fi

# ── 部署完成：不自动扫描，执行时机完全由 agent_config.json 控制 ──
# （此前每次 deploy 都会 --boot-force 立即全量扫描一遍：反复部署时上一次扫描
#   被中途杀掉、当天标记未写，18:00 后每个 5 分钟轮询都会重新拉起全量扫描。
#   launchd 每 5 分钟唤起 job 自行判断，到 run_time 自然执行，部署无需触发）
echo ""
ok "部署完成！执行时机全部由 agent_config.json 控制（改配置即生效，无需重装）。"
ok "当前配置：run_time=${HOUR}:${MINUTE}，launchd 每 5 分钟唤起检查，到点自动执行。"
info "需要立即手动验证时（不影响定时规则）:"
echo "    ./run_once.sh --total 100     # 小批量试跑（不写当天标记）"
echo "    ./run_once.sh --boot-force    # 全量正式重跑（完成后写当天标记）"
