#!/usr/bin/env bash
set -euo pipefail

# 사전 조건: docker login <NCR주소> (NCP API Access/Secret Key), 새 NCR엔 aicc-agent/aicc-admin
# 리포지토리가 미리 있어야 push 가능. 원본 서버로는 SSH 키 인증 + sudo 권한 필요.

# [환경전환] NCP Container Registry (개발계). 운영 전환 시 -dev 빼고 교체.
# 바꾸면 k8s/30,31 Deployment의 image: 주소도 함께 교체할 것.
NCR="gcgf-aicc-dev.ncr.gov-ntruss.com"
# [환경전환] 같은 태그로 재빌드하면 노드 캐시된 구 이미지가 쓰일 수 있음.
# 전환/재배포 시 새 태그(예: 날짜 기반 2026.07.22-1) 권장. Deployment image: 태그도 함께 변경.
TAG="${TAG:-1.0.0}"
# [환경전환] 이미지 소스가 되는 원본 톰캣 서버. 새 환경에서 원본이 바뀌면 IP/계정과 함께
# 아래 HOME_OF의 톰캣 설치 경로도 확인할 것.
APP_USER="${APP_USER:-ubersys}"
APP_HOST="${APP_HOST:-172.16.90.200}"

declare -A HOME_OF=(
  [agent]="/usr/local/src/apache-tomcat-9.0.113-agent"
  [admin]="/usr/local/src/apache-tomcat-9.0.113"
)

build_role() {
  local role="$1" home="${HOME_OF[$role]}" b="build/$role"
  echo "==== [$role] tomcat 가져오기: $home ===="
  rm -rf "$b"; mkdir -p "$b/tomcat"
  ssh "${APP_USER}@${APP_HOST}" \
    "sudo tar czf /tmp/aicc-$role.tgz -C $(dirname "$home") $(basename "$home") \
       --exclude='*/logs/*' --exclude='*/work/*' --exclude='*/temp/*' \
     && sudo chown ${APP_USER}: /tmp/aicc-$role.tgz"
  scp "${APP_USER}@${APP_HOST}:/tmp/aicc-$role.tgz" "$b/tc.tgz"
  ssh "${APP_USER}@${APP_HOST}" "sudo rm -f /tmp/aicc-$role.tgz"
  tar xzf "$b/tc.tgz" -C "$b/tomcat" --strip-components=1 && rm "$b/tc.tgz"
  cp Dockerfile server.xml setenv.sh "$b/"
  echo "==== [$role] 이미지 빌드/푸시 ===="
  docker build -f "$b/Dockerfile" -t "${NCR}/aicc-${role}:${TAG}" "$b"
  docker push "${NCR}/aicc-${role}:${TAG}"
}

build_role agent
build_role admin
echo "완료: ${NCR}/aicc-agent:${TAG} , ${NCR}/aicc-admin:${TAG}"
