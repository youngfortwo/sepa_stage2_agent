#!/usr/bin/env python3
"""扫描机轻量查询服务：把本地 SQLite 的 Stage2 数据暴露给主机拉取。

dashboard 页面浏览器直连本服务（CORS 已放行），不经过主机 stock_server：
    GET /ping                      存活探测
    GET /api/sepa/dates             可用扫描日列表（升序）
    GET /api/sepa/data?date=...     指定日期候选数据（缺省=最新一天）
                                    payload 格式与上报接口一致（columns/rows）

只读服务，不写库；随 deploy.sh 注册为 launchd 常驻（KeepAlive）。
"""
from __future__ import annotations

import argparse
import json
import math
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pandas as pd

from sepa_db import available_dates, load_candidates

DB_PATH = "sepa_stage2.db"


def _json_safe(v):
    if isinstance(v, float) and not math.isfinite(v):
        return None
    return v


def build_payload(df: pd.DataFrame, scan_date: str) -> dict:
    """DataFrame → 与上报接口一致的紧凑 JSON（列数组 + 行数组的数组）。"""
    data = df.astype(object).where(pd.notna(df), None)
    rows = [[_json_safe(v) for v in row] for row in data.values.tolist()]
    return {
        "ok": True,
        "scan_date": scan_date,
        "count": len(rows),
        "columns": list(data.columns),
        "rows": rows,
    }


class QueryHandler(BaseHTTPRequestHandler):
    server_version = "SEPA-Query/1.0"

    def do_GET(self) -> None:  # noqa: N802（http.server 约定）
        parsed = urlparse(self.path)
        if parsed.path == "/ping":
            dates = available_dates(DB_PATH)
            self._json({"ok": True, "service": "sepa_stage2_query",
                        "dates": len(dates), "latest": dates[-1] if dates else ""})
            return
        if parsed.path == "/api/sepa/dates":
            dates = available_dates(DB_PATH)
            self._json({"ok": True, "dates": dates,
                        "latest": dates[-1] if dates else ""})
            return
        if parsed.path == "/api/sepa/data":
            params = parse_qs(parsed.query)
            date = (params.get("date", [""])[0] or "").strip()[:10]
            df = load_candidates(DB_PATH, scan_date=date or None)
            if df is None or df.empty:
                self._json({"ok": False,
                            "error": f"本地无数据：{date or '最新'}"}, status=404)
                return
            scan_date = date or available_dates(DB_PATH)[-1]
            df = df.drop(columns=["scan_date"], errors="ignore")
            self._json(build_payload(df, scan_date))
            return
        self._json({"ok": False, "error": "not found"}, status=404)

    def do_OPTIONS(self) -> None:  # noqa: N802（CORS 预检）
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.end_headers()

    def _json(self, obj: dict, status: int = 200) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        # CORS：dashboard 页面由主机 8001 端口提供，浏览器直连本服务属跨域，必须放行
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:  # 静默常规访问日志
        pass


def main() -> None:
    global DB_PATH
    # 读同目录 agent_config.json（deploy.sh 生成）：db 路径 / 端口可在此改
    cfg: dict = {}
    try:
        cfg = json.loads((Path(__file__).parent / "agent_config.json").read_text(encoding="utf-8"))
    except Exception:
        pass
    parser = argparse.ArgumentParser(description="SEPA Stage2 本地数据查询服务")
    parser.add_argument("--db", default=cfg.get("db", "sepa_stage2.db"), help="本地 SQLite 路径")
    parser.add_argument("--port", type=int, default=int(cfg.get("query_port", 8010)),
                        help="监听端口（默认 8010，可用 agent_config.json 的 query_port 修改）")
    parser.add_argument("--bind", default="0.0.0.0", help="监听地址（默认 0.0.0.0，供主机访问）")
    args = parser.parse_args()
    DB_PATH = str(Path(args.db).resolve())
    print(f"SEPA query service on http://{args.bind}:{args.port} (db: {DB_PATH})", flush=True)
    ThreadingHTTPServer((args.bind, args.port), QueryHandler).serve_forever()


if __name__ == "__main__":
    main()
