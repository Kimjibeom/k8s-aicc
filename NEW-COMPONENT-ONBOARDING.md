# NKS 신규 컴포넌트 온보딩 가이드

작성일: 2026-07-22
대상: U admin / U agent 외의 **새로운 컴포넌트**(예: 또 다른 WAS 앱, API 서버, 배치, 데몬 등)를
본 프로젝트와 동일한 방식(NCR 이미지 + k8s 매니페스트 + NCP ALB/NAS)으로 NKS에 올릴 때
결정·확인·작성해야 하는 항목의 정리.

기존 admin/agent 전환은 "같은 앱을 다른 환경으로 옮기는 것"이었다면, 이 문서는
**"새로운 앱을 이 구조에 편입시키는 것"**을 다룹니다. 환경값 교체 목록은
`NKS-MIGRATION-GUIDE.md`를, 기존 구조의 알려진 이슈는 `PROJECT-REVIEW.md`를 함께 참고하십시오.

---

## 1. 시작 전 — 컴포넌트 특성 파악 (설계 결정)

매니페스트를 작성하기 전에 아래 질문에 먼저 답해야 합니다. 답에 따라 필요한 리소스 종류가 달라집니다.

| # | 질문 | 결정되는 것 |
|---|------|-------------|
| 1 | HTTP 요청을 받는 서비스인가, 백그라운드 작업인가? | Deployment+Service+Ingress ↔ Deployment만 / CronJob |
| 2 | 상태(로컬 파일, 세션)를 가지는가? | 무상태면 Deployment, 로컬 디스크 상태가 있으면 StatefulSet 또는 NAS로 외부화 |
| 3 | 외부(사용자)에 노출되는가, 내부 호출 전용인가? | Ingress 경로 추가 여부 ↔ ClusterIP Service만 |
| 4 | replica를 2 이상으로 늘려도 되는가? | 파일 쓰기 경합·스케줄러 중복 실행·세션 공유 여부 확인. 불가하면 `replicas: 1` + 사유 주석 |
| 5 | 기동 순서 의존이 있는가? (DB, 다른 컴포넌트 선행) | probe의 initialDelay / 재시도 설계 (k8s는 기동 순서를 보장하지 않음 — 앱이 재접속 재시도를 해야 함) |
| 6 | 어떤 런타임인가? (Java/Tomcat, Node, Python 등) | Dockerfile 베이스 이미지, 힙/메모리 설정 방식 |
| 7 | 설정 파일 형식과 위치는? | ConfigMap 마운트 경로, 민감정보의 Secret 분리 범위 |
| 8 | 파일을 읽고 쓰는 경로가 있는가? (업로드, 로그, 임시파일) | NAS 마운트 필요 여부, subPath 구조 |
| 9 | 어떤 외부 시스템과 통신하는가? (DB, CTI, 타 기관 연계 등) | ACG/방화벽 신청 목록, hostAliases 필요 여부, 고정 출구 IP(NAT) 필요 여부 |
| 10 | 리소스 사용량은? (평시/피크 CPU·메모리) | requests/limits 산정. 모르면 기존 VM에서 `top`/모니터링으로 실측 후 산정 |

---

## 2. 컴포넌트별로 새로 만들어야 하는 것

### 2.1 이미지 (Dockerfile + 빌드)

- **이미지 이름 결정**: `<NCR주소>/aicc-<컴포넌트명>:<태그>` 규칙 유지.
  NCR 콘솔에서 **리포지토리를 먼저 생성**해야 push 가능.
- **Dockerfile**: 기존 것은 Tomcat 전용입니다. 새 컴포넌트가 Tomcat WAS라면 재사용 가능하지만,
  다른 런타임이면 새로 작성합니다. 공통으로 지켜야 할 것:
  - `TZ=Asia/Seoul`, `LANG=ko_KR.UTF-8` (로그 시간/한글 처리 — 기존 Dockerfile과 동일하게)
  - 설정 디렉토리와 NAS 마운트 포인트를 이미지 경로 규칙에 맞춤
  - 포트는 **1024 이상**(예: 8080) 사용 — 80 포트는 root 실행을 강제하므로 지양
    (admin의 80 포트가 기존 이슈, `PROJECT-REVIEW.md` 3.1)
