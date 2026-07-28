# 설치 패키지 기반 이미지 빌드 가이드 (U-Agent v6.3.2.023)

작성일: 2026-07-28
대상: `U-Agent_install_Package_v6.3.2.023_20260121_EL9` 설치 패키지를 소스로
NKS용 `aicc-agent` 컨테이너 이미지를 빌드·배포하는 절차.

기존 `build-push.sh`는 **원본 서버(172.16.90.200)에 SSH 접속**하여 설치·운영 중인
톰캣 디렉토리를 통째로 가져와 이미지를 굽습니다. 본 가이드는 그 대신
**벤더가 배포한 설치 패키지의 커스텀 톰캣 + war**를 소스로 사용합니다.

---

## 1. 왜 이 방식인가

### 1.1 "순정 톰캣 베이스 + war"가 안 되는 이유

패키지의 war를 공식 `tomcat` 이미지에 얹는 것만으로는 기존과 동일하게 동작하지
않습니다. 앱이 톰캣 디렉토리 안의 커스텀 파일들에 의존하기 때문입니다.

| 항목 | 내용 | 빠졌을 때 증상 |
|---|---|---|
| `conf/server.xml` | HTTP 8080 + HTTPS 9443 커넥터(keystore 경로·비밀번호 내장), shutdown 8004 | 9443 커넥터 미기동, 포트 구성 상이 |
| `keystore/` | server/client JKS·PEM 인증서 일체 | HTTPS 커넥터 기동 실패, 외부 wss 연동 오류 가능 |
| `conf/redis-data-cache.properties` | 앱이 톰캣 conf에서 읽는 Redis 캐시 설정 | Redis 데이터 캐시 연동 실패 |
| `webapps/ROOT/` | error.jsp, Noto 폰트, robots.txt (mms 업로드 경로의 부모) | 에러 페이지·폰트 누락 |
| `bin/setenv.sh` | jasypt 키, 힙 옵션 | 암호화 설정 복호화 실패로 기동 불가 |
| 한국어 로케일/폰트 | 공식 tomcat 이미지에 없음 | 리포트·이미지 렌더링, 인코딩 문제 |

### 1.2 기존 방식(원본 서버 SSH) 대비 장점

- **원본 서버 의존 제거**: 빌드 머신에서 원본 WAS 서버로의 SSH 키/sudo 권한이 불필요.
  패키지 파일만 있으면 어디서든 재현 가능한 빌드.
- **버전 이력 명확**: 이미지 소스가 "운영 서버의 현재 상태"가 아니라 벤더 릴리스
  패키지이므로, 태그와 패키지 버전이 1:1로 대응.
- **원본 서버 오염 없음**: 운영 중 서버에서 tar를 뜨는 과정(임시파일 생성, sudo) 자체가 없음.

### 1.3 설치 스크립트(`install_uagent.sh`)와의 대응 관계

패키지의 설치 스크립트가 VM에서 하는 일 중 컨테이너에 필요한 것만 이식합니다.

| install_uagent.sh 동작 | 컨테이너 반영 |
|---|---|
| 커스텀 톰캣 압축 해제 | Dockerfile에서 tarball을 `/opt/tomcat`으로 전개 |
| `agent_v*.war` → `webapps/agent.war` 복사 | Dockerfile `COPY` (이름 반드시 `agent.war` — 컨텍스트 경로 `/agent`) |
| `setenv.sh` 복사 | **패키지 것 대신 리포의 `setenv.sh` 사용** (§3.3 참고) |
| `uconnect_agent.properties` → `/usr/local/src/config` | ConfigMap 마운트 (이미지에 넣지 않음) |
| `nexus.conf`의 `version=` 을 properties에 기록 | ConfigMap 갱신 시 수동 반영 (§4.2) |
| JDK 설치, systemctl/uagent.service, SELinux, firewalld, cronolog | 컨테이너에 불필요 (K8s가 대체) |

> cronolog: 원본 catalina.sh가 로그를 cronolog로 파이프하는 것은 `start` 모드에만
> 해당합니다. 컨테이너는 `catalina.sh run`으로 실행되므로 cronolog 설치가 필요 없습니다.

### 1.4 적용 범위와 한계

- 이 패키지에는 **agent만** 들어 있습니다. `aicc-admin` 이미지는 admin 패키지가
  나오기 전까지 기존 방식(또는 기존 이미지)을 유지합니다.
- 현재 운영 이미지는 v6.3.1.x 계열 앱 기준입니다. 이 가이드로 만드는 이미지는
  **v6.3.2.023의 동작**이 기준이므로, 버전 간 기능 차이는 릴리스 노트와 QA로
  별도 검증해야 합니다. "패키징 차이"와 "앱 버전 차이"를 혼동하지 않도록 주의.

