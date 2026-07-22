# NKS 환경 전환 가이드 — 변경 필요 설정값 목록

작성일: 2026-07-22
대상: 새로운 NKS 클러스터(예: 개발계 → 운영계, 또는 신규 클러스터)로 본 프로젝트를 전환 배포할 때
수정해야 하는 모든 환경 의존 값과 사전 준비 작업의 정리.

현재 리포는 값들이 매니페스트/스크립트에 **하드코딩**되어 있으므로, 환경 전환 시 아래 항목을
파일별로 직접 수정해야 합니다. (중장기적으로는 Helm/Kustomize로 값 분리 권장 — `PROJECT-REVIEW.md` 3.6 참고)

---

## 1. 한눈에 보는 변경 대상 요약

| # | 항목 | 현재 값 (개발계) | 위치 | 발급/확인처 |
|---|------|------------------|------|-------------|
| 1 | NCR 레지스트리 주소 | `gcgf-aicc-dev.ncr.gov-ntruss.com` | `build-push.sh`, `k8s/30-*.yaml`, `k8s/31-*.yaml` | NCP 콘솔 > Container Registry |
| 2 | 이미지 태그 | `1.0.0` | `build-push.sh`(TAG), Deployment 2종 | 빌드 시 결정 |
| 3 | imagePullSecret 이름 | `ncr-aicc-dev` | Deployment 2종 | 클러스터에 직접 생성 (§3.2) |
| 4 | 네임스페이스 | `aicc` | k8s 매니페스트 전체, `10-make-configmap.sh` | 클러스터에 직접 생성 (§3.1) |
| 5 | NAS NFS 서버 IP | `169.254.170.73` | `k8s/00-pvc.yaml` | NCP 콘솔 > NAS > 마운트 정보 |
| 6 | NAS 볼륨 경로 | `/n009206_aicc02` | `k8s/00-pvc.yaml` | NCP 콘솔 > NAS |
| 7 | ALB Subnet ID | `"44210"` | `k8s/50-ingress.yaml` | NCP 콘솔 > VPC > Subnet |
| 8 | SSL 인증서 번호 | `"31854"` | `k8s/50-ingress.yaml` | NCP 콘솔 > Certificate Manager |
| 9 | ALB 이름 | `aicc-pri-alb` | `k8s/50-ingress.yaml` | 새 환경 명명 규칙에 맞게 |
| 10 | CTI VIP (hostAliases) | `172.16.90.21` → `uctivip.gcgf.or.kr` | Deployment 2종 | 새 환경의 CTI(nxAdaptor) VIP |
| 11 | Service 고정 clusterIP | `198.19.200.10` / `.11` | `k8s/40-service.yaml` | 새 클러스터의 Service CIDR |
| 12 | 고정 nodePort | `30810` / `30811` | `k8s/40-service.yaml` | 새 클러스터에서 미사용 포트 |
| 13 | 원본 앱 서버 (빌드/설정 소스) | `ubersys@172.16.90.200` | `build-push.sh`, `k8s/10-make-configmap.sh` | 새 환경의 원본 WAS 서버 |
| 14 | JASYPT 암호화 키 | `CHANGE_ME` (예시) | `k8s/20-secret.example.yaml` | 운영 담당자 (앱 암호화 키와 동일해야 함) |
| 15 | properties 내 접속정보 | jdbc.url, upload path 등 | ConfigMap 소스 (`uconnect_*.properties`) | 새 환경 CloudDB/NAS 정보 |

---

## 2. 파일별 상세 설명

### 2.1 `build-push.sh` — 이미지 빌드/푸시

```bash
NCR="gcgf-aicc-dev.ncr.gov-ntruss.com"   # ① 레지스트리 주소
TAG="${TAG:-1.0.0}"                      # ② 이미지 태그
APP_USER="${APP_USER:-ubersys}"          # ③ 원본 서버 SSH 계정
APP_HOST="${APP_HOST:-172.16.90.200}"    # ④ 원본 톰캣이 설치된 서버 IP
```

- **① NCR**: NCP Container Registry의 Private Endpoint 주소. 환경마다 레지스트리가 다르므로
  반드시 교체합니다 (주석대로 운영계는 `-dev` 제거 형태 예상). 새 레지스트리에
  `aicc-agent`, `aicc-admin` 리포지토리가 미리 존재해야 push가 됩니다.
- **② TAG**: 같은 태그로 재빌드하면 노드에 캐시된 구 이미지가 사용될 수 있으므로,
  전환 시점에 새 태그(예: 날짜 기반 `2026.07.22-1`)를 쓰는 것을 권장합니다.
  태그를 바꾸면 Deployment 2종의 `image:` 값도 함께 맞춰야 합니다.
