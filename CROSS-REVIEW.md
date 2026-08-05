# 레거시 설치 가이드 vs 컨테이너 환경 대조 검증 및 수정 절차

작성일: 2026-08-05
대상: 기존 레거시 서버 설치 가이드와 본 리포(Dockerfile, build-push.sh, k8s/*)를 대조하여
컨테이너 환경 전환 시 누락·보완이 필요한 항목을 정리하고, `PROJECT-REVIEW.md`의 기존 지적 사항과
통합한 종합 수정 절차.

---

## 1. 결론

기존 코드(WAR) 수정 없이 동작 가능한 구조임을 확인했습니다.
단, **설정 및 빌드 레벨에서 보완 4건 + 기존 리뷰 미반영 5건 = 총 9건**의 조치가 필요합니다.

---

## 2. 레거시 설치 항목 vs 컨테이너 환경 — 검증 결과

| 레거시 설치 항목 | 컨테이너 환경 처리 방식 | 판정 |
|---|---|---|
| **JHA/VIP 생성** | k8s Service + ALB가 VIP 역할 대체 (`k8s/40-service.yaml`, `50-ingress.yaml`) | ✅ 해소 |
| **데몬/방화벽 설정** | Pod에 해당 없음 — `catalina.sh run` foreground 실행 (`Dockerfile:30`) | ✅ 해소 |
| **환경변수 설정** | Dockerfile ENV (`Dockerfile:3-6`) + `setenv.sh` 덮어쓰기 | ✅ 해소 |
| **주요 앱 IP 설정** | ConfigMap이 `/usr/local/src/config`에 마운트 (`30-deployment-agent.yaml:37`, `31-deployment-admin.yaml:38`) | ✅ 해소 |
| **웹 인증서 교체** | ALB가 TLS 종료 — NCP Certificate Manager (`50-ingress.yaml:12`) | ✅ 해소 |
| **클라이언트 IP 세션 체크** | ALB 뒤에서 X-Forwarded-For 사용 전제. 단 `RemoteIpValve` 미설정 — **기능 테스트 필요** | ⚠️ 조건부 해소 |
| **cronolog 필수 RPM** | `catalina.sh run`은 stdout 출력이라 cronolog 불필요 | ✅ 해소 |

> 7항목 중 6항목은 완전 해소. **클라이언트 IP 세션 체크**는 `RemoteIpValve` 추가 후 테스트로 확정 필요 (§4.1-1).

---

## 3. 보완 필요 항목 — 실제 코드 대조

### 3.1 Redis 세션 저장소 설정 외부화

- `build-push.sh`가 원본 톰캣을 통째로 tar하므로 `conf/redis-data-cache.properties`가 이미지에 포함됨.
- `10-make-configmap.sh`는 `uconnect_*.properties` 2개만 관리 — Redis 설정은 미포함.
- **조치**: ConfigMap(또는 비밀번호가 평문이면 Secret)에 추가 후 subPath 마운트 (§4.2-1).

### 3.2 HTTPS 스킴 인식 문제

- `50-ingress.yaml:14`에서 `backend-protocol: HTTP` 확인. ALB → Pod는 HTTP.
- 리포의 `server.xml`에 `RemoteIpValve` 없음. 그런데 이 server.xml은 **Dockerfile에서 COPY하지 않아 미사용**
  (`PROJECT-REVIEW.md` §2.2). 실제 적용되는 것은 원본 서버의 server.xml.
- **조치**: server.xml을 리포 관리로 전환(COPY 추가) 후 `RemoteIpValve` 추가 (§4.1-1).

### 3.3 MMS 업로드 파일 서빙

- `10-make-configmap.sh:18-19`에서 `mms.upload.path=/mnt/aiccnas/mms` 치환 확인.
- NAS 마운트(`/mnt/aiccnas`)도 Deployment에서 확인.
- 업로드 **저장**은 동작하나, 브라우저의 URL 접근(서빙)은 앱의 서블릿 매핑에 의존.
- **조치**: 배포 후 기능 테스트 (§4.3-2).

### 3.4 이미지 내 민감정보

- `build-push.sh:30-35` — `--exclude`에 `logs/work/temp`만 있고 `keystore/`, `.jks`, `.p12`,
  `redis-data-cache.properties` 등은 포함됨.
- `PROJECT-REVIEW.md` §3.5에서 동일 이슈 이미 지적.
- **조치**: tar exclude 확장 (§4.2-2).

---

## 4. 종합 수정 절차 (기존 `PROJECT-REVIEW.md` 지적 통합)

`PROJECT-REVIEW.md`에 기록되었으나 이번 검토에서 빠진 5개 항목(server.xml 미사용, admin 80포트,
healthcheck 누락, 힙/request 불일치, NodePort 불필요)을 통합하여 Phase별로 정리합니다.

### Phase 1: 즉시 조치 (배포 전 필수)

#### 4.1-1. server.xml COPY 추가 + RemoteIpValve (PROJECT-REVIEW 2.2 + 본문 3.2)

현재 리포의 `server.xml`은 Dockerfile에서 COPY하지 않아 죽은 파일입니다.

**Dockerfile 수정:**
```diff
 COPY setenv.sh  /opt/tomcat/bin/setenv.sh
+COPY server.xml /opt/tomcat/conf/server.xml
```

**server.xml 수정** (Host 태그 안에 RemoteIpValve 추가):
```diff
       <Host name="localhost" appBase="webapps"
-            unpackWARs="true" autoDeploy="true">
+            unpackWARs="true" autoDeploy="false">
+        <Valve className="org.apache.catalina.valves.RemoteIpValve"
+               remoteIpHeader="X-Forwarded-For"
+               protocolHeader="X-Forwarded-Proto" />
         <Valve className="org.apache.catalina.valves.AccessLogValve" directory="logs"
```

선택적 정리:
- `<Server port="8005">` → `port="-1"` (컨테이너 관례)
- `AprLifecycleListener` 제거 (이미지에 APR 없음)

#### 4.1-2. admin 포트 8080 통일 (PROJECT-REVIEW 3.1)

4.1-1에서 server.xml COPY를 추가하면 admin도 리포의 server.xml(8080)을 사용하게 되므로
매니페스트를 맞춤.

**`k8s/31-deployment-admin.yaml`:**
```diff
-        - { containerPort: 80 }
+        - { containerPort: 8080 }
         ...
-          httpGet: { path: /admin, port: 80 }
+          httpGet: { path: /admin, port: 8080 }
```

**`k8s/40-service.yaml` (admin Service):**
```diff
-  - { name: http, port: 8080, targetPort: 80, nodePort: 30811, protocol: TCP }
+  - { name: http, port: 8080, targetPort: 8080, nodePort: 30811, protocol: TCP }
```

#### 4.1-3. admin Service healthcheck-path 추가 (PROJECT-REVIEW 3.3)

**`k8s/40-service.yaml` (aicc-admin metadata):**
```diff
 metadata:
   name: aicc-admin
   namespace: aicc
+  annotations:
+    alb.ingress.kubernetes.io/healthcheck-path: /admin/
```

#### 4.1-4. JVM 힙 / memory request 정합 (PROJECT-REVIEW 3.2)

택일:

**방안 A** — request 상향 (간단, Deployment 2종):
```diff
-          requests: { cpu: "250m", memory: "1536Mi" }
+          requests: { cpu: "250m", memory: "2560Mi" }
```

**방안 B** — MaxRAMPercentage (권장, `setenv.sh`):
```diff
-export JAVA_OPTS="$JAVA_OPTS -server -Xms2048m -Xmx2048m \
+export JAVA_OPTS="$JAVA_OPTS -server \
+ -XX:InitialRAMPercentage=60.0 -XX:MaxRAMPercentage=60.0 \
  -Duser.timezone=Asia/Seoul -Dfile.encoding=UTF-8 \
  -Djasypt.encryptor.password=${JASYPT_ENCRYPTOR_PASSWORD}"
```

> 방안 B는 limit 3Gi 기준 약 1.8Gi 힙. limit 변경 시 자동 추종.

---

### Phase 2: 보안 강화 (배포 초기)

#### 4.2-1. Redis 설정 외부화 (본문 3.1)

1. `10-make-configmap.sh`에 Redis properties 수집 추가:
   ```bash
   scp "${APP_USER}@${APP_HOST}:${HOME_OF[agent]}/conf/redis-data-cache.properties" "$d/"
   ```
2. ConfigMap 생성에 파일 추가 (`--from-file=redis-data-cache.properties=...`).
3. Deployment에 subPath 마운트 추가 (conf/ 전체를 덮어쓰지 않기 위해):
   ```yaml
   - name: config
     mountPath: /opt/tomcat/conf/redis-data-cache.properties
     subPath: redis-data-cache.properties
   ```
4. Redis 비밀번호가 평문이면 ConfigMap 대신 **Secret** 분리.

#### 4.2-2. 이미지 내 민감정보 제거 (본문 3.4)

**`build-push.sh` 수정:**
```diff
     "sudo tar czf /tmp/aicc-$role.tgz -C $(dirname "$home") $(basename "$home") \
-       --exclude='*/logs/*' --exclude='*/work/*' --exclude='*/temp/*' \
+       --exclude='*/logs/*' --exclude='*/work/*' --exclude='*/temp/*' \
+       --exclude='*/keystore/*' --exclude='*.jks' --exclude='*.p12' \
+       --exclude='*/conf/redis-data-cache.properties' \
      && sudo chown ${APP_USER}: /tmp/aicc-$role.tgz"
```

---

### Phase 3: 구조 개선 (안정화 후)

#### 4.3-1. Service를 ClusterIP로 단순화 (PROJECT-REVIEW 2.3)

Ingress `target-type: ip`에서 NodePort/고정 clusterIP가 불필요.

**`k8s/40-service.yaml`:**
```diff
 spec:
-  type: NodePort
-  clusterIP: 198.19.200.10
+  type: ClusterIP
   selector: { app: aicc-agent }
   ports:
-  - { name: http, port: 8080, targetPort: 8080, nodePort: 30810, protocol: TCP }
+  - { name: http, port: 8080, targetPort: 8080, protocol: TCP }
```

> **반드시 개발계에서 먼저 검증.** NCP ALB Ingress Controller 버전에 따라 NodePort를 요구할 수 있음.

#### 4.3-2. MMS 업로드 파일 서빙 테스트 (본문 3.3)

코드 수정이 아닌 기능 테스트:

```text
[ ] MMS 파일 업로드 실행
[ ] NAS /mnt/aiccnas/mms/ 하위에 파일 생성 확인
[ ] 브라우저에서 해당 파일 URL로 접근 시도
[ ] 실패 시 → 앱 서블릿 매핑 또는 Tomcat docBase 설정 확인
```

#### 4.3-3. 패키지 기반 빌드 전환 (중장기)

운영 서버 SSH tar 스냅샷 → `PACKAGE-BUILD-GUIDE.md` 방안 4 (공식 tomcat 이미지 + 벤더 델타)
전환 시 4.1-1, 4.2-2 이슈가 근본 해결됨.

---

## 5. 기타 전제 및 안내 사항

| 항목 | 내용 | 검증 |
|---|---|---|
| **DNS 해석 필수** | 앱 내부 도메인 참조를 위해 CoreDNS 해석 + ACG 허용 필요. CTI VIP만 `hostAliases`로 강제 매핑 중 | 확인됨 |
| **CTI 네트워크 경로 유지** | 상담사 브라우저 → CTI wss:// 직접 연결. 컨테이너화와 무관 | 확인됨 |
| **접속 URL 변경 안내** | `https://IP:9443/agent` → `https://<ALB도메인>/agent` | 확인됨 |

---

## 6. 참고 문서

- 기존 구조 이슈 상세: `PROJECT-REVIEW.md`
- 환경 전환 값 목록: `NKS-MIGRATION-GUIDE.md`
- 패키지 기반 빌드 전환: `PACKAGE-BUILD-GUIDE.md`
- 신규 컴포넌트 추가: `NEW-COMPONENT-ONBOARDING.md`
