# Do not edit! This file was generated via Makefile
FROM openshift/origin-release:golang-1.13 AS builder

WORKDIR ${GOPATH}/src/knative.dev/serving
COPY . .
RUN go build -o /tmp/autoscaler-hpa ./cmd/autoscaler-hpa

FROM openshift/origin-base
COPY --from=builder /tmp/autoscaler-hpa /ko-app/autoscaler-hpa

USER 65532
ENTRYPOINT ["/ko-app/autoscaler-hpa"]