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

# Invoke as ./buildandpush_multiarchimages.sh <registry_url> <registry_namespace> <comma_separated_platforms>
# Examples:
# 1) ./buildandpush_multiarchimages.sh
# 2) ./buildandpush_multiarchimages.sh index.docker.io your_registry_namespace
# 3) ./buildandpush_multiarchimages.sh quay.io your_quay_username linux/amd64,linux/arm64,linux/s390x
# 4) ./buildandpush_multiarchimages.sh docker
# 5) ./buildandpush_multiarchimages.sh podman quay.io your_quay_username linux/amd64,linux/arm64,linux/s390x

if [[ "$(basename "$PWD")" != 'scripts' ]] ; then
  echo 'please run this script from the "scripts" directory'
  exit 1
fi

cd .. # go to the parent directory so that all the relative paths will be correct

REGISTRY_URL=quay.io
REGISTRY_NAMESPACE=myproject
PLATFORMS="linux/amd64,linux/arm64,linux/s390x,linux/ppc64le"
CONTAINER_RUNTIME=podman

if [ "$#" -gt 0 ] && [[ "$1" == "docker" || "$1" == "podman" ]]; then
  CONTAINER_RUNTIME=$1
  shift;
fi

if [ "$#" -gt 1 ]; then
  REGISTRY_URL=$1
  REGISTRY_NAMESPACE=$2
fi
if [ "$#" -eq 3 ]; then
  PLATFORMS=$3
fi

if [ "${CONTAINER_RUNTIME}" != "docker" ] && [ "${CONTAINER_RUNTIME}" != "podman" ]; then
   echo 'Unsupported container runtime passed as an argument for building the images: '"${CONTAINER_RUNTIME}"
   exit 1
fi


# Uncomment the below line if you want to enable login before pushing
# docker login ${REGISTRY_URL}
echo 'building and pushing image golang'
cd source/golang
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/golang .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/golang
  podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/golang .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/golang
fi

cd -
echo 'building and pushing image java-gradle-buildstage'
cd source/java-gradle
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile.buildstage  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle-buildstage .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle-buildstage
  podman build --platform ${PLATFORMS} -f Dockerfile.buildstage --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle-buildstage .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle-buildstage
fi

cd -
echo 'building and pushing image java-maven-buildstage'
cd source/java-maven
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile.buildstage  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven-buildstage .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven-buildstage
  podman build --platform ${PLATFORMS} -f Dockerfile.buildstage --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven-buildstage .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven-buildstage
fi

cd -
echo 'building and pushing image nodejs'
cd source/nodejs
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/nodejs .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/nodejs
  podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/nodejs .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/nodejs
fi

cd -
echo 'building and pushing image php'
cd source/php
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/php .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/php
  podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/php .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/php
fi

cd -
echo 'building and pushing image django'
cd source/django
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/django .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/django
  podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/django .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/django
fi

cd -
echo 'building and pushing image python'
cd source/python
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/python .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/python
  podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/python .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/python
fi

cd -
echo 'building and pushing image ruby'
cd source/ruby
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/ruby .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/ruby
  podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/ruby .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/ruby
fi

cd -
echo 'building and pushing image rust'
cd source/rust
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/rust .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/rust
  podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/rust .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/rust
fi

cd -
echo 'building and pushing image java-gradle'
cd source/java-gradle
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle
  podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle
fi

cd -
echo 'building and pushing image java-maven'
cd source/java-maven
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven
  podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven
fi

cd -
echo 'building and pushing image java-war'
cd source/java-war
if [ "${CONTAINER_RUNTIME}" == "docker" ]
then
  docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-war .
else 
  podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-war
  podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-war .
  podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-war
fi

cd -

echo 'done'
