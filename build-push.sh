#!/usr/bin/env bash
set -euo pipefail

NCR="gcgf-aicc-dev.ncr.gov-ntruss.com"   # NCP Container Registry (개발계). 운영 전환 시 -dev 빼고 교체
TAG="${TAG:-1.0.0}"
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
