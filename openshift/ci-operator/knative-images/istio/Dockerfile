# Do not edit! This file was generated via Makefile
FROM openshift/origin-release:golang-1.13 AS builder

WORKDIR ${GOPATH}/src/knative.dev/serving
COPY . .
RUN go build -o /tmp/istio ./cmd/istio

FROM openshift/origin-base
COPY --from=builder /tmp/istio /ko-app/istio

USER 65532
ENTRYPOINT ["/ko-app/istio"]