# U IVR 온프레미스 배포 가이드

이 `deploy/` 디렉토리는 Kubernetes 클러스터 기준의 **자체완결** 배포 번들이다.
기본 네임스페이스(`aicc`)를 쓰며, 테스트 환경(Docker Hub private repo), 사내 레지스트리(Harbor 등),
오프라인 폐쇄망(직접 docker load) 환경에 모두 대응한다.

IVR 고유 리소스:
- ConfigMap: `configmap/aicc-<GROUP>-ivr-config` (+ 선택 `aicc-<GROUP>-ivr-confd`, `aicc-<GROUP>-ivr-flows`)
- Secret: `secret/aicc-ivr-secret` (+ 선택 `aicc-ivr-channels`)
- Storage: `pvc/aicc-ivr-pvc`
- Workload: `statefulset/aicc-<GROUP>-ivr-<SITE>` (기본 `aicc-shr-ivr-a`) — 컨테이너 `ivr` + `nodered`
- Network: `svc/aicc-<GROUP>-ivr` (Node-RED 1890) + Headless `aicc-<GROUP>-ivr-<SITE>-hl`, 선택 `ingress/aicc-<GROUP>-ivr-nodered`

```text
deploy/
├── DEPLOY.md
├── deploy.env.example          # 통합 배포 환경 설정 템플릿 (IP·노드명·이미지 변수화)
├── deploy.sh                   # 원클릭 배포 (render / diff / apply / delete)
├── 00-pvc.yaml                 # aicc-ivr-pvc (subPath ivr/log, ivr/backup, ivr/voice, nodered, 선택 ivr/record)
├── 10-make-configmap.sh        # config/ivr.env → aicc-<GROUP>-ivr-config, conf.d/ → -confd, flows.d/flows.json → -flows
├── config/ivr.env              # TUI 입력값 (비밀 제외) — 두 컨테이너 공용
├── conf.d/                     # (선택) $NEXUS_HOME/config 파일 통째 교체
├── flows.d/                    # (선택) 사이트 시나리오 flows.json
├── 20-secret.example.yaml      # aicc-ivr-secret (DB 비밀번호·Node-RED 키/관리자 해시), aicc-ivr-channels (내선 목록)
├── 30-statefulset.yaml         # aicc-<GROUP>-ivr-<SITE> (replicas 1, hostNetwork, 2 컨테이너)
├── 40-service.yaml             # ClusterIP aicc-<GROUP>-ivr + Headless
└── nodered-ingress.yaml.template  # (선택) Node-RED 편집기 Ingress (NODERED_DOMAIN 지정 시)
```

- **테스트 환경 (Docker Hub Private)**: `jibeom/aicc:ivr-2.0.2.108-1`, `jibeom/aicc:ivr-nodered-2.0.2.108-1`
- **사내 Harbor**: `harbor.dev.com/aicc/aicc-ivr:<TAG>`, `.../aicc-ivr-nodered:<TAG>` (`REG=harbor.dev.com/aicc PUSH=1 ./build.sh`)
- **오프라인 폐쇄망**: `docker save` 로 반출 후 노드에서 `docker load` (또는 `ctr -n k8s.io image import`), `IMAGE_PULL_SECRET=` 비움

---

## 0. 사전 조건

| 대상 | 내용 |
|---|---|
| DB | `aicc-db`(db-build) 또는 외부 MariaDB. `nexus` 계정에 `CREATE DATABASE` 권한 필요 — **`uivr` DB·테이블은 IVR 이 첫 기동에 직접 만든다** (설치 스크립트 원격 DB 경로와 동일) |
| CTI | `aicc-cti`(cti-build) — IVR 이 CTI 9714(`sys_uivr`)로 접속. CTI 없이도 기동은 된다(`CCSEDOWN` 로그) |
| PBX | U PBX SIP IP (`IVR_SIP_REMOTE_IP`). PBX 측에 IVR 내선(기본 샘플 211001 등) 등록 필요 |
| 노드 | hostNetwork 로 노드 포트를 직접 쓴다 → 노드에서 **UDP 9060, UDP 36384~(RTP), TCP 1890, TCP 1900** 이 비어 있어야 함. PBX 와 같은 노드면 PBX RTP 범위(16384~)와 충돌 확인 |

## 1. 통합 환경 설정 (deploy.env)

```bash
cp deploy.env.example deploy.env
vi deploy.env
```

