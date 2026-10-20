# ivr-build

U IVR(aicc-ivr / aicc-ivr-nodered) 컨테이너 이미지를 빌드하는 프로젝트. `cti-build`와 같은 구조(빌드 / 레지스트리 / 배포 3단계 분리, 멱등 entrypoint, 무상태 이미지)를 따른다.
레거시 VM 설치 스크립트(`install.sh` → `ivr_install.sh` → `do_install_ivr.sh`/`do_install_db.sh`/`do_set_ivr_config_*.sh`)가 설치할 때 한 번 하던 치환·DB 등록을
**컨테이너가 기동할 때마다 환경변수(`env`)를 읽어 다시 수행**하는 entrypoint가 핵심이다.

> **진행 상태 (2026-10-20)**
> - ✅ 설치 패키지·설치 매뉴얼 분석, 설계, 소스·배포 번들 작성
> - ✅ 빌드: `aicc-ivr:2.0.2.108-1` (304MB), `aicc-ivr-nodered:2.0.2.108-1` (494MB), 선택 `…-ffmpeg` (681MB)
> - ✅ docker 통합 검증 (aicc-db + ivr + nodered, Pod 와 같은 네트워크 네임스페이스·공유 voice 볼륨) — §8
> - ✅ `deploy/` 번들 렌더링·스크립트 오프라인 검증 (minikube 미기동이라 클러스터 apply 는 미실시)
> - ⏳ 남은 것: 온프레미스 k8s 배포, U PBX 실연동(REGISTER/통화), CTI 연동 (§9)

---

## 1. 파일 구성

```text
ivr-build/
├── Dockerfile.package     # 1개 Dockerfile, 2개 타깃 (--target ivr / --target nodered), base 스테이지 공유
├── build.sh               # 설치 패키지 → 빌드 컨텍스트 조립 → docker build (+패치/사이트/REG/PUSH)
├── entrypoint.sh          # [ivr] env → config 렌더링 · DB 스키마/등록 · 멘트 시딩 · nxmonitor 감독 · SIGTERM 정지
├── ivr-health.sh          # [ivr] liveness(nxivrcall/nxivrmedia) / --ready (+SIP 포트 바인딩)
├── jedai_env              # [ivr] 설치 스크립트 .jedai_env 의 운영 별칭(gobin, goment, golog …)
├── nodered-entrypoint.sh  # [nodered] userDir 조립 · settings.js 렌더링 · flows 시딩 · node-red exec
├── nodered-flows.js       # [nodered] settings.js 렌더 / flows CONFIG 탭 DB 노드 자동 설정
├── ffmpeg-g711.js         # [nodered] /usr/bin/ffmpeg 대체 shim (WAV → G.711)
├── build/                 # 빌드 임시 컨텍스트 (생성물, .gitignore)
└── deploy/                # 자체완결 k8s 배포 번들 (deploy/DEPLOY.md)
    ├── deploy.env.example · deploy.sh       # 환경 변수화 + render/diff/apply/delete
    ├── 00-pvc.yaml                          # aicc-ivr-pvc (ivr/log, ivr/backup, ivr/voice, nodered)
    ├── 10-make-configmap.sh · config/ivr.env · conf.d/ · flows.d/
    ├── 20-secret.example.yaml               # aicc-ivr-secret, (선택) aicc-ivr-channels
    ├── 30-statefulset.yaml                  # aicc-<GROUP>-ivr-<SITE>: hostNetwork, 컨테이너 ivr + nodered
    ├── 40-service.yaml                      # ClusterIP(Node-RED 1890) + Headless
    └── nodered-ingress.yaml.template        # (선택) 편집기 Ingress
```

---

## 2. 이미지 설계와 근거

