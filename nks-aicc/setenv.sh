#!/bin/sh
export JAVA_HOME=/opt/java
# 힙 2G 고정 — Deployment memory request(1536Mi)보다 커서 eviction 위험 (PROJECT-REVIEW 3.2).
# 새 환경 전환/리소스 조정 시 request를 2.5Gi+로 올리거나
# -XX:MaxRAMPercentage=60.0 방식(limit 3Gi 기준 자동 산정)으로 교체 권장.
# jasypt 키는 이미지에 없고 k8s Secret(aicc-secret) → env로 주입됨. 키 변경 시 재빌드 불필요.
export JAVA_OPTS="$JAVA_OPTS -server -Xms2048m -Xmx2048m \
 -Duser.timezone=Asia/Seoul -Dfile.encoding=UTF-8 \
 -Djasypt.encryptor.password=${JASYPT_ENCRYPTOR_PASSWORD}"
