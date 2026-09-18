# Multi-stage build for the two long-running backend processes: the gateway
# (phone-facing API) and the indexer (the one chain reader — ADR 5). Built
# from one image so both binaries always come from the exact same commit;
# which one runs is picked by CMD/entrypoint at `docker run` time, not by
# building two separate images that could drift apart.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/gateway ./cmd/gateway
RUN CGO_ENABLED=0 go build -o /out/indexer ./cmd/indexer

FROM alpine:3.20
# ERC-4337 endpoints and Monad RPC are always TLS, so the base image needs
# real CA certs or every outbound HTTPS call fails with a confusing
# "certificate signed by unknown authority" the moment this runs somewhere
# that isn't this build machine's own trust store.
RUN apk add --no-cache ca-certificates
COPY --from=build /out/gateway /usr/local/bin/gateway
COPY --from=build /out/indexer /usr/local/bin/indexer
