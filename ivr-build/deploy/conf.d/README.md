여기에 둔 파일은 `10-make-configmap.sh` 가 configmap/aicc-<GROUP>-ivr-confd 로 만들고, ivr 컨테이너의
/etc/ivr/conf.d 에 마운트되어 **렌더링이 끝난 뒤** `$NEXUS_HOME/config/<같은 이름>` 을 통째로 덮어쓴다.
ivr.env 로 표현되지 않는 항목(예: nxivrmedia.json 의 servers 다중화)을 바꿀 때만 사용. 비워 두면 아무 일도 하지 않는다.