- **③④ APP_USER / APP_HOST**: 이미지는 원본 서버의 톰캣 디렉토리
  (`/usr/local/src/apache-tomcat-9.0.113[-agent]`)를 ssh/tar로 가져와 굽습니다.
  새 환경에서 다른 원본 서버를 쓴다면 IP·계정과 함께 **톰캣 설치 경로**(`HOME_OF` 배열)도
  확인해야 합니다. 빌드 머신에서 해당 서버로 SSH 키 인증 및 sudo 권한이 필요합니다.
- **빌드 머신 사전 조건**: `docker login <새 NCR 주소>` (NCP API 키의 Access Key/Secret Key 사용).

### 2.2 `k8s/00-pvc.yaml` — NAS 정적 프로비저닝 (PV/PVC)

```yaml
nfs:
  server: 169.254.170.73        # ① NAS 마운트 IP
  path: /n009206_aicc02         # ② NAS 볼륨 경로
capacity:
  storage: 100Gi                # ③ 용량 (새 볼륨 크기에 맞춤)
```

- **①②**: NCP 콘솔에서 새 환경용 NAS 볼륨 생성 후, 마운트 정보의 IP와 경로로 교체합니다.
  NAS 계정(n009206)이 바뀌면 경로 접두어도 바뀝니다.
- **NAS ACL(중요)**: NAS 볼륨의 접근 제어에 **새 NKS 워커노드 서브넷 대역을 허용**해야
  마운트가 됩니다. 이걸 빠뜨리면 Pod가 `ContainerCreating`에서 멈춥니다.
- **③ capacity**: PV/PVC 양쪽의 `storage` 값을 동일하게 새 볼륨 크기로 맞춥니다
  (정적 프로비저닝이라 실제 쿼터 강제는 아니지만 PV/PVC 값이 일치해야 바인딩됩니다).
- NCP NAS는 NFSv3 기준이므로 `mountOptions: [vers=3]`은 유지합니다.
- `claimRef.namespace`가 `aicc`로 고정되어 있으므로 네임스페이스명을 바꾸면 여기도 수정.
- 새 NAS 마운트 후 로그 디렉토리 구조(`logs/admin/`, `logs/agent/`, `mms/`, `chat/`)는
  subPathExpr/앱이 생성하지만, 권한 문제가 있으면 최초 1회 수동 생성이 필요할 수 있습니다.

### 2.3 `k8s/10-make-configmap.sh` — 앱 설정(ConfigMap) 생성

```bash
NS=aicc                                   # ① 네임스페이스
APP_USER=... APP_HOST=172.16.90.200       # ② properties 원본 서버
APPLY_JDBC_TLS=0                          # ③ CloudDB SSL 적용 여부
```

- **②**: `uconnect_agent.properties`, `uconnect_admin.properties`를 원본 서버의
  `/usr/local/src/config`에서 가져옵니다. 새 환경의 properties에는 **새 CloudDB 접속정보
  (jdbc.url), 연동 시스템 주소** 등이 들어 있어야 하므로, 파일 내용 자체를 새 환경 값으로
  먼저 검증하십시오. 스크립트가 자동 치환하는 것은 upload 경로 2개
  (`mms.upload.path=/mnt/aiccnas/mms`, `webchat.upload.path=/mnt/aiccnas/chat`)뿐입니다.
- **③ APPLY_JDBC_TLS**: 새 환경 CloudDB에서 SSL이 활성화되어 있으면 `APPLY_JDBC_TLS=1`로
  실행하여 jdbc.url에 `sslMode=REQUIRED`를 추가합니다. CloudDB 쪽 SSL 설정 확인이 선행 조건.
- properties에 평문 비밀번호가 있다면 ConfigMap 대신 Secret으로 분리 검토
  (`PROJECT-REVIEW.md` 3.4).

### 2.4 `k8s/20-secret.example.yaml` — JASYPT 복호화 키

```yaml
stringData:
  JASYPT_ENCRYPTOR_PASSWORD: "CHANGE_ME"
```

- 앱 properties의 `ENC(...)` 값을 복호화하는 키입니다. **새 환경 properties를 암호화할 때
  사용한 키와 동일**해야 합니다 (환경별로 키를 다르게 운영한다면 반드시 교체).
- 예시 파일이므로 실제 값을 넣은 사본은 **git에 커밋하지 말고** `kubectl apply`로만 적용하십시오.

### 2.5 `k8s/30-deployment-agent.yaml` / `31-deployment-admin.yaml` — Deployment