- **build-push.sh 확장**: 기존 스크립트는 `HOME_OF` 배열에 역할별 원본 경로를 정의하는 구조라
  Tomcat 앱이면 항목 추가로 끝납니다. 다른 방식(WAR/JAR/바이너리 COPY)이면 컴포넌트 전용
  빌드 스크립트를 작성하되, **NCR 주소·TAG 변수 규칙은 동일하게** 유지하십시오.
- 가능하면 신규 컴포넌트부터는 "운영 VM에서 tar로 뜯어오기" 대신 **빌드 산출물(WAR/JAR)만
  COPY하는 재현 가능한 빌드**로 시작하는 것을 권장합니다 (`PROJECT-REVIEW.md` 3.5).

### 2.2 설정 주입 (ConfigMap / Secret)

- **ConfigMap**: 컴포넌트 전용으로 분리 생성 권장 (예: `aicc-<컴포넌트명>-config`).
  기존 `aicc-config`에 파일만 추가할 수도 있으나, 컴포넌트별 배포/롤백 독립성을 위해 분리가 낫습니다.
  `10-make-configmap.sh`를 참고해 컴포넌트용 스크립트를 만들되, **NAS 경로 치환 규칙**
  (`/mnt/aiccnas/...`)을 동일하게 적용합니다.
- **Secret**: 복호화 키·API 키·평문 비밀번호는 반드시 Secret으로.
  - 기존 `aicc-secret`(JASYPT 키)을 같이 쓸지, 컴포넌트 전용 Secret을 만들지 결정.
    **암호화 키가 다르면 반드시 별도 Secret**으로 분리합니다.
- **경로 규칙**: 앱이 설정을 읽는 절대 경로(예: `/usr/local/src/config`)를 확인하고
  volumeMount의 `mountPath`를 거기에 맞춥니다. 마운트하면 **해당 디렉토리가 통째로
  덮어써진다**는 점 주의 — 이미지에 들어있던 같은 경로의 다른 파일은 사라집니다.

### 2.3 Deployment 매니페스트 (`k8s/3x-deployment-<컴포넌트명>.yaml`)

기존 30/31번 파일을 템플릿으로 복사한 뒤 아래를 컴포넌트에 맞게 수정:

| 항목 | 체크 내용 |
|------|-----------|
| `name` / `labels` / `selector` | `aicc-<컴포넌트명>`으로 통일. **selector와 template labels 불일치 시 배포 실패** |
| `image` | 새 이미지 주소:태그 |
| `containerPort` | 앱 실제 리슨 포트 (admin처럼 매니페스트·이미지 간 포트 불일치 만들지 말 것) |
| `env` | 앱이 요구하는 환경변수 전수 조사 (기동 스크립트·properties에서 `${...}` 참조 검색). Secret 참조로 주입 |
| `resources` | 실측 기반 산정. **Java라면 힙 크기 ≤ memory request**가 되도록 (기존 이슈: 힙 2G vs request 1.5Gi, `PROJECT-REVIEW.md` 3.2) |
| `readinessProbe` | 앱의 헬스 응답 경로 필요. 전용 health 엔드포인트가 없으면 컨텍스트 루트로. **기동 시간 실측 후** initialDelay 설정 (미확인 시 CrashLoop처럼 보이는 재시작 반복 발생) |
| `livenessProbe` | readiness보다 넉넉하게. 기동이 느린 앱은 `startupProbe` 도입 검토 |
| `imagePullSecrets` | 기존 `ncr-aicc-dev` 재사용 (같은 NCR이면 추가 작업 없음) |
| `hostAliases` | 앱이 **IP가 아닌 도메인으로 호출하는 내부 시스템**이 있는지 확인 (기존 CTI 사례). 있으면 항목 추가, 없으면 통째로 제거 |
| 로그 volumeMount | 로그를 NAS로 뺄 경우 `subPathExpr: "logs/<컴포넌트명>/$(POD_NAME)"` 규칙 유지 — **컴포넌트별 하위 디렉토리 분리** 필수 (admin/agent와 섞이지 않게). 앱의 로그 출력 경로가 마운트 지점과 일치하는지 확인 |
| NAS volumeMount | 업로드 등 공유 파일 경로가 있으면 기존 `aicc-nas-pvc` 재사용. **경로가 admin/agent와 겹치지 않는지** 확인 (`/mnt/aiccnas/<컴포넌트명>/...` 권장) |

