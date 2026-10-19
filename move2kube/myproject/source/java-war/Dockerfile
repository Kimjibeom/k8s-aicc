#   Copyright IBM Corporation 2021
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

FROM registry.access.redhat.com/ubi8/ubi-minimal:latest
WORKDIR /usr/local
RUN microdnf update && microdnf install -y java-17-openjdk-devel wget tar gzip shadow-utils && microdnf clean all

# environment variables
ENV CATALINA_PID='/usr/local/tomcat10/temp/tomcat.pid' CATALINA_HOME='/usr/local/tomcat10' CATALINA_BASE='/usr/local/tomcat10'

# install tomcat
RUN wget https://archive.apache.org/dist/tomcat/tomcat-10/v10.0.16/bin/apache-tomcat-10.0.16.tar.gz && \
    tar -zxf apache-tomcat-10.0.16.tar.gz && \
    rm -f apache-tomcat-10.0.16.tar.gz && \
    mv apache-tomcat-10.0.16 tomcat10 && \
    rm -r "$CATALINA_BASE"/webapps/ROOT && \
    mkdir "$CATALINA_BASE"/webapps-javaee/ && \
    adduser -r tomcat && chown -R tomcat:root tomcat10 && \
    usermod -aG root tomcat && \
    chmod -R g+rwX tomcat10/
USER tomcat:root

COPY --chown=tomcat:root java-war.war "$CATALINA_BASE"/webapps-javaee/
EXPOSE 8080
CMD [ "/usr/local/tomcat10/bin/catalina.sh", "run" ]
