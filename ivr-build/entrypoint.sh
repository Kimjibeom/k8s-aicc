#!/bin/bash
# aicc-ivr 컨테이너 엔트리포인트 (설정 렌더링 · DB 초기화/등록 · 엔진 프로세스 감독)
set -uo pipefail

NEXUS_HOME="${NEXUS_HOME:?}"
BIN="$NEXUS_HOME/bin"; CONF="$NEXUS_HOME/config"; DIST="$NEXUS_HOME/dist"
log()  { echo "[ivr-entrypoint] $*"; }
warn() { echo "[ivr-entrypoint][WARN] $*" >&2; }
die()  { echo "[ivr-entrypoint][ERROR] $*" >&2; exit 1; }

# ── 환경값 (기본값은 TUI view_dialog_install.sh 기본값 / 설치 매뉴얼 기준) ─────────────────────
POD_IP="${POD_IP:-}"
IVR_IP="${IVR_IP:-${POD_IP:-$(hostname -i 2>/dev/null | awk '{print $1}')}}"   # TUI: IP setting / SIP IP(IVR)
IVR_ID="${IVR_ID:-1}"                                  # TUI: IVR CALL SERVER ID (서버 다중화 시 2,3..)
IVR_RESOLVE_HOSTS="${IVR_RESOLVE_HOSTS:-1}"            # DB/CTI 호스트명을 IP로 변환해 기록 (TUI는 IP만 허용)

IVR_DB_HOST="${IVR_DB_HOST:-aicc-db}"
IVR_DB_PORT="${IVR_DB_PORT:-3316}"
IVR_DB_NAME="${IVR_DB_NAME:-uivr}"                     # v2.0부터 jedai_ivr → uivr
IVR_DB_USER="${IVR_DB_USER:-nexus}"
IVR_DB_PASSWORD="${IVR_DB_PASSWORD:-}"
IVR_DB_INIT="${IVR_DB_INIT:-on}"                       # on: CREATE DATABASE IF NOT EXISTS + 1-/2-IVR_DATABASE_SCRIPT.SQL (멱등)
IVR_DB_WAIT="${IVR_DB_WAIT:-120}"

IVR_SIP_REALM="${IVR_SIP_REALM:-nexuscommunity.net}"
IVR_SIP_REMOTE_IP="${IVR_SIP_REMOTE_IP:-}"             # U PBX SIP IP
IVR_SIP_REMOTE_PORT="${IVR_SIP_REMOTE_PORT:-5060}"
IVR_SIP_LOCAL_PORT="${IVR_SIP_LOCAL_PORT:-9060}"       # 매뉴얼 실측값. hostNetwork 에서 PBX 5060 과 충돌 방지
IVR_SIP_TRANSPORT="${IVR_SIP_TRANSPORT:-UDP}"          # UDP(3) | TCP(4)
IVR_RTP_START_PORT="${IVR_RTP_START_PORT:-36384}"
IVR_MAX_CALL="${IVR_MAX_CALL:-30}"                     # TUI 범위 30~300
IVR_RTP_END_PORT="${IVR_RTP_END_PORT:-}"               # 비우면 설치 스크립트 공식: start + max_call*2 + 4
IVR_MEDIA_PORT="${IVR_MEDIA_PORT:-1900}"               # nxivrmedia 서버 포트 (nxivrcall → nxivrmedia)
IVR_EXPIRES="${IVR_EXPIRES:-300}"                      # REGISTER EXPIRES (TUI 범위 60~3600)
IVR_STANDBY="${IVR_STANDBY:-600}"
IVR_VOICE_DIR="${IVR_VOICE_DIR:-/var/voice/ivr}"       # NEXUS_HOME 기준 상대 (t_ivr_config.voice_default)

IVR_CTI_USE="${IVR_CTI_USE:-on}"                       # TUI: CTI CUBE setting
IVR_CTI_ID="${IVR_CTI_ID:-1}"
IVR_CTI_HOST1="${IVR_CTI_HOST1:-aicc-cti}"             # CUBE Active
IVR_CTI_HOST2="${IVR_CTI_HOST2:-}"                     # CUBE Standby (단중화면 비움 → ip2='')
IVR_CTI_PORT="${IVR_CTI_PORT:-9714}"                   # CTI nxlistener 1214(sys_uivr)
IVR_CTI_SID="${IVR_CTI_SID:-1}"                        # PBX SERVER ID (CTI media sid)
IVR_CTI_APPNAME="${IVR_CTI_APPNAME:-sys_uivr}"

