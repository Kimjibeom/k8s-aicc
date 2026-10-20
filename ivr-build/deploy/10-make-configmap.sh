#!/usr/bin/env bash
set -euo pipefail

# config/ivr.env, conf.d/, flows.d/ 로부터 ConfigMap 생성 (비밀값은 20-secret.yaml 참조)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# deploy.env 로드 — 호출자가 넘긴 환경변수(deploy.sh 경유 포함)가 우선
_ovr=$(for v in NS GROUP IVR_DB_HOST IVR_DB_PORT IVR_SIP_REMOTE_IP IVR_CTI_HOST1; do [ -n "${!v+x}" ] && printf '%s=%q\n' "$v" "${!v}"; done; true)
# shellcheck disable=SC1091
[ -f "$HERE/deploy.env" ] && source "$HERE/deploy.env"
eval "$_ovr"

NS="${NS:-aicc}"
GROUP="${GROUP:-shr}"                       #[환경전환] 공용=shr / 전용풀=ded1, ded2, ...

tmp=$(mktemp)
grep -vE '^\s*(#|$)' "$HERE/config/ivr.env" | sed -E -e 's/[[:blank:]]*#.*$//' -e 's/[[:blank:]]+$//' > "$tmp"
if grep -qE '^(IVR_DB_PASSWORD|CTI_DB_PASSWORD|NODERED_CREDENTIAL_SECRET|NODERED_ADMIN_PASSWORD_HASH)=' "$tmp"; then
  echo "[ERROR] ivr.env 에 비밀값이 있음 — Secret(20-secret.yaml)으로 옮길 것" >&2; rm -f "$tmp"; exit 1
fi

# deploy.env 값 동적 주입 (IVR_DB_HOST / IVR_DB_PORT / IVR_SIP_REMOTE_IP / IVR_CTI_HOST1)
for k in IVR_DB_HOST IVR_DB_PORT IVR_SIP_REMOTE_IP IVR_CTI_HOST1; do
  v="${!k:-}"
  [ -n "$v" ] || continue
  if grep -qE "^$k=" "$tmp"; then sed -i -E "s|^$k=.*|$k=$v|" "$tmp"; else echo "$k=$v" >> "$tmp"; fi
  echo "[INFO] $k=$v"
done
grep -qE '^IVR_SIP_REMOTE_IP=.+' "$tmp" || echo "[WARN] IVR_SIP_REMOTE_IP 비어 있음 — 127.0.0.1(PBX 동거)로 기록됨"

CM="aicc-${GROUP}-ivr-config"
kubectl -n "$NS" create configmap "$CM" --from-env-file="$tmp" --dry-run=client -o yaml | kubectl apply -f -
rm -f "$tmp"
echo "configmap/$CM 적용 완료 (ns=$NS, group=$GROUP)"

if ls "$HERE"/conf.d/* 2>/dev/null | grep -v README.md >/dev/null; then
  args=(); for f in "$HERE"/conf.d/*; do [ "$(basename "$f")" = README.md ] || args+=(--from-file="$f"); done
  kubectl -n "$NS" create configmap "aicc-${GROUP}-ivr-confd" "${args[@]}" --dry-run=client -o yaml | kubectl apply -f -
  echo "configmap/aicc-${GROUP}-ivr-confd 적용 완료"
fi
if [ -f "$HERE/flows.d/flows.json" ]; then
  kubectl -n "$NS" create configmap "aicc-${GROUP}-ivr-flows" --from-file=flows.json="$HERE/flows.d/flows.json" --dry-run=client -o yaml | kubectl apply -f -
  echo "configmap/aicc-${GROUP}-ivr-flows 적용 완료"
fi
