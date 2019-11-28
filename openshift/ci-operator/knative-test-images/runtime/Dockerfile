# Do not edit! This file was generated via Makefile
FROM openshift/origin-release:golang-1.13 AS builder

WORKDIR ${GOPATH}/src/knative.dev/serving
COPY . .
RUN go build -o /tmp/runtime ./cmd/runtime

FROM openshift/origin-base
COPY --from=builder /tmp/runtime /ko-app/runtime

USER 65532
ENTRYPOINT ["/ko-app/runtime"]