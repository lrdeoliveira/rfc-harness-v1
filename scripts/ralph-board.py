#!/usr/bin/env python3
"""Ralph Kanban board — lê .phases/state e serve em 127.0.0.1."""
from __future__ import annotations

import argparse
import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
HTML = HERE / "ralph-board.html"


def fmt_dur(seconds: int | None) -> str:
    if seconds is None or seconds < 0:
        return "—"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m:02d}m"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def parse_tsv(path: Path) -> dict:
    meta: dict[str, str] = {}
    phases: dict[str, dict] = {}
    order: list[str] = []
    if not path.is_file():
        return {"meta": meta, "phases": phases, "order": order}
    text = path.read_text(encoding="utf-8", errors="replace")
    for raw in text.splitlines():
        if not raw.strip():
            continue
        parts = raw.split("\t")
        kind = parts[0]
        if kind == "META" and len(parts) >= 3:
            meta[parts[1]] = parts[2]
        elif kind == "PHASE" and len(parts) >= 6:
            num = parts[1]
            if num not in phases:
                order.append(num)
            phases[num] = {
                "num": int(num) if num.isdigit() else num,
                "status": parts[2],
                "attempt": parts[3],
                "gates": parts[4].split(),
                "title": parts[5],
                "tasks": [],
            }
        elif kind == "TASK" and len(parts) >= 5:
            num = parts[1]
            phases.setdefault(
                num,
                {"num": int(num) if num.isdigit() else num, "status": "pending",
                 "attempt": "0", "gates": [], "title": f"Phase {num}", "tasks": []},
            )
            if num not in order:
                order.append(num)
            phases[num]["tasks"].append(
                {"i": int(parts[2]) if parts[2].isdigit() else parts[2],
                 "status": parts[3], "title": parts[4]}
            )
        elif kind == "LIVE" and len(parts) >= 3:
            pass
    return {"meta": meta, "phases": phases, "order": order}


def merge_live(data: dict, live_path: Path) -> None:
    if not live_path.is_file():
        return
    cur = None
    activity = None
    live_tasks: dict[str, str] = {}
    for raw in live_path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = raw.split("\t")
        if not parts:
            continue
        if parts[0] == "PHASE" and len(parts) > 1:
            cur = parts[1]
        elif parts[0] == "ACTIVITY" and len(parts) > 1:
            activity = parts[1]
        elif parts[0] == "LIVE" and len(parts) >= 3:
            live_tasks[parts[1]] = parts[2]
    if activity:
        data["meta"]["activity"] = activity
    if cur and cur in data["phases"]:
        data["meta"]["phase_cur"] = cur
        for task in data["phases"][cur]["tasks"]:
            key = str(task["i"])
            if key in live_tasks and task["status"] != "done":
                task["status"] = live_tasks[key]


def enrich_from_phases_dir(repo: Path, data: dict) -> None:
    phases_dir = repo / ".phases"
    if not phases_dir.is_dir():
        return
    by_num: dict[str, Path] = {}
    man = phases_dir / "manifest.txt"
    if man.is_file():
        for line in man.read_text(encoding="utf-8", errors="replace").splitlines():
            # file|num|title
            bits = line.split("|")
            if len(bits) >= 2:
                by_num[bits[1].strip()] = phases_dir / bits[0].strip()
    if not by_num:
        for p in sorted(phases_dir.glob("*.md")):
            m = re.search(r"(\d+)", p.stem)
            if m:
                by_num[str(int(m.group(1)))] = p

    for num, phase in data["phases"].items():
        path = by_num.get(str(num))
        if not path or not path.is_file():
            continue
        body = path.read_text(encoding="utf-8", errors="replace")
        desc = []
        for line in body.splitlines():
            s = line.strip()
            if not s or s.startswith("#") or s.startswith("- [") or s.startswith("<!--"):
                if desc:
                    break
                continue
            if s.lower().startswith("arquivos"):
                break
            desc.append(s)
            if len(" ".join(desc)) > 220:
                break
        phase["description"] = " ".join(desc)[:280]
        files = []
        for m in re.finditer(r"`([^`]+\.[A-Za-z0-9]+)`", body):
            f = m.group(1)
            if f not in files:
                files.append(f)
            if len(files) >= 6:
                break
        phase["files"] = files


def build_state(repo: Path) -> dict:
    run = repo / ".phases" / "state" / "run.tsv"
    live = repo / ".phases" / "state" / "live.tsv"
    if not run.is_file():
        return {"ok": True, "idle": True, "phases": [], "counts": {
            "done_phases": 0, "total_phases": 0, "done_tasks": 0, "total_tasks": 0, "pct": 0
        }, "meta": {}}
    data = parse_tsv(run)
    merge_live(data, live)
    enrich_from_phases_dir(repo, data)
    now = int(time.time())
    meta = data["meta"]
    started = int(meta["started"]) if meta.get("started", "").isdigit() else now
    phases = []
    done_p = done_t = total_t = 0
    for num in data["order"]:
        p = data["phases"][num]
        total_t += len(p["tasks"])
        done_t += sum(1 for t in p["tasks"] if t["status"] == "done")
        if p["status"] == "done":
            done_p += 1
        tkey = f"tdur_{num}"
        skey = f"tstart_{num}"
        if meta.get(tkey, "").isdigit():
            dur = int(meta[tkey])
        elif p["status"] == "running" and meta.get(skey, "").isdigit():
            dur = now - int(meta[skey])
        elif p["status"] == "running":
            dur = now - started
        else:
            dur = None
        p["duration"] = fmt_dur(dur)
        p["duration_s"] = dur
        if str(meta.get("phase_cur")) == str(num):
            p["activity"] = meta.get("activity") or ""
        phases.append(p)
    total_p = len(phases) or 1
    pct = round(100 * done_t / total_t) if total_t else round(100 * done_p / total_p)
    return {
        "ok": True,
        "idle": False,
        "meta": meta,
        "phases": phases,
        "counts": {
            "done_phases": done_p,
            "total_phases": len(phases),
            "done_tasks": done_t,
            "total_tasks": total_t,
            "pct": pct,
        },
    }


def make_handler(repo: Path):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def _send(self, code: int, body: bytes, ctype: str):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urlparse(self.path).path
            if path in ("/", "/index.html"):
                self._send(200, HTML.read_bytes(), "text/html; charset=utf-8")
                return
            if path == "/state.json":
                payload = json.dumps(build_state(repo), ensure_ascii=False).encode("utf-8")
                self._send(200, payload, "application/json; charset=utf-8")
                return
            self._send(404, b"not found", "text/plain")

    return Handler


def main() -> int:
    ap = argparse.ArgumentParser(description="Ralph Kanban board (127.0.0.1)")
    ap.add_argument("repo", nargs="?", default=".")
    ap.add_argument("--port", type=int, default=int(os.environ.get("RALPH_BOARD_PORT", "3847")))
    ap.add_argument("--once", action="store_true", help="imprime state.json e sai")
    args = ap.parse_args()
    repo = Path(args.repo).resolve()
    if args.once:
        print(json.dumps(build_state(repo), ensure_ascii=False, indent=2))
        return 0
    if not HTML.is_file():
        raise SystemExit(f"faltando {HTML}")
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(repo))
    print(f"RALPH board  http://127.0.0.1:{args.port}  repo={repo}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