| 변수 | 기본값 | 설명 |
|---|---|---|
| `NS` / `GROUP` / `SITE` | `aicc` / `shr` / `a` | 리소스 이름 `aicc-<GROUP>-ivr-<SITE>` |
| `IVR_DB_HOST` / `IVR_DB_PORT` | `aicc-db` / `3316` | uivr DB |
| `IVR_SIP_REMOTE_IP` | (필수) | U PBX SIP IP. 비우면 127.0.0.1(PBX 동거) 로 기록되고 경고 |
| `IVR_CTI_HOST1` | `aicc-cti` | CTI Active |
| `TARGET_NODE_NAME` | `""` | IVR IP(=노드 IP) 고정 노드 → `nodeSelector` 자동 주입 |
| `ENABLE_HOST_NETWORK` | `true` | SIP/RTP 직접 통신 |
| `IVR_IMAGE` / `NODERED_IMAGE` | Docker Hub 테스트 이미지 | MP3 멘트 업로드가 필요하면 `…-ffmpeg` 이미지 |
| `IMAGE_PULL_SECRET` | `regcred` | 빈 값이면 imagePullSecrets 제거(폐쇄망) |
| `NODERED_DOMAIN` | `""` | 지정 시 편집기 Ingress(Traefik) 생성 |

명령행 환경변수가 `deploy.env` 보다 우선한다: `GROUP=ded1 SITE=b TARGET_NODE_NAME=k8s-02 ./deploy.sh`.
`config/ivr.env` 의 나머지(REALM, RTP 시작 포트, MAX CALL, CTI Standby·SID 등)는 그 파일에서 직접 수정한다.

## 2. Secret

```bash
kubectl create namespace aicc        # 이미 있으면 생략

# 레지스트리 인증 (Docker Hub / Harbor). 폐쇄망은 생략하고 IMAGE_PULL_SECRET="" 
kubectl -n aicc create secret docker-registry regcred \
  --docker-server=https://index.docker.io/v1/ --docker-username=<ID> --docker-password=<TOKEN>

cp 20-secret.example.yaml 20-secret.yaml      # 실값 기입 (커밋 금지)
vi 20-secret.yaml
```
- `IVR_DB_PASSWORD`: db-build `NEXUS_DB_PASSWORD` 와 동일.
- `NODERED_CREDENTIAL_SECRET`: Node-RED 자격증명 암호키. **한 번 정하면 바꾸지 않는다** (바꾸면 PVC 의 `flows_cred.json` 을 복호화하지 못해 편집기에서 DB 계정을 다시 입력해야 함).
- `NODERED_ADMIN_PASSWORD_HASH`(선택): 편집기 `admin` 비밀번호 bcrypt 해시. 비우면 패키지 기본 `admin / nexus62402580!` — 운영은 교체 필수. 생성 명령은 파일 주석 참조.
- `aicc-ivr-channels`(선택): 내선 목록 `e164.txt`. 없으면 `IVR_ID=1` 에 한해 패키지 테스트 내선 8개를 등록(설치 스크립트와 동일). `IVR_ID≥2` 는 등록하지 않음 — 매뉴얼대로 DB 에서 직접 설정하거나 이 Secret 사용.

## 3. 배포

```bash
./deploy.sh render     # 렌더링 확인 (dry-run)
./deploy.sh apply      # PVC → ConfigMap → Secret → StatefulSet → Service (→ Ingress)
# ./deploy.sh diff | delete     (delete 는 PVC·Secret·uivr DB 를 남김)
```

## 4. 검증

```bash
kubectl -n aicc rollout status statefulset/aicc-shr-ivr-a          # startupProbe: DB 대기 포함 최대 4분
kubectl -n aicc logs aicc-shr-ivr-a-0 -c ivr | grep -v '^\[nxst'     # Configuration 요약 → "기동 완료"
kubectl -n aicc logs aicc-shr-ivr-a-0 -c nodered | tail              # "플로우 시작됨"

# 엔진 프로세스 (매뉴얼 ./nxstart.sh status 와 동일)
kubectl -n aicc exec aicc-shr-ivr-a-0 -c ivr -- nxstart.sh status

# 오늘 로그 (별칭 golog / ivrlog / calllog / medialog 사용 가능)
kubectl -n aicc exec -it aicc-shr-ivr-a-0 -c ivr -- bash
# [ivr@<노드> /home/ivr/nexus/bin]$ golog; ls          → *_nxivrcall *_nxivrmedia *_sip NXWATCHDOG
# [ivr@<노드> /home/ivr/nexus/bin]$ vi ../config/nxivrmedia.json

# DB 등록 확인 (매뉴얼 표와 동일한 형태)
kubectl -n aicc exec aicc-shr-ivr-a-0 -c ivr -- bash -c \
 'MYSQL_PWD=$IVR_DB_PASSWORD mariadb -h$IVR_DB_HOST -P$IVR_DB_PORT -u$IVR_DB_USER uivr -e "select * from t_ivr_scenario_server; select e164,service_type,server_id,ivr_id from t_ivr_channel"'
```
편집기: `http://<노드IP>:1890/` (또는 `NODERED_DOMAIN`). CONFIG 탭의 DB 노드(uivr / JEDAI_CUBE)는 첫 기동에 env 로 이미 설정되어 있다 — 매뉴얼의 "Unlock 후 DB_SERVER 입력" 단계 불필요.
기본 시나리오는 CTI 정보(헌트번호·대표번호·Call ID)가 있는 호만 처리한다 — PBX 내선에서 IVR 내선으로 직접 걸어 테스트하려면 Start 노드 유효성 항목을 매뉴얼대로 조정.

