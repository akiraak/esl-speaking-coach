#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# ポートの決定: VIBEBOARD_PORT > vibeboard.config.json > 3012
PORT="${VIBEBOARD_PORT:-$(node -p "require('./vibeboard.config.json').port" 2>/dev/null || echo 3012)}"

# 既存プロセスがポートを掴んでいれば停止してから起動する
PIDS="$(lsof -ti "tcp:${PORT}" 2>/dev/null || true)"
if [ -n "$PIDS" ]; then
  echo "port ${PORT} を使用中のプロセス (${PIDS}) を停止します"
  kill $PIDS 2>/dev/null || true
  sleep 1
  PIDS="$(lsof -ti "tcp:${PORT}" 2>/dev/null || true)"
  if [ -n "$PIDS" ]; then
    kill -9 $PIDS 2>/dev/null || true
  fi
fi

exec node vibeboard/dist/cli.js --root .
