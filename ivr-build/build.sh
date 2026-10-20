#!/usr/bin/env bash
set -euo pipefail

# U IVR(aicc-ivr / aicc-ivr-nodered) 이미지 빌드 스크립트 (상세 빌드 구조는 README §2 참조)
#
# 사용법:
#   ./build.sh                                          # 로컬 빌드 (두 이미지)
#   TARGET=ivr ./build.sh                               # 엔진 이미지만 (TARGET=nodered: Node-RED 만)
#   PKG=~/U-IVR_Install_v2.0.2.108.EL9.tar.gz ./build.sh  # 설치 패키지 tar.gz 직접 지정
#   PATCH_TAR=~/nxivr.tar.gz ./build.sh                 # 엔진 패치(bin 덮어쓰기, 설치 스크립트 UPDATE_PATCH 와 동일)
#   SITE_DIR=~/site/ivr ./build.sh                      # 사이트 커스터마이즈 (install.sh 의 site/ivr 구조와 동일)
#   WITH_FFMPEG=1 ./build.sh                            # nodered 에 실제 ffmpeg 포함 (MP3 멘트 업로드 지원, +약 100MB)
#   REG=jibeom/aicc PUSH=1 ./build.sh                   # Docker Hub(user/repo): jibeom/aicc:ivr-<ver>-1, :ivr-nodered-<ver>-1
#   REG=harbor.dev.com/aicc PUSH=1 ./build.sh           # 레지스트리/프로젝트: harbor.dev.com/aicc/aicc-ivr:<ver>-1 ...

PKG="${PKG:-$HOME/ivr}"
PATCH_TAR="${PATCH_TAR:-}"
SITE_DIR="${SITE_DIR:-}"
TARGET="${TARGET:-all}"
WITH_FFMPEG="${WITH_FFMPEG:-0}"
REG="${REG:-}"
PUSH="${PUSH:-0}"
REV="${REV:-1}"                                     # 이미지 리비전 (같은 엔진 버전에서 이미지 내용 변경 시 증가)

b="build"
rm -rf "$b"; mkdir -p "$b/pkg" "$b/ctx"
C="$b/ctx"

# ── 1. 설치 패키지 위치 결정 (디렉토리 또는 U-IVR_Install_*.tar.gz) ───────────────────────────
if [ -f "$PKG" ]; then
  tar xzf "$PKG" -C "$b/pkg"; IP=$(dirname "$(find "$b/pkg" -maxdepth 3 -type d -name install_package | head -1)")/install_package
elif [ -d "$PKG/install_package" ]; then IP="$PKG/install_package"
elif [ -d "$PKG/ivr" ] && [ -d "$PKG/nodered" ]; then IP="$PKG"
else echo "[ERROR] $PKG 에 install_package/ 가 없음" >&2; exit 1; fi
[ -f "$IP/ivr/nexus.tar.gz" ] || { echo "[ERROR] $IP/ivr/nexus.tar.gz 없음" >&2; exit 1; }
echo "설치 패키지: $IP"

# ── 2. 엔진 (nexus.tar.gz → nexus/) + 패치 ─────────────────────────────────────────────
tar xzf "$IP/ivr/nexus.tar.gz" -C "$C"
[ -z "$PATCH_TAR" ] && [ -f "$IP/ivr/nxivr.tar.gz" ] && PATCH_TAR="$IP/ivr/nxivr.tar.gz"
if [ -n "$PATCH_TAR" ]; then
  [ -f "$PATCH_TAR" ] || { echo "[ERROR] PATCH_TAR=$PATCH_TAR 없음" >&2; exit 1; }
  echo "엔진 패치 적용: $(basename "$PATCH_TAR") → nexus/bin"
  tar xf "$PATCH_TAR" -C "$C/nexus/bin"
fi
VER=$(sed -n 's/^[0-9-]* : UIVR \([0-9.]*\).*/\1/p' "$C/nexus/bin/README-version.txt" | head -1)
[ -n "$VER" ] || { echo "[ERROR] README-version.txt 에서 UIVR 버전 추출 실패" >&2; exit 1; }

# 컨테이너에서 쓰지 않거나 동작 불가한 파일 제외 (README §2 "제외 항목")
rm -f "$C"/nexus/bin/{nxScenarioBot,nxtoolconfig,NXIVR,nxwav2g711,nxtoolTTSkakao.sh} \
      "$C"/nexus/bin/archer_iptables_*.sh "$C"/nexus/bin/domain_*_inuconnect.co.kr.pem
rm -rf "$C"/nexus/nxcapi/nxcapi_standard/linux/{include,sample,start.sh}
mkdir -p "$C/voice/base"
cp -a "$C/nexus/var/voice/." "$C/voice/base/" 2>/dev/null || true   # nexus.tar.gz 내 korean/cardinal_* 음원
rm -rf "$C/nexus/var"
chmod 755 "$C"/nexus/bin/nx* "$C"/nexus/bin/prt_version
# README-version.txt 는 UTF-8 BOM 포함 → 그대로 둠 (매뉴얼의 'ivr 계정에서 깨짐'은 로케일 문제, 이미지는 ko_KR.UTF-8)