## 5. 운영

| 작업 | 방법 |
|---|---|
| 설정 변경 (PBX IP, MAX CALL 등) | `config/ivr.env` 수정 → `./10-make-configmap.sh` → `kubectl -n aicc rollout restart statefulset/aicc-shr-ivr-a`. 기동 시 `t_ivr_config`/`t_ivr_cti` 의 env 관리 컬럼만 갱신되고 U-Admin 에서 바꾼 다른 컬럼은 유지 |
| 엔진 패치 | `PATCH_TAR=nxivr.tar.gz ./build.sh` → 새 태그로 `IVR_IMAGE` 교체 → apply (Node-RED 이미지는 그대로) |
| 멘트 추가 | 편집기 멘트 업로드 도구(WAV, MP3 는 `-ffmpeg` 이미지) → PVC `ivr/voice` 에 저장되어 엔진이 바로 사용. 또는 `SITE_DIR` 빌드로 이미지에 포함 |
| 시나리오 | 편집기에서 Deploy → PVC `nodered` 에 보존. git 관리하려면 `flows.d/flows.json` + `NODERED_FLOWS_MODE=configmap` |
| 노드 이전 | IP 가 바뀌어도 기동 시 `t_ivr_config.local_sip_ip`·이 IVR 의 `t_ivr_scenario_server.ip` 자동 갱신. 단 PBX 측 내선 등록은 새 IP 로 REGISTER 될 때까지 대기 |
| IVR 증설 | `config/ivr.env` 를 복사해 `IVR_ID=2` 로 바꾼 별도 GROUP/SITE 배포(`SITE=b`), 다른 노드에 고정. 같은 노드 불가(hostNetwork 포트 충돌) |

## 6. 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| `IVR_DB_PASSWORD 미주입` 로 ivr 즉시 종료 | `aicc-ivr-secret` 미적용·키 이름 오타 |
| `DB … 접속 불가 (120s)` | `IVR_DB_HOST/PORT`, NetworkPolicy, aicc-db 기동 상태. 파드 내 `mariadb -h…` 로 확인 |
| `CREATE DATABASE uivr 실패` | `nexus` 계정 권한 — db-build 는 `ALL ON *.*` 로 생성됨 |
| `내선 … 이미 존재 — 건너뜀` | 다른 IVR_ID 가 같은 내선 사용 (t_ivr_channel PK). 매뉴얼 IVR_ID=2 중복 오류와 같은 상황 — 정상 |
| ready 안 됨 (`SIP port 9060 not bound`) | 노드에서 9060 을 다른 프로세스가 사용 (PBX 등) → `IVR_SIP_LOCAL_PORT` 변경 |
| `_sip` 로그에 REGISTER 만 반복 | PBX 미도달·내선 미등록·비밀번호 불일치. `IVR_SIP_REMOTE_IP`, PBX 내선 설정 확인 |
| `_nxivrcall` 에 `CCSEDOWN` 반복 | CTI 9714 미도달 — `IVR_CTI_HOST1`, CTI 의 sys_uivr 리스너(1214) 확인 |
| nodered `Failed to decrypt credentials` | `NODERED_CREDENTIAL_SECRET` 이 바뀜 → 원래 값으로 되돌리거나 PVC `nodered/flows_cred.json` 삭제 후 재기동(재시딩) |
| MP3 업로드 후 g711 미생성 | 기본 이미지의 ffmpeg 는 WAV 전용 shim. `WITH_FFMPEG=1` 이미지 사용 |
| 편집기 팔레트 관리 불가 | 설계상 npm 미포함(불변 이미지). 노드 추가는 이미지 재빌드 |

## 7. 운영 원칙

- 같은 이미지를 모든 환경에서 사용 — 환경 차이는 `deploy.env`·`config/ivr.env`·Secret 으로만 주입.
- 리터럴 IP·노드명을 형상관리 파일에 하드코딩하지 않음.
- `replicas: 1` 고정 (IVR_ID 1개 = 파드 1개). 태그 재사용 금지(내용 변경 시 `REV=2`).
- `20-secret.yaml`·`deploy.env` 실값은 private 환경에서만 보관.
