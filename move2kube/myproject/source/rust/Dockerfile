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


FROM docker.io/library/rust:1 as builder
WORKDIR /rust
COPY . .
RUN cargo build --release

FROM registry.access.redhat.com/ubi8/ubi-minimal:8.3-201
WORKDIR /rust
COPY --from=builder /rust/target/release/rust /rust/
COPY --from=builder /rust/Rocket.toml /rust/
ENV ROCKET_ADDRESS=0.0.0.0
EXPOSE 8085
CMD ["./rust"]