IVR_REGISTER="${IVR_REGISTER:-on}"                     # on: t_ivr_config/t_ivr_cti/시나리오서버 IP 를 env 기준으로 upsert
IVR_CHANNEL_SEED="${IVR_CHANNEL_SEED:-auto}"           # auto: 이 IVR_ID 채널이 0건일 때만 / always / off
IVR_CHANNEL_FILE="${IVR_CHANNEL_FILE:-/etc/ivr/channels/e164.txt}"   # Secret aicc-ivr-channels (없으면 패키지 샘플, IVR_ID=1 한정)
NODERED_PORT="${NODERED_PORT:-1890}"                   # t_ivr_scenario_server.port (같은 파드의 nodered 컨테이너)

IVR_START_TIMEOUT="${IVR_START_TIMEOUT:-60}"
IVR_STOP_TIMEOUT="${IVR_STOP_TIMEOUT:-30}"

# ── 유틸 ──────────────────────────────────────────────────────────────────────────
resolve() {  # 호스트명 → IPv4 (이미 IP/빈값이면 그대로)
  local h="$1"
  if [ -z "$h" ] || [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ "$IVR_RESOLVE_HOSTS" != "1" ]; then echo "$h"; return; fi
  local ip; ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
  [ -n "$ip" ] && echo "$ip" || { warn "호스트 $h 해석 실패 — 이름 그대로 기록"; echo "$h"; }
}
sqlq() { printf '%s' "$1" | sed "s/'/''/g"; }          # SQL 문자열 리터럴 이스케이프
# 비밀번호는 argv(-p) 대신 MYSQL_PWD 로 넘겨 ps 노출을 막는다
db()   { MYSQL_PWD="$IVR_DB_PASSWORD" mariadb --connect-timeout=5 -h"$DB_IP" -P"$IVR_DB_PORT" -u"$IVR_DB_USER" "$@"; }
dbq()  { db -D"$IVR_DB_NAME" -N -s -e "$1"; }

validate() {
  [ -n "$IVR_IP" ] || die "IVR_IP 결정 실패 (POD_IP/IVR_IP 미지정)"
  [ -n "$IVR_DB_PASSWORD" ] || [ "${RENDER_ONLY:-0}" = 1 ] || die "IVR_DB_PASSWORD 미주입 — Secret(aicc-ivr-secret) 필요"
  [ -n "$IVR_SIP_REMOTE_IP" ] || { warn "IVR_SIP_REMOTE_IP 미지정 — 127.0.0.1(PBX 동거 설치 가정)로 기록"; IVR_SIP_REMOTE_IP=127.0.0.1; }
  case "$IVR_SIP_TRANSPORT" in UDP) DB_TRANSPORT=3 ;; TCP) DB_TRANSPORT=4 ;; *) die "IVR_SIP_TRANSPORT=$IVR_SIP_TRANSPORT (UDP|TCP)";; esac
  # TUI 와 동일한 범위 보정
  [ "$IVR_MAX_CALL" -gt 300 ] && IVR_MAX_CALL=300; [ "$IVR_MAX_CALL" -lt 30 ] && IVR_MAX_CALL=30
  [ "$IVR_EXPIRES" -gt 3600 ] && IVR_EXPIRES=3600; [ "$IVR_EXPIRES" -lt 60 ] && IVR_EXPIRES=60
  [ -n "$IVR_RTP_END_PORT" ] || IVR_RTP_END_PORT=$((IVR_RTP_START_PORT + IVR_MAX_CALL * 2 + 4))
  DB_IP=$(resolve "$IVR_DB_HOST")
  CTI_IP1=$(resolve "$IVR_CTI_HOST1"); CTI_IP2=$(resolve "$IVR_CTI_HOST2")
}

# ── 0. 디렉토리 / 멘트 시딩 (PVC subPath 는 첫 기동 시 비어 있음) ─────────────────────────────
seed_dirs() {
  mkdir -p "$CONF" "$NEXUS_HOME"/var/{log,backup,tmp,alarm,record,voice,tls}
  # 이미지 멘트 → var/voice. no-clobber 라 Node-RED 업로드 멘트·운영자 교체본은 보존되고 신규 패키지 멘트만 추가된다.
  local before after
  before=$(find "$NEXUS_HOME/var/voice" -type f | wc -l)
  cp -an "$DIST/voice/." "$NEXUS_HOME/var/voice/" 2>/dev/null || true
  after=$(find "$NEXUS_HOME/var/voice" -type f | wc -l)
  [ "$after" -gt "$before" ] && log "멘트 시딩: +$((after-before))개 (var/voice 총 ${after}개)"
  # .jedai_env 의 ~/log 심링크(오늘 로그 디렉토리)
  mkdir -p "$NEXUS_HOME/var/log/$(date +%Y%m%d)"; ln -sfn "$NEXUS_HOME/var/log/$(date +%Y%m%d)" "$HOME/log" 2>/dev/null
  return 0
}