| 항목 | 현재 값 | 설명 |
|------|---------|------|
| `image` | `gcgf-aicc-dev.ncr.gov-ntruss.com/aicc-{agent,admin}:1.0.0` | 새 NCR 주소 + 새 태그로 교체 |
| `imagePullSecrets` | `ncr-aicc-dev` | 새 환경용 시크릿 이름으로 교체 (§3.2에서 생성) |
| `hostAliases` | `172.16.90.21 → uctivip.gcgf.or.kr` | 앱이 nxAdaptor(CTI)를 도메인으로 호출하는 것을 강제 우회하는 항목. **새 환경의 CTI VIP IP**로 교체. 새 환경에서 내부 DNS로 해석 가능하면 항목 자체 제거 가능 |
| `resources` | requests 250m/1536Mi, limits 1/3Gi | 새 노드 스펙에 맞게 조정. 현재 JVM 힙 2G 고정(`setenv.sh`)이라 request 1536Mi는 과소 — 전환 시 2.5Gi 이상으로 상향 권장 (`PROJECT-REVIEW.md` 3.2) |
| `replicas` | 1 | 운영계는 가용성 요구에 따라 2 이상 검토. NAS 로그가 `$(POD_NAME)`별로 분리되므로 scale-out 자체는 안전 |
| probe 경로 | `/agent`(8080), `/admin`(80) | 컨텍스트 경로가 바뀌지 않으면 유지. admin은 80 포트(root 필요) — 8080 통일 권장 이슈 있음 |

### 2.6 `k8s/40-service.yaml` — Service

```yaml
clusterIP: 198.19.200.10 / .11    # ① 고정 클러스터 IP
nodePort: 30810 / 30811           # ② 고정 노드포트
```

- **① clusterIP**: 새 클러스터의 **Service CIDR이 다르면 생성이 실패**합니다.
  새 클러스터 CIDR 내 미사용 IP로 교체하거나, IP로 직접 호출하는 곳이 없다면
  고정 IP 라인을 삭제(자동 할당)하는 것이 안전합니다.
- **② nodePort**: 새 클러스터에서 이미 점유된 포트면 충돌합니다. Ingress가
  `target-type: ip`(Pod 직접 라우팅)라 NodePort 자체가 사실상 불필요 —
  전환을 기회로 `ClusterIP` 타입으로 단순화 검토 (`PROJECT-REVIEW.md` 2.3).
- agent Service에만 있는 `alb.ingress.kubernetes.io/healthcheck-path` 어노테이션을
  admin에도 추가 권장 (`/admin/`). 누락 시 ALB 헬스체크가 `/`로 나가 404 → unhealthy 가능.

### 2.7 `k8s/50-ingress.yaml` — ALB Ingress

```yaml
alb.ingress.kubernetes.io/network-type: private        # ① ALB 타입
alb.ingress.kubernetes.io/subnet-id: "44210"           # ② ALB 배치 서브넷
alb.ingress.kubernetes.io/load-balancer-name: aicc-pri-alb   # ③ ALB 이름
alb.ingress.kubernetes.io/ssl-certificate-no: "31854"  # ④ 인증서 번호
```

- **② subnet-id**: **새 VPC의 로드밸런서 전용 서브넷 ID**로 교체. NCP 콘솔 > VPC > Subnet에서
  확인하며, 반드시 Load Balancer 타입 서브넷이어야 합니다. (private ALB이므로 private LB 서브넷)
- **④ ssl-certificate-no**: 새 환경(리전/계정)의 Certificate Manager에 인증서를 먼저
  등록/발급하고 그 번호로 교체합니다. 인증서 번호는 **계정·리전 종속**이라 그대로 못 씁니다.
  도메인이 바뀌면(예: 운영 도메인) 해당 도메인의 인증서가 필요합니다.
- **① network-type**: 외부 공개가 필요한 환경이면 `public`으로 변경 (보안 검토 필수).
- **③**: 새 환경 명명 규칙에 맞게 변경 (예: `aicc-prd-alb`).
- 전제: 새 NKS 클러스터에 **NCP ALB Ingress Controller가 설치**되어 있어야 하며
  (`ingressClassName: alb`), 미설치 시 NCP 가이드에 따라 먼저 설치합니다.

### 2.8 `Dockerfile` / `setenv.sh` — 이미지 내부 설정

- 환경 전환 시 직접 바꿀 값은 없지만, `setenv.sh`의 힙 크기(`-Xms2048m -Xmx2048m`)는
  새 노드/리소스 스펙에 맞춰 조정 대상입니다 (limit 3Gi 기준
  `-XX:MaxRAMPercentage=60.0` 방식 권장).
- `JASYPT_ENCRYPTOR_PASSWORD`는 이미지에 없고 Secret → env로 주입되므로 이미지 재빌드 불필요.
- 주의: `server.xml`은 현재 Dockerfile에서 COPY하지 않아 **미사용**입니다. 실제 포트 설정은
  원본 서버 톰캣의 `conf/server.xml`을 따르므로, 새 원본 서버에서 tar를 뜰 때
  그 서버의 server.xml 포트(agent 8080 / admin 80)가 그대로 이미지에 들어갑니다.

---

## 3. 매니페스트에 없는 사전 준비 작업 (수동)

