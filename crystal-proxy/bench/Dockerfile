# Static Linux binaries of the proxy and of the benchmark backend.
FROM crystallang/crystal:latest-alpine AS build
WORKDIR /src
COPY shard.yml ./
COPY src ./src
COPY bench/backend.cr ./bench/backend.cr
RUN crystal build --release --static src/main.cr -o /crystal-proxy \
 && crystal build --release --static bench/backend.cr -o /bench-backend

FROM alpine:3.20
COPY --from=build /crystal-proxy /usr/local/bin/crystal-proxy
COPY --from=build /bench-backend /usr/local/bin/bench-backend
