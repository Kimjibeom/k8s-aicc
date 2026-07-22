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

# 톰캣은 원본 서버(build-push.sh의 APP_HOST)에서 tar로 가져온 것을 그대로 사용.
# 따라서 포트 등 서버 설정은 원본의 conf/server.xml을 따름 (agent 8080 / admin 80).
# 주의: 리포의 server.xml은 여기서 COPY하지 않아 미사용 상태 (PROJECT-REVIEW 2.2 — COPY 추가 or 삭제 결정 필요)
COPY tomcat/ /opt/tomcat/
COPY setenv.sh  /opt/tomcat/bin/setenv.sh

RUN mkdir -p /usr/local/src/config /mnt/aiccnas \
 && chmod +x /opt/tomcat/bin/*.sh \
 && rm -rf /opt/tomcat/logs/* /opt/tomcat/work/* /opt/tomcat/temp/* 2>/dev/null || true

EXPOSE 8080
CMD ["/opt/tomcat/bin/catalina.sh", "run"]