### 2-1. 이미지 2개로 분리 (엔진 / Node-RED), 같은 Pod의 2개 컨테이너로 배포
| 근거 | 내용 |
|---|---|
| 프로세스 성격이 다름 | 엔진 = C 바이너리(nxivrcall·nxivrmedia) + 벤더 감시 스크립트, Node-RED = Node.js 22 런타임. 런타임 의존성이 겹치지 않는다 |
| 갱신 주기가 다름 | 엔진 패치(`nxivr.tar.gz`)와 시나리오 노드/Node-RED 갱신이 따로 온다. 한쪽만 다시 빌드·배포할 수 있다 |
| 장애 격리·프로브 | Node-RED가 죽어도 엔진은 영향받지 않는다. 컨테이너별로 프로브·재시작이 따로 동작한다 |
| 통신 | VM에서도 같은 서버의 localhost/로컬 IP로 통신했다(`t_ivr_scenario_server.ip` = IVR IP). 같은 Pod(같은 네트워크 네임스페이스)라서 그대로 성립한다 |
| 저장 용량 | 두 타깃이 같은 `base` 스테이지를 쓰므로 base 레이어는 레지스트리·노드에 한 번만 저장된다 |

### 2-2. 베이스: `rockylinux:9-minimal`
- 벤더 바이너리 ABI가 EL9: `nxivrcall`/`nxivrmedia`/`nxdatabase` → glibc 2.34, `libssl.so.3`, `libmariadb.so.3`, `libpcre.so.1`, `libjson-c.so.5`. 바이너리를 수정하지 않고 그대로 실행하려면 EL9가 맞다. 빌드할 때 `ldd` 누락 검사도 한다.
- Node-RED 4.0.5에 **glibc 네이티브 모듈**(`@node-rs/bcrypt-linux-x64-gnu`)이 들어 있어 alpine(musl)은 쓸 수 없다. Node.js도 **패키지에 동봉된 el9 rpm(22.19.0)** 그대로 써서 VM과 버전을 맞췄다(오프라인 재현 가능).
- full `rockylinux:9`를 쓰지 않은 이유: 더 크고, 이미 설치된 python3·libusbx가 더 새 버전이라 패키지 ffmpeg rpm 트랜잭션이 실패한다(빌드 중 실제로 확인).
- cti-build와 같은 베이스·같은 관례(비root UID 1000, `vim-minimal`, 절대경로 PS1 `[\u@\h \$PWD]\$`, `TZ=Asia/Seoul`, `ko_KR.UTF-8`).

### 2-3. 경량화 조치 (멀티스테이지 `assets` 빌더는 최종 이미지에 남지 않음)
| 조치 | 효과 / 근거 |
|---|---|
| **멘트 g711 변환을 빌드 시점에 수행** | 설치 스크립트는 런타임에 `nxwav2g711`(ffmpeg)로 wav/mp3 → `.g711u/.g711a`를 만든다. 패키지 ffmpeg rpm 세트는 **366MB**(llvm-libs·mesa 포함)이고, ldd 의존 so만 모아도 약 129MB다 → 변환은 빌더에서 하고 결과만 이미지에 넣는다. 옵션은 `nxwav2g711`과 같다(`-ar 8000 -ac 1 -ab 64k -f mulaw/alaw`, mp3 원본은 `.wav`로 복사하는 동작까지 재현) |
| **ffmpeg shim** (`ffmpeg-g711.js` → `/usr/bin/ffmpeg`) | Node-RED 멘트 업로드 API(`ivr-server.js /API/UPLOAD`)가 `/usr/bin/ffmpeg`를 직접 spawn한다. 파일이 없으면 spawn `error`를 처리하지 않아 **Node-RED 프로세스가 죽는다** → 실제 파일이 있어야 한다. 이미 있는 node로 WAV(PCM)→G.711 변환을 구현했다(표준 G.711 알고리즘). MP3 업로드가 필요하면 `WITH_FFMPEG=1`(+187MB → 681MB, ffmpeg 바이너리와 ldd 의존 so만 복사. 전체 rpm 세트를 깔았다면 +366MB) |
| **Node-RED 사용자 모듈 devDependencies 제거** | `node_modules.user.tar.gz` 436개 패키지 중 419개가 dev(node-red 사본·test-helper·sinon 등). `npm prune --omit=dev --offline` 결과 **68MB → 6MB**. 단 패키지 `settings.js`가 `require('iconv-lite')`(functionGlobalContext)를 하는데 package.json에 선언이 없어 prune 대상이 된다 — **통합 검증에서 "Error loading settings file"로 발견**, 원본(0.6.2)에서 복원하고 빌드 단계에서 settings.js를 실제로 렌더·require 하는 가드를 넣었다 |
| 전역 tar의 npm·소스맵 제거 | `node_modules.tar.gz`에 같이 들어 있는 npm(17MB)과 `*.map`(11MB) 제거. 런타임 팔레트 설치는 불변 이미지 원칙과 맞지 않아 쓰지 않는다(모듈 변경 = 이미지 재빌드) |
| nodejs는 rpm 페이로드만 | `nodejs`+`nodejs-libs`만 rpm2cpio로 꺼냈다. `nodejs-docs`·`npm` 제외, `nodejs-full-i18n`도 제외했다(서버 쪽 Intl/toLocale 사용 없음을 확인. toLocaleString은 브라우저 측 HTML에만 있음) |
| mariadb CLI는 바이너리 1개만 | DB 스키마 적용·등록에 CLI가 필요하지만, EL9 `mariadb` rpm은 perl(약 25MB)을 끌고 온다 → `/usr/bin/mariadb`만 복사하고 런타임 so(libedit/ncurses)만 설치. EL9 10.5 클라이언트를 고른 이유: 패키지의 MariaDB 11.4 클라이언트는 TLS 강제 기본값 때문에 설치 스크립트가 `ERROR 2026` 우회 코드(`do_disable_client_ssl_if_required`)를 따로 둘 정도로 문제가 있었다 |
| **디버그 심볼은 strip 하지 않음** | 엔진 바이너리는 `with debug_info`. 벤더가 `ulimit -c unlimited`·`LimitCORE=infinity`로 코어 분석을 전제로 하므로 gdb 백트레이스용 심볼을 남겼다 |