# ── 3. 멘트 / DB 스크립트 / 채널 샘플 ────────────────────────────────────────────────
cp "$IP/ivr/default.tar.gz" "$IP/ivr/voice.tar.gz" "$C/voice/"
mkdir -p "$C/voice/site" "$C/db" "$C/conf"
cp "$IP"/db/1-IVR_DATABASE_SCRIPT.SQL "$IP"/db/2-IVR_DATABASE_SCRIPT.SQL "$C/db/"
cp "$IP/conf/SITE_IVR_E164.TXT" "$C/conf/"

# ── 4. Node-RED 자산 + rpm (nodejs 런타임 / 빌드 전용 ffmpeg) ─────────────────────────────
NR="$IP/nodered"
mkdir -p "$C/nodered/config" "$C/rpm/nodejs" "$C/rpm/ffmpeg"
cp "$NR/lib/node_modules.tar.gz" "$NR/user/node_modules.user.tar.gz" "$C/nodered/"
cp -a "$NR"/node-red/config/{install.settings.js,flows_template.json,package.json,robots.txt,jedai_module,nexus} "$C/nodered/config/"
cp "$NR"/rpm/el9/nodejs-[0-9]*.rpm "$NR"/rpm/el9/nodejs-libs-*.rpm "$NR"/rpm/el9/npm-*.rpm "$C/rpm/nodejs/"
cp "$IP"/script/rpm/el9/ffmpeg/*.rpm "$C/rpm/ffmpeg/"
NR_CORE=$(tar xzf "$NR/lib/node_modules.tar.gz" node_modules/node-red/package.json -O | sed -n 's/.*"version": "\(.*\)".*/\1/p' | head -1)
NR_MOD=$(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$NR/node-red/config/jedai_module/node-red-contrib-ivr-scenario/package.json" | head -1)

# ── 5. 사이트 커스터마이즈 (install.sh: site/ivr/{conf/SITE_IVR_E164.TXT, scenario/flows_template.json, voice/IVR_Ment.*}) ─
if [ -n "$SITE_DIR" ]; then
  [ -d "$SITE_DIR" ] || { echo "[ERROR] SITE_DIR=$SITE_DIR 없음" >&2; exit 1; }
  [ -f "$SITE_DIR/conf/SITE_IVR_E164.TXT" ] && cp "$SITE_DIR/conf/SITE_IVR_E164.TXT" "$C/conf/" && echo "  사이트 채널 파일 적용"
  [ -f "$SITE_DIR/scenario/flows_template.json" ] && cp "$SITE_DIR/scenario/flows_template.json" "$C/nodered/config/" && echo "  사이트 시나리오 적용"
  for m in "$SITE_DIR"/voice/IVR_Ment.zip "$SITE_DIR"/voice/IVR_Ment.tar.gz "$SITE_DIR"/voice/IVR_Ment.tar; do
    [ -f "$m" ] || continue
    case "$m" in *.zip) unzip -q -o "$m" -d "$C/voice/site" ;; *.tar.gz) tar xzf "$m" -C "$C/voice/site" ;; *.tar) tar xf "$m" -C "$C/voice/site" ;; esac
    echo "  사이트 멘트 적용: $(basename "$m")"; break
  done
fi

# ── 6. 빌드 컨텍스트 조립 ─────────────────────────────────────────────────────────────
cp Dockerfile.package "$C/Dockerfile"
cp entrypoint.sh ivr-health.sh jedai_env nodered-entrypoint.sh nodered-flows.js ffmpeg-g711.js "$C/"

FF=shim; SUF=""
[ "$WITH_FFMPEG" = "1" ] && { FF=full; SUF="-ffmpeg"; }

img_name() {   # $1=aicc-ivr|aicc-ivr-nodered $2=tag
  if [ -z "$REG" ]; then echo "$1:$2"
  elif [[ "${REG%%/*}" == *[.:]* ]] || [[ "$REG" == */*/* ]]; then echo "$REG/$1:$2"      # 레지스트리 호스트/프로젝트
  else echo "$REG:${1#aicc-}-$2"; fi                                                       # Docker Hub user/repo 단일 저장소
}
build_one() {  # $1=target $2=image base name
  local tag="${TAG:-${VER}-${REV}}"; [ "$1" = nodered ] && tag="${tag}${SUF}"
  local img; img=$(img_name "$2" "$tag")
  echo "── docker build --target $1 → $img"
  docker build --target "$1" --build-arg FFMPEG="$FF" --build-arg IVR_VERSION="$VER" \
    --build-arg NODERED_VERSION="${VER} (node-red ${NR_CORE}, ivr-scenario ${NR_MOD})" \
    -t "$img" $([ -n "$REG" ] && echo "-t $2:${tag}") "$C"
  BUILT+=("$img")
}

echo "U IVR ${VER} (node-red ${NR_CORE}, ivr-scenario ${NR_MOD}) / ffmpeg=${FF} / target=${TARGET}"
BUILT=()
case "$TARGET" in
  all)     build_one ivr aicc-ivr; build_one nodered aicc-ivr-nodered ;;
  ivr)     build_one ivr aicc-ivr ;;
  nodered) build_one nodered aicc-ivr-nodered ;;
  *) echo "[ERROR] TARGET=$TARGET (all|ivr|nodered)" >&2; exit 1 ;;
esac

if [ "$PUSH" = "1" ]; then
  [ -n "$REG" ] || { echo "[ERROR] PUSH=1은 REG 지정 필요" >&2; exit 1; }
  for i in "${BUILT[@]}"; do echo "push: $i"; docker push "$i"; done
fi
echo "완료:"; for i in "${BUILT[@]}"; do docker image ls --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' "$i"; done
