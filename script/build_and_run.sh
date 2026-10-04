#!/usr/bin/env bash
set -euo pipefail
BRIDGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_MODE="${1:-run}"
BRIDGE_APP="$BRIDGE_ROOT/build/BelovodieCalendarBridge.app"
case "$BRIDGE_MODE" in run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;; *) printf 'usage: %s [run|--debug|--logs|--telemetry|--verify]\n' "$0" >&2; exit 2 ;; esac
pkill -x BelovodieCalendarBridge >/dev/null 2>&1 || true
"$BRIDGE_ROOT/scripts/build-app.sh"
case "$BRIDGE_MODE" in
  --debug|debug) lldb -- "$BRIDGE_APP/Contents/MacOS/BelovodieCalendarBridge" ;;
  --logs|logs) /usr/bin/open -n "$BRIDGE_APP"; /usr/bin/log stream --info --style compact --predicate 'process == "BelovodieCalendarBridge"' ;;
  --telemetry|telemetry) /usr/bin/open -n "$BRIDGE_APP"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.belovodie.calendar-bridge"' ;;
  --verify|verify) /usr/bin/open -n "$BRIDGE_APP"; sleep 1; pgrep -x BelovodieCalendarBridge >/dev/null ;;
  run) /usr/bin/open -n "$BRIDGE_APP" ;;
esac
