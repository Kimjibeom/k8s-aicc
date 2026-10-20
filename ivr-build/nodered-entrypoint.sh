#!/bin/bash
# aicc-ivr-nodered 컨테이너 엔트리포인트 (userDir 조립 · settings.js 렌더링 · flows 시딩 · node-red 실행)
set -euo pipefail

U="${NODERED_USER_DIR:-/home/ivr/.node-red}"      # PVC subPath(nodered) — flows/자격증명/.config.* 영속
CODE=/opt/nodered/user                             # 이미지 불변 영역 (node_modules, IVR 시나리오 노드)
DIST=/opt/nodered/dist
NODERED_FLOWS_MODE="${NODERED_FLOWS_MODE:-seed}"   # seed: PVC 에 flows 없을 때만 / configmap: 매 기동 ConfigMap 으로 덮어씀
SITE_FLOWS=/etc/ivr/flows/flows.json               # (선택) configmap/aicc-<GROUP>-ivr-flows
log() { echo "[nodered-entrypoint] $*"; }

assemble() {
  mkdir -p "$U"
  # 코드는 이미지에서 심링크로 연결 — PVC 에는 사용자 데이터만 남는다 (이미지 교체 = 모듈 업그레이드)
  for d in node_modules jedai_module nexus; do ln -sfn "$CODE/$d" "$U/$d"; done
  cp -f "$CODE/package.json" "$DIST/robots.txt" "$U/"
  node /usr/local/bin/nodered-flows.js settings "$DIST/install.settings.js" "$U/settings.js"
  if [ "$NODERED_FLOWS_MODE" = "configmap" ] && [ -f "$SITE_FLOWS" ]; then
    cp -f "$SITE_FLOWS" "$U/flows.json"; log "flows.json ← ConfigMap (NODERED_FLOWS_MODE=configmap, 편집기 배포분은 재기동 시 사라짐)"
  elif [ ! -s "$U/flows.json" ]; then
    local src="$DIST/flows_template.json"; [ -f "$SITE_FLOWS" ] && src="$SITE_FLOWS"
    node /usr/local/bin/nodered-flows.js seed "$src" "$U"
    log "flows.json 시딩 ← $src"
  else
    log "flows.json 유지 (PVC, $(stat -c '%y' "$U/flows.json" | cut -d. -f1))"
  fi
  [ -n "${NODERED_CREDENTIAL_SECRET:-}" ] || log "[WARN] NODERED_CREDENTIAL_SECRET 미지정 — 자동 생성키(.config.runtime.json, PVC)로 자격증명 암호화"
}

case "${1:-run}" in
  run)
    assemble
    log "node-red $(node -p "require('/usr/lib/node_modules/node-red/package.json').version") (node $(node -v)) → :${NODERED_PORT:-1890}"
    export PORT="${NODERED_PORT:-1890}"
    # exec: node 가 PID 1 → SIGTERM 을 직접 받아 flows 를 정상 종료 (systemd 의 KillSignal=SIGINT 대응)
    exec node /usr/lib/node_modules/node-red/red.js --userDir "$U" ${NODE_RED_OPTIONS:-} ;;
  render) U=$(mktemp -d); assemble; ls -la "$U"; grep -nE 'uiPort|flowFile|credentialSecret|title' "$U/settings.js" ;;
  shell)  exec /bin/bash ;;
  *)      exec "$@" ;;
esac