아래는 리포의 어떤 파일에도 선언되어 있지 않아 **새 클러스터에서 수동으로 먼저** 해야 하는 작업입니다.

### 3.1 네임스페이스 생성

```bash
kubectl create namespace aicc
```

### 3.2 NCR imagePullSecret 생성

```bash
kubectl -n aicc create secret docker-registry ncr-aicc-dev \
  --docker-server=<새 NCR 주소> \
  --docker-username=<NCP API Access Key> \
  --docker-password=<NCP API Secret Key>
```

시크릿 이름을 바꾸면 Deployment 2종의 `imagePullSecrets`도 함께 수정합니다.
(운영계라면 `ncr-aicc-prd` 등으로 명명 권장)

### 3.3 인프라/네트워크 체크리스트

| 항목 | 확인 내용 |
|------|-----------|
| NKS 클러스터 | 노드 스펙이 리소스 요구(Pod당 limit 3Gi × 2종 + 여유)를 수용하는지 |
| ALB Ingress Controller | 새 클러스터에 설치되어 있는지 (`kubectl get pods -n kube-system \| grep alb`) |
| NAS | 새 볼륨 생성 + 워커노드 서브넷 ACL 허용 + NFSv3 |
| CloudDB (MySQL) | 새 DB 접속정보 확보, ACG에 워커노드 대역 허용, SSL 여부 확인(→ `APPLY_JDBC_TLS`) |
| CTI(nxAdaptor) | 새 환경에서 `uctivip.gcgf.or.kr`이 가리켜야 할 VIP 확인, 워커노드 → CTI 방화벽/ACG 허용 |
| Certificate Manager | 새 도메인 인증서 등록, 인증서 번호 확보 |
| DNS | 서비스 도메인을 새 ALB의 도메인/IP로 변경 (전환 시점에) |
| NCR | 새 레지스트리 생성 + `aicc-agent`/`aicc-admin` 리포지토리 준비 |

---

## 4. 전환 배포 순서

```bash
# 0. (사전) §3의 수동 작업 + §2의 파일 값 수정 완료

# 1. 이미지 빌드/푸시 (새 NCR, 새 태그)
TAG=<새태그> ./build-push.sh

# 2. 스토리지
kubectl apply -f k8s/00-pvc.yaml
kubectl -n aicc get pvc aicc-nas-pvc        # STATUS=Bound 확인

# 3. 앱 설정
./k8s/10-make-configmap.sh                  # 필요 시 APPLY_JDBC_TLS=1
kubectl apply -f <실제 값을 넣은 secret.yaml>   # 20-secret.example.yaml 사본

# 4. 워크로드
kubectl apply -f k8s/30-deployment-agent.yaml -f k8s/31-deployment-admin.yaml
kubectl -n aicc get pods -w                 # Running + READY 1/1 확인

# 5. 노출
kubectl apply -f k8s/40-service.yaml -f k8s/50-ingress.yaml
kubectl -n aicc get ingress                 # ALB 주소 발급 확인 (수 분 소요)
```

### 배포 후 검증

- `https://<ALB주소>/agent`, `/admin` 응답 확인 (ALB 타겟 헬스체크 healthy 확인 포함)
- Pod 로그가 NAS의 `logs/{agent,admin}/<pod명>/`에 쌓이는지 확인
- DB 연결 확인 (jasypt 복호화 실패 시 기동 로그에 예외 발생 → Secret 키 불일치 의심)
- CTI 연동 확인 (`hostAliases` IP가 맞는지 — Pod 안에서 `getent hosts uctivip.gcgf.or.kr`)
- MMS/웹챗 업로드가 `/mnt/aiccnas/{mms,chat}`에 저장되는지 확인

---

## 5. 자주 겪는 전환 실패 원인

| 증상 | 원인 |
|------|------|
| Pod `ContainerCreating`에서 멈춤 | NAS ACL에 새 워커노드 대역 미허용, 또는 PVC 미바인딩 |
| `ImagePullBackOff` | imagePullSecret 미생성/이름 불일치, NCR 주소 오타, 리포지토리 없음 |
| Service 생성 실패 | 고정 `clusterIP`가 새 클러스터 Service CIDR 밖이거나 충돌 |
| ALB 미생성 | subnet-id가 LB 타입 서브넷이 아님, ALB Ingress Controller 미설치, 인증서 번호 오류 |
| ALB 타겟 unhealthy | healthcheck-path 미설정(admin), 앱 기동 지연(probe initialDelay 조정) |
| 앱 기동 중 복호화 예외 | JASYPT 키가 properties 암호화 키와 불일치 |
| DB 연결 실패 | CloudDB ACG 미허용, jdbc.url이 구 환경 값, SSL 설정 불일치 |
| CTI 호출 실패 | hostAliases IP가 구 환경 VIP, 방화벽 미허용 |
