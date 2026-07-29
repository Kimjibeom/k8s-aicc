# U-Agent 이미지 로컬 검증 가이드 (WSL + minikube)

작성일: 2026-07-28
대상: `PACKAGE-BUILD-GUIDE.md`의 최종안(공식 tomcat 이미지 + 벤더 델타)대로
WSL 우분투에서 이미지를 빌드하고, minikube에 배포해 동작을 확인하는 절차.
전제: docker·minikube·kubectl 설치 완료.

---

## 1. 작업 디렉토리 구성

```bash
mkdir -p ~/uagent-minikube && cd ~/uagent-minikube
```

빌드에 필요한 파일 3개를 만든다.

**`Dockerfile.package`** — PACKAGE-BUILD-GUIDE §3.1과 동일:

```dockerfile
FROM tomcat:9.0.113-jre17-temurin-jammy

ENV TZ=Asia/Seoul LANG=ko_KR.UTF-8 LC_ALL=ko_KR.UTF-8
RUN apt-get update \
 && apt-get install -y --no-install-recommends locales fonts-noto-cjk \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i 's/^# *ko_KR.UTF-8/ko_KR.UTF-8/' /etc/locale.gen && locale-gen \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo "$TZ" > /etc/timezone

RUN rm -rf /usr/local/tomcat/webapps/*
COPY vendor/conf/     /usr/local/tomcat/conf/
COPY vendor/keystore/ /usr/local/tomcat/keystore/
COPY vendor/ROOT/     /usr/local/tomcat/webapps/ROOT/
COPY vendor/lib/      /usr/local/tomcat/lib/
COPY agent.war        /usr/local/tomcat/webapps/agent.war
COPY setenv.sh        /usr/local/tomcat/bin/setenv.sh

RUN mkdir -p /usr/local/src/config \
 && ln -s /usr/local/tomcat /usr/local/src/tomcat9_agent

EXPOSE 8080 9443
CMD ["catalina.sh", "run"]
```

> 베이스 태그가 없다고 나오면 `docker pull tomcat:9.0.113-jre17-temurin-jammy`로 먼저
> 확인하고, 없을 경우 가장 가까운 9.0.x-jre17 태그로 교체한다.

**`setenv.sh`**:

```sh
#!/bin/sh
export JAVA_OPTS="$JAVA_OPTS -server \
 -Xms${JAVA_XMS:-2048m} -Xmx${JAVA_XMX:-2048m} \
 -Duser.timezone=Asia/Seoul -Dfile.encoding=UTF-8 \
 -Djasypt.encryptor.password=${JASYPT_ENCRYPTOR_PASSWORD:-ubasenexus}"
```

**`build.sh`** — 로컬 검증용이라 push 없음:

```bash
#!/usr/bin/env bash
set -euo pipefail

TAG="${TAG:-6.3.2.023-1}"
PKG="${PKG:-$HOME/U-Agent_install_Package_v6.3.2.023_20260121_EL9}"

b="build"
rm -rf "$b"; mkdir -p "$b/x"

tar xzf "$PKG/uconnect_agent/tomcat/apache-tomcat-9.0.113-agent.tar.gz" \
    -C "$b/x" --strip-components=1
mkdir -p "$b/vendor"
mkdir -p "$b/vendor/lib"
mv "$b/x/conf" "$b/x/keystore" "$b/vendor/"
mv "$b/x/webapps/ROOT" "$b/vendor/ROOT"
cp "$b/x"/lib/tomcat-cluster-redis-session-manager-*.jar "$b/vendor/lib/"
cp "$b/x"/lib/jedis-*.jar "$b/vendor/lib/"
cp "$b/x"/lib/commons-pool2-*.jar "$b/vendor/lib/"
cp "$b/x"/lib/commons-logging-*.jar "$b/vendor/lib/"
rm -rf "$b/x"

cp "$PKG"/uconnect_agent/svc.war/agent_v*.war "$b/agent.war"
cp Dockerfile.package "$b/Dockerfile"
cp setenv.sh "$b/"

docker build -t "aicc-agent:${TAG}" "$b"
echo "완료: aicc-agent:${TAG}"
```

## 2. 이미지 빌드

```bash
cd ~/uagent-minikube && chmod +x build.sh && ./build.sh
```

빌드 후 확인:

```bash
docker run --rm aicc-agent:6.3.2.023-1 ls /usr/local/tomcat/webapps /usr/local/tomcat/keystore/server
```

`agent.war`, `ROOT`, `serverkeystore.jks`가 보이면 정상.

## 3. minikube 기동 및 이미지 로드

```bash
minikube start --driver=docker --cpus=2 --memory=4096
```

```bash
minikube image load aicc-agent:6.3.2.023-1
```

> 이미지가 커서(수백 MB) load에 1~2분 걸린다. 재빌드 시 같은 태그로 다시 load하면
> 캐시가 남을 수 있으므로 `minikube image rm aicc-agent:6.3.2.023-1` 후 다시 load한다.

## 4. 테스트용 properties 준비

패키지 템플릿(벤더 QA 접속정보)을 기반으로, 로컬 마운트 구성에 맞게 3곳만 수정한다.

```bash
cd ~/uagent-minikube
PKG=$HOME/U-Agent_install_Package_v6.3.2.023_20260121_EL9
cp "$PKG/uconnect_agent/svc.war/uconnect_agent.properties" .

# 설치 스크립트의 setting_version() 대응: nexus.conf의 version= 반영
V=$(grep '^version=' "$PKG/nexus.conf" | sed 's/^version=//')
sed -i '/^version=/d' uconnect_agent.properties
echo "version=$V" >> uconnect_agent.properties

# 업로드 경로를 컨테이너 볼륨(/data)으로
sed -i 's|^mms.upload.path=.*|mms.upload.path=/data/mms|' uconnect_agent.properties
sed -i 's|^webchat.upload.path=.*|webchat.upload.path=/data/chat|' uconnect_agent.properties
```

