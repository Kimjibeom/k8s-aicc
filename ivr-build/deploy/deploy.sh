#!/usr/bin/env bash
set -euo pipefail

# AICC IVR 통합 배포 스크립트 (deploy.sh)
#
# deploy.env(또는 환경변수)를 읽어 ConfigMap / StatefulSet / Service / (선택) Ingress 를 치환·배포합니다.
#
# 사용법:
#   ./deploy.sh                  # 기본 배포 (= apply)
#   ./deploy.sh render           # 렌더링 결과 확인 (kubectl 적용 안 함)
#   ./deploy.sh diff             # 클러스터 상태와 diff
#   ./deploy.sh delete           # 배포 리소스 삭제 (PVC·Secret 은 보존)
#
# 환경변수 오버라이드 예시:
#   TARGET_NODE_NAME=k8s-node-01 IVR_SIP_REMOTE_IP=10.10.x.x ./deploy.sh
#   GROUP=ded1 SITE=b ./deploy.sh

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VARS="NS GROUP SITE IVR_DB_HOST IVR_DB_PORT IVR_SIP_REMOTE_IP IVR_CTI_HOST1 TARGET_NODE_NAME ENABLE_HOST_NETWORK IVR_IMAGE NODERED_IMAGE IMAGE_PULL_SECRET NODERED_DOMAIN"
if [ -f "$HERE/deploy.env" ]; then
  echo "[deploy] $HERE/deploy.env 설정을 로드합니다."
  # 명령행 환경변수가 deploy.env 보다 우선하도록 source 전 값을 보관했다가 되돌린다
  _ovr=$(for v in $VARS; do [ -n "${!v+x}" ] && printf '%s=%q\n' "$v" "${!v}"; done; true)
  # shellcheck disable=SC1091
  source "$HERE/deploy.env"
  eval "$_ovr"
else
  echo "[deploy][INFO] deploy.env 파일이 없어 기본값을 사용합니다 (cp deploy.env.example deploy.env 권장)."
fi

NS="${NS:-aicc}"
GROUP="${GROUP:-shr}"
SITE="${SITE:-a}"
IVR_DB_HOST="${IVR_DB_HOST:-aicc-db}"
IVR_DB_PORT="${IVR_DB_PORT:-3316}"
IVR_SIP_REMOTE_IP="${IVR_SIP_REMOTE_IP:-}"
IVR_CTI_HOST1="${IVR_CTI_HOST1:-aicc-cti}"
TARGET_NODE_NAME="${TARGET_NODE_NAME:-}"
ENABLE_HOST_NETWORK="${ENABLE_HOST_NETWORK:-true}"
IVR_IMAGE="${IVR_IMAGE:-jibeom/aicc:ivr-2.0.2.108-1}"
NODERED_IMAGE="${NODERED_IMAGE:-jibeom/aicc:ivr-nodered-2.0.2.108-1}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET-regcred}"   # 빈 값 = pull secret 제거(폐쇄망)
NODERED_DOMAIN="${NODERED_DOMAIN:-}"

ACTION="${1:-apply}"
STS="aicc-${GROUP}-ivr-${SITE}"

echo "=========================================================="
echo " AICC IVR 통합 배포 ($ACTION)"
echo "----------------------------------------------------------"
echo " 네임스페이스 / 그룹 / 사이트 : $NS / $GROUP / $SITE  → statefulset/$STS"
echo " DB (IVR_DB_HOST)            : $IVR_DB_HOST:$IVR_DB_PORT"
echo " PBX (IVR_SIP_REMOTE_IP)     : ${IVR_SIP_REMOTE_IP:-[미지정 — config/ivr.env 값 사용]}"
echo " CTI (IVR_CTI_HOST1)         : $IVR_CTI_HOST1"
echo " 대상 노드 / hostNetwork     : ${TARGET_NODE_NAME:-[미고정]} / $ENABLE_HOST_NETWORK"
echo " 이미지                      : $IVR_IMAGE"
echo "                               $NODERED_IMAGE"
echo " Node-RED Ingress            : ${NODERED_DOMAIN:-[생략]}"
echo "=========================================================="

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ── 1. 30-statefulset.yaml 렌더링 ────────────────────────────────
STS_OUT="$WORK_DIR/30-statefulset.yaml"
sed -e "s/aicc-shr-ivr-a/${STS}/g" \
    -e "s/aicc-shr-ivr-config/aicc-${GROUP}-ivr-config/g" \
    -e "s/aicc-shr-ivr-confd/aicc-${GROUP}-ivr-confd/g" \
    -e "s/aicc-shr-ivr-flows/aicc-${GROUP}-ivr-flows/g" \
    -e "s/aicc\/group: shr/aicc\/group: ${GROUP}/g" \
    -e "s/aicc\/site: a/aicc\/site: ${SITE}/g" \
    -e "s|image: jibeom/aicc:ivr-nodered-.*|image: ${NODERED_IMAGE}|" \
    -e "s|image: jibeom/aicc:ivr-[0-9].*|image: ${IVR_IMAGE}|" \
    "$HERE/30-statefulset.yaml" > "$STS_OUT"

if [ -n "$TARGET_NODE_NAME" ]; then
  sed -i -E "s|^[[:blank:]]*#?[[:blank:]]*nodeSelector:.*|      nodeSelector: { kubernetes.io/hostname: ${TARGET_NODE_NAME} }|" "$STS_OUT"