---

## 2. 사전 준비

- 패키지 원본: `U-Agent_install_Package_v6.3.2.023_20260121_EL9/`
  - `uconnect_agent/tomcat/apache-tomcat-9.0.113-agent.tar.gz` — 커스텀 톰캣
  - `uconnect_agent/svc.war/agent_v6.3.2.023_NEXUSAICC.war` — 애플리케이션
  - `uconnect_agent/svc.war/uconnect_agent.properties` — 설정 **템플릿** (QA 값이므로 그대로 쓰지 말 것, §4.2)
  - `nexus.conf` — `version=` 값의 출처
- 빌드 머신: docker, NCR 로그인(`docker login <NCR주소>`)
- NCR에 `aicc-agent` 리포지토리 존재

---

## 3. 이미지 빌드

### 3.1 빌드 컨텍스트 구성

```
build/agent-pkg/
├── Dockerfile.package        # §3.2
├── setenv.sh                 # 리포 루트의 것 복사
├── apache-tomcat-9.0.113-agent.tar.gz
└── agent.war                 # agent_v6.3.2.023_NEXUSAICC.war 를 개명한 것
```

### 3.2 Dockerfile.package

기존 `Dockerfile`과 베이스·환경은 동일하고, 톰캣 소스만 tarball로 바뀝니다.

```dockerfile
FROM rockylinux:9

ENV TZ=Asia/Seoul \
    LANG=ko_KR.UTF-8 \
    LC_ALL=ko_KR.UTF-8 \
    LANGUAGE=ko_KR:ko

RUN dnf -y install java-17-openjdk-headless glibc-langpack-ko tzdata fontconfig \
        google-noto-sans-cjk-ttc-fonts \
 && dnf clean all && rm -rf /var/cache/dnf \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo "$TZ" > /etc/timezone \
 && ln -sfn "$(dirname "$(dirname "$(readlink -f /usr/bin/java)")")" /opt/java

ENV JAVA_HOME=/opt/java \
    CATALINA_HOME=/opt/tomcat \
    PATH=/opt/tomcat/bin:/opt/java/bin:$PATH

# 벤더 설치 패키지의 커스텀 톰캣(server.xml, keystore, redis-data-cache.properties,
# webapps/ROOT 포함)을 그대로 사용. ADD는 tar.gz를 자동 전개한다.
ADD apache-tomcat-9.0.113-agent.tar.gz /opt/
RUN mv /opt/apache-tomcat-9.0.113-agent /opt/tomcat

# install_uagent.sh의 cp_war() 대응 — 컨텍스트 경로 /agent 유지를 위해 이름 고정
COPY agent.war /opt/tomcat/webapps/agent.war

# 패키지의 setenv.sh(VM 전용: JDK 경로 하드코딩, jasypt 평문, OOM restart.sh)를
# 컨테이너용으로 교체 (jasypt 키는 k8s Secret → env 주입)
COPY setenv.sh /opt/tomcat/bin/setenv.sh

RUN mkdir -p /usr/local/src/config /mnt/aiccnas \
 && chmod +x /opt/tomcat/bin/*.sh \
 && rm -rf /opt/tomcat/logs/* /opt/tomcat/work/* /opt/tomcat/temp/* 2>/dev/null || true

EXPOSE 8080
CMD ["/opt/tomcat/bin/catalina.sh", "run"]
```

### 3.3 setenv.sh — 반드시 리포의 것 사용

패키지 동봉본은 컨테이너에서 그대로 쓸 수 없습니다.

| | 패키지 setenv.sh | 리포 setenv.sh (사용할 것) |
|---|---|---|
| JAVA_HOME | `/usr/local/src/jdk-17.0.12` 하드코딩 | `/opt/java` |
| jasypt 키 | 평문 하드코딩 | `${JASYPT_ENCRYPTOR_PASSWORD}` (Secret env) |
| OOM 처리 | `restart.sh` 실행 (VM 전용 경로) | 없음 — Pod 재시작은 K8s 담당 |

### 3.4 빌드 스크립트 예시 (`build-from-package.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

NCR="gcgf-aicc-dev.ncr.gov-ntruss.com"            # [환경전환] 운영은 -dev 제거
TAG="${TAG:-6.3.2.023-1}"                          # 패키지 버전 기반 태그 권장
PKG="${PKG:-$HOME/U-Agent_install_Package_v6.3.2.023_20260121_EL9}"

b="build/agent-pkg"
rm -rf "$b"; mkdir -p "$b"

cp "$PKG/uconnect_agent/tomcat/apache-tomcat-9.0.113-agent.tar.gz" "$b/"
cp "$PKG"/uconnect_agent/svc.war/agent_v*.war "$b/agent.war"
cp setenv.sh Dockerfile.package "$b/"

