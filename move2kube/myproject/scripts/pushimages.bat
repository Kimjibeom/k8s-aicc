:: Copyright IBM Corporation 2021
::
::  Licensed under the Apache License, Version 2.0 (the "License");
::  you may not use this file except in compliance with the License.
::  You may obtain a copy of the License at
::
::        http://www.apache.org/licenses/LICENSE-2.0
::
::  Unless required by applicable law or agreed to in writing, software
::  distributed under the License is distributed on an "AS IS" BASIS,
::  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
::  See the License for the specific language governing permissions and
::  limitations under the License.

:: Invoke as pushimages.bat <registry_url> <registry_namespace> <container_runtime>
:: Examples:
:: 1) pushimages.bat
:: 2) pushimages.bat quay.io your_quay_username
:: 3) pushimages.bat index.docker.io your_registry_namespace podman

@echo off
IF "%3"=="" GOTO DEFAULT_CONTAINER_RUNTIME
SET CONTAINER_RUNTIME=%3%
GOTO REGISTRY

:DEFAULT_CONTAINER_RUNTIME
    SET CONTAINER_RUNTIME=docker
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
:: %CONTAINER_RUNTIME% login %REGISTRY_URL%

echo "pushing image java-war"
%CONTAINER_RUNTIME% tag java-war %REGISTRY_URL%/%REGISTRY_NAMESPACE%/java-war
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/java-war

echo "pushing image golang"
%CONTAINER_RUNTIME% tag golang %REGISTRY_URL%/%REGISTRY_NAMESPACE%/golang
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/golang

echo "pushing image java-maven"
%CONTAINER_RUNTIME% tag java-maven %REGISTRY_URL%/%REGISTRY_NAMESPACE%/java-maven
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/java-maven

echo "pushing image java-gradle"
%CONTAINER_RUNTIME% tag java-gradle %REGISTRY_URL%/%REGISTRY_NAMESPACE%/java-gradle
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/java-gradle

echo "pushing image rust"
%CONTAINER_RUNTIME% tag rust %REGISTRY_URL%/%REGISTRY_NAMESPACE%/rust
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/rust

echo "pushing image ruby"
%CONTAINER_RUNTIME% tag ruby %REGISTRY_URL%/%REGISTRY_NAMESPACE%/ruby
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/ruby

echo "pushing image python"
%CONTAINER_RUNTIME% tag python %REGISTRY_URL%/%REGISTRY_NAMESPACE%/python
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/python

echo "pushing image django"
%CONTAINER_RUNTIME% tag django %REGISTRY_URL%/%REGISTRY_NAMESPACE%/django
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/django

echo "pushing image php"
%CONTAINER_RUNTIME% tag php %REGISTRY_URL%/%REGISTRY_NAMESPACE%/php
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/php

echo "pushing image nodejs"
%CONTAINER_RUNTIME% tag nodejs %REGISTRY_URL%/%REGISTRY_NAMESPACE%/nodejs
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/nodejs

echo "pushing image java-maven-buildstage"
%CONTAINER_RUNTIME% tag java-maven-buildstage %REGISTRY_URL%/%REGISTRY_NAMESPACE%/java-maven-buildstage
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/java-maven-buildstage

echo "pushing image java-gradle-buildstage"
%CONTAINER_RUNTIME% tag java-gradle-buildstage %REGISTRY_URL%/%REGISTRY_NAMESPACE%/java-gradle-buildstage
%CONTAINER_RUNTIME% push %REGISTRY_URL%/%REGISTRY_NAMESPACE%/java-gradle-buildstage

echo "done"

:SKIP