**외부 연동 도달성 확인** — 템플릿의 DB/Redis는 벤더 QA 장비다. WSL에서 도달돼야
로그인까지 검증할 수 있다:

```bash
nc -zv -w3 121.170.212.95 3316 && nc -zv -w3 121.170.212.86 6389
```

- 둘 다 열려 있으면: 로그인·화면 진입까지 전체 검증 가능.
- 막혀 있으면: 검증 범위는 "톰캣 기동 + war 배포 + 로그인 페이지 응답"까지로 한정된다
  (기동 로그에 DB 커넥션 오류가 찍히는 것은 이 경우 정상).

## 5. 매니페스트 작성 및 배포

**`k8s-local.yaml`**:

```yaml
apiVersion: v1
kind: Namespace
metadata: { name: aicc-test }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: aicc-agent, namespace: aicc-test }
spec:
  replicas: 1
  selector: { matchLabels: { app: aicc-agent } }
  template:
    metadata: { labels: { app: aicc-agent } }
    spec:
      containers:
      - name: agent
        image: aicc-agent:6.3.2.023-1
        imagePullPolicy: Never          # minikube image load 사용 시 필수
        ports: [ { containerPort: 8080 } ]
        env:
        - { name: JAVA_XMS, value: "1024m" }   # 로컬이라 힙 축소
        - { name: JAVA_XMX, value: "1024m" }
        startupProbe:
          httpGet: { path: /agent/, port: 8080 }
          periodSeconds: 5
          failureThreshold: 60          # 첫 기동(war 압축해제) 최대 5분 허용
        readinessProbe:
          httpGet: { path: /agent/, port: 8080 }
          periodSeconds: 10
        volumeMounts:
        - { name: config, mountPath: /usr/local/src/config }
        - { name: data,   mountPath: /data }
        - { name: logs,   mountPath: /usr/local/tomcat/logs }
      volumes:
      - name: config
        configMap: { name: aicc-config }
      - { name: data, emptyDir: {} }
      - { name: logs, emptyDir: {} }
---
apiVersion: v1
kind: Service
metadata: { name: aicc-agent, namespace: aicc-test }
spec:
  selector: { app: aicc-agent }
  ports: [ { port: 8080, targetPort: 8080 } ]
```

배포:

```bash
kubectl apply -f k8s-local.yaml
kubectl -n aicc-test create configmap aicc-config --from-file=uconnect_agent.properties
kubectl -n aicc-test rollout status deploy/aicc-agent --timeout=5m
```

## 6. 기동 확인

```bash
kubectl -n aicc-test logs deploy/aicc-agent | grep -E 'Server startup|Deploying|jasypt|ERROR|8080|9443' | head -30
```

확인 포인트:
- `Deploying web application archive [/usr/local/tomcat/webapps/agent.war]`
- 8080(http), 9443(https) 커넥터 기동 로그 — keystore가 정상 로드됐다는 뜻
- jasypt 복호화 오류 없음
- `Server startup in [...] ms`

## 7. 접속 검증

```bash
kubectl -n aicc-test port-forward svc/aicc-agent 8080:8080
```

다른 터미널 또는 Windows 브라우저에서 (WSL2의 localhost는 Windows에서 그대로 접근 가능):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/agent/
```

- 브라우저: `http://localhost:8080/agent/` → 로그인 페이지 표시, 화면의 버전 표기가
  properties에 넣은 `version=` 값과 일치하는지 확인.
- DB/Redis 도달 가능 환경이면 실제 로그인 → 상담 화면 진입까지 확인.
- 업로드 검증 시: 파일 업로드 후 `kubectl -n aicc-test exec deploy/aicc-agent -- ls -R /data`

## 8. 체크리스트

- [ ] 이미지 빌드 성공, webapps에 `agent.war`·`ROOT`만 존재
- [ ] Pod Ready (startupProbe 통과), 재시작 루프 없음
- [ ] 기동 로그: 8080/9443 커넥터, jasypt·keystore 오류 없음
- [ ] `/agent/` 응답 200(또는 로그인 리다이렉트), 버전 표기 일치
- [ ] (외부 도달 시) 로그인, DB/Redis 연동 정상
- [ ] access log가 `/usr/local/tomcat/logs`에 생성 (`kubectl exec ... -- ls /usr/local/tomcat/logs`)

## 9. 자주 걸리는 문제

| 증상 | 원인/조치 |
|---|---|
| `ErrImageNeverPull` | `minikube image load` 누락 또는 태그 불일치 — `minikube image ls | grep aicc` |
| startupProbe 실패로 재시작 반복 | 첫 기동이 느린 경우 — `failureThreshold` 상향. 로그에서 실제 오류 먼저 확인 |
| 기동 로그에 DB 커넥션 오류 | WSL에서 벤더 QA DB 미도달(§4) — 페이지 응답 검증까지만 진행 |
| 한글 깨짐 | 이미지의 locale 설정 확인: `kubectl exec ... -- locale` |
| ConfigMap 수정 후 미반영 | configmap 재생성 후 `kubectl -n aicc-test rollout restart deploy/aicc-agent` |

## 10. 정리

```bash
kubectl delete namespace aicc-test
minikube stop        # 완전 삭제는 minikube delete
```
