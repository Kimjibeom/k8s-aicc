# U-Agent 설치 패키지 기반 컨테이너 이미지 가이드

작성일: 2026-07-28
대상: 벤더 설치 패키지(`U-Agent_install_Package_v6.3.2.023_20260121_EL9`)를 소스로,
NKS·온프레미스 등 모든 환경에서 공용으로 쓰는 컨테이너 이미지를 빌드하는 절차.

전제 조건:
- 벤더 전달물(설치 패키지)은 지금 형태 그대로 유지 — 개발사에 요구하는 변경 없음.
- 벤더 기능은 제거하지 않음 — keystore·9443 HTTPS 커넥터 포함 (온프레미스에서
  LB 없이 직접 HTTPS 서비스할 때 필요).
- 이미지는 전 환경 공용 하나. 환경별 차이는 설정 마운트·볼륨·환경변수로만 주입.

---

## 1. 방안 비교와 결론

검토한 방안 (모두 벤더 전달물 무변경):

| # | 방안 | 베이스/톰캣 | 크기(대략) | 톰캣 CVE 대응 | 비고 |
|---|---|---|---|---|---|
| 1 | 기존: 운영 서버 SSH로 톰캣 통째 복사 | rocky9 + dnf JDK / 벤더 톰캣 | ~700MB | 벤더 릴리스 종속 | 재현 불가, 서버 의존 — 폐기 대상 |
| 2 | 패키지 통째 재현 (VM 레이아웃 그대로) | rocky9 + 동봉 JDK / 벤더 톰캣 | ~800MB | 벤더 릴리스 종속 | 벤더 환경과 일치도 최고, 가장 무거움 |
| 3 | 벤더 톰캣 유지 + 경량 JRE 베이스 | temurin JRE / 벤더 톰캣 | ~450MB | 벤더 릴리스 종속 | 크기만 개선 |
| 4 | **공식 tomcat 이미지 + 벤더 델타 이식 (권장)** | tomcat:9.0.x-jre17 / 공식 톰캣 | ~400MB | **공식 이미지 라인** | 아래 상세 |

**결론: 방안 4.** 톰캣 바이너리는 공식 이미지 것을 쓰되, **벤더가 검증한 것과 같은
버전(9.0.113) 태그로 고정**해 시작한다 — 버전 불일치 리스크 없이 공식 바이너리의
이점(경량, 이후 CVE 패치 시 태그만 올려 QA)을 얻는다. 벤더 커스터마이징은 패키지
tarball에서 **빌드 스크립트가 자동 추출**해 얹으므로(사람 손 안 탐), 커스텀 설정·keystore·
ROOT 웹앱이 전부 유지된다. 벤더와의 협의 사항은 파일이 아니라 "공식 빌드 톰캣 사용이
기술지원 범위인가" 하나뿐이다.

이식하는 벤더 델타 (패키지 tarball에서 추출):

| 델타 | 내용 |
|---|---|
| `conf/` 전체 | server.xml(8080/9443, shutdown 8004), redis-data-cache.properties, web.xml·context.xml 등 벤더 수정 가능성 있는 파일 일괄 |
| `keystore/` | 9443 HTTPS 커넥터용 인증서 (기능 유지) |
| `webapps/ROOT/` | error.jsp, 폰트, robots.txt |
| war | `webapps/agent.war` (이름 고정 — 컨텍스트 경로 `/agent`) |

이미지에 넣지 않는 것: `uconnect_agent.properties`(환경별 마운트), 벤더 setenv.sh
(VM 경로 하드코딩 — 컨테이너용으로 대체, §3.3), JDK·cronolog(공식 이미지/`run` 모드에서 불필요).

## 2. 환경별 주입 요소

| 환경별 요소 | 주입 방법 |
|---|---|
| `uconnect_agent.properties` | `/usr/local/src/config` 마운트 (K8s는 ConfigMap, 온프레미스는 디렉토리) |
| 로그·업로드 저장소 | 볼륨 마운트 (`/usr/local/tomcat/logs`, properties의 업로드 경로) |
| jasypt 키 | `JASYPT_ENCRYPTOR_PASSWORD` env (미지정 시 벤더 기본값) |
| 힙 크기 | `JAVA_XMS`/`JAVA_XMX` env (기본 2048m) |

properties의 벤더 기본 경로(`/usr/local/src/tomcat9_agent/...`)가 그대로 든 파일도
동작하도록 이미지 안에 `/usr/local/src/tomcat9_agent → /usr/local/tomcat` 링크를 둔다.

## 3. 빌드

### 3.1 Dockerfile

```dockerfile
# 벤더 검증 버전(9.0.113)과 동일한 공식 톰캣으로 고정.
# CVE 대응 시 이 태그만 상위 9.0.x로 올리고 QA 후 배포.
FROM tomcat:9.0.113-jre17-temurin-jammy

ENV TZ=Asia/Seoul LANG=ko_KR.UTF-8 LC_ALL=ko_KR.UTF-8
RUN apt-get update \
 && apt-get install -y --no-install-recommends locales fonts-noto-cjk \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i 's/^# *ko_KR.UTF-8/ko_KR.UTF-8/' /etc/locale.gen && locale-gen \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo "$TZ" > /etc/timezone

# 공식 이미지 기본 웹앱 제거 후 벤더 델타 이식 (vendor/는 빌드 스크립트가 패키지에서 추출)
RUN rm -rf /usr/local/tomcat/webapps/*
COPY vendor/conf/     /usr/local/tomcat/conf/
COPY vendor/keystore/ /usr/local/tomcat/keystore/
COPY vendor/ROOT/     /usr/local/tomcat/webapps/ROOT/
COPY agent.war        /usr/local/tomcat/webapps/agent.war
COPY setenv.sh        /usr/local/tomcat/bin/setenv.sh

# 설정 마운트 포인트 + 벤더 properties 기본 경로 호환 링크
RUN mkdir -p /usr/local/src/config \
 && ln -s /usr/local/tomcat /usr/local/src/tomcat9_agent

EXPOSE 8080 9443
CMD ["catalina.sh", "run"]
```

