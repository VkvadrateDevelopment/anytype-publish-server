FROM golang:1.26 AS builder

ENV CGO_ENABLED=0 GOOS=linux
COPY . /app
WORKDIR /app
RUN go build -o output/anytype-publish-server ./cmd/server/server.go


FROM debian:stable-slim AS main
COPY --from=builder /app/output/ /opt/

WORKDIR /app
ENTRYPOINT ["/opt/anytype-publish-server", "-c", "/etc/any-type-publish-server/any-type-publish-server.yml"]
