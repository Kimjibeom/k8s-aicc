# U-Agent 설치 패키지 기반 컨테이너 이미지 가이드

작성일: 2026-07-28
대상: 벤더 설치 패키지(`U-Agent_install_Package_v6.3.2.023_20260121_EL9`)를 **수정 없이 그대로**
컨테이너 이미지로 빌드하여 NKS·온프레미스 등 모든 환경에서 공용으로 사용하는 절차.

---

## 1. 목표와 원칙

1. **벤더 전달물 무수정** — war, 커스텀 톰캣(server.xml, keystore, redis-data-cache.properties,
   ROOT 웹앱), setenv.sh, 동봉 JDK를 그대로 사용한다. keystore·9443 HTTPS 커넥터도 유지한다
   (온프레미스에서 LB 없이 직접 HTTPS 서비스하는 경우에 필요).
2. **설치 스크립트(`install_uagent.sh`)의 결과를 컨테이너 안에 그대로 재현** — VM과 동일한
   경로(`/usr/local/src/jdk-17.0.12`, `/usr/local/src/tomcat9_agent`)로 구성한다.
   덕분에 벤더 setenv.sh·restart.sh·properties의 기본 경로가 수정 없이 전부 유효하다.
3. **환경별 차이는 이미지 밖으로** — 이미지는 모든 환경에서 동일한 것 하나만 만들고,
   환경마다 달라지는 것은 아래 세 가지뿐이다.

   | 환경별 요소 | 주입 방법 |
   |---|---|
   | `uconnect_agent.properties` | `/usr/local/src/config` 볼륨 마운트 (K8s는 ConfigMap, 온프레미스는 디렉토리 마운트) |
   | 로그·업로드 저장소 | 볼륨 마운트 (경로는 properties 값과 일치시킴) |
   | jasypt 키 등 JVM 옵션 재정의(필요 시) | `CATALINA_OPTS` 환경변수 (`-D` 중복 시 나중 값이 이겨서 setenv.sh 값을 덮어씀) |

4. 이미지 태그는 패키지 버전과 1:1 (`6.3.2.023-1`). 같은 태그 재사용 금지.
5. 이 패키지는 agent 전용이다. admin은 admin 패키지 릴리스 후 같은 방식을 적용한다.

## 2. 설치 스크립트 ↔ 이미지 대응

| install_uagent.sh (VM) | 컨테이너 |
|---|---|
| JDK 압축 해제 → `/usr/local/src/jdk-17.0.12` | Dockerfile `ADD` (동일 경로) |
| 톰캣 압축 해제 + `tomcat9_agent` 심볼릭 링크 | Dockerfile `ADD` + `ln -s` (동일) |
| cronolog rpm 설치 | 동일 (패키지 동봉 rpm) |
| `setenv.sh` 복사 | 동일 (패키지 최상위 것) |
| `agent_v*.war` → `webapps/agent.war` | 동일 (`COPY`, 이름 반드시 `agent.war`) |
| properties → `/usr/local/src/config` | 이미지에 넣지 않음 — 마운트 포인트만 생성 |
| `nexus.conf`의 `version=` 을 properties에 기록 | 환경별 properties 준비 시 반영 (§5) |
| systemd 서비스, SELinux, firewalld | 불필요 — 기동은 `catalina.sh run`(포그라운드), 재시작은 K8s/docker가 담당 |

`run` 모드이므로 catalina.out은 stdout으로 나간다(`kubectl logs`/`docker logs`로 조회).
파일 로그(access log 등)는 VM과 동일하게 `logs/`에 쌓이므로 볼륨으로 받는다.

## 3. 빌드

### 3.1 Dockerfile

베이스는 패키지 타깃 OS(EL9)와 동일 계열인 `rockylinux:9`. JDK는 패키지 동봉본을 쓰므로
OS에는 로케일·폰트·타임존만 추가한다.

```dockerfile
FROM rockylinux:9

ENV TZ=Asia/Seoul \
    LANG=ko_KR.UTF-8 \
    LC_ALL=ko_KR.UTF-8 \
    LANGUAGE=ko_KR:ko

RUN dnf -y install glibc-langpack-ko tzdata fontconfig google-noto-sans-cjk-ttc-fonts \
 && dnf clean all && rm -rf /var/cache/dnf \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo "$TZ" > /etc/timezone

# ---- 이하 install_uagent.sh 재현 (VM과 동일 경로) ----
COPY cronolog.rpm /tmp/
RUN rpm -Uh --nodeps --quiet --force /tmp/cronolog.rpm && rm -f /tmp/cronolog.rpm

ADD jdk-17.0.12_linux-x64_bin.tar.gz /usr/local/src/
ADD apache-tomcat-9.0.113-agent.tar.gz /usr/local/src/
RUN ln -s /usr/local/src/apache-tomcat-9.0.113-agent /usr/local/src/tomcat9_agent

COPY setenv.sh /usr/local/src/tomcat9_agent/bin/setenv.sh
COPY agent.war /usr/local/src/tomcat9_agent/webapps/agent.war

RUN mkdir -p /usr/local/src/config \
 && chmod +x /usr/local/src/apache-tomcat-9.0.113-agent/bin/*.sh \
 && rm -rf /usr/local/src/apache-tomcat-9.0.113-agent/logs/* \
           /usr/local/src/apache-tomcat-9.0.113-agent/work/* \
           /usr/local/src/apache-tomcat-9.0.113-agent/temp/* 2>/dev/null || true

ENV CATALINA_HOME=/usr/local/src/tomcat9_agent
EXPOSE 8080 9443
CMD ["/usr/local/src/tomcat9_agent/bin/catalina.sh", "run"]
```

