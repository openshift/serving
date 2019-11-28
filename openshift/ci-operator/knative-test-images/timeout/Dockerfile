# Do not edit! This file was generated via Makefile
FROM openshift/origin-release:golang-1.13 AS builder

WORKDIR ${GOPATH}/src/knative.dev/serving
COPY . .
RUN go build -o /tmp/timeout ./cmd/timeout

FROM openshift/origin-base
COPY --from=builder /tmp/timeout /ko-app/timeout

USER 65532
ENTRYPOINT ["/ko-app/timeout"]