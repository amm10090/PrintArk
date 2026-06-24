#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/amo/project/Tabooprint"
PID_FILE="${ROOT}/.cainiao-mock.pid"
LOG_FILE="${ROOT}/.cainiao-mock.log"

cmd="${1:-start}"
shift || true

start() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "mock already running: $pid"
      exit 0
    fi
  fi

  if ports_in_use 13528 13525; then
    echo "port conflict detected on 13528 or 13525"
    exit 1
  fi

  local node_bin
  node_bin="${NODE_BIN:-}"
  if [[ -z "$node_bin" ]]; then
    node_bin="$(command -v node 2>/dev/null || true)"
  fi
  if [[ -z "$node_bin" ]]; then
    for candidate in \
      /Users/amo/.local/bin/node \
      /opt/homebrew/bin/node \
      /usr/local/bin/node
    do
      if [[ -x "$candidate" ]]; then
        node_bin="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$node_bin" ]]; then
    echo "node executable not found"
    exit 1
  fi

  nohup "$node_bin" "$ROOT/scripts/mock_cainiao_server.js" --pid-file "$PID_FILE" "$@" >"$LOG_FILE" 2>&1 < /dev/null &
  sleep 1
  local started_pid
  started_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$started_pid" ]] && kill -0 "$started_pid" 2>/dev/null; then
    echo "mock started: $started_pid"
  else
    rm -f "$PID_FILE"
    echo "mock failed to stay running; check $LOG_FILE"
    exit 1
  fi
}

ports_in_use() {
  local port
  for port in "$@"; do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

stop() {
  if [[ ! -f "$PID_FILE" ]]; then
    echo "mock not running"
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    sleep 1
  fi
  rm -f "$PID_FILE"
  echo "mock stopped"
}

status() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "running $pid"
  elif ports_in_use 13528 13525; then
    echo "running (pid file stale)"
  else
    echo "stopped"
  fi
}

case "$cmd" in
  start) start "$@" ;;
  stop) stop ;;
  status) status ;;
  restart) stop; start "$@" ;;
  *) echo "usage: $0 {start|stop|status|restart}" ; exit 1 ;;
esac