### 2-4. 이미지에서 제외한 패키지 구성요소
| 항목 | 제외 근거 |
|---|---|
| `nxScenarioBot` | EL7 ABI(`libssl.so.10`, `libmysqlclient.so.18`, `libjson-c.so.2`)라 EL9에서 실행되지 않는다. el8/9 설치 기본값 `USE_API=off`에서는 설치 스크립트도 삭제한다 |
| `nxtoolconfig` | `libcrypto.so.1.1`(EL8) 필요. 레거시 `NEXUS_IVR.XML` 경로에서만 쓰이고, v2 설치 흐름에서는 실행되지 않는다(조건 파일 미존재) |
| `archer_iptables_*.sh`, `NXIVR`(SysV init), `domain_*_inuconnect.co.kr.pem`(nxScenarioBot SSL 전용) | root iptables / init 스크립트 / 미사용 |
| `nxwav2g711`, `nxtoolTTSkakao.sh` | ffmpeg·외부 TTS 도구 전제. 멘트 변환은 빌드 시점(§2-3) 또는 Node-RED 업로드로 대체 |
| nxcapi `include/`·`sample/` | 개발용 헤더·샘플 |
| `uivr_web`(Python 모니터, 9080) | 패키지 설치 흐름에서도 비활성(`do_install_all`의 `# do_install_web;`). OS 계정 PAM 로그인과 `systemctl restart`를 전제로 해서 컨테이너와 맞지 않고, 기능(프로세스·로그·재시작)은 k8s 프로브·로그·롤아웃으로 대체된다 |
| MariaDB 서버, gcc/gdb/strace/tcpdump/sngrep/dialog 등 rpm | DB는 `aicc-db`(db-build)로 분리, 나머지는 설치·진단용 |

### 2-5. 이미지 내부 경로 (모두 절대경로, VM과 동일)
| 이미지 | 경로 |
|---|---|
| aicc-ivr | `NEXUS_HOME=/home/ivr/nexus` (bin, lib, nxcapi, config, var/{log,backup,voice,record,tmp,alarm,tls}), 템플릿 `/home/ivr/nexus/dist/{voice,db,conf}`, `WORKDIR /home/ivr/nexus/bin`, `PATH=.:$NEXUS_HOME/bin:…`, `LD_LIBRARY_PATH=$NEXUS_HOME/lib:$NXCAPI_HOME/lib` |
| aicc-ivr-nodered | Node-RED 코어 `/usr/lib/node_modules/node-red`(VM과 동일), 사용자 모듈 `/opt/nodered/user`(불변), userDir `/home/ivr/.node-red`, 멘트 `/home/ivr/nexus/var/voice`(시나리오 노드가 `$HOME/nexus/var/voice/ivr/`를 쓰므로) |