- **HTTP 서비스가 아닌 배치성 작업**이면 Deployment 대신 `CronJob`/`Job`을 사용하고
  Service/Ingress/probe는 생략합니다.

### 2.4 Service (`k8s/40-service.yaml`에 추가 또는 별도 파일)

- `aicc-<컴포넌트명>` Service 추가. selector가 새 Deployment 라벨과 일치하는지 확인.
- **고정 clusterIP / nodePort는 지정하지 말 것** — 기존 파일의 고정값은 정리 대상 이슈이며
  (`PROJECT-REVIEW.md` 2.3), 새로 추가하는 컴포넌트부터는 자동 할당 + DNS 이름
  (`aicc-<컴포넌트명>.aicc.svc`) 호출을 기본으로 합니다.
- 외부 노출 컴포넌트면 ALB 헬스체크 어노테이션을 **처음부터** 넣습니다:
  `alb.ingress.kubernetes.io/healthcheck-path: /<컨텍스트>/` (admin 누락 사례 재발 방지).
- 내부 전용 컴포넌트면 `ClusterIP` 타입으로 충분하며 Ingress 등록은 하지 않습니다.

### 2.5 Ingress (`k8s/50-ingress.yaml`)

외부 노출이 필요한 경우만 해당:

- 기존 Ingress의 `rules.paths`에 경로 추가 (예: `/newcomp` → `aicc-newcomp:8080`).
  같은 ALB를 공유하므로 **새 ALB가 생기지 않고 기존 ALB에 규칙만 추가**됩니다.
- **경로 충돌 확인**: `pathType: Prefix`라서 기존 `/agent`, `/admin`과 겹치는
  접두어(예: `/admin2` 는 안전하지만 `/agent/sub` 은 기존 규칙에 흡수됨)를 피합니다.
- 앱의 **컨텍스트 패스가 Ingress 경로와 일치**해야 합니다. 앱이 루트(`/`)로 서비스하는데
  Ingress가 `/newcomp`로 보내면 404 — 앱 쪽 컨텍스트 조정 또는 rewrite 지원 여부 확인 필요.
- 별도 도메인/별도 ALB가 필요한 경우에만 새 Ingress를 만들며, 이때는 subnet-id·인증서 번호 등
  `NKS-MIGRATION-GUIDE.md` §2.7의 값들이 다시 필요합니다.

### 2.6 스토리지 (필요 시)

- **기존 NAS 공유로 충분한 경우** (로그, 업로드): 새 PV/PVC 없이 `aicc-nas-pvc` 재사용.
  NAS 안에서 컴포넌트 전용 디렉토리만 규칙에 맞게 분리합니다.
- **전용 볼륨이 필요한 경우** (대용량, I/O 격리, 다른 NAS 볼륨): `00-pvc.yaml`을 템플릿으로
  PV/PVC 쌍을 새로 작성 — NAS 볼륨 생성, 마운트 IP/경로, 워커노드 ACL 허용까지 세트로 필요.
- **단일 Pod 전용 블록 스토리지**가 필요하면 NKS 기본 StorageClass(Block Storage CSI)로
  동적 프로비저닝을 쓰되, `ReadWriteOnce`라서 replica 2 이상 불가함을 인지해야 합니다.

---

## 3. 매니페스트 밖에서 확인/신청해야 하는 것

