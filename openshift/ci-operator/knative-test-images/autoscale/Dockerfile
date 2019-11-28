# Do not edit! This file was generated via Makefile
FROM openshift/origin-release:golang-1.13 AS builder

WORKDIR ${GOPATH}/src/knative.dev/serving
COPY . .
RUN go build -o /tmp/autoscale ./cmd/autoscale

FROM openshift/origin-base
COPY --from=builder /tmp/autoscale /ko-app/autoscale

USER 65532
ENTRYPOINT ["/ko-app/autoscale"]