운영 계정은 `ivr`(UID 1000)으로 매뉴얼의 전용 계정과 같다. 매뉴얼에 있는 "root로 기동하면 tmp.dat 문제" 같은 상황은 비root 고정으로 원천 차단된다.

---

## 3. 빌드 (`build.sh`)

```bash
cd ~/ivr-build
./build.sh                                   # ~/ivr (install_package/) 기준, 두 이미지 빌드
TARGET=ivr ./build.sh                        # 엔진만 (TARGET=nodered: Node-RED만)
PKG=~/U-IVR_Install_v2.0.2.108.EL9.tar.gz ./build.sh   # 설치 tar.gz 직접 지정
PATCH_TAR=~/nxivr.tar.gz ./build.sh          # 엔진 패치 → nexus/bin 덮어쓰기 (설치 스크립트 UPDATE_PATCH 와 동일)
SITE_DIR=~/site/ivr ./build.sh               # install.sh 의 site/ivr 구조: conf/SITE_IVR_E164.TXT, scenario/flows_template.json, voice/IVR_Ment.{zip,tar.gz,tar}
WITH_FFMPEG=1 TARGET=nodered ./build.sh     # nodered 에 실제 ffmpeg (태그에 -ffmpeg 접미사)
REG=jibeom/aicc PUSH=1 ./build.sh            # Docker Hub 단일 저장소 → jibeom/aicc:ivr-<ver>-1, :ivr-nodered-<ver>-1
REG=harbor.dev.com/aicc PUSH=1 ./build.sh    # 레지스트리/프로젝트 → harbor.dev.com/aicc/aicc-ivr:<ver>-1 …
```
- 버전은 `README-version.txt` 첫 항목의 `UIVR x.y.z.n`에서 자동으로 뽑는다(현재 패키지는 **2.0.2.108**). 태그는 `<ver>-<REV>`(REV 기본 1).
- 이 호스트에는 buildx가 없어(legacy builder) `RUN --mount`를 쓰지 않고 rpm2cpio로 rpm 페이로드를 추출하는 방식으로 작성했다.
- 빌드 시 확인되는 것: `ldd OK`(엔진 4종 + mariadb CLI), `user node_modules: 68MB → 6MB`, `settings.js load OK`, `ffmpeg: G.711 shim`, `node v22.19.0, node-red 4.0.5`.

**빌드 결과 (2026-10-20)**

| 이미지 | 크기 | 구성 |
|---|---|---|
| `aicc-ivr:2.0.2.108-1` | 304MB | base + 엔진 so/도구(약 31MB) + nexus(28MB) + 멘트(6MB) |
| `aicc-ivr-nodered:2.0.2.108-1` | 494MB | base + nodejs 22(libnode 80MB) + node-red 4.0.5 코어 + 사용자 모듈 6MB |
| `aicc-ivr-nodered:2.0.2.108-1-ffmpeg` | 681MB | 위 + ffmpeg 5.1.7 바이너리·의존 so 113개 (`WITH_FFMPEG=1`) |

(크기는 이 호스트 docker의 `image ls` 값이다. cti-build `aicc-cti`=477MB도 같은 기준이다.)

---

## 4. 엔진 entrypoint (`entrypoint.sh`) — 설치 스크립트 대응

