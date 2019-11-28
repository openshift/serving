# Do not edit! This file was generated via Makefile
FROM openshift/origin-release:golang-1.13 AS builder

WORKDIR ${GOPATH}/src/knative.dev/serving
COPY . .
RUN go build -o /tmp/grpc-ping ./cmd/grpc-ping

FROM openshift/origin-base
COPY --from=builder /tmp/grpc-ping /ko-app/grpc-ping

USER 65532
ENTRYPOINT ["/ko-app/grpc-ping"]