`tomcat:9.0.113-jre17-temurin-jammy` 태그가 레지스트리에 없으면 가장 가까운 9.0.x 태그를
쓰고 검증 항목(§6)으로 확인한다.

### 3.2 빌드 스크립트 (`build-from-package.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

REGISTRY="${REGISTRY:-gcgf-aicc-dev.ncr.gov-ntruss.com}"   # 환경별 레지스트리
TAG="${TAG:-6.3.2.023-1}"                                   # 패키지 버전 기반, 재사용 금지
PKG="${PKG:-$HOME/U-Agent_install_Package_v6.3.2.023_20260121_EL9}"

b="build/agent-pkg"
rm -rf "$b"; mkdir -p "$b/x"

# 패키지 tarball에서 벤더 델타 자동 추출
tar xzf "$PKG/uconnect_agent/tomcat/apache-tomcat-9.0.113-agent.tar.gz" \
    -C "$b/x" --strip-components=1
mkdir -p "$b/vendor"
mv "$b/x/conf" "$b/x/keystore" "$b/vendor/"
mv "$b/x/webapps/ROOT" "$b/vendor/ROOT"
rm -rf "$b/x"

cp "$PKG"/uconnect_agent/svc.war/agent_v*.war "$b/agent.war"
cp Dockerfile.package "$b/Dockerfile"
cp setenv.sh "$b/"

docker build -t "${REGISTRY}/aicc-agent:${TAG}" "$b"
docker push "${REGISTRY}/aicc-agent:${TAG}"
echo "완료: ${REGISTRY}/aicc-agent:${TAG}"
```

### 3.3 컨테이너용 setenv.sh

벤더 setenv.sh는 VM 경로(JDK, restart.sh)를 하드코딩하므로 컨테이너용으로 대체한다.
값은 벤더 것과 동일하되 환경변수로 재정의 가능하게 한다.

```sh
#!/bin/sh
export JAVA_OPTS="$JAVA_OPTS -server \
 -Xms${JAVA_XMS:-2048m} -Xmx${JAVA_XMX:-2048m} \
 -Duser.timezone=Asia/Seoul -Dfile.encoding=UTF-8 \
 -Djasypt.encryptor.password=${JASYPT_ENCRYPTOR_PASSWORD:-ubasenexus}"
```

## 4. 환경별 사용

### 4.1 NKS (기존 매니페스트에서 바꿀 것)

- `image:` → 새 태그.
- 로그 volumeMount는 `/usr/local/tomcat/logs` (기존 `/opt/tomcat/logs`에서 변경).
- config 마운트(`/usr/local/src/config`)와 Secret→`JASYPT_ENCRYPTOR_PASSWORD` env는 기존 그대로.
- TLS를 ALB(Ingress)에서 종료하므로 Service는 8080만 노출 (9443 커넥터는 켜져 있어도 무방).

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
      - ./logs:/usr/local/tomcat/logs
    environment:
      - JASYPT_ENCRYPTOR_PASSWORD=...   # 사이트별 키 사용 시
```

업로드 경로(mms/webchat)는 해당 환경의 properties 값과 같은 경로를 volume으로 추가한다.

## 5. 환경별 properties 준비

패키지 동봉 `uconnect_agent.properties`는 벤더 QA 값이 든 **템플릿**이다. 그대로 쓰지 말고:

1. 운영 중인 환경별 properties를 기준으로 유지.
2. 패키지 템플릿과 키 목록을 diff하여 신규 키만 환경 값으로 추가.
3. `nexus.conf`의 `version=` 값을 properties `version=` 라인에 반영
   (VM에서 설치 스크립트가 자동으로 하던 작업).
4. 업로드·로그 경로가 그 환경의 마운트 구성과 일치하는지 확인.

## 6. 검증 체크리스트

- [ ] 기동 로그(stdout)에 jasypt 복호화·keystore 오류 없음, 8080/9443 커넥터 기동 확인
- [ ] `/agent` 로그인 → 화면 버전 표기 = 패키지 버전(v6.3.2.023)
- [ ] DB·Redis(`conf/redis-data-cache.properties` 포함) 연동 정상
- [ ] MMS/웹챗 업로드가 마운트 볼륨에 저장, access log가 로그 볼륨에 생성
- [ ] CTI(nxAdaptor)·U-PBX websocket 연동 정상
- [ ] 톰캣 버전이 9.0.113과 다른 태그를 쓴 경우: 기동 경고·회귀 여부 중점 확인
- [ ] 이전 버전 대비 신규/변경 기능 QA (릴리스 노트 기준)

## 7. 참고

- 이미지에 keystore 개인키와 설정 파일 내 비밀번호가 포함되므로(벤더 기능 유지 방침),
  레지스트리는 반드시 private으로 운영한다.
- 벤더에 확인할 사항: 공식 빌드 톰캣(동일 9.0.113) 사용이 기술지원 범위인지.
- 이 패키지는 agent 전용. admin은 admin 패키지 릴리스 후 같은 방식을 적용한다.