| VM 설치 단계 | entrypoint 함수 | 내용 |
|---|---|---|
| TUI 기본값(`view_dialog_install.sh`) | 환경변수 기본값 | DB `aicc-db:3316/uivr` user `nexus`, REALM `nexuscommunity.net`, PBX 5060, RTP 36384, MAX CALL 30(30~300 보정), EXPIRES 300(60~3600), CTI 9714 `sys_uivr` sid 1 |
| `do_config_set_db` (nxdatabase) | `render_database` | `nxdatabase MySQL ip port db id pw 1 remote` → `config/NEXUS_DATABASE`(암호화). **nxdatabase가 평문 XML(비밀번호 포함)을 stdout에 출력하는 것을 확인해 출력을 버린다** |
| `write_json_config_call/media` | `render_json` | `nxivrcall.json`(server_id=IVR_ID), `nxivrmedia.json`(local_ip, max_connection, port_start, port_end = start + max_call×2 + 4 — 설치 스크립트 공식, `IVR_RTP_END_PORT`로 변경 가능) |
| `do_check_db_installed`(원격) | `wait_db`·`init_db` | `CREATE DATABASE IF NOT EXISTS uivr` + `1-`/`2-IVR_DATABASE_SCRIPT.SQL` (설치 스크립트도 매번 다시 실행하는 멱등 스크립트) |
| `do_db_insert_t_ivr_config/cti` | `register_ivr` | 원본은 DELETE→INSERT. **env가 관리하는 컬럼만 `ON DUPLICATE KEY UPDATE`** 하도록 바꿔 U-Admin·편집기에서 바꾼 다른 컬럼(dtmf_method, vms_*, tenant_id…)을 보존한다. CTI Standby가 없으면 `ip2=''`, `use_ha=0`(매뉴얼 표와 동일) |
| `do_config_set_ivr_e164` → `do_db_insert_t_ivr_channel` | `seed_channels` | `e164,id,pw,VOICE/CHAT,ip,path`. 시나리오 서버 id는 같은 path가 있으면 재사용, 없으면 MAX+1 → 빈 DB에서 매뉴얼 결과(1 TENANT11 … 4 CHATBOT)와 같다. 채널은 `INSERT IGNORE`로 넣어 운영 중 수정분을 보존하고, 다른 IVR_ID가 이미 쓰는 내선은 건너뛰며 경고만 낸다(매뉴얼의 IVR_ID=2 중복 오류 대응). 기본값 `auto` = 이 IVR_ID 채널이 0건일 때만. 채널 파일이 없으면 IVR_ID=1에 한해 패키지 샘플을 넣는다 |
| (신규) | `sync_scenario_servers` | hostNetwork에서 파드가 다른 노드로 옮겨지면 IP가 바뀐다 → **이 IVR_ID 채널이 참조하는 시나리오 서버 행만** 매 기동 시 IP/포트를 갱신한다. `t_version` upsert |
| `tar default/voice.tar.gz` + nxwav2g711 | `seed_dirs` | 이미지의 변환된 멘트를 `var/voice`로 `cp -an`(no-clobber) → 업로드한 멘트는 보존하고 새 패키지 멘트만 추가 |
| `UIVR.service` (`nxstart.sh start/stop`, MONITOR=on) | `start_engine`/`stop_engine`/`run` | 벤더 `nxmonitor.sh`가 nxwatchdog·nxivrmedia·nxivrcall을 1초 간격으로 감시·재기동. entrypoint는 nxmonitor 데몬 생존을 감시하고(사라지면 종료 → k8s 재시작), SIGTERM을 받으면 `nxstart.sh stop`(시간 초과 시 force) |
| (선택) | `apply_confd` | `/etc/ivr/conf.d/*` → `config/` 통째로 덮어쓰기 |

디버그: `docker run --rm aicc-ivr:2.0.2.108-1 render` (DB 없이 json 렌더 결과만), `… shell`.

## 5. Node-RED entrypoint (`nodered-entrypoint.sh`, `nodered-flows.js`)
- **userDir 분리**: 코드(node_modules, jedai_module, nexus 아이콘)는 이미지 `/opt/nodered/user`에 두고 심링크로 연결한다. userDir(`/home/ivr/.node-red`)에는 flows·자격증명·`.config.*` 같은 사용자 데이터만 남긴다 → 이미지를 바꾸면 모듈이 업그레이드되고, 데이터는 유지된다.
- **settings.js 렌더링**: 패키지 `install.settings.js`에 `install_scenario.sh`와 같은 치환(`${NODERED_PORT}`=1890, `${VERSION}`=시나리오 모듈 버전, `${USER}`=ivr)을 한다. 추가로 `flowFile: 'flows.json'`(기본값 `flows_<hostname>.json`은 hostNetwork에서 노드가 바뀌면 이름이 달라짐), `credentialSecret`(Secret `NODERED_CREDENTIAL_SECRET`), 관리자 해시 교체(`NODERED_ADMIN_PASSWORD_HASH`, 없으면 패키지 기본 admin 계정)를 넣는다.
- **flows 시딩**: userDir에 flows가 없을 때만 템플릿(또는 `/etc/ivr/flows/flows.json`)을 복사한다. 이때 CONFIG 탭의 `MySQLdatabase` 노드(uivr / JEDAI_CUBE) host/port/db를 env로 맞추고 DB 계정을 `flows_cred.json`에 **Node-RED와 같은 방식(aes-256-ctr, key=sha256(credentialSecret))으로 암호화해** 넣는다. 처음엔 평문으로 넣고 Node-RED가 암호화하길 기대했으나, 검증 결과 Node-RED는 자격증명이 바뀌기 전에는 파일을 다시 쓰지 않아(Deploy 후에도) PVC에 평문이 남는 것을 확인해 바꿨다. `NODERED_CREDENTIAL_SECRET`이 없으면 주입하지 않는다. 매뉴얼에서 "CONFIG 탭 Unlock 후 DB_SERVER 수동 입력"하던 단계를 자동화한 것이다. 참고로 **패키지 `install_scenario.sh`의 치환 대상 `10.10.30.211`이 템플릿에 없어서(실제 값은 `localhost`) VM 설치에서도 원격 DB가 반영되지 않는 결함**을 확인했다. `NODERED_FLOWS_MODE=configmap`이면 매 기동 시 ConfigMap으로 덮어쓴다(GitOps, 완전 무상태).
- `exec node red.js` → node가 PID 1이 되어 SIGTERM을 직접 처리한다.