docker build -f "$b/Dockerfile.package" -t "${NCR}/aicc-agent:${TAG}" "$b"
docker push "${NCR}/aicc-agent:${TAG}"
echo "완료: ${NCR}/aicc-agent:${TAG}"
```

태그는 `1.0.0` 같은 임의 번호 대신 **패키지 버전 기반**(`6.3.2.023-1`)을 사용해
이미지와 벤더 릴리스가 1:1로 대응되게 합니다. 같은 태그 재사용 금지
(노드 캐시 문제 — NKS-MIGRATION-GUIDE §2.1 참고).

---

## 4. 설정(ConfigMap) 갱신

### 4.1 원칙

**패키지의 `uconnect_agent.properties`를 그대로 ConfigMap으로 쓰면 안 됩니다.**
그 파일은 벤더 QA 환경(nexuscommunity.net, 121.170.x.x) 값이 들어간 템플릿입니다.
접속 정보는 현재 환경의 properties를 유지하고, 아래 두 가지만 반영합니다.

### 4.2 반영할 항목

1. **버전 표기**: `nexus.conf`의 `version=` 값(v6.3.2.023 ...)을 properties의
   `version=` 라인에 반영. (VM에서는 `install_uagent.sh`의 `setting_version()`이
   자동으로 하던 작업)
2. **신규 설정 키**: 패키지 템플릿과 현재 운영 properties를 diff하여
   v6.3.2에서 새로 추가된 키가 있는지 확인하고, 있다면 환경에 맞는 값으로 추가.

   ```bash
   diff <(grep -E '^[a-zA-Z]' 패키지/uconnect_agent.properties | cut -d= -f1 | sort) \
        <(grep -E '^[a-zA-Z]' 현재운영/uconnect_agent.properties | cut -d= -f1 | sort)
   ```

3. NKS 전용 치환 유지: `mms.upload.path=/mnt/aiccnas/mms`,
   `webchat.upload.path=/mnt/aiccnas/chat` (`k8s/10-make-configmap.sh`가 하던 치환).

갱신 후 ConfigMap 재생성:

```bash
kubectl -n aicc create configmap aicc-config \
  --from-file=uconnect_agent.properties --from-file=uconnect_admin.properties \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## 5. 배포

1. `k8s/30-deployment-agent.yaml`의 `image:`를 새 태그로 변경
   (`.../aicc-agent:6.3.2.023-1`).
2. ConfigMap을 §4대로 먼저 갱신 (Pod가 새로 뜰 때 읽으므로 이미지보다 먼저).
3. 적용 및 재기동:

```bash
kubectl -n aicc apply -f k8s/30-deployment-agent.yaml
kubectl -n aicc rollout status deploy/aicc-agent
```

admin(`31-deployment-admin.yaml`)은 변경하지 않습니다 (§1.4).

---

## 6. 검증 체크리스트

- [ ] Pod Ready, 재시작 루프 없음 (`kubectl -n aicc get pod -w`)
- [ ] 기동 로그에 jasypt 복호화 오류 없음 (`kubectl logs` — Secret env 주입 확인)
- [ ] `/agent` 로그인 페이지 접속, 화면의 버전 표기가 **v6.3.2.023**인지 확인
- [ ] DB(MariaDB)·Redis 연결 정상 (로그인, 상담화면 진입)
- [ ] `conf/redis-data-cache.properties` 관련 캐시 동작 확인
- [ ] MMS 업로드 → NAS(`/mnt/aiccnas/mms`) 저장 확인, 웹챗 파일 업로드 동일
- [ ] 톰캣 로그가 NAS(`logs/agent/<POD_NAME>`)에 쌓이는지 확인
- [ ] CTI(nxAdaptor)·U-PBX websocket 연동 (hostAliases 경유) 정상
- [ ] v6.3.1 → v6.3.2 릴리스 노트 기준 신규/변경 기능 QA

---

## 7. 보안 참고 사항

기존 방식과 동일한 수준이지만, 알고 있어야 할 항목:

- 커스텀 톰캣 tarball에는 **keystore 개인키와 server.xml 내 keystore 비밀번호**가
  포함되어 이미지에 그대로 들어갑니다. NCR 리포지토리가 private인지 확인.
- 패키지 템플릿 properties에는 벤더 QA의 평문 비밀번호가 들어 있으므로
  ConfigMap 소스로 사용하지 말 것 (§4.1). 평문 비밀번호의 Secret 분리는
  `PROJECT-REVIEW.md` 3.4 참고.
- webapps에 `docs/examples/manager/host-manager`가 포함되어 있다면 운영 이미지에서는
  제거를 검토 (Dockerfile `RUN rm -rf` 한 줄 추가).
