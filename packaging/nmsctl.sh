#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

case "$cmd" in
  status)
    systemctl status nms-api --no-pager || true
    systemctl list-units 'nms-*.service' --no-pager || true
    ;;
  logs)
    unit="${1:-nms-api}"
    journalctl -u "$unit" -f
    ;;
  restart)
    unit="${1:-nms-api}"
    systemctl restart "$unit"
    ;;
  *)
    echo "Usage:"
    echo "  ./packaging/nmsctl.sh status"
    echo "  ./packaging/nmsctl.sh logs nms-api"
    echo "  ./packaging/nmsctl.sh logs nms-worker@poller"
    echo "  ./packaging/nmsctl.sh restart nms-api"
    exit 1
    ;;
esac