| 항목 | 확인 내용 |
|------|-----------|
| **NCR 리포지토리** | `aicc-<컴포넌트명>` 리포지토리 생성 (push 전 필수) |
| **노드 용량** | 현재 노드 여유가 새 컴포넌트 requests를 수용하는지 (`kubectl describe nodes`로 Allocated 확인). 부족하면 노드 증설/스케일업 선행 |
| **ACG/방화벽** | 새 컴포넌트가 통신하는 대상 전수 조사 후 신청: 워커노드 대역 → DB/CTI/외부기관 등. **아웃바운드에 고정 IP가 필요한 연계**(상대 기관이 IP 화이트리스트 요구)가 있으면 NAT Gateway 경유 여부 확인 |
| **DB 계정/권한** | 새 컴포넌트용 DB 계정·스키마 권한. CloudDB ACG에 워커노드 대역 허용 |
| **인바운드 호출자** | 이 컴포넌트를 **호출하는 쪽**이 어디인지 — 클러스터 내부(Service DNS로 호출 경로 변경 안내), VPC 내 VM(ALB 또는 Service 노출 방식 결정), 외부(도메인/DNS/인증서) |
| **기존 컴포넌트와의 연동 변경** | admin/agent가 이 컴포넌트를 호출한다면 properties의 대상 주소를 VM IP → `aicc-<컴포넌트명>.aicc.svc` 또는 ALB 경로로 변경 → ConfigMap 재생성 + 기존 Pod 재기동 필요 |
| **세션/이중화 인프라** | 세션 클러스터링, 분산 락 등이 필요하면 Redis 등 별도 인프라 검토 (NAS로는 해결 안 됨) |
| **모니터링/알람** | 새 컴포넌트의 로그 위치(NAS 경로), 헬스 URL을 운영 모니터링에 등록 |

---

## 4. 온보딩 작업 순서 체크리스트

```text
[ ] 1. §1 설계 질문 답변 정리 (워크로드 종류, 노출 범위, replica 정책, 리소스 실측)
[ ] 2. NCR 리포지토리 생성 + Dockerfile 작성/검증 (로컬 docker run으로 기동 확인)
[ ] 3. ACG/방화벽/DB 계정 등 인프라 신청 (리드타임이 길어 가장 먼저 착수 권장)
[ ] 4. 이미지 빌드/푸시 (build-push.sh 확장 또는 전용 스크립트)
[ ] 5. ConfigMap/Secret 생성 (properties 내 주소가 새 환경 기준인지 검증)
[ ] 6. (전용 볼륨 필요 시) NAS 볼륨 + PV/PVC 생성, ACL 허용
[ ] 7. Deployment 적용 → Pod Running/READY, 로그가 NAS 규칙 경로에 쌓이는지 확인
[ ] 8. Service 적용 → 클러스터 내부에서 curl로 응답 확인
       kubectl -n aicc run tmp --rm -it --image=curlimages/curl -- \
         curl -s http://aicc-<컴포넌트명>.aicc.svc:8080/<경로>
[ ] 9. (외부 노출 시) Ingress 경로 추가 → ALB 타겟 healthy 확인 → 도메인 경유 호출 확인
[ ] 10. 연동 검증: DB 연결, 기존 컴포넌트 ↔ 신규 컴포넌트 상호 호출, 파일 업로드/로그
[ ] 11. 문서 갱신: NKS-MIGRATION-GUIDE.md의 변경 대상 표에 새 컴포넌트 값 추가
        (이미지 주소, Ingress 경로, NAS 경로, hostAliases 등 — 다음 환경 전환 때 누락 방지)
```

---

## 5. 기존 구조에서 반복하지 말아야 할 것 (신규 컴포넌트 기준)

`PROJECT-REVIEW.md`에서 지적된 이슈들은 기존 admin/agent에는 남아 있지만,
**새로 추가하는 컴포넌트는 처음부터 아래를 지켜서** 이슈를 늘리지 않습니다.

1. **80 포트 사용 금지** → 8080 등 비특권 포트 + non-root 실행 (`USER` 지정, securityContext)
2. **고정 clusterIP/nodePort 지정 금지** → 자동 할당 + Service DNS 호출
3. **healthcheck-path 어노테이션 누락 금지** → Service 생성 시 처음부터 포함
4. **JVM 힙 > memory request 금지** → `-XX:MaxRAMPercentage` 방식 또는 request 상향
5. **평문 비밀번호의 ConfigMap 저장 금지** → Secret 분리 또는 jasypt ENC() 처리
6. **운영 VM tar 스냅샷 빌드 지양** → 빌드 산출물 COPY 방식으로 시작
7. **이미지에 없는 설정 파일을 리포에 두지 않기** → 리포에 있는 파일은 반드시 Dockerfile에서
   COPY하여 단일 소스 유지 (server.xml 미사용 사례 재발 방지)
