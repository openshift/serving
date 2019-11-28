# Do not edit! This file was generated via Makefile
FROM openshift/origin-release:golang-1.13 AS builder

WORKDIR ${GOPATH}/src/knative.dev/serving
COPY . .
RUN go build -o /tmp/pizzaplanetv1 ./cmd/pizzaplanetv1

FROM openshift/origin-base
COPY --from=builder /tmp/pizzaplanetv1 /ko-app/pizzaplanetv1

USER 65532
ENTRYPOINT ["/ko-app/pizzaplanetv1"]