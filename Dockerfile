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

COPY tomcat/ /opt/tomcat/
COPY setenv.sh  /opt/tomcat/bin/setenv.sh

RUN mkdir -p /usr/local/src/config /mnt/aiccnas \
 && chmod +x /opt/tomcat/bin/*.sh \
 && rm -rf /opt/tomcat/logs/* /opt/tomcat/work/* /opt/tomcat/temp/* 2>/dev/null || true

EXPOSE 8080
CMD ["/opt/tomcat/bin/catalina.sh", "run"]
