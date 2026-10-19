# NKS AICC admin/agent 컨테이너화 프로젝트 리뷰

작성일: 2026-07-22
대상: 리포 루트 (Dockerfile, build-push.sh, setenv.sh, server.xml, k8s/*)

---

## 1. 요약

전체적으로 구조는 잘 잡혀 있습니다 (PV/PVC 정적 바인딩, subPathExpr로 Pod별 로그 분리,
Secret으로 jasypt 키 주입 등). 다만 **실제로는 사용되지 않는 설정 파일(server.xml)**과
**ALB target-type: ip와 충돌하는 NodePort 구성** 등 정리하면 좋을 지점들이 있습니다.

| 구분 | 항목 | 중요도 |
|------|------|--------|
| 불필요/버그 | `server.xml` — Dockerfile에서 COPY하지 않아 **미사용** | **높음** |
| 불필요 | Service의 `NodePort` 타입 + 고정 nodePort/clusterIP | 중간 |
| 불일치 | admin 포트 80 vs Dockerfile `EXPOSE 8080` / server.xml 8080 | **높음** |
| 위험 | JVM 힙 2G 고정 vs 메모리 request 1536Mi | 중간 |
| 권장 | admin Service에 ALB healthcheck-path 어노테이션 누락 | 중간 |
| 권장 | 컨테이너 root 실행, properties의 민감정보가 ConfigMap에 존재 | 중간 |

---

## 2. 명백히 불필요한 요소

(2.1 압축 해제 부산물 — `__MACOSX/`, `.DS_Store`, `Zone.Identifier` — 은 **조치 완료**되어 삭제.
번호는 다른 문서/주석의 상호 참조 유지를 위해 그대로 둠.)

### 2.2 `server.xml` — 리포에 있지만 실제로 사용되지 않음 ★

가장 중요한 발견입니다. [build-push.sh](build-push.sh)에서
`cp Dockerfile server.xml setenv.sh "$b/"`로 빌드 컨텍스트에 복사하지만,
**[Dockerfile](Dockerfile)에는 `COPY server.xml ...` 라인이 없습니다.**
`COPY tomcat/`과 `COPY setenv.sh` 두 개뿐입니다.

즉 실제 컨테이너는 원본 서버(172.16.90.200)에서 tar로 가져온 톰캣에 **원래 들어있던
`conf/server.xml`을 그대로 사용**하고, 리포의 server.xml(8080 포트 설정)은 죽은 파일입니다.

둘 중 하나로 정리해야 합니다:

- **(a) 의도가 "톰캣 설정을 리포에서 관리"라면** — Dockerfile에
  `COPY server.xml /opt/tomcat/conf/server.xml`을 추가. 단, 이 경우 admin도 8080으로
  뜨게 되므로 아래 2.4의 포트 불일치를 함께 해결해야 합니다 (현재 admin 매니페스트는 80 포트 기준).
- **(b) 원본 서버 설정을 그대로 쓰는 게 의도라면** — 리포에서 server.xml과
  build-push.sh의 `cp ... server.xml ...` 부분을 제거해서 혼란을 없앰.

참고로 server.xml을 쓰게 된다면 그 내용 자체에도 컨테이너 환경에서 불필요한 부분이 있습니다:

- `AprLifecycleListener SSLEngine="on"` — 이미지에 APR/tomcat-native가 설치되어 있지 않아 무의미
- `UserDatabase` Realm + `LockOutRealm` — tomcat-users.xml 기반 관리자 인증인데 컨테이너에서 사용할 일 없음
- `shutdown port 8005` — 컨테이너에서는 `port="-1"`로 닫는 것이 관례
- `autoDeploy="true"` — 이미지가 불변(immutable)이므로 `false` 권장
- `redirectPort="8443"` — 8443 리스너가 없으므로 무의미

### 2.3 Service의 NodePort 타입 + 고정 IP들

[50-ingress.yaml:12](k8s/50-ingress.yaml)에서
`alb.ingress.kubernetes.io/target-type: ip`를 사용 중입니다. 이 모드에서는 ALB가
**NodePort를 거치지 않고 Pod IP로 직접** 트래픽을 보내므로,
[40-service.yaml](k8s/40-service.yaml)의 다음 설정은 불필요합니다:

- `type: NodePort` → `ClusterIP`로 충분 (주석에도 "NodePort로 둠"이라고 되어 있지만 target-type: ip에서는 근거가 없음)
- 고정 `nodePort: 30810 / 30811` — 노드 포트가 아예 안 쓰이므로 예약할 이유가 없음
- 고정 `clusterIP: 198.19.200.10 / .11` — 클러스터 내부에서 IP로 직접 호출하는 곳이 없다면
  불필요하고, Service 재생성 시 IP 충돌로 생성 실패하는 원인이 될 수 있음 (DNS 이름
  `aicc-agent.aicc.svc`로 호출하면 고정 IP가 필요 없음)

단, NCP NKS의 ALB Ingress Controller 버전에 따라 NodePort를 요구하는 경우가 과거에
있었으므로, ClusterIP로 바꾼 뒤 dev에서 타겟 등록이 정상인지 확인 후 적용하세요.

### 2.4 Dockerfile의 소소한 중복

- `mkdir -p /usr/local/src/config /mnt/aiccnas` — 두 경로 모두 k8s에서 volumeMount로
  덮어써지므로 없어도 마운트 시점에 자동 생성됩니다 (도커 단독 실행 대비용이면 유지해도 무방).
- [setenv.sh:2](setenv.sh)의 `export JAVA_HOME=/opt/java` —
  Dockerfile ENV에서 이미 설정되어 중복.

---

## 3. 불일치 / 잠재적 문제 (수정 권장)

### 3.1 admin 포트 불일치 ★

- Dockerfile: `EXPOSE 8080`, 리포 server.xml: Connector 8080
- [31-deployment-admin.yaml](k8s/31-deployment-admin.yaml):
  `containerPort: 80`, probe도 80 / Service `targetPort: 80`
- agent는 전부 8080으로 일관

admin 원본 톰캣의 server.xml이 80 포트로 리슨하고 있다는 뜻인데, 이는 곧 **admin 컨테이너가
root로 떠야만 80 포트 바인딩이 가능**하다는 의미이기도 합니다 (1024 미만 특권 포트).
admin/agent 모두 8080으로 통일하고 Service targetPort만 맞추는 것을 권장합니다.
2.2-(a) 방식(server.xml을 리포에서 COPY)으로 가면 자연스럽게 통일됩니다.

### 3.2 JVM 힙과 리소스 request 불일치

[setenv.sh](setenv.sh)가 `-Xms2048m -Xmx2048m`으로 힙을
2G 고정하는데, Deployment의 메모리 **request는 1536Mi**입니다. 힙만으로 request를 초과하므로
스케줄러가 실제 사용량보다 작게 보고 배치하게 되고, 노드 메모리 압박 시 eviction 대상이 되기 쉽습니다.

권장:
- request를 2.5Gi 수준으로 올리거나,
- `-Xms/-Xmx` 대신 `-XX:MaxRAMPercentage=60.0 -XX:InitialRAMPercentage=60.0`을 사용해
  컨테이너 limit(3Gi) 기준으로 자동 산정 (Java 17은 cgroup 인식이 잘 됨).

### 3.3 admin Service에 ALB healthcheck-path 어노테이션 누락

agent Service에는 `alb.ingress.kubernetes.io/healthcheck-path: /agent/`가 있는데
**admin Service에는 없습니다.** 이 경우 ALB 타겟 헬스체크가 기본 경로(`/`)로 나가고,
루트 컨텍스트가 없다면 404로 타겟이 unhealthy 처리될 수 있습니다.
admin Service에 `healthcheck-path: /admin/` 추가를 권장합니다.

### 3.4 properties의 민감정보가 ConfigMap에 저장됨

[10-make-configmap.sh](k8s/10-make-configmap.sh)가
`uconnect_*.properties`를 통째로 ConfigMap에 넣습니다. jdbc.url 등 접속정보가 포함될 텐데,
jasypt로 암호화된 값(ENC(...))만 있다면 괜찮지만 **평문 계정/비밀번호가 있다면 Secret으로
옮기는 것**이 맞습니다. ConfigMap은 네임스페이스 read 권한만 있으면 누구나 열람 가능합니다.

### 3.5 이미지 빌드 방식의 취약성 (중장기)

[build-push.sh](build-push.sh)는 **운영 중인 VM에서
톰캣 디렉토리 전체를 ssh/tar로 뜯어와** 이미지에 굽는 방식입니다. 전환기 스냅샷으로는
실용적이지만:

- 빌드 재현성이 없음 (그 시점 서버 상태에 의존, webapps에 풀린 WAR·임시파일까지 포함)
- 원본 서버의 `conf/` 안 인증서·비밀번호 파일이 이미지에 함께 구워질 위험
- 서버가 사라지면 빌드 불가

중장기적으로는 `tomcat:9-jdk17` 공식 이미지(또는 현재 Rocky 베이스 유지) + CI에서 빌드한
WAR 파일만 `COPY`하는 구조로 전환을 권장합니다. 이렇게 하면 리포의 server.xml/setenv.sh가
진짜 단일 소스가 되어 2.2 문제도 함께 해결됩니다.

### 3.6 기타 개선 권장 (낮은 우선순위)

- **root 실행**: Dockerfile에 `USER` 지정이 없어 톰캣이 root로 실행됩니다. 전용 계정 생성 +
  Deployment `securityContext`(runAsNonRoot, fsGroup) 추가 권장. 3.1의 8080 통일이 선행 조건.
- **namespace 매니페스트 부재**: `aicc` 네임스페이스와 `ncr-aicc-dev` imagePullSecret 생성이
  매니페스트/스크립트 어디에도 없어 수동 작업에 의존합니다. `00-namespace.yaml` 추가하거나
  README에 사전 작업으로 명시 권장.
- **imagePullSecrets 중복**: 두 Deployment에 각각 선언하는 대신 네임스페이스 default
  ServiceAccount에 붙이면 한 곳에서 관리됩니다 (`kubectl patch serviceaccount default ...`).
- **이미지 태그 고정 1.0.0**: 재빌드해도 태그가 같으면 노드에 캐시된 구 이미지가 쓰일 수
  있습니다. 빌드마다 태그를 올리거나(날짜/커밋 기반) `imagePullPolicy: Always` 명시 권장.
- **HTTP→HTTPS 리다이렉트**: Ingress가 80/443 둘 다 리슨하는데 리다이렉트 설정이 없습니다.
  NCP ALB Ingress의 ssl-redirect 지원 여부 확인 후 적용 검토.
- **dev/prod 값 분리**: 레지스트리 주소, 인증서 ID, subnet ID가 매니페스트에 하드코딩되어
  있어, 환경이 늘어나면 Helm 또는 Kustomize 도입을 검토할 만합니다.
- **`.gitignore` 부재**: build-push.sh가 생성하는 `build/` 산출물 디렉토리가 추적 대상에
  포함될 수 있으므로 `.gitignore`에 추가 권장.

---

## 4. 권장 조치 우선순위

1. **(높음)** server.xml 사용 여부 결정 (COPY 추가 or 삭제) + admin 8080 포트 통일 — 2.2, 3.1
2. **(높음)** admin Service에 healthcheck-path 추가 — 3.3
3. **(중간)** JVM 힙 ↔ request 정합화 — 3.2
4. **(중간)** Service를 ClusterIP로 단순화, 고정 IP/nodePort 제거 (dev 검증 후) — 2.3
5. **(중간)** properties 민감정보 Secret 분리 검토 — 3.4
6. **(중장기)** WAR 기반 이미지 빌드 전환, non-root 실행, Helm/Kustomize 검토 — 3.5, 3.6
