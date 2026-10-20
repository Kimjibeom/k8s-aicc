여기에 `flows.json` 을 두면 `10-make-configmap.sh` 가 configmap/aicc-<GROUP>-ivr-flows 로 만들고, nodered 컨테이너의
/etc/ivr/flows/flows.json 에 마운트된다 (ConfigMap 1MB 제한 — 패키지 기본 시나리오는 약 40KB).
- NODERED_FLOWS_MODE=seed (기본): PVC 에 flows 가 없을 때 패키지 템플릿 대신 이 파일로 시딩 (CONFIG 탭 DB 노드는 env 로 자동 설정)
- NODERED_FLOWS_MODE=configmap : 매 기동 이 파일로 덮어씀 — 시나리오를 git 으로 관리하는 무상태 운영. 편집기 Deploy 분은 재기동 시 사라짐
