#!/bin/sh
export JAVA_HOME=/opt/java
export JAVA_OPTS="$JAVA_OPTS -server -Xms2048m -Xmx2048m \
 -Duser.timezone=Asia/Seoul -Dfile.encoding=UTF-8 \
 -Djasypt.encryptor.password=${JASYPT_ENCRYPTOR_PASSWORD}"
