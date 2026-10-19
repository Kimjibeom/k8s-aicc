:: Copyright IBM Corporation 2021
::
::  Licensed under the Apache License, Version 2.0 (the "License");
::   you may not use this file except in compliance with the License.
::   You may obtain a copy of the License at
::
::        http://www.apache.org/licenses/LICENSE-2.0
::
::  Unless required by applicable law or agreed to in writing, software
::  distributed under the License is distributed on an "AS IS" BASIS,
::  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
::  See the License for the specific language governing permissions and
::  limitations under the License.

:: Invoke as buildandpush_multiarchimages.bat <registry_url> <registry_namespace> <comma_separated_platforms>
:: Examples:
:: 1) buildandpush_multiarchimages.bat
:: 2) buildandpush_multiarchimages.bat index.docker.io your_registry_namespace
:: 3) buildandpush_multiarchimages.bat quay.io your_quay_username linux/amd64,linux/arm64,linux/s390x
:: 4) ./buildandpush_multiarchimages.bat docker
:: 5) ./buildandpush_multiarchimages.bat podman quay.io your_quay_username linux/amd64,linux/arm64,linux/s390x

@echo off
for /F "delims=" %%i in ("%cd%") do set basename="%%~ni"

if not %basename% == "scripts" (
    echo "please run this script from the 'scripts' directory"
    exit 1
)

REM go to the parent directory so that all the relative paths will be correct
cd ..

SET CONTAINER_RUNTIME=podman
IF "%1"!="" (
    SET CONTAINER_RUNTIME=%1%
    shift
)

IF "%3"=="" GOTO DEFAULT_PLATFORMS
SET PLATFORMS=%3%
GOTO REGISTRY

:DEFAULT_PLATFORMS
    SET PLATFORMS=linux/amd64,linux/arm64,linux/s390x,linux/ppc64le
	GOTO REGISTRY

:REGISTRY
    IF "%2"=="" GOTO DEFAULT_REGISTRY
    IF "%1"=="" GOTO DEFAULT_REGISTRY
    SET REGISTRY_URL=%1
    SET REGISTRY_NAMESPACE=%2
    GOTO DOCKER_CONTAINER_RUNTIME

:DEFAULT_REGISTRY
    SET REGISTRY_URL=quay.io
    SET REGISTRY_NAMESPACE=myproject
	GOTO DOCKER_CONTAINER_RUNTIME

:DOCKER_CONTAINER_RUNTIME
	IF NOT "%CONTAINER_RUNTIME%" == "docker" GOTO PODMAN_CONTAINER_RUNTIME
	GOTO MAIN

:PODMAN_CONTAINER_RUNTIME
	IF NOT "%CONTAINER_RUNTIME%" == "podman" GOTO UNSUPPORTED_BUILD_SYSTEM
	GOTO MAIN

:UNSUPPORTED_BUILD_SYSTEM
    echo 'Unsupported build system passed as an argument for pushing the images.'
    GOTO SKIP

:MAIN
:: Uncomment the below line if you want to enable login before pushing
:: docker login %REGISTRY_URL%
echo "building and pushing image golang"
pushd source\golang
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/golang . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/golang
    podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/golang .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/golang
)
popd
echo "building and pushing image java-gradle-buildstage"
pushd source\java-gradle
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile.buildstage  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle-buildstage . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle-buildstage
    podman build --platform ${PLATFORMS} -f Dockerfile.buildstage --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle-buildstage .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle-buildstage
)
popd
echo "building and pushing image java-maven-buildstage"
pushd source\java-maven
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile.buildstage  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven-buildstage . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven-buildstage
    podman build --platform ${PLATFORMS} -f Dockerfile.buildstage --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven-buildstage .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven-buildstage
)
popd
echo "building and pushing image nodejs"
pushd source\nodejs
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/nodejs . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/nodejs
    podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/nodejs .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/nodejs
)
popd
echo "building and pushing image php"
pushd source\php
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/php . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/php
    podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/php .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/php
)
popd
echo "building and pushing image django"
pushd source\django
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/django . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/django
    podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/django .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/django
)
popd
echo "building and pushing image python"
pushd source\python
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/python . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/python
    podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/python .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/python
)
popd
echo "building and pushing image ruby"
pushd source\ruby
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/ruby . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/ruby
    podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/ruby .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/ruby
)
popd
echo "building and pushing image rust"
pushd source\rust
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/rust . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/rust
    podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/rust .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/rust
)
popd
echo "building and pushing image java-gradle"
pushd source\java-gradle
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle
    podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-gradle
)
popd
echo "building and pushing image java-maven"
pushd source\java-maven
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven
    podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-maven
)
popd
echo "building and pushing image java-war"
pushd source\java-war
IF  "%CONTAINER_RUNTIME%" == "docker" (
    docker buildx build --platform ${PLATFORMS} -f Dockerfile  --push --tag ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-war . 
) ELSE ( 
    podman manifest create ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-war
    podman build --platform ${PLATFORMS} -f Dockerfile --manifest ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-war .
    podman manifest push ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/java-war
)
popd

echo "done"

:SKIP