---

## 6. 상태(PV) 분석 — "무상태면 log만 PV" 기준

IVR **엔진 자체는 무상태**다. `config/`는 매 기동 재생성되고, 설정의 원본은 DB(`uivr`)와 env다. 다만 패키지 분석에서 런타임에 사용자가 만드는 데이터가 2가지 확인돼 log 외에 예외로 둔다 — `deploy/00-pvc.yaml`·`30-statefulset.yaml` 에 반영.

| 경로 | PV | 근거 |
|---|---|---|
| `var/log`, `var/backup` | ✅ | 엔진 로그와 nxwatchdog의 일자별 로그 압축 백업 |
| `var/voice` (두 컨테이너 공유) | ✅ 예외 | Node-RED 편집기의 **멘트 업로드 도구가 `$HOME/nexus/var/voice/ivr`에 파일을 쓰고**, 엔진이 읽는다. 업로드를 쓰지 않으면 이미지 멘트만으로 무상태 운영 가능 |
| Node-RED userDir (flows, 자격증명) | ✅ 예외 (또는 configmap 모드로 무상태) | 시나리오는 편집기에서 Deploy되는 사용자 데이터 |
| `var/record` | 선택 | VMS/녹취를 쓸 때만 |
| `config/` | ❌ | 매 기동 렌더링 |

---

## 7. 포트 / 네트워크 (설계 근거)
| 포트 | 프로토콜 | 용도 |
|---|---|---|
| 9060 (`IVR_SIP_LOCAL_PORT`) | UDP(기본)/TCP | IVR SIP. 매뉴얼 실측값 9060 채택(TUI 기본은 5060이지만 hostNetwork에서 PBX 5060과 충돌) |
| 36384 ~ (start + max_call×2 + 4) | UDP | RTP (채널당 2포트, 매뉴얼 권장 120% 여유는 `IVR_RTP_END_PORT`로) |
| 1900 | TCP | nxivrcall → nxivrmedia (Pod 내부) |
| 1890 | TCP | Node-RED 편집기 + 시나리오 HTTP (현재 패키지 기본값. 매뉴얼 화면의 1880은 구버전) |
| → 9714 | TCP(아웃바운드) | CTI `sys_uivr` (cti-build `aicc-cti` Service `lsn-uivr`) |
| → 3316 | TCP(아웃바운드) | `aicc-db` |

SIP·SDP에 IVR IP가 들어가고 RTP가 UDP 포트 범위라서 NAT/NodePort로는 성립하지 않는다 → cti-build와 같이 **`hostNetwork: true` + 노드 고정**이 전제다(`IVR_IP`=노드 IP).

---

## 8. 통합 검증 결과 (2026-10-20, docker)

구성: `aicc-db:6.3.3.022-1`(빈 DB) + `aicc-ivr` + `aicc-ivr-nodered`(`--network container:` 로 엔진과 같은 네트워크 네임스페이스 = Pod), voice 볼륨 공유. PBX(10.10.30.177)·CTI(10.10.30.211)는 미도달 주소.