# ── 1. config/ 렌더링 (매 기동 재생성 — 이미지 FS, 영속 불필요) ─────────────────────────────
render_database() {   # do_config_set_db: nxdatabase → bin/NEXUS_DATABASE(암호화) → config/
  local remote=1
  [ "$DB_IP" = "127.0.0.1" ] || [ "$DB_IP" = "$IVR_IP" ] && remote=0
  # nxdatabase 는 평문 XML(비밀번호 포함)을 stdout 에 출력하므로 버린다
  ( cd "$BIN" && ./nxdatabase MySQL "$DB_IP" "$IVR_DB_PORT" "$IVR_DB_NAME" "$IVR_DB_USER" "$IVR_DB_PASSWORD" 1 "$remote" >/dev/null 2>&1 )
  [ -s "$BIN/NEXUS_DATABASE" ] || die "nxdatabase 실행 실패 — NEXUS_DATABASE 미생성"
  mv -f "$BIN/NEXUS_DATABASE" "$CONF/NEXUS_DATABASE"; chmod 600 "$CONF/NEXUS_DATABASE"
}
render_json() {       # write_json_config_call / write_json_config_media (설치 스크립트와 같은 키·형식)
  cat > "$CONF/nxivrcall.json" <<EOF
  {
      "server_id": ${IVR_ID}
  }
EOF
  cat > "$CONF/nxivrmedia.json" <<EOF
  {
      "media_id": 1,
      "local_ip": "${IVR_IP}",
      "max_connection": ${IVR_MAX_CALL},
      "port_start": ${IVR_RTP_START_PORT},
      "port_end": "${IVR_RTP_END_PORT}",
      "servers": [
          {
              "ip": "${IVR_IP}",
              "port": ${IVR_MEDIA_PORT}
          }
      ]
  }
EOF
}
apply_confd() {       # (선택) configmap/aicc-<GROUP>-ivr-confd → config/ 통째 덮어쓰기
  local d=/etc/ivr/conf.d f
  [ -d "$d" ] || return 0
  for f in "$d"/*; do [ -f "$f" ] || continue; cp -f "$f" "$CONF/$(basename "$f")"; log "config/$(basename "$f") ← $d"; done
}

# ── 2. DB 대기 / 스키마 초기화 (do_check_db_installed 원격 경로) ───────────────────────────
wait_db() {
  local n=0
  until db -e "SELECT 1" >/dev/null 2>&1; do
    n=$((n+3)); [ $n -ge "$IVR_DB_WAIT" ] && { db -e "SELECT 1" 2>&1 | tail -1 >&2; die "DB ${IVR_DB_HOST}(${DB_IP}):${IVR_DB_PORT} 접속 불가 (${IVR_DB_WAIT}s)"; }
    sleep 3
  done
}
init_db() {
  [ "$IVR_DB_INIT" = "on" ] || { log "IVR_DB_INIT=off — 스키마 초기화 생략"; return 0; }
  db -e "CREATE DATABASE IF NOT EXISTS \`${IVR_DB_NAME}\`" || die "CREATE DATABASE ${IVR_DB_NAME} 실패 (계정 권한 확인)"
  local f out
  for f in 1-IVR_DATABASE_SCRIPT.SQL 2-IVR_DATABASE_SCRIPT.SQL; do   # 설치 스크립트도 매 설치마다 두 파일을 재실행(멱등)
    out=$(db -D"$IVR_DB_NAME" < "$DIST/db/$f" 2>&1) || { echo "$out" >&2; die "$f 실행 실패"; }
  done
  log "스키마 적용: ${IVR_DB_NAME} (테이블 $(dbq "select count(*) from information_schema.tables where table_schema='${IVR_DB_NAME}'")개)"
}

# ── 3. IVR 등록 (do_config_set_ivr) ───────────────────────────────────────────────────
# 설치 스크립트는 DELETE→INSERT 였으나, U-Admin/시나리오 편집기에서 바꾼 다른 컬럼(dtmf_method, vms_*, tenant_id 등)을
# 보존하도록 env 가 책임지는 컬럼만 INSERT … ON DUPLICATE KEY UPDATE 한다.
register_ivr() {
  [ "$IVR_REGISTER" = "on" ] || { log "IVR_REGISTER=off — DB 등록 생략"; return 0; }
  dbq "INSERT INTO t_ivr_config (ivr_id, realm, remote_sip_ip, remote_sip_port, local_sip_ip, local_sip_port,
         max_call, transport, expires, standby, voice_default, media_port, update_time)
       VALUES (${IVR_ID}, '$(sqlq "$IVR_SIP_REALM")', '${IVR_SIP_REMOTE_IP}', ${IVR_SIP_REMOTE_PORT}, '${IVR_IP}', ${IVR_SIP_LOCAL_PORT},
         ${IVR_MAX_CALL}, ${DB_TRANSPORT}, ${IVR_EXPIRES}, ${IVR_STANDBY}, '$(sqlq "$IVR_VOICE_DIR")', ${IVR_MEDIA_PORT}, now())
       ON DUPLICATE KEY UPDATE realm=VALUES(realm), remote_sip_ip=VALUES(remote_sip_ip), remote_sip_port=VALUES(remote_sip_port),
         local_sip_ip=VALUES(local_sip_ip), local_sip_port=VALUES(local_sip_port), max_call=VALUES(max_call),
         transport=VALUES(transport), expires=VALUES(expires), standby=VALUES(standby),
         voice_default=VALUES(voice_default), media_port=VALUES(media_port), update_time=now()" || die "t_ivr_config 등록 실패"
  if [ "$IVR_CTI_USE" = "on" ]; then
    local ha=0; [ -n "$CTI_IP2" ] && [ "$CTI_IP2" != "$CTI_IP1" ] && ha=1
    dbq "INSERT INTO t_ivr_cti (cti_id, ip1, port1, ip2, port2, sid, use_ha, appname, description, update_time)
         VALUES (${IVR_CTI_ID}, '${CTI_IP1}', ${IVR_CTI_PORT}, '${CTI_IP2}', ${IVR_CTI_PORT}, ${IVR_CTI_SID}, ${ha}, '$(sqlq "$IVR_CTI_APPNAME")', 'CUBE', now())
         ON DUPLICATE KEY UPDATE ip1=VALUES(ip1), port1=VALUES(port1), ip2=VALUES(ip2), port2=VALUES(port2),
           sid=VALUES(sid), use_ha=VALUES(use_ha), appname=VALUES(appname), update_time=now()" || die "t_ivr_cti 등록 실패"
  fi
}

# ── 4. 채널(내선) 시딩 (do_config_set_ivr_e164 → do_db_insert_t_ivr_channel) ───────────────────
# 파일 형식: e164,id,passwd,VOICE|CHAT,ip(미사용),시나리오경로
# 시나리오 서버 id: 같은 path 행이 있으면 재사용, 없으면 MAX+1 (빈 DB 에서 설치 스크립트 결과 1..N 과 동일).
# 채널은 INSERT IGNORE — 운영 중 수정분 보존, 다른 IVR_ID 가 쓰는 내선(PK 중복)은 건너뛰고 경고 (매뉴얼 IVR_ID=2 중복 오류 대응).
seed_channels() {
  [ "$IVR_REGISTER" = "on" ] && [ "$IVR_CHANNEL_SEED" != "off" ] || return 0
  local file="$IVR_CHANNEL_FILE" mine
  if [ ! -f "$file" ]; then
    [ "$IVR_ID" = "1" ] || { log "채널 파일 없음 & IVR_ID=$IVR_ID — 채널 시딩 생략 (매뉴얼: IVR_ID≥2 는 DB 에서 직접 설정)"; return 0; }
    file="$DIST/conf/SITE_IVR_E164.TXT"
  fi
  mine=$(dbq "select count(*) from t_ivr_channel where ivr_id=${IVR_ID}")
  if [ "$IVR_CHANNEL_SEED" = "auto" ] && [ "${mine:-0}" -gt 0 ]; then
    log "채널 ${mine}건 존재 — 시딩 생략 (IVR_CHANNEL_SEED=always 로 강제)"; return 0
  fi
  [ "$file" = "$DIST/conf/SITE_IVR_E164.TXT" ] && warn "채널 ← 패키지 샘플(SITE_IVR_E164.TXT, 테스트 내선) — 운영은 Secret aicc-ivr-channels 사용"
  local e164 id pw kind ip path sid st added=0 skipped=0
  while IFS=, read -r e164 id pw kind ip path _; do
    e164=$(echo "$e164" | tr -d '[:space:]'); path=$(echo "${path:-}" | tr -d '[:space:]\r')
    [ -n "$e164" ] && [ "${e164:0:1}" != "#" ] && [ -n "$path" ] || continue
    sid=$(dbq "select server_id from t_ivr_scenario_server where path='$(sqlq "$path")' order by server_id limit 1")
    if [ -z "$sid" ]; then
      sid=$(dbq "select ifnull(max(server_id),0)+1 from t_ivr_scenario_server")
      dbq "INSERT INTO t_ivr_scenario_server (server_id, ip, port, path, description, update_time)
           VALUES (${sid}, '${IVR_IP}', ${NODERED_PORT}, '$(sqlq "$path")', 'NODE-RED_${sid}', now())"
    fi
    st=1; [ "$(echo "$kind" | tr -d '[:space:]')" = "VOICE" ] || st=2
    local r; r=$(dbq "INSERT IGNORE INTO t_ivr_channel (e164, id, passwd, service_type, server_id, ivr_id, voice_default, use_yn,
                 description, cti_id, tenant_id, regist_date, update_time)
               VALUES ('$(sqlq "$e164")', '$(sqlq "$id")', '$(sqlq "$pw")', ${st}, ${sid}, ${IVR_ID}, '$(sqlq "$IVR_VOICE_DIR")', 1,
                 '$( [ $st = 1 ] && echo VOICE || echo CHAT )_$(sqlq "$e164")', ${IVR_CTI_ID}, 1, now(), now()); select row_count()")
    if [ "$r" = "1" ]; then added=$((added+1)); else skipped=$((skipped+1)); warn "내선 $e164 이미 존재(다른 IVR_ID 일 수 있음) — 건너뜀"; fi
  done < "$file"
  log "채널 시딩: 추가 ${added} / 건너뜀 ${skipped} ← $(basename "$file")"
}

# ── 5. 시나리오 서버 IP 추종 + t_version ─────────────────────────────────────────────────
# Node-RED 는 같은 파드(hostNetwork)라 IVR_IP 가 곧 시나리오 서버 IP. 파드가 다른 노드로 옮겨지면 IP 가 바뀌므로
# 이 IVR_ID 의 채널이 참조하는 시나리오 서버 행만 매 기동 갱신한다(다른 IVR 의 행은 건드리지 않음).
sync_scenario_servers() {
  [ "$IVR_REGISTER" = "on" ] || return 0
  local n
  n=$(dbq "UPDATE t_ivr_scenario_server s JOIN (SELECT DISTINCT server_id FROM t_ivr_channel WHERE ivr_id=${IVR_ID}) c
           ON s.server_id=c.server_id SET s.ip='${IVR_IP}', s.port=${NODERED_PORT}; select row_count()")
  if [ "$(dbq "select count(*) from t_ivr_scenario_server")" = "0" ]; then   # 채널 없이 설치: 설치 스크립트 기본 행
    dbq "INSERT INTO t_ivr_scenario_server (server_id, ip, port, path, description, update_time)
         VALUES (1, '${IVR_IP}', ${NODERED_PORT}, '/uivr', 'NODE-RED_1', now())"
  fi
  [ "${n:-0}" -gt 0 ] && log "시나리오 서버 ${n}건 → ${IVR_IP}:${NODERED_PORT}"
  local ver; ver=$(sed -n 's/^[0-9-]* : UIVR \([0-9.]*\).*/\1/p' "$BIN/README-version.txt" 2>/dev/null | head -1)
  dbq "INSERT INTO t_version (ip, port, remote_ip, remote_port, install_script, install_time, ivr_version, rtp_start_port, max_channel, use_voice)
       VALUES ('${IVR_IP}', ${IVR_SIP_LOCAL_PORT}, '${IVR_SIP_REMOTE_IP}', ${IVR_SIP_REMOTE_PORT}, 'container_${ver}', now(), '${ver}', ${IVR_RTP_START_PORT}, ${IVR_MAX_CALL}, 1)
       ON DUPLICATE KEY UPDATE remote_ip=VALUES(remote_ip), remote_port=VALUES(remote_port), update_script=VALUES(install_script),
         update_time=now(), ivr_version=VALUES(ivr_version), rtp_start_port=VALUES(rtp_start_port), max_channel=VALUES(max_channel)" \
    || warn "t_version 갱신 실패(무시)"
}

