#!/usr/bin/env bash
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

# Invoke as ./buildimages.sh <container_runtime>
# Examples:
# 1) ./buildimages.sh
# 2) ./buildimages.sh podman

if [[ "$(basename "$PWD")" != 'scripts' ]] ; then
  echo 'please run this script from the "scripts" directory'
  exit 1
fi
CONTAINER_RUNTIME=podman
if [ "$#" -eq 1 ]; then
    CONTAINER_RUNTIME=$1
fi
if [ "${CONTAINER_RUNTIME}" != "docker" ] && [ "${CONTAINER_RUNTIME}" != "podman" ]; then
   echo 'Unsupported container runtime passed as an argument for building the images: '"${CONTAINER_RUNTIME}"
   exit 1
fi
cd .. # go to the parent directory so that all the relative paths will be correct

echo 'building image golang'
cd source/golang
${CONTAINER_RUNTIME} build -f Dockerfile -t golang .
cd -

echo 'building image java-gradle-buildstage'
cd source/java-gradle
${CONTAINER_RUNTIME} build -f Dockerfile.buildstage -t java-gradle-buildstage .
cd -

echo 'building image java-maven-buildstage'
cd source/java-maven
${CONTAINER_RUNTIME} build -f Dockerfile.buildstage -t java-maven-buildstage .
cd -

echo 'building image nodejs'
cd source/nodejs
${CONTAINER_RUNTIME} build -f Dockerfile -t nodejs .
cd -

echo 'building image php'
cd source/php
${CONTAINER_RUNTIME} build -f Dockerfile -t php .
cd -

echo 'building image django'
cd source/django
${CONTAINER_RUNTIME} build -f Dockerfile -t django .
cd -

echo 'building image python'
cd source/python
${CONTAINER_RUNTIME} build -f Dockerfile -t python .
cd -

echo 'building image ruby'
cd source/ruby
${CONTAINER_RUNTIME} build -f Dockerfile -t ruby .
cd -

echo 'building image rust'
cd source/rust
${CONTAINER_RUNTIME} build -f Dockerfile -t rust .
cd -

echo 'building image java-gradle'
cd source/java-gradle
${CONTAINER_RUNTIME} build -f Dockerfile -t java-gradle .
cd -

echo 'building image java-maven'
cd source/java-maven
${CONTAINER_RUNTIME} build -f Dockerfile -t java-maven .
cd -

echo 'building image java-war'
cd source/java-war
${CONTAINER_RUNTIME} build -f Dockerfile -t java-war .
cd -

echo 'done'