### 3.2 빌드 스크립트 (`build-from-package.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

REGISTRY="${REGISTRY:-gcgf-aicc-dev.ncr.gov-ntruss.com}"   # 환경별 레지스트리
TAG="${TAG:-6.3.2.023-1}"                                   # 패키지 버전 기반
PKG="${PKG:-$HOME/U-Agent_install_Package_v6.3.2.023_20260121_EL9}"

b="build/agent-pkg"
rm -rf "$b"; mkdir -p "$b"

cp "$PKG/uconnect_agent/jdk/jdk-17.0.12_linux-x64_bin.tar.gz"        "$b/"
cp "$PKG/uconnect_agent/tomcat/apache-tomcat-9.0.113-agent.tar.gz"   "$b/"
cp "$PKG"/uconnect_agent/tomcat/cronolog-*.rpm                       "$b/cronolog.rpm"
cp "$PKG"/uconnect_agent/svc.war/agent_v*.war                        "$b/agent.war"
cp "$PKG/setenv.sh"                                                  "$b/"
cp Dockerfile.package                                                "$b/Dockerfile"

docker build -t "${REGISTRY}/aicc-agent:${TAG}" "$b"
docker push "${REGISTRY}/aicc-agent:${TAG}"
echo "완료: ${REGISTRY}/aicc-agent:${TAG}"
```

패키지 디렉토리 하나만 있으면 어디서든 동일 이미지가 재현된다 (원본 서버 SSH 불필요).

## 4. 환경별 사용

### 4.1 NKS (기존 매니페스트에서 바꿀 것)

- `image:` → 새 태그.
- 톰캣 경로가 `/opt/tomcat` → `/usr/local/src/apache-tomcat-9.0.113-agent`로 바뀌므로
  로그 volumeMount의 `mountPath`를 `/usr/local/src/apache-tomcat-9.0.113-agent/logs`로 수정.
- config 마운트(`/usr/local/src/config`)와 Secret→`JASYPT_ENCRYPTOR_PASSWORD` env는 그대로 두되,
  벤더 setenv.sh의 키를 덮어쓰려면 env를 `CATALINA_OPTS=-Djasypt.encryptor.password=$(...)`
  형태로 전달.
- TLS를 ALB(Ingress)에서 종료하는 구성이면 서비스는 8080만 노출하면 되고,
  9443 커넥터는 켜져 있어도 무방하다.

### 4.2 온프레미스 (docker compose 예시)

```yaml
services:
  agent:
    image: <registry>/aicc-agent:6.3.2.023-1
    restart: always
    ports:
      - "8080:8080"
      - "9443:9443"        # LB 없이 직접 HTTPS 서비스 시 (이미지 내 keystore 사용)
    volumes:
      - ./config:/usr/local/src/config
      - ./logs:/usr/local/src/apache-tomcat-9.0.113-agent/logs
```

업로드 경로(mms/webchat)는 해당 환경의 properties 값과 같은 경로를 volume으로 추가한다.

## 5. 환경별 properties 준비

패키지 동봉 `uconnect_agent.properties`는 벤더 QA 값이 든 **템플릿**이다. 그대로 쓰지 말고:

1. 운영 중인 환경별 properties를 기준으로 유지.
2. 패키지 템플릿과 키 목록을 diff하여 v6.3.2 신규 키만 환경 값으로 추가.
3. `nexus.conf`의 `version=` 값을 properties `version=` 라인에 반영
   (VM에서 설치 스크립트가 자동으로 하던 작업).
4. 업로드·로그 경로가 그 환경의 마운트 구성과 일치하는지 확인.

## 6. 검증 체크리스트

- [ ] 기동 로그(stdout)에 jasypt 복호화·keystore 오류 없음, 8080/9443 커넥터 기동 확인
- [ ] `/agent` 로그인 → 화면 버전 표기 = 패키지 버전(v6.3.2.023)
- [ ] DB·Redis(`conf/redis-data-cache.properties` 포함) 연동 정상
- [ ] MMS/웹챗 업로드가 마운트 볼륨에 저장, access log가 로그 볼륨에 생성
- [ ] CTI(nxAdaptor)·U-PBX websocket 연동 정상
- [ ] 이전 버전 대비 신규/변경 기능 QA (릴리스 노트 기준)

## 7. 참고

- 이미지에 keystore 개인키와 설정 파일 내 비밀번호가 포함되므로(벤더 전달물 유지 방침),
  레지스트리는 반드시 private으로 운영한다.
- 벤더 setenv.sh의 OOM 재기동 훅(restart.sh)은 컨테이너에서도 경로가 유효하며,
  JVM이 종료되면 최종적으로 K8s/docker의 restart 정책이 컨테이너를 재기동한다.
