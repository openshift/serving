# Do not edit! This file was generated via Makefile
FROM openshift/origin-release:golang-1.13 AS builder

WORKDIR ${GOPATH}/src/knative.dev/serving
COPY . .
RUN go build -o /tmp/observed-concurrency ./cmd/observed-concurrency

FROM openshift/origin-base
COPY --from=builder /tmp/observed-concurrency /ko-app/observed-concurrency

USER 65532
ENTRYPOINT ["/ko-app/observed-concurrency"]