fi
[ "$ENABLE_HOST_NETWORK" = "false" ] && sed -i -E "s|hostNetwork: true|hostNetwork: false|" "$STS_OUT"
if [ -z "$IMAGE_PULL_SECRET" ]; then
  sed -i -E '/imagePullSecrets:/,+1d' "$STS_OUT"
else
  sed -i -E "s/- name: regcred/- name: ${IMAGE_PULL_SECRET}/" "$STS_OUT"
fi

# ── 2. 40-service.yaml 렌더링 ────────────────────────────────────
SVC_OUT="$WORK_DIR/40-service.yaml"
sed -e "s/aicc-shr-ivr-a/${STS}/g" \
    -e "s/aicc-shr-ivr/aicc-${GROUP}-ivr/g" \
    -e "s/aicc\/group: shr/aicc\/group: ${GROUP}/g" \
    -e "s/aicc\/site: a/aicc\/site: ${SITE}/g" \
    "$HERE/40-service.yaml" > "$SVC_OUT"

# ── 3. (선택) Node-RED Ingress ────────────────────────────────────
ING_OUT="$WORK_DIR/nodered-ingress.yaml"
if [ -n "$NODERED_DOMAIN" ]; then
  sed -e "s|\${NS}|${NS}|g" -e "s|\${GROUP}|${GROUP}|g" -e "s|\${NODERED_DOMAIN}|${NODERED_DOMAIN}|g" \
      "$HERE/nodered-ingress.yaml.template" > "$ING_OUT"
fi

case "$ACTION" in
  render)
    echo "=== [00-pvc.yaml] ==="; cat "$HERE/00-pvc.yaml"
    echo; echo "=== [30-statefulset.yaml (Rendered)] ==="; cat "$STS_OUT"
    echo; echo "=== [40-service.yaml (Rendered)] ==="; cat "$SVC_OUT"
    [ -n "$NODERED_DOMAIN" ] && { echo; echo "=== [nodered-ingress.yaml (Rendered)] ==="; cat "$ING_OUT"; }
    exit 0 ;;

  diff)
    for f in "$HERE/00-pvc.yaml" "$STS_OUT" "$SVC_OUT"; do kubectl -n "$NS" diff -f "$f" || true; done
    [ -n "$NODERED_DOMAIN" ] && { kubectl -n "$NS" diff -f "$ING_OUT" || true; }
    exit 0 ;;

  delete)
    [ -n "$NODERED_DOMAIN" ] && kubectl -n "$NS" delete -f "$ING_OUT" --ignore-not-found=true
    kubectl -n "$NS" delete -f "$SVC_OUT" --ignore-not-found=true
    kubectl -n "$NS" delete -f "$STS_OUT" --ignore-not-found=true
    kubectl -n "$NS" delete configmap "aicc-${GROUP}-ivr-config" "aicc-${GROUP}-ivr-confd" "aicc-${GROUP}-ivr-flows" --ignore-not-found=true
    echo "삭제 완료 (PVC·Secret 은 보존됨. uivr DB 데이터도 그대로)"
    exit 0 ;;

  apply)
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
    echo "[1/5] PVC 적용..."
    kubectl -n "$NS" apply -f "$HERE/00-pvc.yaml"

    echo "[2/5] ConfigMap 생성/적용..."
    NS="$NS" GROUP="$GROUP" IVR_DB_HOST="$IVR_DB_HOST" IVR_DB_PORT="$IVR_DB_PORT" \
      IVR_SIP_REMOTE_IP="$IVR_SIP_REMOTE_IP" IVR_CTI_HOST1="$IVR_CTI_HOST1" "$HERE/10-make-configmap.sh"

    echo "[3/5] Secret 확인..."
    if [ -f "$HERE/20-secret.yaml" ]; then
      kubectl -n "$NS" apply -f "$HERE/20-secret.yaml"
    elif kubectl -n "$NS" get secret aicc-ivr-secret >/dev/null 2>&1; then
      echo "secret/aicc-ivr-secret 이미 존재 — 유지"
    else
      echo "[WARN] 20-secret.yaml 없음 & secret/aicc-ivr-secret 미존재 — ivr 컨테이너가 IVR_DB_PASSWORD 미주입으로 종료됩니다."
      echo "       cp 20-secret.example.yaml 20-secret.yaml 후 실제 값을 넣고 다시 실행하십시오."
    fi

    echo "[4/5] StatefulSet 배포..."
    kubectl -n "$NS" apply -f "$STS_OUT"
    echo "[5/5] Service 배포..."
    kubectl -n "$NS" apply -f "$SVC_OUT"
    if [ -n "$NODERED_DOMAIN" ]; then
      kubectl -n "$NS" apply -f "$ING_OUT"; echo "Node-RED 편집기: http(s)://${NODERED_DOMAIN}/"
    fi

    echo "=========================================================="
    echo " AICC IVR 배포 완료"
    echo " 상태 확인  : kubectl -n $NS get pods -l app=aicc-ivr -o wide"
    echo " 롤아웃 대기: kubectl -n $NS rollout status statefulset/$STS"
    echo "=========================================================="
    ;;

  *) echo "사용법: $0 [apply|render|diff|delete]" >&2; exit 1 ;;
esac
