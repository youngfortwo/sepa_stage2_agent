#!/usr/bin/env python3
"""SEPA Stage2 独立定时扫描任务（部署在局域网另一台扫描机上）。

触发模型（launchd 只是"哑触发器"：开机 + 每 5 分钟唤起一次本脚本）：
所有执行时机均由 agent_config.json 控制，改配置立即生效、无需重装定时任务：
    run_time           每日执行时间（到点后的第一个轮询触发开始执行）
    boot_run           开机是否立即执行（当天未执行时）
    boot_force         开机是否强制执行（忽略当天已执行标记）
    check_trading_day  是否跳过非交易日（false = 周末节假日也执行）
    enabled            总开关（false = 任何触发都直接退出）

完整流程：
1. 交易日判断（check_trading_day=true 时；周一~周五 + 新浪交易日历，缓存 90 天）
2. 分批调用 sepa_stage2_scanner.py（默认 200 只/批，单批 900s 超时，与 _scan_worker 约定一致）
3. 合并去重结果写入本地 SQLite（sepa_stage2.db）—— 断网兜底 + 历史归档
4. HTTP POST 上报主机 stock_server（/api/sepa/stage2/upload），失败重试 3 次
   主机收到后写入自己的 SQLite 并原子覆写 sepa_stage2_candidates_test.csv，
   dashboard 页面 / 下载 Excel 链路零改动。

参数速查：
    --force            手动试跑（忽略所有检查，不写"已执行"标记，不影响定时任务）
    --boot-force       手动正式重跑（忽略检查，完成后更新标记）
    --total/--batch    扫描总数 / 每批数量（默认 5000 / 200）
    --no-upload        只落本地 SQLite，不上报（调试用）
    --reupload DATE    跳过扫描，从本地 SQLite 补传指定日期数据（网络恢复后用）
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import time
import traceback
from pathlib import Path

# pandas / sepa_db 延迟导入（_ensure_heavy_modules）：launchd 每 5 分钟轮询唤起时，
# 未到时间 / 已执行 / 已停用等场景只做轻量判断即退出，不加载重量级依赖
pd = None
save_candidates = None
load_candidates = None


def _ensure_heavy_modules() -> None:
    """首次真正需要扫描时才加载 pandas / sepa_db（轻量轮询的开销 < 0.1s）。"""
    global pd, save_candidates, load_candidates
    if pd is not None:
        return
    import pandas
    pd = pandas
    import sepa_db
    save_candidates = sepa_db.save_candidates
    load_candidates = sepa_db.load_candidates


def _prevent_sleep_during_scan() -> None:
    """扫描期间阻止 macOS 闲置睡眠：pmset 定时唤醒后无人操作，系统可能在
    扫描中途（30-60 分钟）再次睡回去导致任务挂起、上报中断。
    caffeinate -w 绑定本进程 PID，进程退出时 assertion 自动释放。"""
    if sys.platform != "darwin":
        return
    try:
        subprocess.Popen(
            ["caffeinate", "-i", "-m", "-w", str(os.getpid())],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


BATCH_TIMEOUT = 900          # 单批超时（秒），与 _scan_worker.py 约定一致
UPLOAD_RETRIES = 3           # 上报失败重试次数
UPLOAD_RETRY_WAIT = 10       # 重试间隔（秒）
CALENDAR_CACHE = Path(__file__).parent / "trade_calendar_cache.json"
CALENDAR_TTL_DAYS = 90        # 交易日历缓存有效期
MARKER_FILE = Path(__file__).parent / "last_run_marker.txt"   # 当天已执行标记
LOCK_FILE = Path(__file__).parent / ".job.lock"               # 单实例锁（防并发扫描）
BOOT_WINDOW_SECONDS = 600     # 开机后 10 分钟内的触发视为 RunAtLoad 开机触发


def _ran_today() -> bool:
    """当天是否已成功执行过（标记文件记录最近一次成功完成的日期）。"""
    try:
        return MARKER_FILE.read_text(encoding="utf-8").strip() == str(dt.date.today())
    except Exception:
        return False


def _mark_ran_today() -> None:
    """扫描完成并落库后写标记：启动/18点后续触发自动跳过。"""
    try:
        MARKER_FILE.write_text(str(dt.date.today()), encoding="utf-8")
    except Exception:
        pass


def _uptime_seconds() -> float:
    """系统已运行秒数（识别开机触发；获取失败返回 inf = 按轮询触发处理）。"""
    try:
        if sys.platform == "darwin":
            import re
            out = subprocess.check_output(["sysctl", "-n", "kern.boottime"], text=True, timeout=5)
            m = re.search(r"sec\s*=\s*(\d+)", out)
            if m:
                return time.time() - int(m.group(1))
        with open("/proc/uptime", encoding="ascii") as f:
            return float(f.read().split()[0])
    except Exception:
        pass
    return float("inf")


def _run_time_today(cfg: dict):
    """配置的今日执行时刻（datetime）；配置无效返回 None。"""
    try:
        h, m = map(int, str(cfg.get("run_time", "18:00")).split(":"))
        if not (0 <= h <= 23 and 0 <= m <= 59):
            return None
        return dt.datetime.now().replace(hour=h, minute=m, second=0, microsecond=0)
    except ValueError:
        return None


def is_trading_day(day: dt.date) -> bool:
    """周一~周五 + 新浪交易日历（best-effort，日历失败时仅按周末判断）。"""
    if day.weekday() >= 5:
        return False
    key = day.strftime("%Y-%m-%d")
    try:
        cache = json.loads(CALENDAR_CACHE.read_text(encoding="utf-8"))
        cached_at = dt.date.fromisoformat(cache["fetched_at"])
        if (dt.date.today() - cached_at).days <= CALENDAR_TTL_DAYS:
            return key in cache["trade_dates"]
    except Exception:
        pass
    # 缓存缺失/过期：拉取新浪交易日历
    try:
        import akshare as ak
        cal = ak.tool_trade_date_hist_sina()
        dates = {str(d) for d in cal["trade_date"]}
        CALENDAR_CACHE.write_text(
            json.dumps({"fetched_at": str(dt.date.today()), "trade_dates": sorted(dates)}),
            encoding="utf-8",
        )
        return key in dates
    except Exception as exc:
        print(f"WARN 交易日历获取失败（按周末规则执行）: {exc}")
        return True


def run_batches(total: int, batch: int) -> pd.DataFrame:
    """分批调用 scanner，增量合并 batch_results/sepa_*.csv。"""
    batch_dir = Path("batch_results")
    batch_dir.mkdir(exist_ok=True)
    for f in batch_dir.glob("job_sepa_*.csv"):
        try:
            f.unlink()
        except FileNotFoundError:
            pass

    total_batches = (total + batch - 1) // batch
    merged = pd.DataFrame()
    for batch_no in range(total_batches):
        offset = batch_no * batch
        limit = min(batch, total - offset)
        print(f"[job] 第 {batch_no + 1}/{total_batches} 批（{offset}-{offset + limit}）扫描中…", flush=True)
        try:
            proc = subprocess.run(
                [sys.executable, "sepa_stage2_scanner.py",
                 "--offset", str(offset), "--limit", str(limit),
                 "--output", f"batch_results/job_sepa_{offset}.csv",
                 "--sleep-seconds", "0.15"],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                text=True, timeout=BATCH_TIMEOUT,
            )
            if proc.returncode != 0:
                print(f"WARN 第 {batch_no + 1} 批失败: {proc.stderr[:200]}", file=sys.stderr)
        except subprocess.TimeoutExpired:
            print(f"WARN 第 {batch_no + 1} 批超时（>{BATCH_TIMEOUT}s），跳过", file=sys.stderr)
            continue

        part = f"batch_results/job_sepa_{offset}.csv"
        try:
            frame = pd.read_csv(part, dtype={"code": str})
        except Exception:
            continue
        if frame.empty:
            continue
        frame["code"] = frame["code"].astype(str).str.zfill(6)
        merged = frame if merged.empty else pd.concat([merged, frame], ignore_index=True)

    if merged.empty:
        return merged
    merged = merged.drop_duplicates(subset=["code"], keep="first")
    sort_cols = [c for c in ("score", "amount_cny") if c in merged.columns]
    if sort_cols:
        merged = merged.sort_values(sort_cols, ascending=[False] * len(sort_cols))
    # 清理 np.True_/np.False_ 等 repr 残留（与 _scan_worker.merge_and_write 保持一致）
    for col in ["conditions", "cup_handle_details", "vcp_details", "pullback_details"]:
        if col in merged.columns:
            merged[col] = (merged[col].astype(str)
                           .str.replace(r"np\.True_", "true", regex=True)
                           .str.replace(r"np\.False_", "false", regex=True)
                           .str.replace(r"np\.float64\(([\d.]+)\)", r"\1", regex=True)
                           .str.replace(r"np\.int64\((\d+)\)", r"\1", regex=True)
                           .str.replace("'", '"', regex=False)
                           .str.replace(r"\bTrue\b", "true", regex=True)
                           .str.replace(r"\bFalse\b", "false", regex=True))
    return merged


def read_rps_csv() -> str:
    """读取 scanner 输出的 rps_all.csv（分批增量合并后的全量 RPS），随 payload 一并上报。"""
    path = Path("rps_all.csv")
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""


def upload(server: str, token: str, payload: dict, retries: int = UPLOAD_RETRIES) -> bool:
    """POST 上报主机，带重试。"""
    import requests

    url = server.rstrip("/") + "/api/sepa/stage2/upload"
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Upload-Token"] = token
    for attempt in range(1, retries + 1):
        try:
            resp = requests.post(url, json=payload, headers=headers, timeout=60)
            if resp.status_code == 200 and resp.json().get("ok"):
                print(f"[job] 上报成功: {resp.json()}")
                return True
            print(f"WARN 上报被拒（HTTP {resp.status_code}）: {resp.text[:200]}", file=sys.stderr)
        except Exception as exc:
            print(f"WARN 上报失败（第 {attempt}/{retries} 次）: {exc}", file=sys.stderr)
        if attempt < retries:
            time.sleep(UPLOAD_RETRY_WAIT)
    return False


def _json_safe(v):
    """NaN/±inf → None（json.dumps 不接受非有限浮点数）。"""
    if v is None:
        return None
    if isinstance(v, float) and (v != v or v in (float("inf"), float("-inf"))):
        return None
    return v


def build_payload(df: pd.DataFrame, scan_date: str, generated_at: str) -> dict:
    """DataFrame → 紧凑 JSON payload（列数组 + 行数组的数组）。"""
    data = df.astype(object).where(pd.notna(df), None)
    rows = [[_json_safe(v) for v in row] for row in data.values.tolist()]
    return {
        "scan_date": scan_date,
        "generated_at": generated_at,
        "count": len(rows),
        "columns": list(data.columns),
        "rows": rows,
        "rps_csv": read_rps_csv(),
    }


def _load_agent_config() -> dict:
    """读取同目录 agent_config.json（deploy.sh 生成）：改主机地址无需重装定时任务。"""
    try:
        return json.loads((Path(__file__).parent / "agent_config.json").read_text(encoding="utf-8"))
    except Exception:
        return {}


def parse_args() -> argparse.Namespace:
    cfg = _load_agent_config()
    parser = argparse.ArgumentParser(description="SEPA Stage2 standalone daily job.")
    parser.add_argument("--server", default=cfg.get("server", ""), help="主机 stock_server 地址，如 http://192.168.1.100:8001（默认读 agent_config.json）")
    parser.add_argument("--token", default=cfg.get("token", ""), help="主机设置的 SEPA_UPLOAD_TOKEN（可选）")
    parser.add_argument("--total", type=int, default=5000, help="扫描股票总数")
    parser.add_argument("--batch", type=int, default=200, help="每批数量")
    parser.add_argument("--db", default=cfg.get("db", "sepa_stage2.db"), help="本地 SQLite 路径")
    parser.add_argument("--force", action="store_true", help="非交易日强制运行")
    parser.add_argument("--boot-force", action="store_true",
                        help="忽略当天已执行标记强制重跑（每次运行时传参，正式重跑并更新标记）")
    parser.add_argument("--no-upload", action="store_true", help="只写本地 SQLite，不上报")
    parser.add_argument("--reupload", default="", metavar="YYYY-MM-DD", help="跳过扫描，补传指定日期本地数据")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    cfg = _load_agent_config()

    # 单实例锁：launchd 轮询（每 5 分钟）、开机触发、手动运行可能同时发生，
    # 防止并发扫描写坏文件
    import fcntl
    lock_fp = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("[job] 已有实例在运行，退出")
        return 0

    # 补传模式：从本地 SQLite 读指定日期数据重新上报
    if args.reupload:
        _ensure_heavy_modules()
        df = load_candidates(args.db, scan_date=args.reupload)
        if df.empty:
            print(f"[job] 本地无 {args.reupload} 的数据，退出")
            return 1
        df = df.drop(columns=["scan_date"], errors="ignore")
        payload = build_payload(df, args.reupload, time.strftime("%Y-%m-%d %H:%M:%S"))
        payload["rps_csv"] = ""  # 补传不带 RPS，避免旧数据覆盖
        ok = upload(args.server, args.token, payload)
        return 0 if ok else 1

    today = dt.date.today()

    # ── 触发判断：全部由 agent_config.json 控制（改配置即生效，无需重装定时任务） ──
    if not cfg.get("enabled", True):
        print("[job] enabled=false，任务已停用")
        return 0

    ran_today = _ran_today()
    manual = args.force or args.boot_force

    if manual:
        # 手动运行（run_once.sh 自动带 --force / --boot-force）：想跑就跑
        if ran_today:
            kind = "--boot-force 正式重跑" if args.boot_force else "--force 试跑"
            print(f"[job] {today} 已执行过，{kind}：忽略标记")
    elif _uptime_seconds() < BOOT_WINDOW_SECONDS:
        # 开机触发（launchd RunAtLoad / Linux @reboot 后的首次轮询）
        if not cfg.get("boot_run", True):
            print("[job] 开机触发，boot_run=false，跳过")
            return 0
        if ran_today and not cfg.get("boot_force", False):
            print(f"[job] {today} 已执行过，开机触发跳过（boot_force=true 可强制）")
            return 0
        print("[job] 开机触发，开始执行" + ("（boot_force 强制）" if ran_today else ""))
    else:
        # 轮询触发（每 5 分钟）：到 run_time 且当天未执行才执行
        if ran_today:
            print(f"[job] {today} 已执行过，跳过")
            return 0
        scheduled = _run_time_today(cfg)
        if scheduled is None:
            print(f"WARN run_time 配置无效: {cfg.get('run_time')}（应为 HH:MM），跳过", file=sys.stderr)
            return 1
        if dt.datetime.now() < scheduled:
            print(f"[job] 未到执行时间 {cfg.get('run_time')}，跳过")
            return 0
        print(f"[job] 已到执行时间 {cfg.get('run_time')}，开始执行")

    # 交易日检查（--force 手动试跑绕过；配置 check_trading_day=false 关闭）
    if not args.force and cfg.get("check_trading_day", True) and not is_trading_day(today):
        print(f"[job] {today} 非交易日，跳过（check_trading_day=false 关闭检查 / --force 强制）")
        return 0

    _ensure_heavy_modules()
    _prevent_sleep_during_scan()  # 扫描全程阻止系统闲置睡眠（仅 macOS）
    scan_date = today.isoformat()
    generated_at = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[job] 开始 SEPA Stage2 扫描：{scan_date}，共 {args.total} 只，{args.batch} 只/批", flush=True)

    df = run_batches(args.total, args.batch)
    print(f"[job] 扫描完成：{len(df)} 只候选股", flush=True)

    # 空结果也照常落库/上报（表示"今日无候选"），但保留上次 CSV 的行为由主机端决定
    if df.empty:
        print("[job] 今日无候选股")

    # 1) 本地 SQLite 兜底存储
    try:
        saved = save_candidates(df, args.db, scan_date)
        print(f"[job] 本地 SQLite 写入 {saved} 行 → {args.db}")
        # 定时/开机触发成功后标记当天已完成；--force 手动试跑不写标记（不影响定时），
        # --boot-force 手动正式重跑（及配置 boot_force 强制执行）完成后更新标记
        if not args.force or args.boot_force:
            _mark_ran_today()
    except Exception:
        traceback.print_exc()

    # 2) 上报主机
    if args.no_upload or not args.server:
        print("[job] 未指定 --server 或 --no-upload，跳过上报")
        return 0
    df_out = df.copy()
    df_out["scanned_at"] = generated_at
    payload = build_payload(df_out, scan_date, generated_at)
    ok = upload(args.server, args.token, payload)
    if not ok:
        print(f"[job] 上报失败：数据已存本地 SQLite，网络恢复后补传: ./run_once.sh --reupload {scan_date}", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
