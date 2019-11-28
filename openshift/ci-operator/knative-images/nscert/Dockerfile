# Do not edit! This file was generated via Makefile
FROM openshift/origin-release:golang-1.13 AS builder

WORKDIR ${GOPATH}/src/knative.dev/serving
COPY . .
RUN go build -o /tmp/nscert ./cmd/nscert

FROM openshift/origin-base
COPY --from=builder /tmp/nscert /ko-app/nscert

USER 65532
ENTRYPOINT ["/ko-app/nscert"]