print_summary() {
  cat <<EOF
[ivr-entrypoint] ─── Configuration (TUI 확인 화면과 동일 항목) ───
 [IP]                  : ${IVR_IP}   [IVR CALL SERVER ID] : ${IVR_ID}
 [DB]   HOST/PORT/NAME : ${IVR_DB_HOST}(${DB_IP}):${IVR_DB_PORT}/${IVR_DB_NAME}  USER : ${IVR_DB_USER}
 [SIP]  REALM          : ${IVR_SIP_REALM}
        SIP (PBX)      : ${IVR_SIP_REMOTE_IP}:${IVR_SIP_REMOTE_PORT}
        SIP (IVR)      : ${IVR_IP}:${IVR_SIP_LOCAL_PORT} ${IVR_SIP_TRANSPORT}
        RTP            : ${IVR_RTP_START_PORT}~${IVR_RTP_END_PORT} (MAX CALL ${IVR_MAX_CALL})  MEDIA PORT : ${IVR_MEDIA_PORT}
 [CUBE] ACTIVE/STANDBY : ${CTI_IP1:-n/a}/${CTI_IP2:-null}:${IVR_CTI_PORT}  SID ${IVR_CTI_SID}  LISTENER ${IVR_CTI_APPNAME}  (use=${IVR_CTI_USE})
 [NODE-RED]            : ${IVR_IP}:${NODERED_PORT}
EOF
}