| 항목 | 결과 |
|---|---|
| 스키마 | `uivr` 생성, 15개 테이블(매뉴얼 14 + `t_nodered`) — 재기동 시 1-/2- SQL 재실행 무오류(멱등) |
| DB 등록 | `t_ivr_config`·`t_ivr_cti`(ip2 '' / use_ha 0)·`t_ivr_scenario_server`(1 TENANT11, 2 TENANT12, 3 TENANT13, 4 CHATBOT)·`t_ivr_channel` 8건 — **매뉴얼의 표와 동일** |
| 엔진 기동 | nxwatchdog·nxivrmedia·nxivrcall 기동, nxivrcall↔nxivrmedia heartbeat, SIP 9060/UDP 바인딩, 8개 내선 REGISTER 송신(→PBX), CTI `CCSEDOWN`(CTI 부재 — 예상대로), 로그 `var/log/<날짜>/{*_nxivrcall,*_nxivrmedia,*_sip,NXWATCHDOG}` |
| 멘트 | 이미지 멘트 175개 시딩, 재기동 시 중복 없음 |
| 재기동 멱등성 | 채널 시딩 생략, **U-Admin 편집 가정 컬럼(dtmf_method, description, rec_time_sec) 보존** |
| 장애 복구 | `kill -9 nxivrcall` → nxmonitor 가 1초 내 재기동, readiness 유지 / nxmonitor 종료 → 컨테이너 exit 1 (k8s 재시작 경로) |
| 정상 종료 | SIGTERM → `nxstart.sh stop` 3초 내 완료 |
| 노드 이전 | IP 변경 기동 시 `local_sip_ip`·시나리오 서버 4건 자동 갱신 |
| Node-RED | 4.0.5 기동, 노드 세트 60개 오류 0(IVR 시나리오 노드 21종), 매뉴얼 계정 `admin / nexus62402580!` 로그인, 관리자 해시 교체 시 신규 200·기존 403 |
| flows/자격증명 | CONFIG 탭 DB 노드 → `aicc-db`, 자격증명 암호화 저장·복호화, DB 커넥션 확인(엔진+Node-RED uivr 4, JEDAI_CUBE 2), 재기동 시 flows 유지, SIGTERM 정상 종료 |
| 시나리오 HTTP | `GET /TENANT11_CALL_IVR` → 200 `JEDAI_IVR:{…}` |
| 멘트 업로드 | WAV → shim 변환(`.g711u/.g711a`), 엔진 컨테이너에서 공유 확인. 패키지 ffmpeg 출력 대비 길이 동일·RMS 차 2% 이내·상관 0.98. MP3 → shim 이 명확한 오류로 실패하고 Node-RED 는 계속 동작. `-ffmpeg` 이미지는 MP3 변환 결과가 빌드 시점 변환본과 **바이트 단위 동일** |

검증 중 발견해 고친 것: ① iconv-lite prune 으로 settings.js 로드 실패(§2-3) ② 평문 자격증명이 PVC 에 남는 문제(§5) ③ deploy.sh/10-make-configmap.sh 에서 명령행 환경변수가 deploy.env 에 덮이던 문제(cti-build `deploy.sh` 에도 같은 구조가 있음) ④ `IMAGE_PULL_SECRET=` 빈 값이 regcred 로 되돌아가던 문제.

## 9. 배포 및 남은 작업
배포 절차는 [deploy/DEPLOY.md](deploy/DEPLOY.md). 렌더링(GROUP/SITE/노드 고정/이미지/pull secret/Ingress)과 ConfigMap 생성 스크립트는 오프라인으로 검증했다.

남은 것:
1. 온프레미스 k8s 배포 (minikube 컨텍스트 미기동) — PVC subPath 권한(fsGroup), hostNetwork 프로브, aicc-db 3316 연동
2. U PBX 실연동 — 내선 REGISTER 200, 실제 통화 시 RTP(36384~)·멘트 재생·Node-RED 시나리오 호출
3. CTI(aicc-cti 9714 sys_uivr) 연동 — SST 전환
4. 이미지 push (`REG=… PUSH=1`) 및 NCP 번들(`ncp-deploy/`) 필요 여부
