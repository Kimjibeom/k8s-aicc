#!/usr/bin/env bash
set -euo pipefail
# [환경전환] APP_HOST: properties 원본 서버. 새 환경의 properties에는 새 CloudDB 접속정보(jdbc.url),
# 연동 시스템 주소가 들어 있어야 하므로 가져오기 전에 파일 내용을 새 환경 값으로 먼저 검증할 것.
# 이 스크립트가 자동 치환하는 것은 아래 upload 경로 2개뿐임.
# 참고: 평문 비밀번호가 있다면 ConfigMap 대신 Secret 분리 검토 (PROJECT-REVIEW 3.4).
NS=aicc; APP_USER="${APP_USER:-ubersys}"; APP_HOST="${APP_HOST:-172.16.90.200}"
CFG=/usr/local/src/config
# [환경전환] 새 환경 CloudDB가 SSL 활성화 상태면 APPLY_JDBC_TLS=1로 실행 (CloudDB 쪽 확인 선행)
APPLY_JDBC_TLS="${APPLY_JDBC_TLS:-0}"
d=$(mktemp -d)

# 속성 소스 수집
scp "${APP_USER}@${APP_HOST}:${CFG}/uconnect_agent.properties" "$d/" 
scp "${APP_USER}@${APP_HOST}:${CFG}/uconnect_admin.properties" "$d/"

# 경로 수정 (NAS 경로에 맞게)
sed -i -E 's#^mms.upload.path=.*#mms.upload.path=/mnt/aiccnas/mms#'          "$d/uconnect_agent.properties" || true
sed -i -E 's#^webchat.upload.path=.*#webchat.upload.path=/mnt/aiccnas/chat#'  "$d/uconnect_agent.properties" || true

# CDB SSL용 추가
if [ "$APPLY_JDBC_TLS" = "1" ]; then
  for f in "$d/uconnect_agent.properties" "$d/uconnect_admin.properties"; do
    if grep -qE '^jdbc.url=jdbc:mysql://.*JEDAI_CUBE' "$f" && ! grep -q 'sslMode=' "$f"; then
      sed -i -E '/^jdbc.url=jdbc:mysql:\/\/.*JEDAI_CUBE/ s/$/\&sslMode=REQUIRED/' "$f"
    fi
  done
  echo "[info] JDBC sslMode=REQUIRED 적용 (CloudDB SSL 활성화 전제)"
else
  echo "[info] JDBC TLS 미적용(기본). 적용하려면 APPLY_JDBC_TLS=1 (CloudDB SSL 확인 후)"
fi

# configmap 생성/업데이트
kubectl -n "$NS" create configmap aicc-config \
  --from-file=uconnect_agent.properties="$d/uconnect_agent.properties" \
  --from-file=uconnect_admin.properties="$d/uconnect_admin.properties" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "configmap/aicc-config 적용 완료"
rm -rf "$d"