render_all() {
  validate; seed_dirs; render_database; render_json; apply_confd
  wait_db; init_db; register_ivr; seed_channels; sync_scenario_servers
  print_summary
}

# ── 기동/종료 (UIVR.service: nxstart.sh start|stop 을 포그라운드 감독으로) ────────────────────
# nxstart.sh → nxmonitor.sh(데몬): nxmonitor.conf 의 nxwatchdog/nxivrmedia/nxivrcall 을 1초 주기로 감시·재기동 (TUI MONITOR=on)
monitor_pid() { cat "$BIN/.nxmonitor.pid" 2>/dev/null; }
start_engine() {
  cd "$BIN" || die "cd $BIN"
  rm -f "$BIN/.nxmonitor.pid"
  log "nxstart.sh start"
  ./nxstart.sh start 2>&1 | sed 's/^/[nxstart] /'
}
stop_engine() {
  cd "$BIN" || return
  log "nxstart.sh stop"
  timeout "$IVR_STOP_TIMEOUT" ./nxstart.sh stop 2>&1 | sed 's/^/[nxstop] /' \
    || { warn "${IVR_STOP_TIMEOUT}s 내 미종료 — nxstart.sh force"; ./nxstart.sh force >/dev/null 2>&1; }
  pkill -9 -f "$BIN/nxwatchdog" 2>/dev/null
  log "정지 완료"
}
wait_ready() {
  local n=0
  until ivr-health.sh --ready >/dev/null 2>&1; do
    sleep 1; n=$((n+1))
    [ $n -ge "$IVR_START_TIMEOUT" ] && { warn "${IVR_START_TIMEOUT}s 내 기동 미완료: $(ivr-health.sh --ready)"; return 1; }
  done
  log "기동 완료 (${n}s) — $(ps -o pid=,comm= -u "$(id -u)" | awk '/nxivr|nxwatchdog|nxmonitor/{printf "%s(%s) ", $2, $1}')"
}

run() {
  render_all
  trap 'log "SIGTERM 수신"; stop_engine; exit 0' TERM INT
  start_engine
  wait_ready || { stop_engine; exit 1; }
  # 감독 루프: nxmonitor 데몬(재기동 담당)이 사라지면 컨테이너를 종료해 k8s 가 재시작하게 한다
  while sleep 5 & wait $!; do
    local p; p=$(monitor_pid)
    { [ -n "$p" ] && kill -0 "$p" 2>/dev/null; } || { warn "nxmonitor 소멸 — 종료"; stop_engine; exit 1; }
  done
}

case "${1:-run}" in
  run)    run ;;
  render) RENDER_ONLY=1; validate; seed_dirs; render_json; print_summary; for f in nxivrcall.json nxivrmedia.json; do echo "===== config/$f"; cat "$CONF/$f"; done ;;
  shell)  exec /bin/bash ;;
  *)      exec "$@" ;;
esac
