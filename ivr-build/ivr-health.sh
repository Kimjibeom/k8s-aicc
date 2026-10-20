#!/bin/bash
# liveness: ivr-health.sh  /  readiness·startup: ivr-health.sh --ready
# liveness 는 엔진 프로세스만 본다 (nxmonitor 가 1초 내 재기동하므로 순간 부재는 failureThreshold 로 흡수)
need="nxivrcall nxivrmedia"
for p in $need; do
  pgrep -x "$p" >/dev/null || { echo "down: $p"; exit 1; }
done
if [ "${1:-}" = "--ready" ]; then
  # SIP 포트 바인딩까지 확인 (/proc/net/udp|tcp 의 로컬 포트, 16진수)
  port=$(printf ':%04X ' "${IVR_SIP_LOCAL_PORT:-9060}")
  grep -q "$port" /proc/net/udp /proc/net/udp6 /proc/net/tcp /proc/net/tcp6 2>/dev/null \
    || { echo "SIP port ${IVR_SIP_LOCAL_PORT:-9060} not bound"; exit 1; }
fi
exit 0
