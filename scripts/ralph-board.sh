#!/usr/bin/env bash
# Sobe o Kanban do Ralph em 127.0.0.1 (nunca 0.0.0.0).
exec python3 "$(cd "$(dirname "$0")" && pwd)/ralph-board.py" "$@"
